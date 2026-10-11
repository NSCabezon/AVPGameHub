import Foundation

/// Minimal protobuf (proto2 wire format) writer. Steam's messages are small and we only need a
/// handful of fields, so a hand-rolled codec avoids pulling in swift-protobuf + protoc codegen.
/// Field numbers come from SteamDatabase/Protobufs (see Messages.swift).
struct ProtoWriter {
    private(set) var data = Data()

    init() {}

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func uint(_ field: Int, _ v: UInt64?) {
        guard let v else { return }
        tag(field, 0); varint(v)
    }
    mutating func uint(_ field: Int, _ v: UInt32?) { uint(field, v.map(UInt64.init)) }
    mutating func int(_ field: Int, _ v: Int32?) {
        guard let v else { return }
        tag(field, 0); varint(UInt64(bitPattern: Int64(v)))
    }
    mutating func bool(_ field: Int, _ v: Bool?) { uint(field, v.map { $0 ? UInt64(1) : 0 }) }

    mutating func fixed64(_ field: Int, _ v: UInt64?) {
        guard let v else { return }
        tag(field, 1)
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func fixed32(_ field: Int, _ v: UInt32?) {
        guard let v else { return }
        tag(field, 5)
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ field: Int, _ v: Data?) {
        guard let v else { return }
        tag(field, 2); varint(UInt64(v.count)); data.append(v)
    }
    mutating func string(_ field: Int, _ v: String?) { bytes(field, v.map { Data($0.utf8) }) }
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var w = ProtoWriter()
        build(&w)
        bytes(field, w.data)
    }
}

/// Minimal protobuf reader: decodes a message into field-number -> [raw values].
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        var r = ByteReader(data)
        while !r.atEnd {
            let key = try r.varint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0: value = .varint(try r.varint())
            case 1: value = .fixed64(try r.u64())
            case 2:
                let len = Int(try r.varint())
                value = .bytes(try r.take(len))
            case 5: value = .fixed32(try r.u32())
            default: throw SteamDepotError.protocolError("unsupported protobuf wire type \(key & 7)")
            }
            fields[field, default: []].append(value)
        }
    }

    func has(_ f: Int) -> Bool { fields[f] != nil }

    func u64(_ f: Int) -> UInt64? {
        guard let v = fields[f]?.last else { return nil }
        switch v {
        case .varint(let x), .fixed64(let x): return x
        case .fixed32(let x): return UInt64(x)
        case .bytes: return nil
        }
    }
    func u32(_ f: Int) -> UInt32? { u64(f).map { UInt32(truncatingIfNeeded: $0) } }
    func i32(_ f: Int) -> Int32? { u64(f).map { Int32(truncatingIfNeeded: $0) } }
    func bool(_ f: Int) -> Bool? { u64(f).map { $0 != 0 } }
    func float(_ f: Int) -> Float? {
        guard case .fixed32(let x)? = fields[f]?.last else { return nil }
        return Float(bitPattern: x)
    }
    func bytes(_ f: Int) -> Data? {
        guard case .bytes(let d)? = fields[f]?.last else { return nil }
        return d
    }
    func string(_ f: Int) -> String? { bytes(f).map { String(decoding: $0, as: UTF8.self) } }
    func message(_ f: Int) throws -> ProtoMessage? { try bytes(f).map(ProtoMessage.init) }
    func messages(_ f: Int) throws -> [ProtoMessage] {
        try (fields[f] ?? []).compactMap { if case .bytes(let d) = $0 { return try ProtoMessage(d) } else { return nil } }
    }
    func strings(_ f: Int) -> [String] {
        (fields[f] ?? []).compactMap { if case .bytes(let d) = $0 { return String(decoding: d, as: UTF8.self) } else { return nil } }
    }
    /// Repeated scalar varint field, accepting both packed and unpacked encodings.
    func u32s(_ f: Int) -> [UInt32] {
        var out: [UInt32] = []
        for v in fields[f] ?? [] {
            switch v {
            case .varint(let x): out.append(UInt32(truncatingIfNeeded: x))
            case .fixed32(let x): out.append(x)
            case .fixed64(let x): out.append(UInt32(truncatingIfNeeded: x))
            case .bytes(let d):
                var r = ByteReader(d)
                while !r.atEnd, let x = try? r.varint() { out.append(UInt32(truncatingIfNeeded: x)) }
            }
        }
        return out
    }
}

/// Little-endian cursor over Data.
struct ByteReader {
    let data: Data
    var pos: Int

    init(_ data: Data) {
        self.data = data
        self.pos = data.startIndex
    }

    var atEnd: Bool { pos >= data.endIndex }
    var remaining: Int { data.endIndex - pos }

    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw SteamDepotError.protocolError("truncated data") }
        let d = data.subdata(in: pos..<(pos + n))
        pos += n
        return d
    }
    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw SteamDepotError.protocolError("truncated data") }
        defer { pos += 1 }
        return data[pos]
    }
    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[b.startIndex + i]) << (8 * i) }
        return v
    }
    mutating func u64() throws -> UInt64 {
        let b = try take(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[b.startIndex + i]) << (8 * i) }
        return v
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try u8()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw SteamDepotError.protocolError("varint too long") }
        }
    }
}

extension Data {
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        var d = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            d.append(v)
        }
        self = d
    }
}
