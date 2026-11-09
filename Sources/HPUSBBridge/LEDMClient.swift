// SPDX-License-Identifier: GPL-3.0-or-later
//
// High level access to the LEDM web services of an HP printer over USB.

import Foundation

public final class LEDMClient {
    public let http: HTTPOverUSB

    public init(http: HTTPOverUSB) { self.http = http }

    /// Opens the LEDM management interface of the first attached HP printer.
    public static func open(productID: Int? = nil,
                            selector: USBInterfaceSelector = .ledm,
                            verbose: Bool = false) throws -> LEDMClient {
        let transport = try USBBulkTransport(selector: selector, productID: productID)
        let http = HTTPOverUSB(transport: transport)
        http.verbose = verbose
        return LEDMClient(http: http)
    }

    /// Tries each LEDM interface in turn until one answers `probePath`.
    public static func openFirstResponding(productID: Int? = nil,
                                           candidates: [USBInterfaceSelector] = [.ledm, .ledmScan],
                                           probePath: String = "/DevMgmt/DiscoveryTree.xml",
                                           verbose: Bool = false) throws -> LEDMClient {
        var lastError: Error = USBTransportError.interfaceNotFound(candidates.first ?? .ledm)
        for selector in candidates {
            for skip in 0..<2 {
                do {
                    let transport = try USBBulkTransport(selector: selector, productID: productID, skip: skip)
                    let http = HTTPOverUSB(transport: transport)
                    http.verbose = verbose
                    http.responseTimeout = 5
                    let r = try http.request("GET", probePath)
                    if r.status < 500 {
                        http.responseTimeout = 15
                        if verbose {
                            FileHandle.standardError.write(Data("using LEDM interface \(selector) #\(transport.interfaceNumber)\n".utf8))
                        }
                        return LEDMClient(http: http)
                    }
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    // MARK: - Discovery

    /// Lists the resource paths the firmware advertises (useful for supporting new models).
    public func discoveryTree() throws -> [DiscoveryResource] {
        let xml = try XMLNodeView(data: http.get("/DevMgmt/DiscoveryTree.xml").body)
        return LEDMParsers.discoveryResources(xml)
    }

    // MARK: - Status & consumables

    public func productStatus() throws -> PrinterStatus {
        try LEDMParsers.status(XMLNodeView(data: http.get("/DevMgmt/ProductStatusDyn.xml").body))
    }

    public func consumables() throws -> [Consumable] {
        try LEDMParsers.consumables(XMLNodeView(data: http.get("/DevMgmt/ConsumableConfigDyn.xml").body))
    }

    public func productInfo() throws -> ProductInfo {
        try LEDMParsers.productInfo(XMLNodeView(data: http.get("/DevMgmt/ProductConfigDyn.xml").body))
    }

    // MARK: - Maintenance

    /// Asks the printer to run one of its internal maintenance/report jobs
    /// (e.g. printhead cleaning or a print-quality diagnostics page).
    ///
    /// Not every model accepts every job type; the printer answers with an
    /// HTTP error in that case. Use `supportedInternalPrintJobs()` to check.
    public func runInternalPrint(_ job: InternalPrintJob) throws {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ipdyn:InternalPrintDyn xmlns:ipdyn="http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21" \
        xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
        <ipdyn:JobType>\(XMLEscape.escape(job.rawValue))</ipdyn:JobType>
        </ipdyn:InternalPrintDyn>
        """
        let r = try http.request("PUT", "/DevMgmt/InternalPrintDyn.xml",
                                 body: Data(body.utf8), contentType: "text/xml")
        guard r.isSuccess else {
            throw HTTPError.unexpectedStatus(r.status, r.reason, path: "/DevMgmt/InternalPrintDyn.xml (\(job.rawValue))")
        }
    }

    /// Job types the firmware lists as supported, if it publishes a capability document.
    public func supportedInternalPrintJobs() throws -> [String] {
        let r = try http.request("GET", "/DevMgmt/InternalPrintCap.xml")
        guard r.isSuccess else { return [] }
        return try XMLNodeView(data: r.body).all("JobType").map(\.text)
    }
}

public enum InternalPrintJob: String, CaseIterable, Sendable {
    case cleaning = "cleaningPage"
    case cleaningLevel2 = "cleaningPageLevel2"
    case cleaningLevel3 = "cleaningPageLevel3"
    case alignment = "alignmentPage"
    case printQualityDiagnostics = "pqDiagnosticsPage"
    case configuration = "configurationPage"
    case selfTest = "selfTestPage"

    public var displayName: String {
        switch self {
        case .cleaning: return "Printhead cleaning (level 1)"
        case .cleaningLevel2: return "Printhead cleaning (level 2)"
        case .cleaningLevel3: return "Printhead cleaning (level 3)"
        case .alignment: return "Printhead alignment page"
        case .printQualityDiagnostics: return "Print quality diagnostics page"
        case .configuration: return "Configuration page"
        case .selfTest: return "Self-test page"
        }
    }
}

// MARK: - Models

public struct DiscoveryResource: Sendable {
    public var type: String
    public var path: String
}

public struct PrinterStatus: Sendable {
    public var category: String          // e.g. "ready", "processing", "inkSystemFailure"
    public var alerts: [Alert]

    public struct Alert: Sendable {
        public var id: String
        public var severity: String?
        public var color: String?
    }

    public var isReady: Bool { category.lowercased() == "ready" }
}

public struct Consumable: Sendable {
    public var label: String              // "K", "CMY", "C", ...
    public var color: String              // human readable
    public var percentRemaining: Int?
    public var state: String?
    public var type: String?

    public var bar: String {
        guard let p = percentRemaining else { return "[ unknown ]" }
        let filled = max(0, min(20, p / 5))
        return "[" + String(repeating: "#", count: filled) + String(repeating: ".", count: 20 - filled) + "]"
    }
}

public struct ProductInfo: Sendable {
    public var makeAndModel: String?
    public var serialNumber: String?
    public var firmware: String?
    public var productNumber: String?
}

// MARK: - Parsers (pure functions, unit tested with captured fixtures)

public enum LEDMParsers {
    public static func discoveryResources(_ xml: XMLNodeView) -> [DiscoveryResource] {
        xml.all("SupportedTree").compactMap { tree in
            guard let path = tree.value("ResourceURI") else { return nil }
            return DiscoveryResource(type: tree.value("ResourceType") ?? "", path: path)
        } + xml.all("SupportedIfc").compactMap { ifc in
            guard let path = ifc.value("ResourceURI") else { return nil }
            return DiscoveryResource(type: ifc.value("ResourceType") ?? "", path: path)
        }
    }

    public static func status(_ xml: XMLNodeView) -> PrinterStatus {
        let category = xml.first("Status")?.value("StatusCategory") ?? xml.value("StatusCategory") ?? "unknown"
        let alerts = xml.all("Alert").map { a in
            PrinterStatus.Alert(id: a.value("ProductStatusAlertID") ?? a.value("AlertID") ?? "unknown",
                                severity: a.value("Severity"),
                                color: a.value("Color"))
        }
        return PrinterStatus(category: category, alerts: alerts)
    }

    public static func consumables(_ xml: XMLNodeView) -> [Consumable] {
        xml.all("ConsumableInfo").compactMap { info in
            let label = info.value("ConsumableLabelCode") ?? info.value("ConsumableTypeEnum") ?? "?"
            let typeEnum = info.value("ConsumableTypeEnum")
            if let t = typeEnum?.lowercased(), t.contains("printhead") && info.value("ConsumablePercentageLevelRemaining") == nil {
                return nil
            }
            let pct = info.value("ConsumablePercentageLevelRemaining").flatMap { Int($0) }
            return Consumable(label: label,
                              color: colorName(for: label),
                              percentRemaining: pct,
                              state: info.value("ConsumableState") ?? info.value("ConsumableLifeState"),
                              type: typeEnum)
        }
    }

    public static func productInfo(_ xml: XMLNodeView) -> ProductInfo {
        ProductInfo(makeAndModel: xml.value("MakeAndModel") ?? xml.value("MakeAndModelBase"),
                    serialNumber: xml.value("SerialNumber"),
                    firmware: xml.value("Revision") ?? xml.value("FirmwareRevision"),
                    productNumber: xml.value("ProductNumber"))
    }

    static func colorName(for label: String) -> String {
        switch label.uppercased() {
        case "K": return "Black"
        case "C": return "Cyan"
        case "M": return "Magenta"
        case "Y": return "Yellow"
        case "CMY": return "Tri-color"
        case "KCMY": return "Black + color"
        default: return label
        }
    }
}
