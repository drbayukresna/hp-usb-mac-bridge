// SPDX-License-Identifier: GPL-3.0-or-later
//
// hpbridge — command line front end for hp-usb-mac-bridge.

import Foundation
import HPUSBBridge

let version = "0.1.0"

let usage = """
hpbridge \(version) — use USB-only HP printers on macOS without HP software

USAGE: hpbridge <command> [options]

COMMANDS
  devices                     List HP printers attached over USB
  setup-print [--queue NAME] [--ppd PATH] [--no-default] [--test]
                              Create/repair a colour CUPS print queue
  status                      Show printer state and alerts
  ink                         Show ink / consumable levels
  info                        Show model, serial number and firmware
  scan [-o FILE] [--dpi N] [--gray] [--paper a4|letter|legal|f4|a5|4x6|5x7|max]
       [--pages N] [--photo]  Scan from the flatbed to PDF (or .jpg for one page)
  clean [--level 1|2|3]       Run a printhead cleaning cycle
  maintenance <job>           Run an internal job: alignment, pq-report, config-page, self-test
  discover                    Dump the LEDM resources the firmware advertises
  raw GET|PUT|POST PATH [--body FILE]
                              Send a raw LEDM request (for developers)

GLOBAL OPTIONS
  -v, --verbose               Log USB/HTTP traffic to stderr
  -h, --help                  Show this help
"""

struct CLIError: Error, CustomStringConvertible { let description: String }

// MARK: - Argument helpers

var args = Array(CommandLine.arguments.dropFirst())
let verbose = args.contains("-v") || args.contains("--verbose")
args.removeAll { $0 == "-v" || $0 == "--verbose" }

func flag(_ names: String...) -> Bool {
    if let i = args.firstIndex(where: { names.contains($0) }) { args.remove(at: i); return true }
    return false
}

func option(_ names: String...) throws -> String? {
    guard let i = args.firstIndex(where: { names.contains($0) }) else { return nil }
    guard i + 1 < args.count else { throw CLIError(description: "\(args[i]) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func openClient() throws -> LEDMClient {
    try LEDMClient.openFirstResponding(verbose: verbose)
}

// MARK: - Commands

func cmdDevices() {
    let devices = USBBulkTransport.findDevices()
    if devices.isEmpty {
        print("No HP USB devices found.")
        return
    }
    for d in devices {
        print(d)
        if let p = PrinterModelProfile.profile(forProductName: d.name) {
            print("  supported profile: \(p.notes)")
        } else {
            print("  no tested profile yet — please run `hpbridge discover` and open an issue")
        }
    }
}

func cmdSetupPrint() throws {
    let queue = try option("--queue")
    let ppd = try option("--ppd")
    let noDefault = flag("--no-default")
    let test = flag("--test")
    var config = try PrintSetup.plan(queueName: queue, ppdOverride: ppd)
    config.makeDefault = !noDefault
    print("Queue:   \(config.queueName)")
    print("Device:  \(config.deviceURI)")
    print("Driver:  \(config.ppdPath)")
    try PrintSetup.apply(config)
    print("Print queue is ready" + (config.makeDefault ? " and set as default." : "."))
    if test { print(try PrintSetup.printTestPage(queue: config.queueName)) }
}

func cmdStatus() throws {
    let status = try openClient().productStatus()
    print("State: \(status.category)")
    if status.alerts.isEmpty { print("Alerts: none") }
    for a in status.alerts {
        print("Alert: \(a.id)" + (a.severity.map { " [\($0)]" } ?? "") + (a.color.map { " (\($0))" } ?? ""))
    }
}

func cmdInk() throws {
    let items = try openClient().consumables()
    if items.isEmpty { print("The printer did not report any consumables.") }
    for c in items {
        let pct = c.percentRemaining.map { "\($0)%" } ?? "n/a"
        print("\(c.color.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c.bar) \(pct)"
              + (c.state.map { "  \($0)" } ?? ""))
    }
    print("\nNote: on ink-tank printers this is an estimate; check the tank windows for the real level.")
}

func cmdInfo() throws {
    let info = try openClient().productInfo()
    print("Model:    \(info.makeAndModel ?? "?")")
    print("Product:  \(info.productNumber ?? "?")")
    print("Serial:   \(info.serialNumber ?? "?")")
    print("Firmware: \(info.firmware ?? "?")")
}

func cmdDiscover() throws {
    for r in try openClient().discoveryTree() {
        print("\(r.path)\t\(r.type)")
    }
}

func cmdScan() throws {
    var options = ScanOptions()
    if let dpi = try option("--dpi") {
        guard let v = Int(dpi) else { throw CLIError(description: "--dpi must be a number") }
        options.resolution = v
    }
    if flag("--gray", "--grey") { options.colorMode = .gray }
    if flag("--photo") { options.contentType = "Photo" }
    if let paper = try option("--paper") {
        guard let p = ScanPaper(rawValue: paper.lowercased()) else {
            throw CLIError(description: "Unknown paper '\(paper)'")
        }
        options.paper = p
    }
    let pages = Int(try option("--pages") ?? "1") ?? 1
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let defaultName = "Scan \(formatter.string(from: Date())).pdf"
    let output = URL(fileURLWithPath: try option("-o", "--output")
        ?? (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(defaultName)").path))

    let scanner = LEDMScanner(client: try LEDMClient.openFirstResponding(
        candidates: [.ledmScan, .ledm], probePath: "/Scan/ScanCaps.xml", verbose: verbose))
    scanner.log = { stderr($0) }

    var images: [Data] = []
    for page in 1...max(1, pages) {
        if page > 1 {
            stderr("Place page \(page) on the glass and press Return (or type q to finish)…")
            if let line = readLine(), line.lowercased().hasPrefix("q") { break }
        }
        images.append(try scanner.scanPage(options))
        stderr("Page \(page) scanned.")
    }

    if output.pathExtension.lowercased() == "jpg" || output.pathExtension.lowercased() == "jpeg" {
        if images.count == 1 {
            try images[0].write(to: output)
        } else {
            for (i, img) in images.enumerated() {
                let url = output.deletingPathExtension().appendingPathExtension("\(i + 1).jpg")
                try img.write(to: url)
            }
        }
    } else {
        try PDFWriter.write(pages: images, dpi: options.resolution, to: output)
    }
    print(output.path)
}

func cmdClean() throws {
    let level = try option("--level") ?? "1"
    let job: InternalPrintJob
    switch level {
    case "1": job = .cleaning
    case "2": job = .cleaningLevel2
    case "3": job = .cleaningLevel3
    default: throw CLIError(description: "--level must be 1, 2 or 3")
    }
    try runMaintenance(job)
}

func cmdMaintenance() throws {
    guard let name = args.first else { throw CLIError(description: "maintenance needs a job name") }
    args.removeFirst()
    let map: [String: InternalPrintJob] = [
        "alignment": .alignment, "align": .alignment,
        "pq-report": .printQualityDiagnostics, "quality": .printQualityDiagnostics,
        "config-page": .configuration, "self-test": .selfTest,
    ]
    guard let job = map[name] else {
        throw CLIError(description: "Unknown job '\(name)'. Use: alignment, pq-report, config-page, self-test")
    }
    try runMaintenance(job)
}

func runMaintenance(_ job: InternalPrintJob) throws {
    let client = try openClient()
    let supported = (try? client.supportedInternalPrintJobs()) ?? []
    if !supported.isEmpty && !supported.contains(job.rawValue) {
        throw CLIError(description: "This printer does not offer \(job.displayName) over USB. Supported: \(supported.joined(separator: ", "))")
    }
    try client.runInternalPrint(job)
    print("\(job.displayName) started. Load plain paper if the printer asks for it.")
}

func cmdRaw() throws {
    guard args.count >= 2 else { throw CLIError(description: "raw needs METHOD and PATH") }
    let bodyFile = try option("--body")
    let method = args[0].uppercased(), path = args[1]
    let body = try bodyFile.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    let r = try openClient().http.request(method, path, body: body, contentType: body == nil ? nil : "text/xml")
    stderr("HTTP \(r.status) \(r.reason)")
    for (k, v) in r.headers.sorted(by: { $0.key < $1.key }) { stderr("\(k): \(v)") }
    FileHandle.standardOutput.write(r.body)
}

// MARK: - Dispatch

do {
    if args.isEmpty || flag("-h", "--help", "help") {
        print(usage)
        exit(0)
    }
    let command = args.removeFirst()
    switch command {
    case "devices": cmdDevices()
    case "setup-print": try cmdSetupPrint()
    case "status": try cmdStatus()
    case "ink": try cmdInk()
    case "info": try cmdInfo()
    case "discover": try cmdDiscover()
    case "scan": try cmdScan()
    case "clean": try cmdClean()
    case "maintenance": try cmdMaintenance()
    case "raw": try cmdRaw()
    case "--version", "version": print(version)
    default:
        stderr("Unknown command '\(command)'.\n")
        stderr(usage)
        exit(64)
    }
} catch {
    stderr("error: \(error)")
    exit(1)
}
