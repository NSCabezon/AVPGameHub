import CryptoKit
import Foundation

// The backup format shared by the Mac copies (SaveBackupStore) and the headset's iCloud copies
// (SaveVault): <base>/<target>/<YYYY-MM-DDTHH-MM-SSZ>/{manifest.json, files/<container-relative
// path>}. One reader works for both.

public struct SaveManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var sha256: String
        public init(path: String, size: Int64, sha256: String) {
            self.path = path; self.size = size; self.sha256 = sha256
        }
    }
    public var version = 1
    public var target: String
    public var bundle: String
    public var created: Date
    /// "manual", "all", "pre-restore", "auto".
    public var reason: String
    /// Who made it (the headset's device name). nil in Mac backups and older manifests.
    public var device: String?
    public var files: [Entry]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public init(target: String, bundle: String, created: Date, reason: String, device: String? = nil, files: [Entry]) {
        self.target = target; self.bundle = bundle; self.created = created; self.reason = reason
        self.device = device; self.files = files
    }

    /// Same files with the same contents.
    public func sameContents(as other: SaveManifest) -> Bool {
        Dictionary(files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
            == Dictionary(other.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
    }
}

public struct SaveBackup: Identifiable, Hashable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    public let manifest: SaveManifest
    public init(directory: URL, manifest: SaveManifest) { self.directory = directory; self.manifest = manifest }
    public var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }
    public func localURL(_ path: String) -> URL { filesDirectory.appendingPathComponent(path) }
    public static func == (a: SaveBackup, b: SaveBackup) -> Bool { a.directory == b.directory }
    public func hash(into h: inout Hasher) { h.combine(directory) }
}

public enum SaveBackupError: Error, CustomStringConvertible {
    case missingFile(String)
    public var description: String {
        switch self { case .missingFile(let p): return "missing \(p)" }
    }
}

/// The on-disk format: stamps, manifest coding, hashing. Shared by SaveBackupStore and SaveVault.
public enum SaveFormat {
    public static let manifestName = "manifest.json"
    public static let filesName = "files"

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    /// "2026-10-12T18-30-05Z".
    public static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
    /// The date of a backup directory name ("…Z" or "…Z-2" after a same-second collision).
    public static func date(fromStamp s: String) -> Date? {
        if let d = stampFormatter.date(from: s) { return d }
        guard let dash = s.lastIndex(of: "-"), Int(s[s.index(after: dash)...]) != nil else { return nil }
        return stampFormatter.date(from: String(s[..<dash]))
    }

    /// Staging and hidden directories (".tmp-<uuid>", "<stamp>.partial", ".DS_Store", iCloud
    /// placeholders) are never finished backups.
    public static func isBackupDirectoryName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.hasSuffix(".partial")
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The finished backup in `dir`, if its manifest is there, readable and of `target`.
    public static func readBackup(_ dir: URL, target: String) -> SaveBackup? {
        guard isBackupDirectoryName(dir.lastPathComponent),
              let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)),
              let m = try? decoder().decode(SaveManifest.self, from: data), m.target == target else { return nil }
        return SaveBackup(directory: dir, manifest: m)
    }

    public static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `<dir>/<name>`, or `<name>-2`, `-3`… if taken.
    static func freeName(in dir: URL, _ name: String) -> URL {
        var final = dir.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: final.path) {
            final = dir.appendingPathComponent(name + "-\(n)", isDirectory: true); n += 1
        }
        return final
    }
}

/// The Mac copies: <base>/<target>/<timestamp>/{manifest.json, files/<container-relative path>}.
/// Files arrive by devicectl, so the caller stages them (`begin`) and seals them (`finish`).
public struct SaveBackupStore: Sendable {
    public let base: URL
    public static let manifestName = SaveFormat.manifestName
    public static let keepDefault = 10

    public init(base: URL) { self.base = base }

    public func directory(_ target: String) -> URL { base.appendingPathComponent(target, isDirectory: true) }

    /// Finished backups of `target`, newest first. Partial or unreadable ones are skipped.
    public func list(_ target: String) -> [SaveBackup] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: directory(target), includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { SaveFormat.readBackup($0, target: target) }
            .sorted { ($0.manifest.created, $0.directory.lastPathComponent) > ($1.manifest.created, $1.directory.lastPathComponent) }
    }

    /// A fresh staging directory; copy each save to `<returned>/files/<path>`, then `finish`.
    public func begin(_ target: String, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = directory(target)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Leftovers of an interrupted backup are never data anyone relies on.
        for d in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where d.lastPathComponent.hasSuffix(".partial") { try? fm.removeItem(at: d) }
        let staging = dir.appendingPathComponent(SaveFormat.stamp(date) + ".partial", isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent(SaveFormat.filesName), withIntermediateDirectories: true)
        return staging
    }

    public enum Finish: Sendable { case created(SaveBackup), unchanged(SaveBackup) }

    /// Hashes the staged `paths`, writes the manifest and makes the backup final. When the newest
    /// backup already holds the same contents the staging is dropped and that one is returned.
    public func finish(staging: URL, target: String, bundle: String, reason: String, paths: [String],
                       date: Date = Date()) throws -> Finish {
        let fm = FileManager.default
        var entries: [SaveManifest.Entry] = []
        for p in paths.sorted() {
            let u = staging.appendingPathComponent(SaveFormat.filesName).appendingPathComponent(p)
            guard let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber else {
                throw SaveBackupError.missingFile(p)
            }
            entries.append(.init(path: p, size: size.int64Value, sha256: try SaveFormat.sha256(u)))
        }
        let m = SaveManifest(target: target, bundle: bundle, created: date, reason: reason, files: entries)
        if let latest = list(target).first, latest.manifest.sameContents(as: m) {
            try? fm.removeItem(at: staging)
            return .unchanged(latest)
        }
        try SaveFormat.encoder().encode(m).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
        let final = SaveFormat.freeName(in: directory(target), String(staging.lastPathComponent.dropLast(".partial".count)))
        try fm.moveItem(at: staging, to: final)
        return .created(SaveBackup(directory: final, manifest: m))
    }

    /// Keeps the newest `keep` backups of `target` (plus any in `protecting`); removes the rest.
    @discardableResult
    public func rotate(_ target: String, keep: Int = keepDefault, protecting: Set<URL> = []) -> [URL] {
        let all = list(target)
        let protected = Set(protecting.map { $0.resolvingSymlinksInPath().path })
        var removed: [URL] = []
        for b in all.dropFirst(max(0, keep)) where !protected.contains(b.directory.resolvingSymlinksInPath().path) {
            if (try? FileManager.default.removeItem(at: b.directory)) != nil { removed.append(b.directory) }
        }
        return removed
    }

    /// Paths whose local copy is missing or does not match the manifest. Empty = intact.
    public func verify(_ b: SaveBackup) -> [String] {
        b.manifest.files.filter { e in
            guard SaveTable.isSafeRelativePath(e.path) else { return true }
            return (try? Self.sha256(b.localURL(e.path))) != e.sha256
        }.map(\.path)
    }

    public static func sha256(_ url: URL) throws -> String { try SaveFormat.sha256(url) }
}
