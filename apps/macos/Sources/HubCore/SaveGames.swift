import CryptoKit
import Foundation

// Where each hub game keeps its saves inside the hub's app data container, and the Mac-side
// backup store for them. Pure data and file logic: the devicectl calls live in the app
// (AVPGameHub/Saves.swift). The table is read off the Klepton fork; see
// docs/2026-10-12-save-games.md for the why of every row.

/// A directory in the hub's data container that holds (some of) a game's saves.
public struct SaveRoot: Hashable, Sendable {
    /// Container-relative directory ("Documents/games/superhot/android-files/shared_prefs").
    public let path: String
    /// Root-relative path prefixes kept (component-wise); empty = everything under the root.
    public let include: [String]
    /// Root-relative directory names never kept for this game, on top of the global list.
    public let excludeDirs: [String]
    public let what: String

    public init(path: String, include: [String] = [], excludeDirs: [String] = [], what: String) {
        self.path = path; self.include = include; self.excludeDirs = excludeDirs; self.what = what
    }
}

public struct GameSaveLocation: Hashable, Sendable {
    public let target: String
    public let engine: String
    public let roots: [SaveRoot]
}

/// One file (or directory) in a devicectl listing, by its container-relative path.
public struct RemoteFile: Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public init(path: String, size: Int64, isDirectory: Bool = false, isSymbolicLink: Bool = false) {
        self.path = path; self.size = size; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink
    }
}

public enum SaveTable {
    /// The game's container root in the hub (Klepton Paths.containerURL(for:)).
    public static func container(_ t: String) -> String { "Documents/games/\(t)" }
    /// The guest's Android data dir (kl_app.c g_files): getFilesDir/getExternalFilesDir map to
    /// <this>/files (as /sdcard/files), SharedPreferences to <this>/shared_prefs, Meta
    /// CloudStorage2 to <this>/cloudstorage.
    public static func androidFiles(_ t: String) -> String { container(t) + "/android-files" }
    /// kl_userdata_dir(<target>) on the headset: $HOME is the container root.
    public static func userdata(_ t: String) -> String { "Library/Application Support/Klepton/userdata/\(t)" }

    /// A Unity APK guest: Application.persistentDataPath, PlayerPrefs and Meta cloud storage.
    static func unity(_ t: String, excludeDirs: [String] = []) -> GameSaveLocation {
        let a = androidFiles(t)
        return GameSaveLocation(target: t, engine: "Unity", roots: [
            SaveRoot(path: a + "/files", excludeDirs: excludeDirs,
                     what: "Application.persistentDataPath (partidas, ajustes del juego)"),
            SaveRoot(path: a + "/shared_prefs", what: "PlayerPrefs (SharedPreferences .xml)"),
            SaveRoot(path: a + "/cloudstorage", what: "Meta CloudStorage2 (directorio de usuario)"),
        ])
    }

    public static let locations: [GameSaveLocation] = [
        // Source 2 (glibc port): everything the engine writes beside itself lands in kl_glibc's
        // write layer, <userdata>/gameroot; game/hlvr/save is the Steam Auto-Cloud rule.
        GameSaveLocation(target: "alyx", engine: "Source 2 (glibc)", roots: [
            SaveRoot(path: userdata("alyx") + "/gameroot", include: ["hlvr/save", "hlvr/cfg"],
                     what: "game/hlvr/save (partidas) y game/hlvr/cfg (ajustes) en la capa de escritura"),
            SaveRoot(path: userdata("alyx") + "/steam", what: "carpeta de usuario de Steam (kl_steam)"),
        ]),
        unity("superhot"),
        unity("beatsaber", excludeDirs: ["CustomLevels", "CustomWIPLevels"]),
        unity("batman"),
        // UE5: getFilesDir and getExternalFilesDir are both android-files; the engine keeps
        // UnrealGame/<Project>/<Project>/Saved (project "Impact"). Only SaveGames and Config.
        GameSaveLocation(target: "metro", engine: "Unreal Engine 5", roots: [
            SaveRoot(path: androidFiles("metro") + "/UnrealGame", include: ["Impact/Impact/Saved/SaveGames",
                                                                         "Impact/Impact/Saved/Config",
                                                                         "Impact/Saved/SaveGames",
                                                                         "Impact/Saved/Config"],
                     what: "Saved/SaveGames (partidas) y Saved/Config (ajustes .ini)"),
            SaveRoot(path: androidFiles("metro") + "/cloudstorage", what: "Meta CloudStorage2"),
            SaveRoot(path: userdata("metro") + "/steam", what: "carpeta de usuario de Steam (kl_steam)"),
        ]),
        unity("ieytd"),
        unity("ktane"),
    ]

    public static func location(for target: String) -> GameSaveLocation? { locations.first { $0.target == target } }

    /// Directory names that are never saves, anywhere under a root (compared case-insensitively):
    /// engine caches, logs, downloaded content, store bookkeeping.
    public static let excludedDirs: Set<String> = [
        "obb", "cache", "caches", "il2cpp", "unity", "unitycache", "com.unity.addressables", "addressables",
        "shadercache", "shadercaches", "pipelinecache", "logs", "crashes", "profiling", ".steamdepot", "meta",
        "fovea", "klepton-assets",
    ]
    /// File extensions that are game data, caches or logs, never saves.
    public static let excludedExtensions: Set<String> = [
        "apk", "obb", "pak", "utoc", "ucas", "vpk", "foz", "bundle", "mp4", "so", "dylib",
        "upipelinecache", "ushaderbytecode", "ushadercache", "vcs", "log", "dmp",
    ]
    /// A save never gets this big; anything larger is content that slipped through.
    public static let maxFileBytes: Int64 = 256 << 20

    /// `path` (container-relative) is a save of `root`.
    public static func keeps(_ root: SaveRoot, path: String, size: Int64) -> Bool {
        guard isSafeRelativePath(path), size <= maxFileBytes, path.hasPrefix(root.path + "/") else { return false }
        let rel = String(path.dropFirst(root.path.count + 1))
        let comps = rel.split(separator: "/").map(String.init)
        guard let name = comps.last else { return false }
        if !root.include.isEmpty {
            let ok = root.include.contains { inc in
                let ic = inc.split(separator: "/").map(String.init)
                return comps.count > ic.count && Array(comps.prefix(ic.count)) == ic
            }
            if !ok { return false }
        }
        let extra = Set(root.excludeDirs.map { $0.lowercased() })
        for dir in comps.dropLast() {
            let d = dir.lowercased()
            if excludedDirs.contains(d) || extra.contains(d) { return false }
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return !excludedExtensions.contains(ext)
    }

    /// The save files of `target` among `listing` (regular files only, no symlinks).
    public static func saveFiles(_ target: String, in listing: [RemoteFile]) -> [RemoteFile] {
        guard let loc = location(for: target) else { return [] }
        var seen = Set<String>()
        return listing.filter { f in
            guard !f.isDirectory, !f.isSymbolicLink, !seen.contains(f.path) else { return false }
            guard loc.roots.contains(where: { keeps($0, path: f.path, size: f.size) }) else { return false }
            seen.insert(f.path)
            return true
        }.sorted { $0.path < $1.path }
    }

    /// Restore guard: `path` belongs to one of the game's save roots and passes the filters.
    public static func isRestorable(_ target: String, path: String, size: Int64) -> Bool {
        location(for: target)?.roots.contains { keeps($0, path: path, size: size) } ?? false
    }

    /// Relative, no "..", no empty or "." components, no leading slash.
    public static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains("\\"), !p.contains("\0") else { return false }
        return !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

// MARK: - devicectl JSON

public enum DeviceJSON {
    /// `devicectl device info files --json-output` → container-relative files. nil when the
    /// result carries an error or no file list (e.g. the subdirectory does not exist).
    public static func files(_ data: Data, subdirectory: String) -> [RemoteFile]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil,
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else { return nil }
        let base = subdirectory.hasSuffix("/") ? String(subdirectory.dropLast()) : subdirectory
        return files.compactMap { f in
            guard let rel = (f["relativePath"] as? String) ?? (f["name"] as? String), !rel.isEmpty else { return nil }
            let meta = f["metadata"] as? [String: Any] ?? [:]
            let res = f["resources"] as? [String: Any] ?? [:]
            let size = (meta["size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(path: base.isEmpty ? rel : base + "/" + rel, size: size,
                              isDirectory: res["isDirectory"] as? Bool ?? false,
                              isSymbolicLink: res["isSymbolicLink"] as? Bool ?? false)
        }
    }

    /// `devicectl device info apps --bundle-id X --json-output` → the app's bundle URL, if installed.
    public static func appURL(_ data: Data, bundle: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else { return nil }
        return apps.first { $0["bundleIdentifier"] as? String == bundle }?["url"] as? String
    }

    /// `devicectl device info processes --json-output` → executable URLs. nil if unreadable.
    public static func processExecutables(_ data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let procs = result["runningProcesses"] as? [[String: Any]] else { return nil }
        return procs.compactMap { $0["executable"] as? String }
    }

    /// Some process runs out of the app bundle at `appURL`.
    public static func isRunning(appURL: String, executables: [String]) -> Bool {
        let base = appURL.hasSuffix("/") ? appURL : appURL + "/"
        return executables.contains { $0.hasPrefix(base) }
    }
}

public extension DeviceCtl {
    static func appInfoArgs(device: String, bundle: String, jsonOutput: String) -> [String] {
        ["device", "info", "apps", "--device", device, "--bundle-id", bundle, "--json-output", jsonOutput]
    }
    static func processesArgs(device: String, jsonOutput: String) -> [String] {
        ["device", "info", "processes", "--device", device, "--json-output", jsonOutput]
    }
}

// MARK: - Backups on the Mac

public struct SaveManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var sha256: String
    }
    public var version = 1
    public var target: String
    public var bundle: String
    public var created: Date
    /// "manual", "all", "pre-restore".
    public var reason: String
    public var files: [Entry]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Same files with the same contents.
    public func sameContents(as other: SaveManifest) -> Bool {
        Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.sha256) })
            == Dictionary(uniqueKeysWithValues: other.files.map { ($0.path, $0.sha256) })
    }
}

public struct SaveBackup: Identifiable, Hashable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    public let manifest: SaveManifest
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

/// <base>/<target>/<timestamp>/{manifest.json, files/<container-relative path>}.
public struct SaveBackupStore: Sendable {
    public let base: URL
    public static let manifestName = "manifest.json"
    public static let keepDefault = 10

    public init(base: URL) { self.base = base }

    public func directory(_ target: String) -> URL { base.appendingPathComponent(target, isDirectory: true) }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Finished backups of `target`, newest first. Partial or unreadable ones are skipped.
    public func list(_ target: String) -> [SaveBackup] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: directory(target), includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { d -> SaveBackup? in
            guard !d.lastPathComponent.hasSuffix(".partial"),
                  let data = try? Data(contentsOf: d.appendingPathComponent(Self.manifestName)),
                  let m = try? Self.decoder().decode(SaveManifest.self, from: data), m.target == target else { return nil }
            return SaveBackup(directory: d, manifest: m)
        }.sorted { ($0.manifest.created, $0.directory.lastPathComponent) > ($1.manifest.created, $1.directory.lastPathComponent) }
    }

    /// A fresh staging directory; copy each save to `<returned>/files/<path>`, then `finish`.
    public func begin(_ target: String, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = directory(target)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Leftovers of an interrupted backup are never data anyone relies on.
        for d in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where d.lastPathComponent.hasSuffix(".partial") { try? fm.removeItem(at: d) }
        let staging = dir.appendingPathComponent(Self.stamp.string(from: date) + ".partial", isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("files"), withIntermediateDirectories: true)
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
            let u = staging.appendingPathComponent("files").appendingPathComponent(p)
            guard let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber else {
                throw SaveBackupError.missingFile(p)
            }
            entries.append(.init(path: p, size: size.int64Value, sha256: try Self.sha256(u)))
        }
        let m = SaveManifest(target: target, bundle: bundle, created: date, reason: reason, files: entries)
        if let latest = list(target).first, latest.manifest.sameContents(as: m) {
            try? fm.removeItem(at: staging)
            return .unchanged(latest)
        }
        try Self.encoder().encode(m).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
        var name = String(staging.lastPathComponent.dropLast(".partial".count))
        var final = directory(target).appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: final.path) {
            name = String(staging.lastPathComponent.dropLast(".partial".count)) + "-\(n)"; n += 1
            final = directory(target).appendingPathComponent(name, isDirectory: true)
        }
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

    public static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
