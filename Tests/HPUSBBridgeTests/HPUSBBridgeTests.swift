// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HPUSBBridge

// MARK: - Helpers

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// In-memory transport: records writes, replays scripted responses in fragments.
final class MockTransport: ByteTransport {
    var written = Data()
    var pending: [Data]

    init(responses: [Data]) { pending = responses }

    func write(_ data: Data, timeout: TimeInterval) throws { written.append(data) }

    func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard !pending.isEmpty else { return Data() }
        return pending.removeFirst()
    }

    func close() {}
}

// MARK: - HTTP parsing

@Suite struct HTTPParserTests {
    @Test func contentLengthBody() throws {
        var p = HTTPResponseParser()
        #expect(try p.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel".utf8)) == nil)
        let r = try #require(try p.feed(Data("lo".utf8)))
        #expect(r.status == 200)
        #expect(r.text == "hello")
    }

    @Test func chunkedBodySplitAcrossReads() throws {
        var p = HTTPResponseParser()
        #expect(try p.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi".utf8)) == nil)
        #expect(try p.feed(Data("ki\r\n5;ext=1\r\npedia\r\n".utf8)) == nil)
        let r = try #require(try p.feed(Data("0\r\n\r\n".utf8)))
        #expect(r.text == "Wikipedia")
    }

    @Test func closeDelimitedBody() throws {
        var p = HTTPResponseParser()
        #expect(try p.feed(Data("HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n\r\nabc".utf8)) == nil)
        let r = try #require(try p.feed(Data(), endOfStream: true))
        #expect(r.text == "abc")
    }

    @Test func headersAreCaseInsensitiveAndLeadingBlankLinesIgnored() throws {
        var p = HTTPResponseParser()
        let r = try #require(try p.feed(Data("\r\nHTTP/1.1 201 Created\r\nLOCATION: /Jobs/JobList/7\r\nContent-Length: 0\r\n\r\n".utf8)))
        #expect(r.status == 201)
        #expect(r.header("Location") == "/Jobs/JobList/7")
    }

    @Test func malformedStatusLineThrows() {
        var p = HTTPResponseParser()
        #expect(throws: HTTPError.self) { try p.feed(Data("garbage\r\n\r\n".utf8)) }
    }

    @Test func requestRoundTripOverMockTransport() throws {
        let mock = MockTransport(responses: [
            Data("HTTP/1.1 200 OK\r\nContent-Le".utf8),
            Data("ngth: 2\r\n\r\nok".utf8),
        ])
        let http = HTTPOverUSB(transport: mock)
        let r = try http.request("PUT", "/DevMgmt/InternalPrintDyn.xml", body: Data("<x/>".utf8), contentType: "text/xml")
        #expect(r.text == "ok")
        let sent = String(decoding: mock.written, as: UTF8.self)
        #expect(sent.hasPrefix("PUT /DevMgmt/InternalPrintDyn.xml HTTP/1.1\r\n"))
        #expect(sent.contains("Content-Length: 4\r\n"))
        #expect(sent.hasSuffix("\r\n\r\n<x/>"))
    }
}

// MARK: - Device ID

@Suite struct DeviceIDTests {
    @Test func parsesLEDMDISFromSmartTank500() {
        let sel = USBInterfaceSelector.parseLEDMDIS("USB#FF#04#01,USB#FF#CC#00")
        #expect(sel == [.ledm, .ledmScan])
    }

    @Test func cupsURIEncodesModel() {
        let d = USBDeviceInfo(vendorID: 0x03F0, productID: 0x2B54, name: "Smart Tank 500 series", serial: "CN00000000")
        #expect(d.cupsURI == "usb://HP/Smart%20Tank%20500%20series?serial=CN00000000")
    }

    @Test func knownProfileForSmartTank500() {
        #expect(PrinterModelProfile.profile(forProductName: "HP Smart Tank 500 series")?.ppdName == "HP Deskjet 2640 series.ppd.gz")
        #expect(PrinterModelProfile.profile(forProductName: "LaserJet M428") == nil)
    }

    @Test func queueNameIsCUPSSafe() {
        #expect(PrintSetup.defaultQueueName(for: "Smart Tank 500 series") == "HP_Smart_Tank_500_USB")
    }

    @Test func reportsMissingDriversAndRosettaTogether() {
        let ppd = "/Library/Printers/PPDs/Contents/Resources/HP Deskjet 2640 series.ppd.gz"
        let none = PrintSetup.missingPrerequisites(ppdPath: ppd, isAppleSilicon: true) { _ in false }
        #expect(none == [.hpDrivers(ppdPath: ppd), .rosetta])
        let text = PrintSetupError.missingPrerequisites(none).description
        #expect(text.contains(PrintSetup.hpDriversDownloadURL))
        #expect(text.contains("softwareupdate --install-rosetta"))
    }

    @Test func rosettaOnlyMattersOnAppleSilicon() {
        let ppd = "/x.ppd.gz"
        #expect(PrintSetup.missingPrerequisites(ppdPath: ppd, isAppleSilicon: false) { _ in false } == [.hpDrivers(ppdPath: ppd)])
        #expect(PrintSetup.missingPrerequisites(ppdPath: ppd, isAppleSilicon: true) { _ in true }.isEmpty)
    }
}

// MARK: - LEDM documents

@Suite struct LEDMParserTests {
    @Test func consumablesSeparateTanksFromPrintheads() throws {
        let items = LEDMParsers.consumables(try XMLNodeView(data: fixture("ConsumableConfigDyn")))
        let inks = items.filter { $0.kind == .ink }
        let heads = items.filter { $0.kind == .printhead }
        #expect(inks.map(\.label) == ["C", "M", "Y", "K"])
        #expect(inks.allSatisfy { $0.percentRemaining == 100 && $0.stateDescription == "OK" })
        #expect(heads.map(\.color) == ["Tri-color", "Black"])
        #expect(heads.map(\.partNumber) == ["M0H50A", "X4E75A"])
        #expect(heads.first?.stateDescription == "OK (genuine HP)")
    }

    @Test func barRendering() {
        let c = Consumable(label: "C", color: "Cyan", percentRemaining: 35)
        #expect(c.bar == "[#######.............]")
    }

    @Test func statusReadyWithoutAlerts() throws {
        let s = LEDMParsers.status(try XMLNodeView(data: fixture("ProductStatusDyn")))
        #expect(s.isReady)
        #expect(s.alerts.isEmpty)
    }

    @Test func productInfoUsesFirmwareNotSchemaRevision() throws {
        let info = LEDMParsers.productInfo(try XMLNodeView(data: fixture("ProductConfigDyn")))
        #expect(info.makeAndModel == "Smart Tank 500 series")
        #expect(info.productNumber == "4SR29A")
        #expect(info.firmware == "POSPPLPP1N001.2330A.00")
        #expect(info.firmwareDate == "2023-07-26")
    }

    @Test func internalPrintCapListsCleaningLevels() throws {
        let jobs = try XMLNodeView(data: fixture("InternalPrintCap")).all("JobType").map(\.text)
        for job in InternalPrintJob.allCases {
            #expect(jobs.contains(job.rawValue), "\(job.rawValue) not offered by the captured printer")
        }
    }

    @Test func scanCapabilities() throws {
        let caps = LEDMScanParsers.capabilities(try XMLNodeView(data: fixture("ScanCaps")))
        #expect(caps.maxWidth300 == 2550)
        #expect(caps.maxHeight300 == 3508)
        #expect(caps.resolutions == [75, 100, 150, 200, 300, 400, 600, 1200])
        #expect(caps.colorModes == ["Color8", "Gray8", "K1"])
    }

    @Test func readyPageBinaryURL() throws {
        let job = try XMLNodeView(data: fixture("ScanJob"))
        #expect(LEDMScanParsers.readyBinaryURL(job) == "/Scan/Jobs/2/Pages/1")
    }

    @Test func locationToPath() {
        #expect(LEDMScanParsers.path(fromLocation: "http://localhost:8080/Jobs/JobList/3") == "/Jobs/JobList/3")
        #expect(LEDMScanParsers.path(fromLocation: "/Jobs/JobList/3") == "/Jobs/JobList/3")
        #expect(LEDMScanParsers.path(fromLocation: "Jobs/JobList/3") == "/Jobs/JobList/3")
    }

    @Test func scanSettingsDocumentIsValidXML() throws {
        var o = ScanOptions()
        o.colorMode = .gray
        o.resolution = 600
        let xml = LEDMScanParsers.scanSettingsXML(options: o, width300: 2480, height300: 3508)
        let doc = try XMLNodeView(data: Data(xml.utf8))
        #expect(doc.name == "ScanSettings")
        #expect(doc.value("ColorSpace") == "Gray")
        #expect(doc.value("XResolution") == "600")
        #expect(doc.value("Width") == "2480")
    }
}

// MARK: - PDF output

@Suite struct PDFWriterTests {
    func jpeg(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func pagesAreSizedFromDPI() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hpbridge-test-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // A4 at 100 dpi: 827 x 1169 px -> 595.4 x 841.7 pt
        try PDFWriter.write(pages: [jpeg(width: 827, height: 1169), jpeg(width: 827, height: 1169)], dpi: 100, to: url)
        let doc = try #require(CGPDFDocument(url as CFURL))
        #expect(doc.numberOfPages == 2)
        let box = try #require(doc.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(abs(box.width - 595.44) < 0.5)
        #expect(abs(box.height - 841.68) < 0.5)
    }
}
