// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
//   launcher/Sources/SteamLauncherKit/Cloud/SteamCloud.swift (CloudSaveRule, Glob, CloudSync)
//
// Steam Cloud save sync, tuned to never lose a save:
// - OFF unless the caller runs it; two modes: download-only (default) and two-way.
// - A local file is only ever replaced after a timestamped backup of it, and every write goes to a
//   temp file, is hash-checked, then renamed into place (a save is never half-written).
// - Nothing is ever deleted from the cloud (CloudRemote has no delete), and deletions are never
//   propagated in either direction.
// - A file goes up only (two-way mode) when its content changed locally since the last sync
//   baseline AND the cloud still holds the version it was last in sync with (that cloud version is
//   backed up first). The first two-way run only records the baseline; it uploads nothing.
// - Both sides changed (or they differ with no history) -> CONFLICT: both kept (the local file stays
//   in place, the cloud copy is saved beside the backups), nothing uploaded, reported to the caller.
//   The caller can resolve a conflict explicitly (CloudSyncState.resolve).
// - A save slot the headset started (e.g. `s0`) that collides with a different slot of the same name
//   in the cloud, with no history, moves to a free slot number so both games are kept (Glovebox).
// - Only files the game's own Auto-Cloud rules (PICS `ufs/savefiles`) cover are considered, and
//   `neverUpload` names (the device's own settings) only ever come down.
//
// The decision is a pure function (CloudSyncPlanner.plan) so it is unit-tested without disk or network;
// CloudSync performs a plan against a folder and a CloudRemote.
import Foundation

/// One Auto-Cloud rule from the app's PICS info (`ufs/savefiles`), e.g. for Alyx:
/// root `gameinstall`, path `game/hlvr/save`, pattern `*`, recursive.
public struct CloudSaveRule: Sendable, Equatable, Codable {
    public var root: String
    public var path: String
    public var pattern: String
    public var recursive: Bool

    public init(root: String, path: String, pattern: String = "*", recursive: Bool = true) {
        self.root = root; self.path = path; self.pattern = pattern; self.recursive = recursive
    }

    /// The rules in an app's PICS info (`appinfo/ufs/savefiles`).
    public static func parse(appInfo: KeyValue) -> [CloudSaveRule] {
        (appInfo["ufs"]?["savefiles"]?.children ?? []).map { v in
            var p = v["path"]?.value ?? ""
            while p.hasSuffix("/") { p.removeLast() }
            return CloudSaveRule(root: v["root"]?.value ?? "", path: p,
                                 pattern: v["pattern"]?.value ?? "*", recursive: v["recursive"]?.value == "1")
        }
    }

    func matches(fileName: String) -> Bool {
        pattern == "*" || CloudGlob.match(pattern.lowercased(), fileName.lowercased())
    }

    /// The lowercased cloud-name prefix of this rule's folder: `%gameinstall%game/hlvr/save/`.
    var keyPrefix: String { "%\(root)%\(path)/".lowercased() }
    /// The cloud name for a path below this rule's folder, in Steam's spelling of the root token.
    func cloudName(_ sub: String) -> String { "%\(CloudSync.tokenName(root))%\(path)/\(sub)" }
}

enum CloudGlob {
    static func match(_ p: String, _ s: String) -> Bool {
        let p = Array(p), s = Array(s)
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: s.count + 1), count: p.count + 1)
        func go(_ i: Int, _ j: Int) -> Bool {
            if let m = memo[i][j] { return m }
            let r: Bool
            if i == p.count { r = j == s.count }
            else if p[i] == "*" { r = go(i + 1, j) || (j < s.count && go(i, j + 1)) }
            else { r = j < s.count && (p[i] == "?" || p[i] == s[j]) && go(i + 1, j + 1) }
            memo[i][j] = r
            return r
        }
        return go(0, 0)
    }
}

public enum CloudSyncMode: String, Codable, Sendable, CaseIterable {
    case downloadOnly, twoWay
}

/// A file both sides changed (or that differs with no sync history). Both copies are kept.
public struct CloudConflict: Codable, Equatable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable { case bothChanged, noHistory }
    /// Lowercased cloud name (the state key).
    public var key: String
    /// The cloud's own spelling.
    public var cloudName: String
    public var localSHA: String
    public var cloudSHA: String
    public var reason: Reason
    /// Where the cloud's copy was saved (relative to the backup root), when it was fetched.
    public var cloudCopy: String?
}

/// What the sync remembers between runs (JSON beside the backups).
public struct CloudSyncState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// SHA-1 both sides held at the end of the last sync that touched this file.
        public var synced: String?
        /// SHA-1 of the local file recorded at the end of the last run (the "baseline").
        public var local: String?
        /// The person chose "keep the headset's copy" for a conflict: upload it on the next
        /// two-way run even though no baseline says it changed.
        public var pendingUpload: Bool?
        public init(synced: String? = nil, local: String? = nil, pendingUpload: Bool? = nil) {
            self.synced = synced; self.local = local; self.pendingUpload = pendingUpload
        }
    }
    public var files: [String: Entry] = [:]
    /// A two-way run has recorded the local baseline (until then nothing is uploaded).
    public var uploadBaseline = false
    public var lastRun: Date?
    public var lastMode: CloudSyncMode?
    /// Conflicts still open after the last run.
    public var conflicts: [CloudConflict] = []

    public init() {}

    public static func load(_ url: URL) -> CloudSyncState {
        guard let d = try? Data(contentsOf: url) else { return CloudSyncState() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(CloudSyncState.self, from: d)) ?? CloudSyncState()
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public enum Choice: String, Sendable { case useCloud, keepHeadset }

    /// Resolve a conflict for the next run. `useCloud`: the cloud copy replaces the local one (which is
    /// backed up first). `keepHeadset`: the local file stays; in two-way mode it is uploaded over the
    /// cloud copy (which is backed up first). Either only applies while both files are still the ones
    /// the conflict saw; otherwise the next run reports a conflict again.
    public mutating func resolve(_ c: CloudConflict, _ choice: Choice) {
        switch choice {
        case .useCloud: files[c.key] = Entry(synced: c.localSHA, local: c.localSHA)
        case .keepHeadset: files[c.key] = Entry(synced: c.cloudSHA, local: nil, pendingUpload: true)
        }
        conflicts.removeAll { $0.key == c.key }
    }
}

/// A local file a rule covers.
public struct CloudLocalFile: Equatable, Sendable {
    /// The rule's lowercased key prefix (`%gameinstall%game/hlvr/save/`).
    public var prefix: String
    /// Path below the rule's folder as it is on disk (`s0/autosave.sav`).
    public var sub: String
    /// The name it would have in the cloud.
    public var cloudName: String
    public var sha: String
    public init(prefix: String, sub: String, cloudName: String, sha: String) {
        self.prefix = prefix; self.sub = sub; self.cloudName = cloudName; self.sha = sha
    }
    public var key: String { prefix + sub.lowercased() }
}

public enum CloudAction: Equatable, Sendable {
    public enum KeepReason: String, Sendable { case neverUpload, unchangedSinceBaseline }
    public enum HoldReason: String, Sendable { case downloadOnly, baselineRun }
    /// Same content on both sides.
    case inSync(key: String, sha: String)
    /// The cloud copy comes down; `replacing` = the local file it replaces (backed up first).
    case download(key: String, remote: CloudFile, replacing: CloudLocalFile?)
    /// The local file goes up; `over` = the cloud copy it replaces (backed up first).
    case upload(key: String, local: CloudLocalFile, over: CloudFile?)
    /// Would go up, but uploads are off (download-only) or this run records the baseline.
    case hold(key: String, local: CloudLocalFile, reason: HoldReason)
    /// Stays local only.
    case keepLocal(key: String, local: CloudLocalFile, reason: KeepReason)
    case conflict(CloudConflict, remote: CloudFile, local: CloudLocalFile)
    /// The game deleted a file we had synced: the cloud copy is left alone (not brought back).
    case skipDeletedLocally(key: String)
    /// The cloud dropped a file we had synced: the local copy is left alone (not re-uploaded).
    case skipDeletedInCloud(key: String)

    public var key: String {
        switch self {
        case .inSync(let k, _), .download(let k, _, _), .upload(let k, _, _), .hold(let k, _, _),
             .keepLocal(let k, _, _), .skipDeletedLocally(let k), .skipDeletedInCloud(let k): return k
        case .conflict(let c, _, _): return c.key
        }
    }
}

/// A save slot moved to a free number, e.g. `s0` -> `s5` under one rule's folder.
public struct CloudRelocation: Equatable, Sendable {
    public var prefix: String
    public var from: String
    public var to: String
}

public struct CloudPlan: Equatable, Sendable {
    public var relocations: [CloudRelocation] = []
    public var actions: [CloudAction] = []
    /// State the relocations invalidate (keys of the slots that moved away).
    public var clearedKeys: [String] = []
    /// Baseline entries for the files that moved (recorded so they do not count as "changed").
    public var relocatedBaseline: [String: String] = [:]

    public var downloads: Int { actions.filter { if case .download = $0 { return true }; return false }.count }
    public var uploads: Int { actions.filter { if case .upload = $0 { return true }; return false }.count }
    public var conflicts: [CloudConflict] { actions.compactMap { if case .conflict(let c, _, _) = $0 { return c }; return nil } }
}

public enum CloudSyncPlanner {
    /// A save slot folder, e.g. `s0` in `s0/autosave.sav`: letters then a number.
    static func slot(of sub: String) -> String? {
        guard sub.contains("/"), let first = sub.split(separator: "/").first else { return nil }
        let s = String(first)
        let digits = s.reversed().prefix { $0.isNumber }.count
        guard digits > 0, s.dropLast(digits).allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        return s
    }

    /// The lowest slot number with the same prefix that nobody uses: `s0` with s0…s4 taken -> `s5`.
    static func freeSlot(after slot: String, taken: Set<String>) -> String {
        let digits = slot.reversed().prefix { $0.isNumber }.count
        let prefix = String(slot.dropLast(digits))
        let used = Set(taken.compactMap { t -> Int? in t.hasPrefix(prefix) ? Int(t.dropFirst(prefix.count)) : nil })
        var n = 0
        while used.contains(n) { n += 1 }
        return prefix + String(n)
    }

    static func neverGoesUp(_ key: String, _ globs: [String]) -> Bool {
        let file = (key.lowercased() as NSString).lastPathComponent
        return globs.contains { CloudGlob.match($0.lowercased(), file) }
    }

    /// Decide what to do. `remote`: the cloud listing; `local`: what the rules cover on disk;
    /// `occupiedSlots`: per rule prefix, slot folders that hold any file locally (incl. ones the rules
    /// do not cover), so a relocation never lands on one.
    public static func plan(remote remoteFiles: [CloudFile], local localFiles: [CloudLocalFile], state: CloudSyncState,
                            mode: CloudSyncMode, neverUpload: [String] = [], relocateSlots: Bool = true,
                            occupiedSlots: [String: Set<String>] = [:]) -> CloudPlan {
        var out = CloudPlan()
        // One entry per name however the cloud spells it; with two spellings, the newer one.
        var remote: [String: CloudFile] = [:]
        for f in remoteFiles {
            let k = f.filename.lowercased()
            if let seen = remote[k], seen.timestamp >= f.timestamp { continue }
            remote[k] = f
        }
        var local: [String: CloudLocalFile] = [:]
        for f in localFiles { local[f.key] = f }
        var files = state.files

        // 1. Slots the headset started that collide with a different cloud slot of the same name.
        if relocateSlots {
            let prefixes = Set(localFiles.map(\.prefix))
            for prefix in prefixes.sorted() {
                var foreign = Set<String>()
                for f in localFiles where f.prefix == prefix && !neverGoesUp(f.key, neverUpload) {
                    guard let r = remote[f.key], r.sha1Hex.lowercased() != f.sha, files[f.key]?.synced == nil,
                          let s = slot(of: f.sub.lowercased()) else { continue }
                    foreign.insert(s)
                }
                guard !foreign.isEmpty else { continue }
                var taken = Set(localFiles.filter { $0.prefix == prefix }.compactMap { slot(of: $0.sub.lowercased()) })
                taken.formUnion(occupiedSlots[prefix] ?? [])
                for k in remote.keys where k.hasPrefix(prefix) {
                    if let s = slot(of: String(k.dropFirst(prefix.count))) { taken.insert(s) }
                }
                for s in foreign.sorted() {
                    let fresh = freeSlot(after: s, taken: taken)
                    taken.insert(fresh)
                    out.relocations.append(CloudRelocation(prefix: prefix, from: s, to: fresh))
                    // Everything synced in that slot left with it: the cloud's copies come down.
                    for k in files.keys where k.hasPrefix(prefix + s + "/") { files[k] = nil; out.clearedKeys.append(k) }
                    for (k, f) in local where f.prefix == prefix && slot(of: f.sub.lowercased()) == s {
                        local[k] = nil
                        var moved = f
                        let rest = f.sub.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                        moved.sub = fresh + "/" + rest
                        moved.cloudName = String(f.cloudName.dropLast(f.sub.count)) + moved.sub
                        local[moved.key] = moved
                        // The moved files are the headset's own: baseline them so they are not
                        // counted as changed (they go up once the game changes them again).
                        files[moved.key] = CloudSyncState.Entry(synced: nil, local: moved.sha)
                        out.relocatedBaseline[moved.key] = moved.sha
                    }
                }
            }
        }

        // 2. Per file.
        for key in Set(remote.keys).union(local.keys).sorted() {
            let r = remote[key], l = local[key], e = files[key]
            let rSHA = r?.sha1Hex.lowercased()
            let neverUp = neverGoesUp(key, neverUpload)

            func uploadLadder(_ l: CloudLocalFile, over: CloudFile?) -> CloudAction {
                if neverUp { return .keepLocal(key: key, local: l, reason: .neverUpload) }
                let pending = e?.pendingUpload == true
                if !pending, e?.local == l.sha { return .keepLocal(key: key, local: l, reason: .unchangedSinceBaseline) }
                if mode == .downloadOnly { return .hold(key: key, local: l, reason: .downloadOnly) }
                if !pending, !state.uploadBaseline { return .hold(key: key, local: l, reason: .baselineRun) }
                return .upload(key: key, local: l, over: over)
            }

            switch (r, l) {
            case (nil, nil):
                continue
            case let (r?, l?) where l.sha == rSHA:
                _ = r
                out.actions.append(.inSync(key: key, sha: l.sha))
            case let (r?, nil):
                if let s = e?.synced, s == rSHA { out.actions.append(.skipDeletedLocally(key: key)); continue }
                out.actions.append(.download(key: key, remote: r, replacing: nil))
            case let (nil, l?):
                if let s = e?.synced, s == l.sha { out.actions.append(.skipDeletedInCloud(key: key)); continue }
                out.actions.append(uploadLadder(l, over: nil))
            case let (r?, l?):
                let s = e?.synced
                if let s, s == rSHA {
                    // Only the headset changed since the last sync.
                    out.actions.append(uploadLadder(l, over: r))
                } else if let s, s == l.sha {
                    // Only the cloud changed: it comes down, the headset's copy is backed up first.
                    out.actions.append(.download(key: key, remote: r, replacing: l))
                } else if s == nil, neverUp {
                    // Never goes up, so the cloud's copy is the only shared one (headset's backed up).
                    out.actions.append(.download(key: key, remote: r, replacing: l))
                } else {
                    let c = CloudConflict(key: key, cloudName: r.filename, localSHA: l.sha, cloudSHA: rSHA ?? "",
                                          reason: s == nil ? .noHistory : .bothChanged, cloudCopy: nil)
                    out.actions.append(.conflict(c, remote: r, local: l))
                }
            }
        }
        return out
    }
}

/// Performs a plan against a local folder and a CloudRemote.
public struct CloudSync: Sendable {
    public struct Report: Sendable, Equatable {
        public var downloaded: [String] = []
        public var uploaded: [String] = []
        /// Backup paths, relative to the backup root.
        public var backedUp: [String] = []
        public var relocated: [String] = []
        /// Not uploaded: download-only mode, or the run that records the baseline.
        public var held: [String] = []
        public var conflicts: [CloudConflict] = []
        public var unchanged = 0
        public var keptLocal = 0
        public var dryRun = false
        public init() {}

        public var summary: String {
            var parts = ["\(downloaded.count) down", "\(uploaded.count) up", "\(unchanged) in sync"]
            if !held.isEmpty { parts.append("\(held.count) not uploaded") }
            if !conflicts.isEmpty { parts.append("\(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")") }
            if !relocated.isEmpty { parts.append("slots moved: \(relocated.joined(separator: ", "))") }
            return parts.joined(separator: ", ")
        }
    }

    public let remote: CloudRemote
    public let rules: [CloudSaveRule]
    /// The folder a rule's root token maps to (lowercased token, e.g. `gameinstall`).
    public let rootFolder: @Sendable (String) -> URL?
    /// Maps a lowercased path below the root token to the path below `rootFolder` (nil = not here).
    public let localPath: @Sendable (String) -> String?
    public let stateURL: URL
    public let backupRoot: URL
    public var mode: CloudSyncMode = .downloadOnly
    /// File names (globs, any case) that never go up, e.g. the device's own settings.
    public var neverUpload: [String] = []
    public var relocateSlots = true
    public var now: @Sendable () -> Date = { Date() }
    public var log: @Sendable (String) -> Void = { _ in }

    public init(remote: CloudRemote, rules: [CloudSaveRule], rootFolder: @escaping @Sendable (String) -> URL?,
                localPath: @escaping @Sendable (String) -> String? = { $0 }, stateURL: URL, backupRoot: URL) {
        self.remote = remote; self.rules = rules; self.rootFolder = rootFolder; self.localPath = localPath
        self.stateURL = stateURL; self.backupRoot = backupRoot
    }

    /// Steam writes root tokens in their canonical case, e.g. `GameInstall`.
    static func tokenName(_ root: String) -> String {
        ["gameinstall": "GameInstall", "winmydocuments": "WinMyDocuments", "winappdataroaming": "WinAppDataRoaming",
         "winappdatalocal": "WinAppDataLocal", "winsavedgames": "WinSavedGames", "macappsupport": "MacAppSupport",
         "linuxhome": "LinuxHome", "linuxxdgdatahome": "LinuxXdgDataHome"][root.lowercased()] ?? root
    }

    /// `%GameInstall%game/hlvr/save/x.sav` -> (gameinstall, game/hlvr/save/x.sav)
    public static func split(_ name: String) -> (root: String?, path: String) {
        guard name.hasPrefix("%"), let end = name.dropFirst().firstIndex(of: "%") else { return (nil, name) }
        return (String(name[name.index(after: name.startIndex)..<end]).lowercased(), String(name[name.index(after: end)...]))
    }

    /// A rule's folder on disk.
    public func folder(for rule: CloudSaveRule) -> URL? {
        guard let base = rootFolder(rule.root.lowercased()), let rel = localPath(rule.path.lowercased()) else { return nil }
        return rel.isEmpty ? base : base.appendingPathComponent(rel, isDirectory: true)
    }

    /// The rule that covers a cloud name, and the path below its folder.
    private func rule(forKey key: String) -> (CloudSaveRule, String)? {
        for r in rules where key.hasPrefix(r.keyPrefix) {
            let sub = String(key.dropFirst(r.keyPrefix.count))
            if !r.recursive, sub.contains("/") { continue }
            if r.matches(fileName: (sub as NSString).lastPathComponent) { return (r, sub) }
        }
        return nil
    }

    private static func isFile(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func hasFiles(_ d: URL) -> Bool {
        guard let e = FileManager.default.enumerator(atPath: d.path) else { return false }
        while let sub = e.nextObject() as? String { if isFile(d.appendingPathComponent(sub)) { return true } }
        return false
    }

    /// Every local file the rules cover, and the slot folders that hold any file.
    public func scanLocal() -> (files: [CloudLocalFile], urls: [String: URL], occupied: [String: Set<String>]) {
        var files: [CloudLocalFile] = [], urls: [String: URL] = [:], occupied: [String: Set<String>] = [:]
        for rule in rules {
            guard let dir = folder(for: rule), let e = FileManager.default.enumerator(atPath: dir.path) else { continue }
            for case let sub as String in e {
                let u = dir.appendingPathComponent(sub)
                guard Self.isFile(u) else { continue }
                if sub.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }  // temp/hidden
                if let s = CloudSyncPlanner.slot(of: sub.lowercased()) { occupied[rule.keyPrefix, default: []].insert(s) }
                if !rule.recursive, sub.contains("/") { continue }
                guard rule.matches(fileName: u.lastPathComponent), let d = try? Data(contentsOf: u) else { continue }
                let f = CloudLocalFile(prefix: rule.keyPrefix, sub: sub, cloudName: rule.cloudName(sub), sha: CloudSHA.hex(d))
                files.append(f); urls[f.key] = u
            }
        }
        return (files, urls, occupied)
    }

    /// The plan for the current disk and cloud, without changing anything.
    public func plan() async throws -> (plan: CloudPlan, remote: [CloudFile], state: CloudSyncState) {
        let state = CloudSyncState.load(stateURL)
        let remoteFiles = try await remote.list().filter { rule(forKey: $0.filename.lowercased()) != nil }
        let scan = scanLocal()
        let p = CloudSyncPlanner.plan(remote: remoteFiles, local: scan.files, state: state, mode: mode,
                                      neverUpload: neverUpload, relocateSlots: relocateSlots, occupiedSlots: scan.occupied)
        return (p, remoteFiles, state)
    }

    /// Keeps a copy under `<backupRoot>/<stamp>/<side>/<path below the root token>`; returns that relative path.
    private func backup(_ data: Data, side: String, key: String, stamp: String) throws -> String {
        let rel = "\(stamp)/\(side)/\(Self.split(key).path)"
        let dest = backupRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        guard CloudSHA.hex((try? Data(contentsOf: dest)) ?? Data()) == CloudSHA.hex(data) else {
            throw SteamDepotError.corrupt("backup \(rel) did not verify")
        }
        return rel
    }

    private func writeSafely(_ data: Data, to url: URL, time: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).cloud-tmp")
        try data.write(to: tmp)
        guard let check = try? Data(contentsOf: tmp), CloudSHA.sha1(check) == CloudSHA.sha1(data) else {
            try? fm.removeItem(at: tmp)
            throw SteamDepotError.corrupt("couldn't write \(url.lastPathComponent) intact")
        }
        // rename(2) swaps the file in atomically: readers see the old save or the new one, never a mix.
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw SteamDepotError.corrupt("couldn't replace \(url.lastPathComponent)")
        }
        try? fm.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
    }

    /// Where a cloud file goes on disk when nothing local has its name (lowercase, as the game writes).
    private func destination(forKey key: String) -> URL? {
        guard let (r, sub) = rule(forKey: key), let dir = folder(for: r) else { return nil }
        return dir.appendingPathComponent(sub)
    }

    /// Run a sync. `dryRun`: plan only (only the cloud listing is read; nothing is written anywhere).
    @discardableResult
    public func run(dryRun: Bool = false) async throws -> (report: Report, plan: CloudPlan) {
        let planned = try await self.plan()
        let plan = planned.plan
        var state = planned.state
        var report = Report()
        report.dryRun = dryRun
        report.conflicts = plan.conflicts
        report.relocated = plan.relocations.map { "\($0.from) → \($0.to)" }
        for a in plan.actions {
            switch a {
            case .inSync: report.unchanged += 1
            case .keepLocal: report.keptLocal += 1
            case .hold(_, let l, _): report.held.append(l.cloudName)
            default: break
            }
        }
        if dryRun {
            for a in plan.actions {
                if case .download(_, let r, _) = a { report.downloaded.append(r.filename) }
                if case .upload(_, let l, _) = a { report.uploaded.append(l.cloudName) }
            }
            return (report, plan)
        }

        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        func saveState() throws { try state.save(stateURL) }

        // 1. Relocations (moves only; a destination holding any file aborts the run untouched).
        // Cancellation is honoured between steps only, never in the middle of a write.
        try Task.checkCancellation()
        for rel in plan.relocations {
            guard let rule = rules.first(where: { $0.keyPrefix == rel.prefix }), let dir = folder(for: rule) else { continue }
            let from = dir.appendingPathComponent(rel.from), to = dir.appendingPathComponent(rel.to)
            if Self.hasFiles(to) { throw SteamDepotError.protocolError("cloud: slot \(rel.to) is not free; nothing changed") }
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }   // an empty folder (no files anywhere in it)
            try fm.moveItem(at: from, to: to)
            log("moved slot \(rel.from) → \(rel.to) (it collided with a different cloud slot)")
        }
        for k in plan.clearedKeys { state.files[k] = nil }
        for (k, sha) in plan.relocatedBaseline { state.files[k] = .init(synced: nil, local: sha) }
        if !plan.relocations.isEmpty { try saveState() }

        // Local URLs after relocation.
        let urls = scanLocal().urls

        // 2. Downloads and conflict copies, one by one (state saved after each).
        var uploads: [(key: String, local: CloudLocalFile, data: Data, url: URL)] = []
        var openConflicts: [CloudConflict] = []
        for a in plan.actions {
            switch a {
            case .inSync(let key, let sha):
                state.files[key] = .init(synced: sha, local: sha)
            case .download(let key, let r, let replacing):
                try Task.checkCancellation()
                guard let dest = urls[key] ?? destination(forKey: key) else { continue }
                let data = try await remote.download(r)
                try Task.checkCancellation()
                let sha = CloudSHA.hex(data)
                if let replacing {
                    // Re-read: only replace the exact file the plan saw.
                    let cur = try Data(contentsOf: dest)
                    guard CloudSHA.hex(cur) == replacing.sha else { log("\(key) changed during sync; left alone"); continue }
                    report.backedUp.append(try backup(cur, side: "headset", key: key, stamp: stamp))
                } else if fm.fileExists(atPath: dest.path) {
                    log("\(key) appeared during sync; left alone"); continue
                }
                try writeSafely(data, to: dest, time: Date(timeIntervalSince1970: TimeInterval(r.timestamp)))
                state.files[key] = .init(synced: sha, local: sha)
                report.downloaded.append(r.filename)
                try saveState()
            case .conflict(var c, let r, _):
                // Both kept: the local file stays, the cloud's copy is saved beside the backups.
                if let data = try? await remote.download(r) {
                    c.cloudCopy = try backup(data, side: "cloud-conflict", key: c.key, stamp: stamp)
                    report.backedUp.append(c.cloudCopy!)
                }
                openConflicts.append(c)
            case .upload(let key, let l, _):
                guard let u = urls[key], let d = try? Data(contentsOf: u), CloudSHA.hex(d) == l.sha else {
                    log("\(key) changed during sync; not uploaded"); continue
                }
                uploads.append((key, l, d, u))
            case .hold(let key, let l, let why):
                if why == .baselineRun { state.files[key, default: .init()].local = l.sha }
            case .keepLocal(let key, let l, _):
                if mode == .twoWay { state.files[key, default: .init()].local = l.sha }
            case .skipDeletedLocally, .skipDeletedInCloud:
                break
            }
        }
        report.conflicts = openConflicts

        // 3. Uploads, as one batch, each over the cloud version it was last in sync with (backed up first).
        if !uploads.isEmpty, mode == .twoWay {
            try Task.checkCancellation()
            for case .upload(let key, _, let over?) in plan.actions where uploads.contains(where: { $0.key == key }) {
                let old = try await remote.download(over)
                report.backedUp.append(try backup(old, side: "cloud", key: key, stamp: stamp))
            }
            try await remote.upload(uploads.map { u in
                let t = (try? u.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
                return CloudUpload(name: u.local.cloudName, data: u.data, time: t)
            })
            for u in uploads {
                state.files[u.key] = .init(synced: u.local.sha, local: u.local.sha)
                report.uploaded.append(u.local.cloudName)
            }
        }

        if mode == .twoWay { state.uploadBaseline = true }
        state.conflicts = openConflicts
        state.lastRun = now()
        state.lastMode = mode
        try saveState()
        return (report, plan)
    }
}

/// Where a Klepton port keeps one game's cloud-covered files.
///
/// Half-Life: Alyx: the guest's game root is `<install>/game` (kl_glibc's g_root is two levels above
/// game/bin/linuxsteamrtarm64), and everything the engine writes under it lands in the WRITE LAYER
/// (`KL_GLIBC_WRITE`, default `<userdata>/alyx/gameroot`, i.e.
/// `~/Library/Application Support/Klepton/userdata/alyx/gameroot` — on the headset, inside the app
/// container). The Auto-Cloud rule `gameinstall` + `game/hlvr/save` is therefore
/// `<write layer>/hlvr/save`.
public struct CloudSaveProfile: Sendable {
    public let appID: UInt32
    /// The install-relative folder the write layer stands for ("game/" for Source 2).
    public let installPrefix: String
    /// Names that never go up (device settings; level state the port leaves behind on exit).
    public let neverUpload: [String]

    public init(appID: UInt32, installPrefix: String, neverUpload: [String]) {
        self.appID = appID; self.installPrefix = installPrefix; self.neverUpload = neverUpload
    }

    /// Glovebox's list for the same port: personal.cfg is this device's settings; the .hl1/.hl2/.hl3
    /// files hold the level the game was in, left behind because the port exits the app.
    public static let alyx = CloudSaveProfile(appID: 546560, installPrefix: "game/",
                                              neverUpload: ["personal.cfg", "*.hl1", "*.hl2", "*.hl3"])

    public static func forApp(_ app: UInt32) -> CloudSaveProfile? { app == alyx.appID ? alyx : nil }

    /// `<base>/Library/Application Support/Klepton/userdata/<target>/gameroot` (base = home / app container).
    public static func defaultWriteLayer(target: String, home: URL) -> URL {
        if let w = ProcessInfo.processInfo.environment["KL_GLIBC_WRITE"], !w.isEmpty { return URL(fileURLWithPath: w) }
        if let f = ProcessInfo.processInfo.environment["KL_FILES_DIR"], !f.isEmpty {
            return URL(fileURLWithPath: f).appendingPathComponent("gameroot")
        }
        return home.appendingPathComponent("Library/Application Support/Klepton/userdata/\(target)/gameroot")
    }

    public func makeSync(remote: CloudRemote, rules: [CloudSaveRule], writeLayer: URL, stateDir: URL,
                         mode: CloudSyncMode) -> CloudSync {
        let prefix = installPrefix.lowercased()
        var s = CloudSync(remote: remote, rules: rules,
                          rootFolder: { $0 == "gameinstall" ? writeLayer : nil },
                          localPath: { p in
                              let p = p.lowercased()
                              if p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
                              return p + "/" == prefix ? "" : nil
                          },
                          stateURL: stateDir.appendingPathComponent("state.json"),
                          backupRoot: stateDir.appendingPathComponent("backups"))
        s.mode = mode
        s.neverUpload = neverUpload
        return s
    }
}

extension SteamSession {
    /// The app's Auto-Cloud rules and current public build id, from PICS.
    public func cloudRules(app: UInt32) async throws -> (rules: [CloudSaveRule], buildID: UInt64) {
        let info = try await appInfo(app: app)
        let build = UInt64(info["depots"]?["branches"]?["public"]?["buildid"]?.value ?? "") ?? 0
        return (CloudSaveRule.parse(appInfo: info), build)
    }
}
