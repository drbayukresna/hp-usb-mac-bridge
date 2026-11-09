// SPDX-License-Identifier: GPL-3.0-or-later
//
// App state. All USB work runs on one serial queue (the printer handles one
// LEDM conversation at a time); results are published on the main actor.

import AppKit
import Foundation
import HPUSBBridge
import SwiftUI

/// Serialises every LEDM conversation and reuses the opened USB interface.
final class LEDMSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hpbridge.usb")
    private var client: LEDMClient?
    private var scanClient: LEDMClient?

    func run<T>(_ body: @escaping (LEDMClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    if self.client == nil { self.client = try LEDMClient.openFirstResponding() }
                    cont.resume(returning: try body(self.client!))
                } catch {
                    self.client = nil   // reopen next time (printer may have been unplugged)
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func scan(_ options: ScanOptions, log: @escaping (String) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    if self.scanClient == nil {
                        self.scanClient = try LEDMClient.openFirstResponding(
                            candidates: [.ledmScan, .ledm], probePath: "/Scan/ScanCaps")
                    }
                    let scanner = LEDMScanner(client: self.scanClient!)
                    scanner.log = log
                    cont.resume(returning: try scanner.scanPage(options))
                } catch {
                    self.scanClient = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func reset() {
        queue.async {
            self.client = nil
            self.scanClient = nil
        }
    }
}

struct ScannedPage: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data
    let image: NSImage
    let dpi: Int
}

enum ConnectionState: Equatable {
    case searching
    case disconnected
    case connected(USBDeviceInfo)

    static func == (a: ConnectionState, b: ConnectionState) -> Bool {
        switch (a, b) {
        case (.searching, .searching), (.disconnected, .disconnected): return true
        case let (.connected(x), .connected(y)): return x.productID == y.productID && x.serial == y.serial
        default: return false
        }
    }
}

enum PrintSetupState: Equatable {
    case unknown
    case ready(queue: String, isDefault: Bool)
    case limited(queue: String, driver: String)
    case missing
}

@MainActor
final class PrinterModel: ObservableObject {
    @Published var connection: ConnectionState = .searching
    @Published var info: ProductInfo?
    @Published var status: PrinterStatus?
    @Published var consumables: [Consumable] = []
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    @Published var printSetup: PrintSetupState = .unknown
    @Published var isSettingUpPrint = false

    @Published var pages: [ScannedPage] = []
    @Published var scanOptions = ScanOptions()
    @Published var isScanning = false
    @Published var scanStep: String?

    @Published var maintenanceRunning: InternalPrintJob?
    @Published var supportedJobs: Set<String> = []

    @Published var banner: Banner?

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
        var isError: Bool
    }

    private let session = LEDMSession()
    private var pollTimer: Timer?
    private var statusTimer: Timer?

    var device: USBDeviceInfo? {
        if case let .connected(d) = connection { return d }
        return nil
    }

    var inks: [Consumable] { consumables.filter { $0.kind == .ink } }
    var printheads: [Consumable] { consumables.filter { $0.kind == .printhead } }
    var isBusy: Bool { isScanning || maintenanceRunning != nil }

    // MARK: - Lifecycle

    func start() {
        detectDevice()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.detectDevice() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.device != nil, !self.isBusy else { return }
                await self.refresh(quiet: true)
            }
        }
    }

    private func detectDevice() {
        let found = USBBulkTransport.findDevices().first
        switch (connection, found) {
        case (.connected, nil):
            connection = .disconnected
            session.reset()
            status = nil
        case let (_, d?) where connection != .connected(d):
            connection = .connected(d)
            Task { await refresh() }
        case (.searching, nil):
            connection = .disconnected
        default:
            break
        }
    }

    // MARK: - Status

    func refresh(quiet: Bool = false) async {
        guard device != nil else { return }
        if !quiet { isRefreshing = true }
        defer { isRefreshing = false }
        do {
            let result = try await session.run { client in
                (try client.productInfo(),
                 try client.productStatus(),
                 try client.consumables(),
                 (try? client.supportedInternalPrintJobs()) ?? [])
            }
            withAnimation(.spring(duration: 0.6)) {
                info = result.0
                status = result.1
                consumables = result.2
            }
            supportedJobs = Set(result.3)
            lastUpdated = Date()
        } catch {
            if !quiet { show(error, title: String(localized: "Couldn't read the printer")) }
        }
        refreshPrintSetup()
    }

    // MARK: - Printing

    func refreshPrintSetup() {
        guard let device else { printSetup = .unknown; return }
        let uri = device.cupsURI
        Task.detached {
            let queues = PrintSetup.existingQueues(forDeviceURI: uri)
            let state: PrintSetupState
            if let good = queues.first(where: { !PrintSetup.isLimitedDriver($0.driver) }) {
                state = .ready(queue: good.name, isDefault: good.isDefault)
            } else if let limited = queues.first {
                state = .limited(queue: limited.name, driver: limited.driver ?? "Generic")
            } else {
                state = .missing
            }
            await MainActor.run { self.printSetup = state }
        }
    }

    func setUpPrinting(makeDefault: Bool, printTest: Bool) {
        isSettingUpPrint = true
        Task.detached {
            do {
                var plan = try PrintSetup.plan()
                plan.makeDefault = makeDefault
                let config = plan
                try PrintSetup.apply(config)
                if printTest { _ = try PrintSetup.printTestPage(queue: config.queueName) }
                await MainActor.run {
                    self.isSettingUpPrint = false
                    self.banner = Banner(
                        title: String(localized: "Printing is ready"),
                        message: printTest
                            ? String(localized: "A colour test page is on its way. Choose “\(config.description)” in any Print dialog.")
                            : String(localized: "Choose “\(config.description)” in any Print dialog."),
                        isError: false)
                    self.refreshPrintSetup()
                }
            } catch {
                await MainActor.run {
                    self.isSettingUpPrint = false
                    self.show(error, title: String(localized: "Couldn't set up printing"))
                }
            }
        }
    }

    func printTestPage(queue: String) {
        Task.detached {
            do {
                _ = try PrintSetup.printTestPage(queue: queue)
                await MainActor.run {
                    self.banner = Banner(title: String(localized: "Test page sent"),
                                         message: String(localized: "It should come out of the printer in a few seconds."),
                                         isError: false)
                }
            } catch {
                await MainActor.run { self.show(error, title: String(localized: "Couldn't print a test page")) }
            }
        }
    }

    func openPrintersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scanning

    func scan() async {
        guard !isBusy else { return }
        isScanning = true
        scanStep = String(localized: "Preparing the scanner…")
        defer { isScanning = false; scanStep = nil }
        let options = scanOptions
        do {
            let jpeg = try await session.scan(options) { line in
                Task { @MainActor in
                    if line.hasPrefix("Starting") { self.scanStep = String(localized: "Scanning…") }
                    else if line.hasPrefix("Downloading") { self.scanStep = String(localized: "Receiving the image…") }
                }
            }
            guard let image = NSImage(data: jpeg) else { throw PDFWriterError.badImage(pages.count) }
            withAnimation(.spring(duration: 0.45)) {
                pages.append(ScannedPage(jpeg: jpeg, image: image, dpi: options.resolution))
            }
        } catch {
            show(error, title: String(localized: "Scan failed"))
        }
    }

    func removePage(_ page: ScannedPage) {
        withAnimation { pages.removeAll { $0.id == page.id } }
    }

    func movePage(_ page: ScannedPage, by offset: Int) {
        guard let i = pages.firstIndex(of: page) else { return }
        let j = i + offset
        guard pages.indices.contains(j) else { return }
        withAnimation(.snappy) { pages.swapAt(i, j) }
    }

    func savePDF() {
        guard !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultScanName() + ".pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Each page keeps its own resolution so mixed-quality scans are sized correctly.
            try PDFWriter.write(pages: pages.map { (jpeg: $0.jpeg, dpi: $0.dpi) }, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            banner = Banner(title: String(localized: "Saved"), message: url.lastPathComponent, isError: false)
        } catch {
            show(error, title: String(localized: "Couldn't save the PDF"))
        }
    }

    func saveImages() {
        guard !pages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = defaultScanName()
        do {
            var urls: [URL] = []
            for (i, page) in pages.enumerated() {
                let url = dir.appendingPathComponent(pages.count == 1 ? "\(base).jpg" : "\(base) \(i + 1).jpg")
                try page.jpeg.write(to: url)
                urls.append(url)
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            show(error, title: String(localized: "Couldn't save the images"))
        }
    }

    private func defaultScanName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return String(localized: "Scan") + " " + f.string(from: Date())
    }

    // MARK: - Maintenance

    func run(_ job: InternalPrintJob) async {
        guard !isBusy else { return }
        maintenanceRunning = job
        defer { maintenanceRunning = nil }
        do {
            try await session.run { try $0.runInternalPrint(job) }
            // Follow the printer until it is ready again (cleaning takes ~90 s).
            try? await Task.sleep(for: .seconds(4))
            for _ in 0..<60 {
                let s = try? await session.run { try $0.productStatus() }
                if let s { status = s }
                if s?.isReady == true { break }
                try? await Task.sleep(for: .seconds(4))
            }
            banner = Banner(title: String(localized: "Done"),
                            message: String(localized: "\(job.localizedName) finished."),
                            isError: false)
        } catch {
            show(error, title: String(localized: "The printer refused the request"))
        }
    }

    // MARK: - Errors

    func show(_ error: Error, title: String) {
        banner = Banner(title: title, message: String(describing: error), isError: true)
    }
}

extension InternalPrintJob {
    var localizedName: String {
        switch self {
        case .cleaning: return String(localized: "Standard cleaning")
        case .cleaningLevel2: return String(localized: "Deep cleaning")
        case .cleaningLevel3: return String(localized: "Intensive cleaning")
        case .cleaningVerification: return String(localized: "Cleaning check page")
        case .printQualityDiagnostics: return String(localized: "Print quality report")
        case .diagnostics: return String(localized: "Diagnostics page")
        case .configuration: return String(localized: "Configuration page")
        case .extendedConfiguration: return String(localized: "Extended configuration page")
        }
    }
}
