//
//  XMLNode.swift
//  SonosBar
//
//  A minimal DOM-style XML wrapper over Foundation's XMLParser (SAX).
//  We deliberately don't pull in a third-party XML library: SOAP envelopes
//  and DIDL-Lite are small and well-structured, and XMLParser is on every
//  Apple platform. The trade-off is a few hundred lines of glue here in
//  exchange for zero external surface area.
//
//  Usage:
//      let root = try XMLNode.parse(data)
//      let volume = root.first("Volume")?.text
//      let players = root.descendants(named: "ZoneGroupMember")
//

import Foundation

final class XMLNode: @unchecked Sendable {

    let name: String
    var attributes: [String: String]
    var children: [XMLNode] = []
    weak var parent: XMLNode?

    // Concatenated text content for this node. Stored as a single string
    // because Sonos responses never mix elements and significant text at
    // the same level — text is either everything or nothing in a node.
    var text: String = ""

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    // MARK: - Convenience traversal

    /// First direct child with the given name.
    func first(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// All direct children with the given name.
    func all(_ name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    /// Depth-first descendants matching the name (any depth below self).
    func descendants(named name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(named: name))
        }
        return result
    }

    /// Trimmed text — Sonos likes to wrap values with whitespace/newlines.
    var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    enum ParseError: Error {
        case invalidXML(underlying: Error?)
        case emptyDocument
    }

    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidXML(underlying: parser.parserError)
        }
        guard let root = delegate.root else {
            throw ParseError.emptyDocument
        }
        return root
    }

    static func parse(_ string: String) throws -> XMLNode {
        guard let data = string.data(using: .utf8) else {
            throw ParseError.emptyDocument
        }
        return try parse(data)
    }

    // MARK: - SAX delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
                node.parent = parent
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        // CDATA blocks (used heavily in DIDL-Lite responses) come through
        // a different delegate call than regular text. We treat them
        // identically — the consumer can re-parse the CDATA contents as
        // XML if they need to (favorite metadata is XML-in-CDATA).
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.text += s
            }
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}
