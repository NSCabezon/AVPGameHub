import Foundation

// The headset's own save backups: the hub copies each game's saves out of its container into a
// vault directory (in the hub, iCloud Drive's Documents/Partidas) and restores them from there.
// Same layout and manifest as the Mac copies (SaveBackupStore), so one reader works for both:
//   <root>/<target>/<YYYY-MM-DDTHH-MM-SSZ>/{manifest.json, files/<container-relative path>}
// Plain file I/O only: no iCloud APIs here. The vault tolerates iCloud placeholders
// (".<name>.icloud" for a file not downloaded yet), reports them, and never restores from them.

public enum SaveVaultError: Error, Equatable, CustomStringConvertible {
    case unknownTarget(String)
    case noSuchBackup(String)
    /// Files (vault-relative) that are still iCloud placeholders; download them and retry.
    case notDownloaded([String])
    /// Manifest paths that are not saves of the game (or not safe relative paths).
    case unsafePaths([String])
    /// Files missing from the backup or whose sha256 does not match the manifest.
    case corrupt([String])

    public var description: String {
        switch self {
        case .unknownTarget(let t): return "no save table for \(t)"
        case .noSuchBackup(let s): return "no backup \(s)"
        case .notDownloaded(let p): return "not downloaded from iCloud yet: \(p.joined(separator: ", "))"
        case .unsafePaths(let p): return "not saves of this game: \(p.joined(separator: ", "))"
        case .corrupt(let p): return "missing or damaged in the backup: \(p.joined(separator: ", "))"
        }
    }
}

public struct SaveVault: Sendable {
    public let root: URL
    /// Written into each manifest's `bundle` (the hub's bundle id).
    public let bundle: String
    /// Largest file kept (SaveTable.maxFileBytes; tests lower it).
    public let maxFileBytes: Int64
    public static let keepDefault = SaveBackupStore.keepDefault
    /// A staging directory older than this is a crashed snapshot, not one in progress.
    static let staleStaging: TimeInterval = 3600
    /// Where snapshots are built, outside the vault so iCloud never sees a temp folder (nil: inside the target's directory).
    public let stagingRoot: URL?

    public init(root: URL, bundle: String = Bundle.main.bundleIdentifier ?? "", maxFileBytes: Int64 = SaveTable.maxFileBytes,
                stagingRoot: URL? = nil) {
        self.root = root; self.bundle = bundle; self.maxFileBytes = maxFileBytes; self.stagingRoot = stagingRoot
    }

    public func directory(_ target: String) -> URL { root.appendingPathComponent(target, isDirectory: true) }

    public enum Result: Equatable, Sendable {
        /// The game has no save files in the container: nothing was written.
        case noSaves
        /// The newest backup already holds exactly these files (stamp of that backup).
        case unchanged(String)
        case created(String)
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { stamp }
        /// Directory name: "2026-10-12T18-30-05Z" (or "…Z-2").
        public let stamp: String
        public let directory: URL
        public let date: Date
        /// nil in Mac backups, old manifests and not-downloaded entries.
        public let device: String?
        /// "manual", "all", "pre-restore", "auto"; "" while not downloaded.
        public let reason: String
        public let fileCount: Int
        public let totalBytes: Int64
        /// The manifest and every file are local (no iCloud placeholder left).
        public let isDownloaded: Bool
    }

    // MARK: iCloud placeholders

    /// Where iCloud keeps the stand-in of a file not downloaded yet: "<dir>/.<name>.icloud".
    public static func placeholderURL(for item: URL) -> URL {
        item.deletingLastPathComponent().appendingPathComponent("." + item.lastPathComponent + ".icloud")
    }
    /// The real item a placeholder stands for, or nil if `url` is not a placeholder.
    public static func itemURL(forPlaceholder url: URL) -> URL? {
        let n = url.lastPathComponent
        guard n.hasPrefix("."), n.hasSuffix(".icloud"), n.count > ".icloud".count + 1 else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(String(n.dropFirst().dropLast(".icloud".count)))
    }
    static func isPlaceholder(_ item: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: item.path) && fm.fileExists(atPath: placeholderURL(for: item).path)
    }

    // MARK: Reading

    /// Backups of `target`, newest first. Staging, partial and unreadable ones are skipped; one
    /// whose manifest is still an iCloud placeholder is listed with `isDownloaded == false`.
    public func list(target: String) -> [Entry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: directory(target), includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.compactMap { found -> Entry? in
            let name = found.lastPathComponent
            guard SaveFormat.isBackupDirectoryName(name),
                  (try? found.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            // Under `root` as given, not as the listing resolved it (/var vs /private/var).
            let d = directory(target).appendingPathComponent(name, isDirectory: true)
            if let b = SaveFormat.readBackup(d, target: target) {
                let m = b.manifest
                let pending = m.files.contains { SaveTable.isSafeRelativePath($0.path) && Self.isPlaceholder(b.localURL($0.path)) }
                return Entry(stamp: name, directory: d, date: m.created, device: m.device, reason: m.reason,
                             fileCount: m.files.count, totalBytes: m.totalBytes, isDownloaded: !pending)
            }
            let manifest = d.appendingPathComponent(SaveFormat.manifestName)
            guard Self.isPlaceholder(manifest), let date = SaveFormat.date(fromStamp: name) else { return nil }
            return Entry(stamp: name, directory: d, date: date, device: nil, reason: "",
                         fileCount: 0, totalBytes: 0, isDownloaded: false)
        }.sorted { ($0.date, $0.stamp) > ($1.date, $1.stamp) }
    }

    /// The items of `target` (one backup if `stamp` is given) that are still iCloud placeholders,
    /// as the URLs of the real items: what FileManager.startDownloadingUbiquitousItem(at:) takes.
    public func pendingDownloads(target: String, stamp: String? = nil) -> [URL] {
        let fm = FileManager.default
        let dirs: [URL]
        if let stamp {
            guard SaveFormat.isBackupDirectoryName(stamp), !stamp.contains("/") else { return [] }
            dirs = [directory(target).appendingPathComponent(stamp, isDirectory: true)]
        } else {
            dirs = list(target: target).map(\.directory)
        }
        var out: [URL] = []
        for d in dirs {
            // Relative paths keep the URLs under `root` as given (no /private/var resolution).
            guard let e = fm.enumerator(atPath: d.path) else { continue }
            while let rel = e.nextObject() as? String {
                if let item = Self.itemURL(forPlaceholder: d.appendingPathComponent(rel)) { out.append(item) }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: The container side

    struct LocalSave { let path: String; let url: URL; let size: Int64 }

    /// The save files of `target` under `containerRoot` (regular files only, no symlinks),
    /// sorted by container-relative path.
    func localSaves(_ loc: GameSaveLocation, containerRoot: URL) -> [LocalSave] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [LocalSave] = []
        for r in loc.roots {
            let base = containerRoot.appendingPathComponent(r.path, isDirectory: true)
            guard let e = fm.enumerator(atPath: base.path) else { continue }
            while let rel = e.nextObject() as? String {
                let attrs = e.fileAttributes ?? [:]
                let type = attrs[.type] as? FileAttributeType
                if type == .typeDirectory {
                    // Caches and downloaded content can be huge: do not even walk them.
                    if SaveTable.isExcludedDirectory((rel as NSString).lastPathComponent, in: r) { e.skipDescendants() }
                    continue
                }
                guard type == .typeRegular else { continue }
                let path = r.path + "/" + rel
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard !seen.contains(path), SaveTable.keeps(r, path: path, size: size, maxBytes: maxFileBytes) else { continue }
                seen.insert(path)
                out.append(LocalSave(path: path, url: base.appendingPathComponent(rel), size: size))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The container holds at least one file the save table keeps for `target`.
    public func hasLocalSaves(target: String, containerRoot: URL) -> Bool {
        guard let loc = SaveTable.location(for: target) else { return false }
        return !localSaves(loc, containerRoot: containerRoot).isEmpty
    }

    // MARK: Writing

    /// Copies the saves of `target` out of `containerRoot` (the hub's NSHomeDirectory()) into a
    /// new backup. Built in `<stagingRoot>/.savevault-<uuid>/` (no stagingRoot: `<target>/.tmp-<uuid>/`)
    /// and moved into place, so a reader never sees half a backup. Nothing is written when there are no saves or nothing changed since the
    /// newest backup.
    public func snapshot(target: String, containerRoot: URL, device: String?, reason: String,
                         date: Date = Date()) throws -> Result {
        guard let loc = SaveTable.location(for: target) else { throw SaveVaultError.unknownTarget(target) }
        let saves = localSaves(loc, containerRoot: containerRoot)
        if saves.isEmpty { return .noSaves }
        let fm = FileManager.default
        let dir = directory(target)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        removeStaleStaging(dir)
        let staging: URL
        if let stagingRoot {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            staging = stagingRoot.appendingPathComponent(".savevault-" + UUID().uuidString, isDirectory: true)
        } else {
            staging = dir.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        }
        var sealed = false
        defer { if !sealed { try? fm.removeItem(at: staging) } }
        let files = staging.appendingPathComponent(SaveFormat.filesName, isDirectory: true)
        var entries: [SaveManifest.Entry] = []
        for s in saves {
            let dest = files.appendingPathComponent(s.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: s.url, to: dest)
            // Size and hash of the copy: the game may be writing the original right now.
            let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? s.size
            entries.append(.init(path: s.path, size: size, sha256: try SaveFormat.sha256(dest)))
        }
        let m = SaveManifest(target: target, bundle: bundle, created: date, reason: reason, device: device, files: entries)
        if let newest = list(target: target).first,
           let latest = SaveFormat.readBackup(newest.directory, target: target), latest.manifest.sameContents(as: m) {
            return .unchanged(newest.stamp)
        }
        try SaveFormat.encoder().encode(m).write(to: staging.appendingPathComponent(SaveFormat.manifestName), options: .atomic)
        let final = SaveFormat.freeName(in: dir, SaveFormat.stamp(date))
        do {
            try fm.moveItem(at: staging, to: final)
        } catch {
            // Staging on another volume than the vault: copy, then drop the staging copy.
            try fm.copyItem(at: staging, to: final)
            try? fm.removeItem(at: staging)
        }
        sealed = true
        return .created(final.lastPathComponent)
    }

    /// Leftovers of a crashed snapshot. Recent ones may be another snapshot still copying.
    func removeStaleStaging(_ dir: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.staleStaging)
        for d in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where d.lastPathComponent.hasPrefix(".tmp-") {
            let mod = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mod < cutoff { try? fm.removeItem(at: d) }
        }
    }

    /// Puts backup `stamp` of `target` back into `containerRoot`. Refuses (before touching the
    /// container) a backup with iCloud placeholders, paths that are not saves of the game, or
    /// files whose sha256 does not match. Then snapshots the current saves as "pre-restore"
    /// (none: skipped) and copies every file over, creating directories. Local files that are
    /// not in the backup stay: same semantics as the Mac restore.
    public func restore(target: String, stamp: String, containerRoot: URL, device: String?) throws {
        guard SaveTable.location(for: target) != nil else { throw SaveVaultError.unknownTarget(target) }
        guard SaveFormat.isBackupDirectoryName(stamp), !stamp.contains("/") else { throw SaveVaultError.noSuchBackup(stamp) }
        let dir = directory(target).appendingPathComponent(stamp, isDirectory: true)
        guard let b = SaveFormat.readBackup(dir, target: target) else {
            if Self.isPlaceholder(dir.appendingPathComponent(SaveFormat.manifestName)) {
                throw SaveVaultError.notDownloaded([stamp + "/" + SaveFormat.manifestName])
            }
            throw SaveVaultError.noSuchBackup(stamp)
        }
        let files = b.manifest.files
        let unsafe = files.filter { !SaveTable.isRestorable(target, path: $0.path, size: $0.size, maxBytes: maxFileBytes) }
        if !unsafe.isEmpty { throw SaveVaultError.unsafePaths(unsafe.map(\.path)) }
        let pending = files.filter { Self.isPlaceholder(b.localURL($0.path)) }
        if !pending.isEmpty { throw SaveVaultError.notDownloaded(pending.map { stamp + "/files/" + $0.path }) }
        let bad = files.filter { (try? SaveFormat.sha256(b.localURL($0.path))) != $0.sha256 }
        if !bad.isEmpty { throw SaveVaultError.corrupt(bad.map(\.path)) }

        _ = try snapshot(target: target, containerRoot: containerRoot, device: device, reason: "pre-restore")

        let fm = FileManager.default
        for f in files {
            let dest = containerRoot.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Copy beside the target, then swap: a crash never leaves half a save file.
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).restore-\(UUID().uuidString)")
            try fm.copyItem(at: b.localURL(f.path), to: tmp)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        }
    }

    /// Keeps the newest `keep` backups of `target` (never fewer than one: the newest always
    /// stays) and removes the rest, "pre-restore" ones included, except those in `protecting`
    /// (e.g. the backup just restored). Returns the removed stamps.
    @discardableResult
    public func prune(target: String, keep: Int = keepDefault, protecting: Set<String> = []) -> [String] {
        var removed: [String] = []
        for e in list(target: target).dropFirst(max(1, keep)) where !protecting.contains(e.stamp) {
            if (try? FileManager.default.removeItem(at: e.directory)) != nil { removed.append(e.stamp) }
        }
        return removed
    }
}
