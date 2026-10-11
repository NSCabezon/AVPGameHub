import Foundation

/// Text KeyValues (VDF) tree, as returned in PICS app info buffers.
public final class KeyValue: @unchecked Sendable, CustomStringConvertible {
    public let name: String
    public var value: String?
    public var children: [KeyValue] = []

    init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }

    /// Case-insensitive child lookup (like SteamKit's KeyValue indexer).
    public subscript(key: String) -> KeyValue? {
        children.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    public var description: String { render(indent: 0) }

    private func render(indent: Int) -> String {
        let pad = String(repeating: "\t", count: indent)
        if let value { return "\(pad)\"\(name)\"\t\t\"\(value)\"\n" }
        var s = "\(pad)\"\(name)\"\n\(pad){\n"
        for c in children { s += c.render(indent: indent + 1) }
        return s + "\(pad)}\n"
    }

    /// Parse text VDF. Returns the root key.
    public static func parse(text: String) throws -> KeyValue {
        var p = Parser(scalars: Array(text.unicodeScalars))
        guard let rootName = try p.token(), case .string(let name) = rootName else {
            throw SteamDepotError.protocolError("VDF: empty")
        }
        let root = KeyValue(name: name)
        guard case .open? = try p.token() else { throw SteamDepotError.protocolError("VDF: expected {") }
        try p.parseBody(into: root)
        return root
    }

    /// Parse binary KeyValues (as in PICS *package* info buffers, after their 4-byte header).
    /// Every scalar is stored as its decimal/string form so lookups work like the text tree.
    public static func parseBinary(_ data: Data) throws -> KeyValue {
        var r = BinaryReader(bytes: [UInt8](data))
        let root = KeyValue(name: "")
        try r.parseBody(into: root)
        guard root.children.count == 1, let only = root.children.first else {
            if root.children.isEmpty { throw SteamDepotError.protocolError("binary VDF: empty") }
            return root
        }
        return only
    }

    private struct BinaryReader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() throws -> UInt8 {
            guard i < bytes.count else { throw SteamDepotError.protocolError("binary VDF: truncated") }
            defer { i += 1 }
            return bytes[i]
        }
        mutating func le(_ n: Int) throws -> UInt64 {
            guard i + n <= bytes.count else { throw SteamDepotError.protocolError("binary VDF: truncated") }
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(bytes[i + k]) << (8 * k) }
            i += n
            return v
        }
        mutating func cString() throws -> String {
            guard let end = bytes[i...].firstIndex(of: 0) else { throw SteamDepotError.protocolError("binary VDF: unterminated string") }
            defer { i = end + 1 }
            return String(decoding: bytes[i..<end], as: UTF8.self)
        }

        mutating func parseBody(into node: KeyValue) throws {
            while i < bytes.count {
                let type = try byte()
                if type == 8 || type == 11 { return } // end of subtree
                let name = try cString()
                switch type {
                case 0:
                    let child = KeyValue(name: name)
                    try parseBody(into: child)
                    node.children.append(child)
                case 1: node.children.append(KeyValue(name: name, value: try cString()))
                case 2, 4, 6: node.children.append(KeyValue(name: name, value: String(Int32(truncatingIfNeeded: try le(4)))))
                case 3: node.children.append(KeyValue(name: name, value: String(Float(bitPattern: UInt32(try le(4))))))
                case 5: // UTF-16LE, NUL-terminated
                    var units: [UInt16] = []
                    while true { let u = UInt16(try le(2)); if u == 0 { break }; units.append(u) }
                    node.children.append(KeyValue(name: name, value: String(decoding: units, as: UTF16.self)))
                case 7: node.children.append(KeyValue(name: name, value: String(try le(8))))
                case 10: node.children.append(KeyValue(name: name, value: String(Int64(bitPattern: try le(8)))))
                default: throw SteamDepotError.protocolError("binary VDF: unknown type \(type)")
                }
            }
        }
    }

    private struct Parser {
        enum Tok { case string(String), open, close }
        let scalars: [Unicode.Scalar]
        var i = 0

        mutating func skipWS() {
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
                if c == "/" && i + 1 < scalars.count && scalars[i + 1] == "/" {
                    while i < scalars.count && scalars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "[" { // conditional like [$WIN32]
                    while i < scalars.count && scalars[i] != "]" { i += 1 }
                    i += 1
                    continue
                }
                break
            }
        }

        mutating func token() throws -> Tok? {
            skipWS()
            guard i < scalars.count else { return nil }
            let c = scalars[i]
            if c == "{" { i += 1; return .open }
            if c == "}" { i += 1; return .close }
            var s = String.UnicodeScalarView()
            if c == "\"" {
                i += 1
                while i < scalars.count && scalars[i] != "\"" {
                    if scalars[i] == "\\" && i + 1 < scalars.count {
                        i += 1
                        switch scalars[i] {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        case "\\": s.append("\\")
                        case "\"": s.append("\"")
                        default: s.append("\\"); s.append(scalars[i])
                        }
                    } else {
                        s.append(scalars[i])
                    }
                    i += 1
                }
                i += 1
            } else {
                while i < scalars.count {
                    let d = scalars[i]
                    if d == " " || d == "\t" || d == "\n" || d == "\r" || d == "{" || d == "}" || d == "\"" { break }
                    s.append(d); i += 1
                }
            }
            return .string(String(s))
        }

        mutating func parseBody(into node: KeyValue) throws {
            while true {
                guard let t = try token() else { return } // tolerate missing close
                switch t {
                case .close: return
                case .open: throw SteamDepotError.protocolError("VDF: unexpected {")
                case .string(let key):
                    guard let v = try token() else { throw SteamDepotError.protocolError("VDF: missing value") }
                    switch v {
                    case .string(let value): node.children.append(KeyValue(name: key, value: value))
                    case .open:
                        let child = KeyValue(name: key)
                        try parseBody(into: child)
                        node.children.append(child)
                    case .close: throw SteamDepotError.protocolError("VDF: unexpected }")
                    }
                }
            }
        }
    }
}
