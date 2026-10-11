import Foundation
import Compression

/// Raw DEFLATE / gzip / zip helpers on top of Apple's Compression framework
/// (COMPRESSION_ZLIB is raw deflate, RFC 1951, without zlib/gzip headers).
enum Inflate {
    /// Inflate a raw deflate stream. `expectedSize` is a hint (exact size when known).
    static func raw(_ input: Data, expectedSize: Int? = nil) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SteamDepotError.corrupt("inflate init failed")
        }
        defer { compression_stream_destroy(&stream) }

        let chunk = max(64 * 1024, min(expectedSize ?? 0, 64 * 1024 * 1024))
        var out = Data()
        out.reserveCapacity(expectedSize ?? input.count * 4)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }

        return try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 { out.append(buffer, count: produced) }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { return out }
                default: throw SteamDepotError.corrupt("inflate failed")
                }
            }
        }
    }

    /// Decode a gzip member (RFC 1952).
    static func gunzip(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        var r = ByteReader(data)
        guard try r.u8() == 0x1f, try r.u8() == 0x8b, try r.u8() == 8 else {
            throw SteamDepotError.corrupt("not gzip")
        }
        let flags = try r.u8()
        _ = try r.take(6) // mtime, xfl, os
        if flags & 0x04 != 0 { let xlen = Int(try r.u16()); _ = try r.take(xlen) }
        if flags & 0x08 != 0 { while try r.u8() != 0 {} }
        if flags & 0x10 != 0 { while try r.u8() != 0 {} }
        if flags & 0x02 != 0 { _ = try r.take(2) }
        let body = data.subdata(in: r.pos..<max(r.pos, data.endIndex - 8))
        return try raw(body, expectedSize: expectedSize)
    }

    /// Extract the first entry of a zip archive (Steam manifests are a zip with one file "z").
    static func unzipFirst(_ data: Data) throws -> Data {
        // Locate End Of Central Directory record.
        let bytes = [UInt8](data)
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65535) {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        func le32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func le16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        guard eocd >= 0 else { throw SteamDepotError.corrupt("zip: no EOCD") }
        let cdOffset = le32(eocd + 16)
        guard cdOffset + 46 <= bytes.count, le32(cdOffset) == 0x02014b50 else { throw SteamDepotError.corrupt("zip: bad central dir") }
        let method = le16(cdOffset + 10)
        let compSize = le32(cdOffset + 20)
        let uncompSize = le32(cdOffset + 24)
        let localOffset = le32(cdOffset + 42)
        guard le32(localOffset) == 0x04034b50 else { throw SteamDepotError.corrupt("zip: bad local header") }
        let dataStart = localOffset + 30 + le16(localOffset + 26) + le16(localOffset + 28)
        guard dataStart + compSize <= bytes.count else { throw SteamDepotError.corrupt("zip: truncated") }
        let payload = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataStart + compSize))
        switch method {
        case 0: return payload
        case 8:
            let out = try raw(payload, expectedSize: uncompSize)
            guard out.count == uncompSize else { throw SteamDepotError.corrupt("zip: size mismatch") }
            return out
        default: throw SteamDepotError.corrupt("zip: unsupported method \(method)")
        }
    }
}
