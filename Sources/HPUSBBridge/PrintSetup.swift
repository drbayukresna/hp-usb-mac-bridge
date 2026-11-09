// SPDX-License-Identifier: GPL-3.0-or-later
//
// Creates a working CUPS print queue for USB-only HP inkjets that macOS no
// longer has a driver for.
//
// Background (see docs/FINDINGS.md): the HP Smart Tank 500 series speaks
// PCL3GUI natively (IEEE-1284 CMD field) but has no IPP-over-USB interface,
// so AirPrint over USB is impossible and raw URF/PWG raster sent through the
// USB printer class interface is silently ignored. The PCL3GUI renderer in
// Apple's "HP Printer Drivers" package (Inkjet9, used by the DeskJet 2640
// PPD) produces output the printer accepts, in full colour.

import Foundation

public struct PrinterModelProfile: Sendable {
    public var usbProductName: String      // as reported by USB, e.g. "Smart Tank 500 series"
    public var ppdName: String             // file name inside the HP PPD folder
    public var notes: String

    public static let known: [PrinterModelProfile] = [
        PrinterModelProfile(usbProductName: "Smart Tank 500 series",
                            ppdName: "HP Deskjet 2640 series.ppd.gz",
                            notes: "Verified: colour PCL3GUI output, A4/F4/photo sizes."),
    ]

    public static func profile(forProductName name: String) -> PrinterModelProfile? {
        known.first { name.localizedCaseInsensitiveContains($0.usbProductName) }
    }
}

public enum PrintSetupError: Error, CustomStringConvertible {
    case noPrinter
    case ppdMissing(String)
    case unknownModel(String)
    case command(String, Int32, String)

    public var description: String {
        switch self {
        case .noPrinter:
            return "No USB HP printer is visible to CUPS. Switch it on, plug it in, and try again."
        case let .ppdMissing(path):
            return "Driver file not found: \(path). Install Apple's \"HP Printer Drivers\" package, or pass --ppd."
        case let .unknownModel(name):
            return "No tested driver profile for \"\(name)\". Pass --ppd with a PCL3GUI HP inkjet PPD and please report the result."
        case let .command(cmd, code, out):
            return "\(cmd) failed (exit \(code)): \(out)"
        }
    }
}

public struct PrintQueueConfig: Sendable {
    public var queueName: String
    public var description: String
    public var deviceURI: String
    public var ppdPath: String
    public var defaultPageSize = "A4"
    public var makeDefault = true
}

public enum PrintSetup {
    public static let hpPPDDirectory = "/Library/Printers/PPDs/Contents/Resources"

    /// USB HP devices as CUPS sees them: (uri, make-and-model).
    public static func cupsUSBDevices() throws -> [(uri: String, model: String)] {
        let out = try run("/usr/sbin/lpinfo", ["-l", "-v"])
        var result: [(String, String)] = []
        var uri: String?
        for line in out.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Device: uri = ") {
                uri = String(line.dropFirst("Device: uri = ".count))
            } else if line.hasPrefix("make-and-model = "), let u = uri, u.hasPrefix("usb://HP/") {
                result.append((u, String(line.dropFirst("make-and-model = ".count))))
                uri = nil
            }
        }
        return result
    }

    public static func plan(queueName: String? = nil, ppdOverride: String? = nil) throws -> PrintQueueConfig {
        guard let device = try cupsUSBDevices().first else { throw PrintSetupError.noPrinter }
        let model = device.model.replacingOccurrences(of: "HP ", with: "")
        let ppdPath: String
        if let ppdOverride {
            ppdPath = ppdOverride
        } else if let profile = PrinterModelProfile.profile(forProductName: model) {
            ppdPath = "\(hpPPDDirectory)/\(profile.ppdName)"
        } else {
            throw PrintSetupError.unknownModel(device.model)
        }
        guard FileManager.default.fileExists(atPath: ppdPath) else { throw PrintSetupError.ppdMissing(ppdPath) }
        let name = queueName ?? defaultQueueName(for: model)
        return PrintQueueConfig(queueName: name,
                                description: "HP \(model) (USB)",
                                deviceURI: device.uri,
                                ppdPath: ppdPath)
    }

    /// Creates or updates the queue. Safe to run repeatedly.
    public static func apply(_ config: PrintQueueConfig) throws {
        _ = try run("/usr/sbin/lpadmin", [
            "-p", config.queueName,
            "-D", config.description,
            "-L", "USB",
            "-v", config.deviceURI,
            "-P", config.ppdPath,
            "-o", "printer-is-shared=false",
            "-o", "PageSize=\(config.defaultPageSize)",
            "-E",
        ])
        if config.makeDefault {
            _ = try run("/usr/bin/lpoptions", ["-d", config.queueName])
        }
    }

    public static func printTestPage(queue: String) throws -> String {
        try run("/usr/bin/lp", ["-d", queue, "-t", "hp-usb-mac-bridge test page",
                                "/usr/share/cups/data/testprint"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultQueueName(for model: String) -> String {
        let cleaned = model.replacingOccurrences(of: " series", with: "")
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "HP_" + String(cleaned) + "_USB"
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        // lpadmin prints a deprecation notice for PPD drivers on every call; it is harmless.
        if p.terminationStatus != 0 {
            throw PrintSetupError.command(([tool] + args).joined(separator: " "), p.terminationStatus, out)
        }
        return out
    }
}
