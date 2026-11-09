// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal HTTP/1.1 client that runs over a ByteTransport (USB bulk pipes).
// LEDM devices answer ordinary HTTP requests on their LEDM interface; the
// "Host" header is ignored but required by the protocol.

import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var headers: [String: String]   // lower-cased keys
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

public enum HTTPError: Error, CustomStringConvertible {
    case malformedResponse(String)
    case unexpectedStatus(Int, String, path: String)
    case noResponse(path: String)

    public var description: String {
        switch self {
        case let .malformedResponse(m): return "Malformed HTTP response from printer: \(m)"
        case let .unexpectedStatus(code, reason, path): return "Printer answered \(code) \(reason) for \(path)"
        case let .noResponse(path): return "Printer did not answer request for \(path)"
        }
    }
}

/// Incremental HTTP/1.1 response parser (supports Content-Length, chunked, and close-delimited bodies).
public struct HTTPResponseParser {
    private var buffer = Data()
    private var head: (status: Int, reason: String, headers: [String: String])?
    private var bodyStart = 0

    public init() {}

    /// Feeds bytes; returns a complete response once available.
    /// - Parameter endOfStream: true when no more bytes will arrive (close-delimited body).
    public mutating func feed(_ data: Data, endOfStream: Bool = false) throws -> HTTPResponse? {
        buffer.append(data)
        if head == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if endOfStream && !buffer.isEmpty { throw HTTPError.malformedResponse("incomplete header") }
                return nil
            }
            let headText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            var lines = headText.components(separatedBy: "\r\n")
            // Some firmwares send stray CR/LF before the status line.
            while let first = lines.first, first.isEmpty { lines.removeFirst() }
            guard let statusLine = lines.first else { throw HTTPError.malformedResponse("empty") }
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
                throw HTTPError.malformedResponse("bad status line: \(statusLine)")
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            head = (code, parts.count > 2 ? String(parts[2]) : "", headers)
            bodyStart = range.upperBound - buffer.startIndex
        }
        guard let head else { return nil }
        let body = buffer.subdata(in: (buffer.startIndex + bodyStart)..<buffer.endIndex)

        // Responses without a body.
        if head.status == 204 || head.status == 304 || (100..<200).contains(head.status) {
            return HTTPResponse(status: head.status, reason: head.reason, headers: head.headers, body: Data())
        }

        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            if let decoded = try HTTPResponseParser.decodeChunked(body) {
                return HTTPResponse(status: head.status, reason: head.reason, headers: head.headers, body: decoded)
            }
            if endOfStream { throw HTTPError.malformedResponse("truncated chunked body") }
            return nil
        }
        if let lengthText = head.headers["content-length"], let length = Int(lengthText) {
            if body.count >= length {
                return HTTPResponse(status: head.status, reason: head.reason, headers: head.headers,
                                    body: body.prefix(length))
            }
            if endOfStream { throw HTTPError.malformedResponse("body shorter than Content-Length") }
            return nil
        }
        // No length information: body runs until the device stops sending.
        if endOfStream {
            return HTTPResponse(status: head.status, reason: head.reason, headers: head.headers, body: body)
        }
        return nil
    }

    /// Returns the decoded body, or nil if the terminating zero-length chunk has not arrived yet.
    static func decodeChunked(_ data: Data) throws -> Data? {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                throw HTTPError.malformedResponse("bad chunk size '\(sizeText)'")
            }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return out }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            out.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}

public final class HTTPOverUSB {
    public let transport: ByteTransport
    /// How long to wait for the first byte of a response.
    public var responseTimeout: TimeInterval = 15
    /// Idle time after which a close-delimited body is considered complete.
    public var idleTimeout: TimeInterval = 1.5
    public var verbose = false

    public init(transport: ByteTransport) {
        self.transport = transport
    }

    @discardableResult
    public func request(_ method: String, _ path: String,
                        body: Data? = nil, contentType: String? = nil,
                        extraHeaders: [String: String] = [:],
                        timeout: TimeInterval? = nil) throws -> HTTPResponse {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nUser-Agent: hp-usb-mac-bridge\r\nAccept: */*\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var packet = Data(head.utf8)
        if let body { packet.append(body) }
        if verbose { FileHandle.standardError.write(Data("> \(method) \(path)\n".utf8)) }

        if let usb = transport as? USBBulkTransport { usb.drain() }
        try transport.write(packet, timeout: 10)

        var parser = HTTPResponseParser()
        let firstByteDeadline = Date().addingTimeInterval(timeout ?? responseTimeout)
        var receivedAny = false
        var lastData = Date()
        while true {
            let chunk = try transport.read(maxLength: 64 * 1024, timeout: 0.5)
            if !chunk.isEmpty {
                receivedAny = true
                lastData = Date()
                if let response = try parser.feed(chunk) {
                    if verbose { FileHandle.standardError.write(Data("< \(response.status) \(response.reason) (\(response.body.count) bytes)\n".utf8)) }
                    return response
                }
                continue
            }
            if !receivedAny {
                if Date() > firstByteDeadline { throw HTTPError.noResponse(path: path) }
            } else if Date().timeIntervalSince(lastData) > idleTimeout {
                if let response = try parser.feed(Data(), endOfStream: true) { return response }
                throw HTTPError.noResponse(path: path)
            }
        }
    }

    public func get(_ path: String, timeout: TimeInterval? = nil) throws -> HTTPResponse {
        let r = try request("GET", path, timeout: timeout)
        guard r.isSuccess else { throw HTTPError.unexpectedStatus(r.status, r.reason, path: path) }
        return r
    }
}
