// SPDX-License-Identifier: GPL-3.0-or-later
//
// Raw bulk transport to one vendor-specific USB interface of an HP printer.
//
// HP LEDM ("Low End Data Model") devices expose their web services (status,
// consumables, scanning, maintenance) as plain HTTP/1.1 spoken over a pair of
// bulk endpoints on a vendor-specific interface. The printer's IEEE-1284
// device ID advertises which interfaces carry LEDM, for example:
//
//     LEDMDIS:USB#FF#04#01,USB#FF#CC#00;
//
// meaning class 0xFF / subclass 0x04 / protocol 0x01 and 0xFF / 0xCC / 0x00.

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

public enum USBTransportError: Error, CustomStringConvertible {
    case deviceNotFound(vendorID: Int, productID: Int?)
    case interfaceNotFound(USBInterfaceSelector)
    case endpointsNotFound
    case io(String)
    case timeout

    public var description: String {
        switch self {
        case let .deviceNotFound(v, p):
            return String(format: "No USB device found for vendor 0x%04x", v)
                + (p.map { String(format: " product 0x%04x", $0) } ?? "")
                + ". Is the printer switched on and plugged in?"
        case let .interfaceNotFound(sel):
            return "The printer has no free USB interface \(sel). Another program (e.g. a vendor driver) may be holding it."
        case .endpointsNotFound:
            return "The interface has no bulk IN/OUT endpoint pair."
        case let .io(msg):
            return "USB I/O error: \(msg)"
        case .timeout:
            return "Timed out waiting for the printer."
        }
    }
}

/// Identifies a USB interface by class / subclass / protocol.
public struct USBInterfaceSelector: Hashable, CustomStringConvertible, Sendable {
    public var interfaceClass: Int
    public var interfaceSubclass: Int
    public var interfaceProtocol: Int

    public init(_ cls: Int, _ sub: Int, _ proto: Int) {
        interfaceClass = cls
        interfaceSubclass = sub
        interfaceProtocol = proto
    }

    /// LEDM management channel (DevMgmt, ProductStatus, ...).
    public static let ledm = USBInterfaceSelector(0xFF, 0x04, 0x01)
    /// Secondary LEDM channel, used by HP for scanning on many models.
    public static let ledmScan = USBInterfaceSelector(0xFF, 0xCC, 0x00)

    public var description: String {
        String(format: "%02X/%02X/%02X", interfaceClass, interfaceSubclass, interfaceProtocol)
    }

    /// Parses the `LEDMDIS:` field of an IEEE-1284 device ID, e.g. `USB#FF#04#01,USB#FF#CC#00`.
    public static func parseLEDMDIS(_ value: String) -> [USBInterfaceSelector] {
        value.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "#")
            guard parts.count == 4, parts[0] == "USB",
                  let c = Int(parts[1], radix: 16), let s = Int(parts[2], radix: 16), let p = Int(parts[3], radix: 16)
            else { return nil }
            return USBInterfaceSelector(c, s, p)
        }
    }
}

/// Byte-stream style access to a bulk IN/OUT pair.
public protocol ByteTransport: AnyObject {
    func write(_ data: Data, timeout: TimeInterval) throws
    /// Reads whatever the device has available, up to `maxLength` bytes.
    /// Returns an empty Data when the device produced nothing before `timeout`.
    func read(maxLength: Int, timeout: TimeInterval) throws -> Data
    func close()
}

public final class USBBulkTransport: ByteTransport {
    public static let hpVendorID = 0x03F0
    static let ioReturnTimeout = Int(Int32(bitPattern: 0xE000_02D6))   // kIOReturnTimeout
    static let ioReturnAborted = Int(Int32(bitPattern: 0xE000_02EB))   // kIOReturnAborted
    static let pipeStalled = Int(Int32(bitPattern: 0xE000_5000))       // kUSBHostReturnPipeStalled

    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    public let selector: USBInterfaceSelector
    public let interfaceNumber: Int

    /// Opens the first interface matching `selector` on an HP device.
    /// - Parameters:
    ///   - productID: restrict to one model (nil = any HP device).
    ///   - skip: number of matching interfaces to skip (some models expose two identical LEDM interfaces).
    public init(selector: USBInterfaceSelector,
                vendorID: Int = USBBulkTransport.hpVendorID,
                productID: Int? = nil,
                skip: Int = 0) throws {
        self.selector = selector

        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID),
            productID: productID.map { NSNumber(value: $0) },
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: NSNumber(value: selector.interfaceClass),
            interfaceSubclass: NSNumber(value: selector.interfaceSubclass),
            interfaceProtocol: NSNumber(value: selector.interfaceProtocol),
            speed: nil,
            productIDArray: nil
        )

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching.takeRetainedValue(), &iterator) == KERN_SUCCESS else {
            throw USBTransportError.interfaceNotFound(selector)
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        defer { services.forEach { IOObjectRelease($0) } }

        if services.isEmpty {
            if USBBulkTransport.findDevices(vendorID: vendorID, productID: productID).isEmpty {
                throw USBTransportError.deviceNotFound(vendorID: vendorID, productID: productID)
            }
            throw USBTransportError.interfaceNotFound(selector)
        }

        var lastError: Error = USBTransportError.interfaceNotFound(selector)
        var opened: (IOUSBHostInterface, IOUSBHostPipe, IOUSBHostPipe)?
        for service in services.dropFirst(skip) {
            do {
                let iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
                do {
                    let (inAddr, outAddr) = try USBBulkTransport.bulkEndpoints(of: iface)
                    opened = (iface,
                              try iface.copyPipe(withAddress: inAddr),
                              try iface.copyPipe(withAddress: outAddr))
                    break
                } catch {
                    iface.destroy()
                    throw error
                }
            } catch {
                lastError = error
            }
        }
        guard let (iface, inPipe, outPipe) = opened else { throw lastError }
        self.interface = iface
        self.inPipe = inPipe
        self.outPipe = outPipe
        self.interfaceNumber = Int(iface.interfaceDescriptor.pointee.bInterfaceNumber)
    }

    deinit { close() }

    public func close() {
        interface.destroy()
    }

    public func write(_ data: Data, timeout: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(data.count, offset + 64 * 1024))
            let buffer = NSMutableData(data: chunk)
            var transferred: UInt = 0
            do {
                try outPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                throw USBTransportError.io("write failed: \(error.localizedDescription)")
            }
            if transferred == 0 { throw USBTransportError.timeout }
            offset += Int(transferred)
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        // The IN request length must be a multiple of the endpoint's max packet size.
        let packet = max(64, Int(inPipe.descriptors.pointee.descriptor.wMaxPacketSize & 0x7FF))
        let length = max(packet, (maxLength / packet) * packet)
        guard let buffer = NSMutableData(length: length) else { throw USBTransportError.io("out of memory") }
        var transferred: UInt = 0
        do {
            try inPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch let error as NSError {
            // A timeout simply means "no data yet"; a stall is cleared and treated the same way.
            if error.code == USBBulkTransport.ioReturnTimeout || error.code == USBBulkTransport.ioReturnAborted {
                return Data()
            }
            if error.code == USBBulkTransport.pipeStalled {
                try? inPipe.clearStall()
                return Data()
            }
            throw USBTransportError.io("read failed: \(error.localizedDescription)")
        }
        return Data(bytes: buffer.bytes, count: Int(transferred))
    }

    /// Discards anything left in the IN pipe from an earlier, interrupted conversation.
    public func drain() {
        for _ in 0..<16 {
            guard let d = try? read(maxLength: 16 * 1024, timeout: 0.05), !d.isEmpty else { return }
        }
    }

    // MARK: - Helpers

    private static func bulkEndpoints(of iface: IOUSBHostInterface) throws -> (in: Int, out: Int) {
        let config = iface.configurationDescriptor
        let ifDesc = iface.interfaceDescriptor
        var inAddr: Int?
        var outAddr: Int?
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let ep = IOUSBGetNextEndpointDescriptor(config, ifDesc, current) {
            let address = Int(ep.pointee.bEndpointAddress)
            let type = Int(ep.pointee.bmAttributes) & 0x03
            if type == 2 { // bulk
                if address & 0x80 != 0 { inAddr = inAddr ?? address } else { outAddr = outAddr ?? address }
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let i = inAddr, let o = outAddr else { throw USBTransportError.endpointsNotFound }
        return (i, o)
    }

    /// Lists HP USB devices currently attached: (productID, product name, serial).
    public static func findDevices(vendorID: Int = hpVendorID, productID: Int? = nil) -> [USBDeviceInfo] {
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID),
            productID: productID.map { NSNumber(value: $0) },
            bcdDevice: nil, deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil,
            speed: nil, productIDArray: nil
        )
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching.takeRetainedValue(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [USBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            result.append(USBDeviceInfo(
                vendorID: (prop("idVendor") as? Int) ?? vendorID,
                productID: (prop("idProduct") as? Int) ?? 0,
                name: (prop("USB Product Name") as? String) ?? (prop("kUSBProductString") as? String) ?? "HP device",
                serial: (prop("USB Serial Number") as? String) ?? (prop("kUSBSerialNumberString") as? String)
            ))
        }
        return result
    }
}

public struct USBDeviceInfo: Sendable, CustomStringConvertible {
    public var vendorID: Int
    public var productID: Int
    public var name: String
    public var serial: String?

    public var description: String {
        String(format: "%@ (USB %04x:%04x)", name, vendorID, productID) + (serial.map { ", serial \($0)" } ?? "")
    }

    /// CUPS USB backend URI for this device, e.g. `usb://HP/Smart%20Tank%20500%20series?serial=XXXX`.
    public var cupsURI: String {
        let model = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return "usb://HP/\(model)" + (serial.map { "?serial=\($0)" } ?? "")
    }
}
