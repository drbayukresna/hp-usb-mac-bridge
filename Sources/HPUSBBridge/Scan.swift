// SPDX-License-Identifier: GPL-3.0-or-later
//
// LEDM flatbed scanning.
//
// Flow (all over the LEDM USB interface):
//   GET  /Scan/ScanCaps.xml            -> platen size and supported resolutions
//   GET  /Scan/Status.xml              -> scanner must be "Idle"
//   POST /Scan/Jobs  (ScanSettings)    -> 201 Created, Location: /Jobs/JobList/<n>
//   GET  <job>                         -> poll until a page is "ReadyToUpload" and has a BinaryURL
//   GET  <BinaryURL>                   -> the page image (JPEG)
//   GET  <job>                         -> poll until JobState is "Completed"
//
// Geometry in ScanSettings is expressed in 1/300 inch.

import Foundation

public enum ScanColorMode: String, CaseIterable, Sendable {
    case color = "Color"
    case gray = "Gray"
}

public enum ScanPaper: String, CaseIterable, Sendable {
    case a4, letter, legal, f4, a5, photo4x6 = "4x6", photo5x7 = "5x7", max

    /// Size in 1/300 inch.
    public var size300: (width: Int, height: Int)? {
        switch self {
        case .a4: return (2480, 3508)
        case .letter: return (2550, 3300)
        case .legal: return (2550, 4200)
        case .f4: return (2550, 3900)
        case .a5: return (1748, 2480)
        case .photo4x6: return (1200, 1800)
        case .photo5x7: return (1500, 2100)
        case .max: return nil
        }
    }
}

public struct ScanOptions: Sendable {
    public var resolution: Int = 300
    public var colorMode: ScanColorMode = .color
    public var paper: ScanPaper = .a4
    public var contentType: String = "Document"   // "Document" or "Photo"
    /// JPEG quality factor understood by HP firmware: lower = better quality (0...100).
    public var compressionQFactor: Int = 15

    public init() {}
}

public struct ScanCapabilities: Sendable {
    public var maxWidth300: Int
    public var maxHeight300: Int
    public var resolutions: [Int]
    public var colorModes: [String]
}

public enum ScanError: Error, CustomStringConvertible {
    case scannerBusy(String)
    case noJobLocation
    case jobFailed(String)
    case timeout(String)
    case unsupportedResolution(Int, [Int])

    public var description: String {
        switch self {
        case let .scannerBusy(state): return "Scanner is not idle (state: \(state)). Close the lid, wait, and try again."
        case .noJobLocation: return "Printer accepted the scan job but did not say where to find it."
        case let .jobFailed(state): return "Scan job failed (state: \(state))."
        case let .timeout(step): return "Timed out while \(step)."
        case let .unsupportedResolution(r, supported):
            return "Resolution \(r) dpi is not supported. Choose one of: \(supported.map(String.init).joined(separator: ", "))."
        }
    }
}

public final class LEDMScanner {
    public let client: LEDMClient
    public var log: (String) -> Void = { _ in }

    public init(client: LEDMClient) { self.client = client }

    public func capabilities() throws -> ScanCapabilities {
        let r = try client.http.get("/Scan/ScanCaps.xml")
        return LEDMScanParsers.capabilities(try XMLNodeView(data: r.body))
    }

    public func scannerState() throws -> String {
        let r = try client.http.get("/Scan/Status.xml")
        return try XMLNodeView(data: r.body).value("ScannerState") ?? "Unknown"
    }

    /// Scans one page from the flatbed and returns the JPEG data.
    public func scanPage(_ options: ScanOptions) throws -> Data {
        let caps = try? capabilities()
        if let caps, !caps.resolutions.isEmpty, !caps.resolutions.contains(options.resolution) {
            throw ScanError.unsupportedResolution(options.resolution, caps.resolutions)
        }

        let state = try scannerState()
        guard state.lowercased() == "idle" else { throw ScanError.scannerBusy(state) }

        var (width, height) = options.paper.size300 ?? (caps?.maxWidth300 ?? 2550, caps?.maxHeight300 ?? 3508)
        if let caps {
            width = min(width, caps.maxWidth300)
            height = min(height, caps.maxHeight300)
        }

        let settings = LEDMScanParsers.scanSettingsXML(options: options, width300: width, height300: height)
        log("Starting scan: \(options.resolution) dpi, \(options.colorMode.rawValue), \(options.paper.rawValue)")
        let created = try client.http.request("POST", "/Scan/Jobs", body: Data(settings.utf8), contentType: "text/xml")
        guard created.status == 201 || created.isSuccess else {
            throw HTTPError.unexpectedStatus(created.status, created.reason, path: "/Scan/Jobs")
        }
        guard let location = created.header("Location") else { throw ScanError.noJobLocation }
        let jobPath = LEDMScanParsers.path(fromLocation: location)
        log("Scan job: \(jobPath)")

        // Wait for the page to be ready.
        let binaryURL = try poll(step: "waiting for the scanner to capture the page", timeout: 180) { () -> String? in
            let job = try XMLNodeView(data: client.http.get(jobPath).body)
            let jobState = job.value("JobState") ?? ""
            if ["canceled", "cancelled", "aborted", "failed"].contains(jobState.lowercased()) {
                throw ScanError.jobFailed(jobState)
            }
            return LEDMScanParsers.readyBinaryURL(job)
        }

        log("Downloading page from \(binaryURL)")
        let image = try client.http.get(binaryURL, timeout: 120)

        // Let the job finish so the scanner returns to Idle (ignore errors; the image is what matters).
        _ = try? poll(step: "finishing the scan job", timeout: 30) { () -> Bool? in
            let job = try XMLNodeView(data: client.http.get(jobPath).body)
            return (job.value("JobState")?.lowercased() == "completed") ? true : nil
        }
        return image.body
    }

    private func poll<T>(step: String, timeout: TimeInterval, interval: TimeInterval = 1,
                         _ body: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try body() { return value }
            Thread.sleep(forTimeInterval: interval)
        }
        throw ScanError.timeout(step)
    }
}

public enum LEDMScanParsers {
    public static func capabilities(_ xml: XMLNodeView) -> ScanCapabilities {
        let platen = xml.first("Platen") ?? xml
        let maxW = platen.value("MaxWidth").flatMap { Int($0) } ?? 2550
        let maxH = platen.value("MaxHeight").flatMap { Int($0) } ?? 3508
        var resolutions = Set<Int>()
        for r in platen.all("Resolution") {
            if let x = r.value("XResolution").flatMap({ Int($0) }) { resolutions.insert(x) }
        }
        let modes = Set(xml.all("ColorType").map(\.text))
        return ScanCapabilities(maxWidth300: maxW, maxHeight300: maxH,
                                resolutions: resolutions.sorted(), colorModes: modes.sorted())
    }

    public static func scanSettingsXML(options: ScanOptions, width300: Int, height300: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ScanSettings xmlns="http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19">
        <XResolution>\(options.resolution)</XResolution>
        <YResolution>\(options.resolution)</YResolution>
        <XStart>0</XStart>
        <YStart>0</YStart>
        <Width>\(width300)</Width>
        <Height>\(height300)</Height>
        <Format>Jpeg</Format>
        <CompressionQFactor>\(options.compressionQFactor)</CompressionQFactor>
        <ColorSpace>\(options.colorMode.rawValue)</ColorSpace>
        <BitDepth>8</BitDepth>
        <InputSource>Platen</InputSource>
        <GrayRendering>NTSC</GrayRendering>
        <ToneMap>
        <Gamma>1000</Gamma>
        <Brightness>1000</Brightness>
        <Contrast>1000</Contrast>
        <Highlite>179</Highlite>
        <Shadow>25</Shadow>
        </ToneMap>
        <ContentType>\(XMLEscape.escape(options.contentType))</ContentType>
        </ScanSettings>
        """
    }

    /// `Location` may be absolute (`http://localhost/Jobs/JobList/2`) or a path.
    public static func path(fromLocation location: String) -> String {
        if let url = URL(string: location), url.host != nil {
            return url.path.isEmpty ? "/" : url.path
        }
        return location.hasPrefix("/") ? location : "/" + location
    }

    /// Returns the BinaryURL of the first page that is ready to upload.
    public static func readyBinaryURL(_ job: XMLNodeView) -> String? {
        for page in job.all("PreScanPage") + job.all("ScanPage") {
            let state = page.value("PageState")?.lowercased() ?? ""
            if state == "readytoupload", let url = page.value("BinaryURL"), !url.isEmpty {
                return path(fromLocation: url)
            }
        }
        return nil
    }
}
