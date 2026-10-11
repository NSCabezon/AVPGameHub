import Foundation

/// File-level helpers for setting up Meta's ovr-platform-util: spotting a finished download
/// (the bare tool or a zip holding it), finding the tool inside an unpacked zip, and telling
/// whether a binary can run natively or needs Rosetta. No signature checks here — those live in
/// MetaStore.MetaTool and are always applied before anything is installed.
/// Ideas adapted from avp-play (MIT, github.com/myMartek/avp-play): MetaTool.downloads, Rosetta.
public enum MetaToolFiles {
    public static let toolName = "ovr-platform-util"

    /// Meta's page for the tool. Meta hands the file out only there (no stable public direct link).
    public static let downloadPage = URL(string: "https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/")!

    public static let rosettaCommand = "softwareupdate --install-rosetta --agree-to-license"

    private static let unfinished: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    /// Whether a file name in a downloads folder looks like the tool or a zip of it. Browsers
    /// append " (1)" for duplicates; unfinished downloads are skipped.
    public static func isCandidateName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if unfinished.contains(ext) { return false }
        let looksLikeTool = lower.hasPrefix(toolName) || lower.hasPrefix("ovr_platform_util")
        guard looksLikeTool else { return false }
        return ext.isEmpty || ext == "zip" || lower.hasPrefix(toolName + " (")
    }

    public static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// Candidates in `folders`, newest first, de-duplicated.
    public static func candidates(in folders: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var seen = Set<String>()
        var found: [(URL, Date)] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            for url in items where isCandidateName(url.lastPathComponent) {
                let v = try? url.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true, seen.insert(url.standardizedFileURL.path).inserted else { continue }
                found.append((url, v?.contentModificationDate ?? .distantPast))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The tool inside an unpacked zip (any depth; macOS metadata folders skipped).
    public static func toolInside(_ folder: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in e {
            if url.lastPathComponent == "__MACOSX" { e.skipDescendants(); continue }
            if url.lastPathComponent == toolName,
               (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return url }
        }
        return nil
    }

    /// Whether Intel programs run on this Mac (always true on an Intel Mac).
    public static var rosettaInstalled: Bool {
        #if arch(x86_64)
        return true
        #else
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        #endif
    }

    /// Whether this Mac must have Rosetta to run `file`: true only for a readable Mach-O without
    /// an arm64 slice, on Apple silicon.
    public static func needsRosetta(_ file: URL) -> Bool {
        #if arch(x86_64)
        return false
        #else
        return hasArm64Slice(file) == false
        #endif
    }

    /// Whether a Mach-O file contains an arm64 slice; nil if unreadable or not Mach-O.
    public static func hasArm64Slice(_ file: URL) -> Bool? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 4096), data.count >= 8 else { return nil }
        return hasArm64Slice(header: data)
    }

    public static func hasArm64Slice(header data: Data) -> Bool? {
        let bytes = [UInt8](data)
        func be(_ at: Int) -> UInt32? { at + 4 <= bytes.count ? bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } : nil }
        func le(_ at: Int) -> UInt32? { at + 4 <= bytes.count ? bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : nil }
        let arm64: UInt32 = 0x0100_000C
        guard let magic = be(0) else { return nil }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:                  // universal (fat / fat64)
            let stride = magic == 0xCAFE_BABE ? 20 : 32
            guard let count = be(4), count > 0, count < 32 else { return nil }
            for i in 0..<Int(count) {
                guard let cpu = be(8 + i * stride) else { return nil }
                if cpu == arm64 { return true }
            }
            return false
        case 0xCFFA_EDFE:                               // thin 64-bit, little-endian on disk
            return le(4).map { $0 == arm64 }
        default:
            return nil
        }
    }
}
