// SPDX-License-Identifier: GPL-3.0-or-later
//
// Epson status over USB.
//
// Epson inkjets expose a control channel through IEEE 1284.4 ("D4") packets
// on the ordinary USB printer-class interface (07/01/02). The device ID
// advertises it as `CMD:...,D4,...`. After switching the printer to D4 mode
// we open the "EPSON-CTRL" service and send the `st` command; the printer
// answers with an "@BDC ST2" binary status block that includes ink levels.
//
// Protocol reference: IEEE 1284.4-2000 and the public behaviour documented
// by Gutenprint's escputil. This is an independent implementation.

import Foundation

public enum EpsonError: Error, CustomStringConvertible {
    case protocolError(String)
    case noReply(String)
    case printing

    public var description: String {
        switch self {
        case .printing: return "The printer is printing. Status is read over the same USB channel as print data, so try again when the job has finished."
        case let .protocolError(m): return "Epson protocol error: \(m)"
        case let .noReply(step): return "The printer did not answer (\(step)). It may be busy printing."
        }
    }
}

public struct EpsonStatus: Sendable {
    public var statusCode: Int?
    public var errorCode: Int?
    public var inks: [Consumable]
    public var rawFields: [UInt8: [UInt8]]

    public var state: String {
        switch statusCode {
        case 0: return "error"
        case 1: return "selfPrinting"
        case 2: return "busy"
        case 3: return "waiting"
        case 4: return "ready"
        case 7: return "cleaning"
        case 8: return "shuttingDown"
        case let c?: return "status\(c)"
        case nil: return "unknown"
        }
    }

    public var isReady: Bool { statusCode == 4 || statusCode == 3 }

    /// True when the printer refills from tanks and does not measure ink.
    public var hasUnmeasuredTanks: Bool { !inks.isEmpty && inks.allSatisfy { $0.percentRemaining == nil } }

    public var errorDescription: String? {
        switch errorCode {
        case nil, 0?: return nil
        case 1?: return "Interface error"
        case 4?: return "Paper jam"
        case 5?: return "Ink out"
        case 6?: return "Paper out"
        case 0x0C?: return "Cover open"
        case 0x10?: return "Ink pad (maintenance box) full"
        case let c?: return String(format: "Error 0x%02X", c)
        }
    }
}

public enum EpsonParsers {
    /// Parses an "@BDC ST2" reply.
    public static func st2(_ data: [UInt8]) throws -> EpsonStatus {
        let marker = Array("@BDC ST2\r\n".utf8)
        guard let start = find(marker, in: data), data.count >= start + marker.count + 2 else {
            throw EpsonError.protocolError("no ST2 block in reply")
        }
        var i = start + marker.count
        let length = Int(data[i]) | (Int(data[i + 1]) << 8)
        i += 2
        let end = min(data.count, i + length)
        var fields: [UInt8: [UInt8]] = [:]
        while i + 2 <= end {
            let code = data[i], len = Int(data[i + 1])
            let stop = min(end, i + 2 + len)
            fields[code] = Array(data[(i + 2)..<stop])
            i = stop
        }
        var inks: [Consumable] = []
        if let f = fields[0x0F], let size = f.first.map(Int.init), size >= 3 {
            var p = 1
            while p + size <= f.count {
                let colorID = f[p + 1], level = Int(f[p + 2])
                let (label, name) = color(colorID)
                // 0x69 (105) is what ink-tank (EcoTank / L-series) models report:
                // the tanks are refilled by hand and not measured.
                let measured = level <= 100
                var c = Consumable(label: label, color: name, percentRemaining: measured ? level : nil)
                c.kind = .ink
                c.type = level == 0x69 ? "inkTank" : "inkCartridge"
                c.state = measured ? (level == 0 ? "out" : level <= 10 ? "low" : "ok") : nil
                inks.append(c)
                p += size
            }
        }
        return EpsonStatus(statusCode: fields[0x01]?.first.map(Int.init),
                           errorCode: fields[0x02]?.first.map(Int.init),
                           inks: inks, rawFields: fields)
    }

    static func color(_ id: UInt8) -> (String, String) {
        switch id {
        case 0x00: return ("K", "Black")
        case 0x01: return ("C", "Cyan")
        case 0x02: return ("M", "Magenta")
        case 0x03: return ("Y", "Yellow")
        case 0x04: return ("LC", "Light Cyan")
        case 0x05: return ("LM", "Light Magenta")
        case 0x0A: return ("PK", "Photo Black")
        case 0x0B: return ("MK", "Matte Black")
        default: return (String(format: "#%02X", id), String(format: "Ink 0x%02X", id))
        }
    }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}

/// One IEEE 1284.4 conversation with an Epson printer.
public final class EpsonD4Session {
    public static let epsonVendorID = 0x04B8
    static let printerClass = USBInterfaceSelector(0x07, 0x01, 0x02)

    private let transport: ByteTransport
    private var pending: [UInt8] = []
    public var verbose = false

    public init(transport: ByteTransport) { self.transport = transport }

    /// True while CUPS is sending a job to an Epson USB printer. Talking D4 on
    /// the printer interface at that moment would corrupt the page being printed.
    public static func isPrintingOverUSB() -> Bool {
        guard let queues = try? PrintSetup.run("/usr/bin/lpstat", ["-v"]) else { return false }
        for line in queues.split(separator: "\n") where line.contains("usb://EPSON/") {
            guard line.hasPrefix("device for "), let colon = line.range(of: ": ") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 11)..<colon.lowerBound])
            if let jobs = try? PrintSetup.run("/usr/bin/lpstat", ["-o", name]),
               !jobs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }

    public static func open(productID: Int? = nil) throws -> EpsonD4Session {
        if isPrintingOverUSB() { throw EpsonError.printing }
        let t = try USBBulkTransport(selector: printerClass, vendorID: epsonVendorID, productID: productID)
        t.drain()
        return EpsonD4Session(transport: t)
    }

    /// Reads the printer status and ink levels, then leaves D4 mode.
    public func readStatus() throws -> EpsonStatus {
        try enterD4()
        defer { try? command([0x08]); transport.close() }                  // Exit
        _ = try command([0x00, 0x10], step: "Init")                       // Init, revision 0x10
        let sockReply = try command([0x09] + Array("EPSON-CTRL".utf8), step: "GetSocketID")
        guard sockReply.count >= 3, sockReply[1] == 0 else {
            throw EpsonError.protocolError("printer has no EPSON-CTRL service")
        }
        let sock = sockReply[2]
        let open = try command([0x01, sock, sock, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00], step: "OpenChannel")
        guard open.count >= 2, open[1] == 0 else { throw EpsonError.protocolError("OpenChannel refused") }
        defer { _ = try? command([0x02, sock, sock]) }                    // CloseChannel
        _ = try command([0x04, sock, sock, 0x00, 0x80, 0xFF, 0xFF], step: "CreditRequest")

        try send(psid: sock, payload: Array("st".utf8) + [0x01, 0x00, 0x01])
        _ = try command([0x03, sock, sock, 0x00, 0x01], step: "Credit")   // let the printer answer
        var reply: [UInt8] = []
        for _ in 0..<4 {
            let packet = try readPacket(step: "status reply")
            if packet.psid == sock { reply += packet.payload }
            if EpsonParsers.find(Array("@BDC ST2\r\n".utf8), in: reply) != nil { break }
        }
        return try EpsonParsers.st2(reply)
    }

    // MARK: - D4 plumbing

    private func enterD4() throws {
        let cmd: [UInt8] = [0x00, 0x00, 0x00, 0x1B, 0x01] + Array("@EJL 1284.4\n@EJL\n@EJL\n".utf8)
        try transport.write(Data(cmd), timeout: 5)
        // The printer echoes a short acknowledgement; it is not a D4 packet.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let d = try transport.read(maxLength: 512, timeout: 0.3)
            if verbose, !d.isEmpty { log("enter reply", [UInt8](d)) }
            if !d.isEmpty { break }
        }
    }

    private func send(psid: UInt8, payload: [UInt8], credit: UInt8 = 0) throws {
        let len = payload.count + 6
        let packet: [UInt8] = [psid, psid, UInt8(len >> 8), UInt8(len & 0xFF), credit, 0x00] + payload
        if verbose { log(">", packet) }
        try transport.write(Data(packet), timeout: 5)
    }

    /// Sends a command on the control channel (socket 0) and returns its reply payload.
    @discardableResult
    private func command(_ payload: [UInt8], step: String = "command") throws -> [UInt8] {
        try send(psid: 0, payload: payload, credit: 1)
        for _ in 0..<6 {
            let p = try readPacket(step: step)
            if p.psid == 0, let first = p.payload.first, first == payload[0] | 0x80 { return p.payload }
            if p.psid == 0, p.payload.first == 0x7F { throw EpsonError.protocolError("\(step) rejected") }
        }
        throw EpsonError.noReply(step)
    }

    private func readPacket(step: String) throws -> (psid: UInt8, payload: [UInt8]) {
        let deadline = Date().addingTimeInterval(4)
        while true {
            if pending.count >= 6 {
                let len = (Int(pending[2]) << 8) | Int(pending[3])
                if len >= 6, pending.count >= len {
                    let packet = Array(pending[0..<len])
                    pending.removeFirst(len)
                    if verbose { log("<", packet) }
                    return (packet[0], Array(packet[6...]))
                }
                if len < 6 { pending.removeAll(); throw EpsonError.protocolError("bad packet length") }
            }
            guard Date() < deadline else { throw EpsonError.noReply(step) }
            pending += [UInt8](try transport.read(maxLength: 4096, timeout: 0.5))
        }
    }

    private func log(_ tag: String, _ bytes: [UInt8]) {
        let hex = bytes.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        FileHandle.standardError.write(Data("\(tag) \(hex)\n".utf8))
    }
}

// MARK: - Bridging to the vendor-neutral models used by the app

extension EpsonStatus {
    /// The same shape the HP (LEDM) path produces, so UIs can show either printer.
    public var printerStatus: PrinterStatus {
        let category: String
        switch statusCode {
        case 3, 4: category = "ready"
        case 1, 2, 7: category = "processing"
        default: category = state
        }
        let alerts = errorDescription.map { [PrinterStatus.Alert(id: $0, severity: "Error", color: nil)] } ?? []
        return PrinterStatus(category: category, alerts: alerts)
    }
}

extension ProductInfo {
    /// Product info for printers that only report their USB identity.
    public static func fromUSB(_ device: USBDeviceInfo, vendor: String) -> ProductInfo {
        ProductInfo(makeAndModel: device.name, serialNumber: device.serial, firmware: nil,
                    firmwareDate: nil, productNumber: String(format: "USB %04x:%04x", device.vendorID, device.productID))
    }
}
