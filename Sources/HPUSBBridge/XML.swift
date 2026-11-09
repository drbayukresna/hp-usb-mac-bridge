// SPDX-License-Identifier: GPL-3.0-or-later
//
// Namespace-agnostic XML helpers. LEDM documents use many vendor namespaces
// whose prefixes differ between firmware versions, so lookups match on the
// element's local name only.

import Foundation

public struct XMLNodeView {
    let node: XMLNode

    public init(_ node: XMLNode) { self.node = node }

    public init(data: Data) throws {
        let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let root = doc.rootElement() else {
            throw HTTPError.malformedResponse("XML document has no root element")
        }
        node = root
    }

    public var name: String { node.localName ?? node.name ?? "" }
    public var text: String { (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// All descendants (any depth) with the given local name.
    public func all(_ localName: String) -> [XMLNodeView] {
        let nodes = (try? node.nodes(forXPath: ".//*[local-name()='\(localName)']")) ?? []
        return nodes.map(XMLNodeView.init)
    }

    /// First descendant with the given local name.
    public func first(_ localName: String) -> XMLNodeView? { all(localName).first }

    /// Text of the first descendant with the given local name.
    public func value(_ localName: String) -> String? { first(localName)?.text }

    /// Direct children elements.
    public var children: [XMLNodeView] {
        (node.children ?? []).filter { $0.kind == .element }.map(XMLNodeView.init)
    }
}

enum XMLEscape {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
