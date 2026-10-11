import Foundation

/// Parsed depot manifest (protobuf "version 5" format from the CDN).
public struct DepotManifest: Sendable {
    public struct Chunk: Sendable, Hashable {
        public let sha: Data          // chunk id (20 bytes)
        public let checksum: UInt32   // Steam adler of uncompressed data
        public let offset: UInt64
        public let uncompressedLength: UInt32
        public let compressedLength: UInt32
        public var id: String { sha.hex }
    }

    public struct File: Sendable {
        public var name: String       // relative path with '/' separators
        public let size: UInt64
        public let flags: UInt32
        public let shaContent: Data
        public let chunks: [Chunk]
        public var linkTarget: String?

        public var isDirectory: Bool { flags & 64 != 0 }
        public var isExecutable: Bool { flags & 32 != 0 }
        public var isSymlink: Bool { flags & 512 != 0 }
    }

    public let depotID: UInt32
    public let manifestID: UInt64
    public let creationTime: Date
    public var filenamesEncrypted: Bool
    public let totalUncompressed: UInt64
    public let totalCompressed: UInt64
    public var files: [File]

    static let payloadMagic: UInt32 = 0x71F6_17D0
    static let metadataMagic: UInt32 = 0x1F48_12BE
    static let signatureMagic: UInt32 = 0x1B81_B817
    static let endMagic: UInt32 = 0x32C4_15AB

    /// Parse the raw (already unzipped) manifest bytes.
    public static func parse(_ data: Data) throws -> DepotManifest {
        var r = ByteReader(data)
        var payload: ProtoMessage?
        var metadata: ProtoMessage?
        while r.remaining >= 4 {
            let magic = try r.u32()
            if magic == endMagic { break }
            let len = Int(try r.u32())
            let section = try r.take(len)
            switch magic {
            case payloadMagic: payload = try ProtoMessage(section)
            case metadataMagic: metadata = try ProtoMessage(section)
            case signatureMagic: break
            default: throw SteamDepotError.corrupt(String(format: "unknown manifest section magic 0x%08x", magic))
            }
        }
        guard let payload, let metadata else { throw SteamDepotError.corrupt("manifest missing payload/metadata") }

        let files: [File] = try payload.messages(1).map { m in
            let chunks = try m.messages(6).map { c in
                Chunk(sha: c.bytes(1) ?? Data(), checksum: c.u32(2) ?? 0, offset: c.u64(3) ?? 0,
                      uncompressedLength: c.u32(4) ?? 0, compressedLength: c.u32(5) ?? 0)
            }.sorted { $0.offset < $1.offset }
            let link = m.string(7)
            return File(name: m.string(1) ?? "", size: m.u64(2) ?? 0, flags: m.u32(3) ?? 0,
                        shaContent: m.bytes(5) ?? Data(), chunks: chunks, linkTarget: (link?.isEmpty ?? true) ? nil : link)
        }
        return DepotManifest(depotID: metadata.u32(1) ?? 0, manifestID: metadata.u64(2) ?? 0,
                             creationTime: Date(timeIntervalSince1970: TimeInterval(metadata.u32(3) ?? 0)),
                             filenamesEncrypted: metadata.bool(4) ?? false,
                             totalUncompressed: metadata.u64(5) ?? 0, totalCompressed: metadata.u64(6) ?? 0,
                             files: files)
    }

    /// Decrypt base64 AES filenames with the depot key, normalise separators to '/'.
    public mutating func decryptFilenames(key: Data) throws {
        if filenamesEncrypted {
            func dec(_ s: String) throws -> String {
                guard let raw = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else {
                    throw SteamDepotError.corrupt("filename is not base64")
                }
                var plain = try DepotCrypto.symmetricDecrypt(raw, key: key)
                if let z = plain.firstIndex(of: 0) { plain = plain.prefix(upTo: z) }
                return String(decoding: plain, as: UTF8.self)
            }
            for i in files.indices {
                files[i].name = try dec(files[i].name)
                if let l = files[i].linkTarget { files[i].linkTarget = try dec(l) }
            }
            filenamesEncrypted = false
        }
        for i in files.indices {
            files[i].name = files[i].name.replacingOccurrences(of: "\\", with: "/")
            files[i].linkTarget = files[i].linkTarget?.replacingOccurrences(of: "\\", with: "/")
        }
        files.sort { $0.name.lowercased() < $1.name.lowercased() }
    }
}
