import Foundation

/// Decrypt + decompress + verify one depot chunk (mirrors SteamKit2 CDN/DepotChunk.cs).
public enum DepotChunk {
    public enum Format: String, Sendable { case vzip = "VZip/LZMA", vzstd = "VZstd", pkzip = "PKZip" }

    public static func process(_ encrypted: Data, chunk: DepotManifest.Chunk, key: Data) throws -> (Data, Format) {
        let plain = try DepotCrypto.symmetricDecrypt(encrypted, key: key)
        guard plain.count >= 16 else { throw SteamDepotError.corrupt("chunk \(chunk.id): too short") }
        let b = [UInt8](plain.prefix(4))
        let out: Data
        let format: Format
        if b == [0x56, 0x53, 0x5A, 0x61] { // "VSZa"
            out = try vzstd(plain, expected: Int(chunk.uncompressedLength))
            format = .vzstd
        } else if b[0] == 0x56 && b[1] == 0x5A && b[2] == 0x61 { // "VZa"
            out = try vzip(plain, expected: Int(chunk.uncompressedLength))
            format = .vzip
        } else if b == [0x50, 0x4B, 0x03, 0x04] {
            out = try Inflate.unzipFirst(plain)
            format = .pkzip
        } else {
            throw SteamDepotError.corrupt("chunk \(chunk.id): unknown compression \(Data(b).hex)")
        }
        guard out.count == Int(chunk.uncompressedLength) else {
            throw SteamDepotError.corrupt("chunk \(chunk.id): size \(out.count) != \(chunk.uncompressedLength)")
        }
        guard DepotCrypto.adler(out) == chunk.checksum else {
            throw SteamDepotError.corrupt("chunk \(chunk.id): checksum mismatch")
        }
        return (out, format)
    }

    static func vzip(_ data: Data, expected: Int) throws -> Data {
        // header: "VZ" 'a' u32(crc/timestamp) | props u8 | dictSize u32 | lzma… | footer: crc u32, size u32, "zv"
        guard data.count >= 7 + 5 + 10 else { throw SteamDepotError.corrupt("VZip too short") }
        var r = ByteReader(data)
        _ = try r.take(7)
        let props = try r.u8()
        let dict = try r.u32()
        let start = r.pos
        var f = ByteReader(data)
        f.pos = data.endIndex - 10
        _ = try f.u32() // crc
        let size = Int(try f.u32())
        guard try f.u8() == 0x7A, try f.u8() == 0x76 else { throw SteamDepotError.corrupt("VZip footer") }
        guard size == expected else { throw SteamDepotError.corrupt("VZip size \(size) != \(expected)") }
        var out = Data(count: size)
        let compressed = data.subdata(in: start..<(data.endIndex - 10))
        try out.withUnsafeMutableBytes { o in
            try compressed.withUnsafeBytes { i in
                try LZMA.decode(properties: props, dictSize: dict, input: i, output: o, outSize: size)
            }
        }
        return out
    }

    static func vzstd(_ data: Data, expected: Int) throws -> Data {
        guard data.count >= 8 + 15 else { throw SteamDepotError.corrupt("VZstd too short") }
        let end = data.endIndex
        guard data[end - 3] == 0x7A, data[end - 2] == 0x73, data[end - 1] == 0x76 else {
            throw SteamDepotError.corrupt("VZstd footer")
        }
        var f = ByteReader(data)
        f.pos = end - 11
        let size = Int(try f.u32())
        guard size == expected else { throw SteamDepotError.corrupt("VZstd size \(size) != \(expected)") }
        let frame = data.subdata(in: (data.startIndex + 8)..<(end - 15))
        return try Zstd.decompress(frame, expectedSize: size)
    }
}
