import Foundation

// Where each hub game keeps its saves inside the hub's app data container. Pure data: the Mac
// app lists the container with devicectl, the headset hub walks it directly (SaveVault). The
// table is read off the Klepton fork; see docs/2026-10-12-save-games.md for the why of every row.

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

    public init(target: String, engine: String, roots: [SaveRoot]) {
        self.target = target; self.engine = engine; self.roots = roots
    }
}

/// One file (or directory) in a container listing, by its container-relative path.
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

    /// `dir` (one path component under `root`) is never descended into for saves.
    public static func isExcludedDirectory(_ dir: String, in root: SaveRoot) -> Bool {
        let d = dir.lowercased()
        return excludedDirs.contains(d) || root.excludeDirs.contains { $0.lowercased() == d }
    }

    /// `path` (container-relative) is a save of `root`. `maxBytes` is only lowered by tests.
    public static func keeps(_ root: SaveRoot, path: String, size: Int64, maxBytes: Int64 = maxFileBytes) -> Bool {
        guard isSafeRelativePath(path), size <= maxBytes, path.hasPrefix(root.path + "/") else { return false }
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
        if comps.dropLast().contains(where: { isExcludedDirectory($0, in: root) }) { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !excludedExtensions.contains(ext)
    }

    /// The save files of `target` among `listing` (regular files only, no symlinks).
    public static func saveFiles(_ target: String, in listing: [RemoteFile], maxBytes: Int64 = maxFileBytes) -> [RemoteFile] {
        guard let loc = location(for: target) else { return [] }
        var seen = Set<String>()
        return listing.filter { f in
            guard !f.isDirectory, !f.isSymbolicLink, !seen.contains(f.path) else { return false }
            guard loc.roots.contains(where: { keeps($0, path: f.path, size: f.size, maxBytes: maxBytes) }) else { return false }
            seen.insert(f.path)
            return true
        }.sorted { $0.path < $1.path }
    }

    /// Restore guard: `path` belongs to one of the game's save roots and passes the filters.
    public static func isRestorable(_ target: String, path: String, size: Int64, maxBytes: Int64 = maxFileBytes) -> Bool {
        location(for: target)?.roots.contains { keeps($0, path: path, size: size, maxBytes: maxBytes) } ?? false
    }

    /// Relative, no "..", no empty or "." components, no leading slash.
    public static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains("\\"), !p.contains("\0") else { return false }
        return !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
