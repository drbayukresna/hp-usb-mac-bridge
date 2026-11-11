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

/// Something the Mac needs before the HP PCL3GUI driver can print.
public enum PrintPrerequisite: Sendable, Equatable {
    /// The PPD file is not installed (Apple's "HP Printer Drivers" package).
    case hpDrivers(ppdPath: String)
    /// Apple Silicon without Rosetta 2: HP's print filters are Intel-only.
    case rosetta
}

public enum PrintSetupError: Error, CustomStringConvertible {
    case noPrinter
    case missingPrerequisites([PrintPrerequisite])
    case unknownModel(String)
    case command(String, Int32, String)

    public var description: String {
        switch self {
        case .noPrinter:
            return "No USB HP printer is visible to CUPS. Switch it on, plug it in, and try again."
        case let .missingPrerequisites(items):
            var lines = ["Printing needs \(items.count == 1 ? "one thing" : "\(items.count) things") this Mac doesn't have yet:"]
            for (i, item) in items.enumerated() {
                switch item {
                case let .hpDrivers(path):
                    lines.append("""
                    \(i + 1). Apple's "HP Printer Drivers" package (driver file not found: \(path)).
                       Download HewlettPackardPrinterDrivers.dmg from \(PrintSetup.hpDriversDownloadURL)
                       and run the installer inside it. On macOS newer than 15 the installer refuses;
                       see "Installing the print driver" in the README to copy the driver by hand.
                       Or pass --ppd with another PCL3GUI HP PPD.
                    """)
                case .rosetta:
                    lines.append("""
                    \(i + 1). Rosetta 2 (HP's print filters are Intel-only). Install it in Terminal with:
                       softwareupdate --install-rosetta --agree-to-license
                    """)
                }
            }
            lines.append("Then run the printer setup again.")
            return lines.joined(separator: "\n")
        case let .unknownModel(name):
            return "No tested driver profile for \"\(name)\". Pass --ppd with a PCL3GUI HP inkjet PPD and please report the result."
        case let .command(cmd, code, out):
            return "\(cmd) failed (exit \(code)): \(out)"
        }
    }
}

public struct ExistingQueue: Sendable, Hashable {
    public var name: String
    public var deviceURI: String
    public var driver: String?
    public var isDefault: Bool
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
    public static let hpDriversDownloadURL = "https://support.apple.com/en-us/106385"
    /// Present only when Rosetta 2 is installed.
    static let rosettaRuntimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Everything missing before `ppdPath` can print, in install order.
    static func missingPrerequisites(ppdPath: String,
                                     isAppleSilicon: Bool = PrintSetup.isAppleSilicon,
                                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [PrintPrerequisite] {
        var missing: [PrintPrerequisite] = []
        if !fileExists(ppdPath) { missing.append(.hpDrivers(ppdPath: ppdPath)) }
        if isAppleSilicon && !fileExists(rosettaRuntimePath) { missing.append(.rosetta) }
        return missing
    }

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
        let missing = missingPrerequisites(ppdPath: ppdPath)
        guard missing.isEmpty else { throw PrintSetupError.missingPrerequisites(missing) }
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

    /// CUPS queues that print to `deviceURI` (matched without the query string),
    /// with the driver (PPD NickName) each one uses.
    public static func existingQueues(forDeviceURI deviceURI: String) -> [ExistingQueue] {
        guard let out = try? run("/usr/bin/lpstat", ["-v"]) else { return [] }
        let wanted = deviceURI.split(separator: "?").first.map(String.init) ?? deviceURI
        let defaultQueue = (try? run("/usr/bin/lpstat", ["-d"]))?
            .components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.split(separator: "\n").compactMap { line in
            // "device for NAME: URI"
            guard line.hasPrefix("device for "), let colon = line.range(of: ": ") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 11)..<colon.lowerBound])
            let uri = String(line[colon.upperBound...])
            guard (uri.split(separator: "?").first.map(String.init) ?? uri) == wanted else { return nil }
            let ppd = try? String(contentsOfFile: "/etc/cups/ppd/\(name).ppd", encoding: .isoLatin1)
            let nick = ppd?.split(separator: "\n")
                .first { $0.hasPrefix("*NickName:") }
                .map { $0.dropFirst("*NickName:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            return ExistingQueue(name: name, deviceURI: uri, driver: nick, isDefault: name == defaultQueue)
        }
    }

    /// True when the queue uses a driver known to give monochrome-only output.
    public static func isLimitedDriver(_ driver: String?) -> Bool {
        guard let d = driver?.lowercased() else { return false }
        return d.contains("generic pcl") || d.contains("generic postscript")
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
