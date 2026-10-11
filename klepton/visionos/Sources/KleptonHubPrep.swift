// The hub's last step before booting an APK game: derive, on the headset, what
// the runtime reads, from the data the headset downloaded itself (from Steam or,
// through MetaStore, from Meta's store — whichever store is active for the game,
// KLCatalog.sourceAPK).
//
// A single-game build has run.sh/stage_assets.sh push three things from the
// Mac into the container: <tree>.apk, the apktool tree's <tree>/assets, and the
// two metadata files beside it. The hub stages nothing (its games download their
// own data), so for a game whose download is an APK (SteamGameDescriptor.apk, or
// a Meta recipe's apk file in <container>/meta/; its OBBs land in place already)
// this does the same on device, laid out exactly as kl_app_configure expects
// under the game's container root (Documents/games/<target>/):
//
//   <apk>              the downloaded APK, HARD-LINKED under the runtime's name
//                      (no second copy; getPackageCodePath() hands this path to
//                      Unity, which mounts it as a zip and reads its data from it)
//   <tree>/assets/     only the APK's SMALL assets/ entries (<= 16 MB each:
//                      boot.config, global-metadata.dat, the json manifests...),
//                      extracted — what the AssetManager doors and raw opens of
//                      "<apk>/assets/..." are served from. The bulk (SUPERHOT's
//                      data.unity3d / resources.resource, ~590 MB stored) stays in
//                      the APK, where Unity reads it; extracting it would double
//                      the game's footprint for nothing.
//   <tree>/apktool.yml, <tree>/AndroidManifest.xml
//                      versionCode / package / <meta-data>, baked into the build's
//                      manifest from the Mac's apktool tree (gen_xcodeproj.py):
//                      metadata, not game data, and decoding the APK's binary
//                      manifest here would be a second apktool.
//
// Idempotent: the extraction is stamped with the APK's size and mtime, so it
// reruns only when Steam changes the APK; the link is re-made if it no longer
// points at the downloaded file's inode.
#if KL_HUB
import Foundation

enum HubPrep {
    /// Entries larger than this stay inside the APK.
    static let maxExtract: UInt64 = 16 << 20
    /// Bump when what is derived changes, to redo it on every device.
    static let schema = 1

    /// nil when the game is ready to boot (or has nothing to derive), else why not.
    static func prepare(_ row: KLHubGameRow) -> String? {
        let fm = FileManager.default
        let container = Paths.containerURL(for: row.target)
        let tree = container.appendingPathComponent(row.tree, isDirectory: true)
        do {
            if !row.meta.isEmpty {
                try fm.createDirectory(at: tree, withIntermediateDirectories: true)
                for (name, b64) in row.meta {
                    guard let data = Data(base64Encoded: b64) else { continue }
                    let url = tree.appendingPathComponent(name)
                    if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
                }
            }
            // The APK the active store downloaded (Steam depot or Meta recipe; KleptonCatalog.swift).
            guard let source = KLCatalog.sourceAPK(row.target) else { return nil }
            let src = source.url, depotAPK = source.label
            guard let attrs = try? fm.attributesOfItem(atPath: src.path) else {
                return "\(depotAPK) has not been downloaded"
            }

            // The APK, under the runtime's name.
            let dst = container.appendingPathComponent(row.apk)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            let have = ((try? fm.attributesOfItem(atPath: dst.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
            if inode == nil || inode != have {
                try? fm.removeItem(at: dst)
                do {
                    try fm.linkItem(at: src, to: dst)          // same volume: no copy
                } catch {
                    try fm.createSymbolicLink(at: dst, withDestinationURL: src)
                }
                NSLog("[hub] \(row.target): \(row.apk) -> \(depotAPK)")
            }

            // The small assets/ entries.
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let stamp = "v\(schema) \(size) \(mtime) \(maxExtract)\n"
            let stampURL = tree.appendingPathComponent(".klepton-assets")
            let assets = tree.appendingPathComponent("assets", isDirectory: true)
            if fm.fileExists(atPath: assets.path), (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp {
                return nil
            }
            let tmp = tree.appendingPathComponent("assets.partial", isDirectory: true)
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let t0 = Date()
            let (n, bytes) = try ZipReader(url: src).extract(prefix: "assets/", maxSize: maxExtract, into: tmp)
            try? fm.removeItem(at: assets)
            try fm.moveItem(at: tmp, to: assets)
            try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            NSLog("[hub] \(row.target): extracted \(n) assets/ entries (\(bytes) bytes) from \(depotAPK) "
                  + "in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            return nil
        } catch {
            return "\(error)"
        }
    }
}

/// Just enough of a zip reader for an APK: the central directory, stored and
/// deflated entries. No zip64 (an APK's central directory fits in 32 bits).
struct ZipReader {
    enum Failure: Error, CustomStringConvertible {
        case notZip, zip64, truncated(String), unsupported(String), corrupt(String)
        var description: String {
            switch self {
            case .notZip: return "not a zip file"
            case .zip64: return "zip64 is not supported"
            case .truncated(let w): return "truncated zip (\(w))"
            case .unsupported(let w): return "unsupported zip entry (\(w))"
            case .corrupt(let w): return "corrupt zip entry (\(w))"
            }
        }
    }

    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localHeader: UInt64
    }

    private let fh: FileHandle
    private let length: UInt64

    init(url: URL) throws {
        fh = try FileHandle(forReadingFrom: url)
        length = try fh.seekToEnd()
    }

    private func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
        try fh.seek(toOffset: offset)
        guard let d = try fh.read(upToCount: count), d.count == count else { throw Failure.truncated("at \(offset)") }
        return [UInt8](d)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    func entries() throws -> [Entry] {
        // End of central directory: 22 bytes plus a comment of up to 64 KB.
        let tailLen = Int(min(length, 22 + 65535))
        guard tailLen >= 22 else { throw Failure.notZip }
        let tail = try read(length - UInt64(tailLen), tailLen)
        var eocd = -1
        var i = tailLen - 22
        while i >= 0 {
            if Self.u32(tail, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        let count = Int(Self.u16(tail, eocd + 10))
        let cdSize = Self.u32(tail, eocd + 12)
        let cdOffset = Self.u32(tail, eocd + 16)
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw Failure.zip64 }
        let cd = try read(UInt64(cdOffset), Int(cdSize))
        var out: [Entry] = []
        out.reserveCapacity(count)
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, Self.u32(cd, p) == 0x0201_4b50 else { throw Failure.truncated("central directory") }
            let nameLen = Int(Self.u16(cd, p + 28)), extraLen = Int(Self.u16(cd, p + 30))
            let commentLen = Int(Self.u16(cd, p + 32))
            guard p + 46 + nameLen <= cd.count else { throw Failure.truncated("central directory") }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            out.append(Entry(name: name, method: Self.u16(cd, p + 10), flags: Self.u16(cd, p + 8),
                             compressedSize: UInt64(Self.u32(cd, p + 20)), size: UInt64(Self.u32(cd, p + 24)),
                             localHeader: UInt64(Self.u32(cd, p + 42))))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    func data(_ e: Entry) throws -> Data {
        if e.flags & 1 != 0 { throw Failure.unsupported("\(e.name) is encrypted") }
        let lh = try read(e.localHeader, 30)
        guard Self.u32(lh, 0) == 0x0403_4b50 else { throw Failure.corrupt("\(e.name): no local header") }
        let start = e.localHeader + 30 + UInt64(Self.u16(lh, 26)) + UInt64(Self.u16(lh, 28))
        let raw = Data(try read(start, Int(e.compressedSize)))
        switch e.method {
        case 0:
            guard raw.count == Int(e.size) else { throw Failure.corrupt("\(e.name): stored size") }
            return raw
        case 8:
            if e.size == 0 { return Data() }
            // .zlib is raw DEFLATE (RFC 1951), which is what a zip entry holds.
            let out = try (raw as NSData).decompressed(using: .zlib) as Data
            guard out.count == Int(e.size) else { throw Failure.corrupt("\(e.name): inflated size") }
            return out
        default:
            throw Failure.unsupported("\(e.name): method \(e.method)")
        }
    }

    /// Extract every file entry under `prefix` of at most `maxSize` bytes into
    /// `dir` (the prefix stripped). Returns (files, bytes).
    func extract(prefix: String, maxSize: UInt64, into dir: URL) throws -> (Int, UInt64) {
        let fm = FileManager.default
        var n = 0
        var bytes: UInt64 = 0
        for e in try entries() where e.name.hasPrefix(prefix) && !e.name.hasSuffix("/") && e.size <= maxSize {
            let rel = String(e.name.dropFirst(prefix.count))
            let parts = rel.split(separator: "/")
            // An entry name is data from the APK: never let it leave `dir`.
            guard !rel.isEmpty, !rel.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." }) else { continue }
            let url = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(e).write(to: url)
            n += 1
            bytes += e.size
        }
        return (n, bytes)
    }
}
#endif
