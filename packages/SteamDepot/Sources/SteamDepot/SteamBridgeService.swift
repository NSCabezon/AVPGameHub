import Foundation

/// Real-Steam backend for Klepton's Steamworks stand-in (kl_steam.c): identity, ownership,
/// stats/achievements and "Playing X", answered from one logged-on SteamSession.
///
/// Wire contract (newline-delimited JSON, one response line per request, always `"ok"`, plus
/// `"error"` on failure):
///   {"op":"hello","app":N}    -> {"ok","steamid","name","owned","offline"}
///   {"op":"stats","app":N,"lang"?} -> {"ok","offline","stats":{name:{type,value}},
///                                "achievements":{name:{unlocked,time,"display"?:{name,desc,icon,icon_gray,hidden}}}}
///   {"op":"store","app":N,"stats":{name:num},"achievements":{name:true},"dry_run"?,"lang"?}
///                             -> {"ok","queued","stored","unlocked":[{api,name,desc?,icon?}]}
///   {"op":"playing","app":N,"on":bool} -> {"ok"}
///   {"op":"icon","url":"https://...steamstatic.com/..."} -> {"ok","path"}
///
/// Display texts are localised with "lang" (Steam API language name: "spanish", "latam"...),
/// falling back to english, then any language. "display" keys are present only when the schema
/// has them (hidden always). "unlocked" lists achievements the store turned false -> true:
/// online, as Steam confirmed (merged state minus values Steam reverted); queued offline, against
/// the cached snapshot plus earlier queued stores; with dry_run, what would unlock. "icon"
/// downloads an achievement icon once into cacheDir/icons/ and returns the local file.
///
/// Behaviour: connects lazily with the saved refresh token (never an interactive login),
/// reconnects after a drop, serialises all CM traffic, caches hello/stats per app in
/// `cacheDir` for offline launches, and queues stores made while offline in
/// `cacheDir/store-queue.json`, flushed in order on the next successful logon.
public actor SteamBridgeService {
    public struct Hello: Sendable, Equatable {
        public let steamID: UInt64
        public let name: String
        public let owned: Bool
        public let offline: Bool
    }

    public struct Stats: Sendable {
        public let snapshot: UserStatsSnapshot
        public let offline: Bool
    }

    public struct StoreOutcome: Sendable {
        public var queued = false
        public var stored = false
        /// Achievements this store turned false -> true (see the contract above).
        public var unlocked: [UserStatsSchema.Achievement] = []
        /// ClientStoreUserStats2 body (built in every online path; what dry-run reports).
        public var message: Data?
        public var changedStatIDs: [UInt32] = []
        public var newlyUnlocked: [String] = []
        public var revertedStatIDs: [UInt32] = []
    }

    public struct PlayingOutcome: Sendable {
        public let offline: Bool
        /// Another session of the account is playing; Steam ignores ours until it stops.
        public let blocked: Bool
    }

    struct AccountCache: Codable {
        var steamID: UInt64
        var personaName: String
        var ownedApps: [UInt32]
        var updatedAt: Date
    }

    struct QueuedStore: Codable, Equatable {
        var id: UUID
        var app: UInt32
        var stats: [String: Double]
        var achievements: [String: Bool]
        var queuedAt: Date
    }

    let credentials: CredentialStore
    let tokenDescription: String
    public nonisolated let cacheDir: URL
    let logger: @Sendable (String) -> Void
    /// After a failed connection, requests answer from the cache for this long before retrying.
    public var retryInterval: TimeInterval = 20
    /// Development safety switch: every store is handled as `dry_run` (validated and built,
    /// never sent or queued). `steamdepot serve --dry-run-stores` sets it.
    public var dryRunStores = false
    public func setDryRunStores(_ on: Bool) { dryRunStores = on }

    private var session: SteamSession?
    private var lastFailure: Date?
    private var lastFailureReason = ""
    private var ownedApps: Set<UInt32>?
    private var playing: [UInt32] = []
    private var personaOnline = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(tokenFile: URL, cacheDir: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(credentials: FileCredentialStore(url: tokenFile), tokenDescription: tokenFile.path, cacheDir: cacheDir, log: log)
    }

    /// For the visionOS app: pass a KeychainCredentialStore and an app-container cache dir.
    public init(credentials: CredentialStore, tokenDescription: String = "credential store", cacheDir: URL,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.credentials = credentials
        self.tokenDescription = tokenDescription
        self.cacheDir = cacheDir
        self.logger = log
    }

    // MARK: JSON contract

    public func handle(_ requestJSON: Data) async -> Data {
        let response: [String: Any]
        do {
            guard let req = (try? JSONSerialization.jsonObject(with: requestJSON)) as? [String: Any] else {
                throw BridgeError.badRequest("request must be a JSON object")
            }
            response = try await dispatch(req)
        } catch let e as BridgeError {
            response = ["ok": false, "error": e.description]
        } catch let e as StatsMergeError {
            response = ["ok": false, "error": e.description]
        } catch let e as SteamDepotError {
            response = ["ok": false, "error": e.description]
        } catch {
            response = ["ok": false, "error": "\(error)"]
        }
        return Self.encode(response)
    }

    static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"error":"could not encode response"}"#.utf8)
    }

    private func dispatch(_ req: [String: Any]) async throws -> [String: Any] {
        guard let op = req["op"] as? String else { throw BridgeError.badRequest("missing \"op\"") }
        if op == "icon" {
            guard let url = req["url"] as? String else { throw BridgeError.badRequest("missing \"url\"") }
            return ["ok": true, "path": try await icon(url: url).path]
        }
        var lang: String?
        if let raw = req["lang"] {
            guard let l = raw as? String else { throw BridgeError.badRequest("\"lang\" must be a string") }
            lang = l.isEmpty ? nil : l
        }
        guard let appNum = req["app"] as? NSNumber, let app = UInt32(exactly: appNum.doubleValue), app != 0 else {
            throw BridgeError.badRequest("missing or invalid \"app\"")
        }
        switch op {
        case "hello":
            let h = try await hello(app: app)
            return ["ok": true, "steamid": String(h.steamID), "name": h.name, "owned": h.owned, "offline": h.offline]
        case "stats":
            let s = try await stats(app: app)
            return Self.statsJSON(s.snapshot, offline: s.offline, lang: lang)
        case "store":
            var stats: [String: Double] = [:]
            if let raw = req["stats"] {
                guard let dict = raw as? [String: Any] else { throw BridgeError.badRequest("\"stats\" must be an object") }
                for (k, v) in dict {
                    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                        throw BridgeError.badRequest("stat \(k) must be a number")
                    }
                    stats[k] = n.doubleValue
                }
            }
            var achievements: [String: Bool] = [:]
            if let raw = req["achievements"] {
                guard let dict = raw as? [String: Any] else { throw BridgeError.badRequest("\"achievements\" must be an object") }
                for (k, v) in dict {
                    guard let b = v as? Bool else { throw BridgeError.badRequest("achievement \(k) must be true/false") }
                    achievements[k] = b
                }
            }
            let dryRun = (req["dry_run"] as? Bool ?? false) || dryRunStores
            let o = try await store(app: app, stats: stats, achievements: achievements, dryRun: dryRun)
            var out: [String: Any] = ["ok": true, "queued": o.queued, "stored": o.stored,
                                      "unlocked": o.unlocked.map { Self.unlockedJSON($0, app: app, lang: lang) }]
            if dryRun {
                out["dry_run"] = true
                out["changed_stat_ids"] = o.changedStatIDs.map { Int($0) }
                out["unlocks"] = o.newlyUnlocked
                if let m = o.message { out["message_hex"] = m.hex }
            }
            return out
        case "playing":
            guard let on = req["on"] as? Bool else { throw BridgeError.badRequest("missing \"on\"") }
            let p = try await setPlaying(app: app, on: on)
            var out: [String: Any] = ["ok": true]
            if p.offline { out["offline"] = true }
            if p.blocked { out["blocked"] = true }
            return out
        default:
            throw BridgeError.badRequest("unknown op \(op)")
        }
    }

    public static func statsJSON(_ snap: UserStatsSnapshot, offline: Bool, lang: String? = nil) -> [String: Any] {
        var stats: [String: Any] = [:]
        for s in snap.schema.stats where !s.type.isAchievementBlock {
            switch snap.value(s) {
            case .int(let i): stats[s.name] = ["type": "int", "value": Int(i)]
            case .float(let f): stats[s.name] = ["type": "float", "value": Double("\(f)") ?? Double(f)]
            }
        }
        var achievements: [String: Any] = [:]
        for a in snap.schema.achievements {
            var entry: [String: Any] = ["unlocked": snap.isUnlocked(a), "time": Int(snap.unlockTime(a))]
            if let d = displayJSON(a, app: snap.appID, lang: lang) { entry["display"] = d }
            achievements[a.name] = entry
        }
        return ["ok": true, "offline": offline, "stats": stats, "achievements": achievements]
    }

    /// {name?, desc?, icon?, icon_gray?, hidden}; nil when the schema has no display data at all.
    static func displayJSON(_ a: UserStatsSchema.Achievement, app: UInt32, lang: String?) -> [String: Any]? {
        var d: [String: Any] = [:]
        if let n = a.name(lang) { d["name"] = n }
        if let t = a.desc(lang) { d["desc"] = t }
        if let u = UserStatsSchema.iconURL(app: app, file: a.icon) { d["icon"] = u }
        if let u = UserStatsSchema.iconURL(app: app, file: a.iconGray) { d["icon_gray"] = u }
        guard !d.isEmpty || a.hidden else { return nil }
        d["hidden"] = a.hidden
        return d
    }

    /// {api, name (falls back to api), desc?, icon?} for the store response's "unlocked".
    static func unlockedJSON(_ a: UserStatsSchema.Achievement, app: UInt32, lang: String?) -> [String: Any] {
        var d: [String: Any] = ["api": a.name, "name": a.name(lang) ?? a.name]
        if let t = a.desc(lang) { d["desc"] = t }
        if let u = UserStatsSchema.iconURL(app: app, file: a.icon) { d["icon"] = u }
        return d
    }

    // MARK: typed API

    public func hello(app: UInt32) async throws -> Hello {
        try await serial {
            if let s = try await online() {
                do {
                    let owned = try await ownership(s)
                    let steamID = await s.steamID
                    let persona = await s.personaName
                    let cache = AccountCache(steamID: steamID, personaName: persona ?? loadAccount()?.personaName ?? "",
                                             ownedApps: owned.sorted(), updatedAt: Date())
                    try? save(cache, to: accountURL)
                    return Hello(steamID: cache.steamID, name: cache.personaName, owned: owned.contains(app), offline: false)
                } catch where Self.isNetwork(error) {
                    await dropSession(error)
                }
            }
            guard let cache = loadAccount() else {
                throw BridgeError.offlineNoCache("Steam is unreachable (\(lastFailureReason)) and no account is cached")
            }
            return Hello(steamID: cache.steamID, name: cache.personaName, owned: cache.ownedApps.contains(app), offline: true)
        }
    }

    public func stats(app: UInt32) async throws -> Stats {
        try await serial {
            if let s = try await online() {
                do {
                    let snap = try await s.userStats(app: app)
                    try? save(snap, to: statsURL(app))
                    return Stats(snapshot: snap, offline: false)
                } catch where Self.isNetwork(error) {
                    await dropSession(error)
                }
            }
            guard let snap = offlineSnapshot(app) else {
                throw BridgeError.offlineNoCache("Steam is unreachable (\(lastFailureReason)) and no stats are cached for app \(app)")
            }
            return Stats(snapshot: snap, offline: true)
        }
    }

    public func store(app: UInt32, stats: [String: Double], achievements: [String: Bool], dryRun requestedDryRun: Bool) async throws -> StoreOutcome {
        let dryRun = requestedDryRun || dryRunStores
        return try await serial {
            if let s = try await online() {
                do {
                    return try await storeOnline(s, app: app, stats: stats, achievements: achievements, dryRun: dryRun)
                } catch where Self.isNetwork(error) {
                    await dropSession(error)
                }
            }
            // Offline: validate against the cached schema when there is one, then queue. Unlocks
            // are judged against the offline state (cache + earlier queued stores).
            var o = StoreOutcome()
            if let snap = offlineSnapshot(app) {
                let (merged, changed) = try snap.merging(stats: stats, achievements: achievements)
                o.unlocked = Self.unlockedAchievements(from: snap, to: merged)
                o.newlyUnlocked = o.unlocked.map(\.name)
                if dryRun {
                    o.changedStatIDs = changed
                    o.message = SteamSession.storeUserStatsBody(merged, statIDs: changed, steamID: loadAccount()?.steamID ?? 0)
                    return o
                }
            }
            if dryRun { return o }
            var q = loadQueue()
            q.append(QueuedStore(id: UUID(), app: app, stats: stats, achievements: achievements, queuedAt: Date()))
            try save(q, to: queueURL)
            logger("offline: queued store for app \(app) (\(q.count) pending)")
            o.queued = true
            return o
        }
    }

    public func setPlaying(app: UInt32, on: Bool) async throws -> PlayingOutcome {
        try await serial {
            if on { if !playing.contains(app) { playing.append(app) } } else { playing.removeAll { $0 == app } }
            if let s = try await online() {
                do {
                    try await applyPlaying(s)
                    logger("games played: \(playing)")
                    return PlayingOutcome(offline: false, blocked: await s.playingBlocked)
                } catch where Self.isNetwork(error) {
                    await dropSession(error)
                }
            }
            return PlayingOutcome(offline: true, blocked: false) // re-sent on the next logon
        }
    }

    public struct CurrentValuesStore: Sendable {
        public let statCount: Int
        /// Stats Steam had no stored value for (still at the schema default).
        public let defaultedCount: Int
        public let body: Data
        public let crcBefore: UInt32
        public let crcAfter: UInt32?
        public let reverted: [UInt32]
    }

    /// Round-trip test: re-send every client-writable, non-achievement stat with the value Steam
    /// just returned. Achievement bitfields are never sent, so nothing can unlock. Online only;
    /// with `dryRun` the message is only built.
    public func storeCurrentValues(app: UInt32, dryRun: Bool) async throws -> CurrentValuesStore {
        try await serial {
            guard let s = try await online() else { throw BridgeError.offlineNoCache("Steam is unreachable (\(lastFailureReason))") }
            let snap = try await s.userStats(app: app)
            let stats = snap.schema.stats.filter { !$0.type.isAchievementBlock && !$0.isProtected }
            let ids = stats.map(\.id)
            var exact = snap
            for st in stats { exact.values[String(st.id)] = snap.raw(st) }
            let defaulted = stats.filter { snap.values[String($0.id)] == nil }.count
            if dryRun {
                let body = try await s.storeUserStats(exact, statIDs: ids, dryRun: true).body
                return CurrentValuesStore(statCount: ids.count, defaultedCount: defaulted, body: body,
                                          crcBefore: snap.crc, crcAfter: nil, reverted: [])
            }
            let sent = try await sendStore(s, exact, statIDs: ids)
            return CurrentValuesStore(statCount: ids.count, defaultedCount: defaulted, body: sent.body,
                                      crcBefore: snap.crc, crcAfter: loadStats(app)?.crc, reverted: sent.reverted)
        }
    }

    /// Clear "Playing", log off and disconnect.
    public func shutdown() async {
        await serial {
            if let s = session {
                if !playing.isEmpty, await s.isLoggedOn {
                    playing = []
                    try? await applyPlaying(s)
                }
                await s.disconnect()
            }
            playing = []
            session = nil
        }
    }

    /// Send the games-played list, with the persona Online while something plays (so the
    /// profile shows it) and back to Offline, this session's state at logon, when nothing does.
    private func applyPlaying(_ s: SteamSession) async throws {
        if !playing.isEmpty, !personaOnline { try await s.setPersonaState(1); personaOnline = true }
        try await s.setGamesPlayed(playing)
        if playing.isEmpty, personaOnline { try await s.setPersonaState(0); personaOnline = false }
    }

    // MARK: store internals

    private func storeOnline(_ s: SteamSession, app: UInt32, stats: [String: Double], achievements: [String: Bool],
                             dryRun: Bool) async throws -> StoreOutcome {
        let current = try await s.userStats(app: app)
        try? save(current, to: statsURL(app))
        let (merged, changed) = try current.merging(stats: stats, achievements: achievements)
        var o = StoreOutcome()
        o.changedStatIDs = changed
        o.newlyUnlocked = Self.unlocks(from: current, to: merged)
        if dryRun {
            o.unlocked = Self.unlockedAchievements(from: current, to: merged)
            o.message = try await s.storeUserStats(merged, statIDs: changed, dryRun: true).body
            return o
        }
        guard !changed.isEmpty else { o.stored = true; return o } // nothing differs from Steam
        let result = try await sendStore(s, merged, statIDs: changed)
        o.message = result.body
        o.stored = true
        o.revertedStatIDs = result.reverted
        // Confirmed by Steam: the merged state with the values it reverted put back.
        o.unlocked = Self.unlockedAchievements(from: current, to: result.updated)
        o.newlyUnlocked = o.unlocked.map(\.name)
        return o
    }

    /// Send a store while the app is "playing" (the Steam client only writes stats for a running
    /// game), restoring the previous games-played list afterwards. Updates the stats cache.
    private func sendStore(_ s: SteamSession, _ snap: UserStatsSnapshot, statIDs: [UInt32]) async throws -> (body: Data, reverted: [UInt32], updated: UserStatsSnapshot) {
        let app = snap.appID
        let wasPlaying = playing.contains(app)
        if !wasPlaying { try await s.setGamesPlayed(playing + [app]) }
        let sent: (body: Data, result: StoreUserStatsResult?)
        do {
            sent = try await s.storeUserStats(snap, statIDs: statIDs, dryRun: false)
        } catch {
            if !wasPlaying { try? await s.setGamesPlayed(playing) }
            throw error
        }
        if !wasPlaying { try? await s.setGamesPlayed(playing) }
        let (body, res) = sent
        guard let res else { throw SteamDepotError.protocolError("store: no response") }
        guard res.eresult == EResult.ok else {
            throw SteamDepotError.steamResult("StoreUserStats(\(app))" + (res.statsOutOfDate ? " (stats out of date)" : ""), res.eresult)
        }
        var updated = snap
        updated.crc = res.crc
        for (id, v) in res.failedValidation { updated.values[String(id)] = v }
        updated.fetchedAt = Date()
        try? save(updated, to: statsURL(app))
        logger("stored \(statIDs.count) stats for app \(app)" + (res.failedValidation.isEmpty ? "" : "; Steam reverted \(res.failedValidation.keys.sorted())"))
        return (body, res.failedValidation.keys.sorted(), updated)
    }

    static func unlocks(from a: UserStatsSnapshot, to b: UserStatsSnapshot) -> [String] {
        unlockedAchievements(from: a, to: b).map(\.name)
    }

    /// Achievements locked in `a` and unlocked in `b` (schema order).
    static func unlockedAchievements(from a: UserStatsSnapshot, to b: UserStatsSnapshot) -> [UserStatsSchema.Achievement] {
        a.schema.achievements.filter { !a.isUnlocked($0) && b.isUnlocked($0) }
    }

    /// Cached snapshot plus the stores queued for it while offline (the game's current state).
    func offlineSnapshot(_ app: UInt32) -> UserStatsSnapshot? {
        guard var snap = loadStats(app) else { return nil }
        for q in loadQueue() where q.app == app {
            if let merged = try? snap.merging(stats: q.stats, achievements: q.achievements,
                                              now: UInt32(q.queuedAt.timeIntervalSince1970)) {
                snap = merged.0
            }
        }
        return snap
    }

    // MARK: icon cache

    /// Hosts the icon op may fetch from (Steam's CDNs); anything else is refused.
    static let iconHostSuffixes = ["steamstatic.com", "akamaihd.net", "steampowered.com", "steamcommunity.com"]
    static let maxIconBytes = 4 << 20

    var iconDir: URL { cacheDir.appendingPathComponent("icons", isDirectory: true) }

    /// Cache file stem for an icon URL: "<appid>_<file name without extension>" when the URL is
    /// .../apps/<appid>/<file>, else the sanitised file name. nil for URLs the op refuses.
    static func iconCacheStem(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), url.scheme == "https", let host = url.host?.lowercased(),
              iconHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let file = parts.last else { return nil }
        let base = (file as NSString).deletingPathExtension
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !base.isEmpty, base.unicodeScalars.allSatisfy(ok.contains) else { return nil }
        if parts.count >= 2, let app = UInt32(parts[parts.count - 2]) { return "\(app)_\(base)" }
        return base
    }

    /// "png" / "jpg" from the file's magic bytes; nil for anything else.
    static func imageExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(8))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        return nil
    }

    /// Cached icon file for `url`, if already downloaded.
    public nonisolated func cachedIcon(url: String) -> URL? {
        guard let stem = Self.iconCacheStem(url) else { return nil }
        let dir = cacheDir.appendingPathComponent("icons", isDirectory: true)
        return ["jpg", "png"].map { dir.appendingPathComponent("\(stem).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Download an achievement icon once into cacheDir/icons/ and return the local file. Not
    /// serialised with the CM traffic (plain HTTPS to the CDN).
    public func icon(url: String) async throws -> URL {
        guard let stem = Self.iconCacheStem(url), let u = URL(string: url) else {
            throw BridgeError.badRequest("icon url must be https on a Steam CDN host: \(url)")
        }
        if let hit = cachedIcon(url: url) { return hit }
        let (data, resp) = try await URLSession.shared.data(from: u)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw BridgeError.iconFailed("icon download: HTTP \(http.statusCode) for \(url)")
        }
        guard data.count <= Self.maxIconBytes, let ext = Self.imageExtension(data) else {
            throw BridgeError.iconFailed("icon download: not a PNG/JPEG image (\(data.count) bytes) for \(url)")
        }
        try FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = iconDir.appendingPathComponent("\(stem).\(ext)")
        try data.write(to: file, options: .atomic)
        logger("icon cached: \(file.path)")
        return file
    }

    /// Send queued offline stores in order. Stops (keeping the rest) at the first network error;
    /// drops entries Steam or the merge rules reject, with a log line.
    private func flushQueue(_ s: SteamSession) async throws {
        var q = loadQueue()
        guard !q.isEmpty else { return }
        logger("flushing \(q.count) queued stores")
        while let entry = q.first {
            do {
                let current = try await s.userStats(app: entry.app)
                let (merged, changed) = try current.merging(stats: entry.stats, achievements: entry.achievements,
                                                            now: UInt32(entry.queuedAt.timeIntervalSince1970))
                if !changed.isEmpty { _ = try await sendStore(s, merged, statIDs: changed) }
            } catch where Self.isNetwork(error) {
                try? save(q, to: queueURL)
                throw error
            } catch {
                logger("dropping queued store for app \(entry.app): \(error)")
            }
            q.removeFirst()
            try? save(q, to: queueURL)
        }
    }

    // MARK: connection

    /// Logged-on session, or nil when Steam cannot be reached (callers fall back to the cache).
    /// Throws only for problems a retry will not fix (no token, token rejected).
    private func online() async throws -> SteamSession? {
        if let s = session {
            if await s.isLoggedOn, await s.isConnected { return s }
            logger("Steam session dropped; reconnecting")
            await s.disconnect()
            session = nil
            ownedApps = nil
        }
        guard let creds = try credentials.load() else {
            throw BridgeError.noToken("no saved Steam token (\(tokenDescription)); sign in once with `steamdepot --login-only`")
        }
        if let t = lastFailure, Date().timeIntervalSince(t) < retryInterval { return nil }
        let s = SteamSession(log: logger)
        do {
            try await s.connect()
            try await s.logOn(creds)
        } catch SteamDepotError.logonFailed(let r) where Self.tokenRejected.contains(r) {
            await s.disconnect()
            throw BridgeError.tokenRejected("saved Steam token rejected (EResult \(r)); sign in again with `steamdepot --login-only`")
        } catch {
            await s.disconnect()
            lastFailure = Date()
            lastFailureReason = "\(error)"
            logger("Steam unreachable: \(error)")
            return nil
        }
        lastFailure = nil
        session = s
        personaOnline = false
        logger("logged on to Steam as \(await s.steamID)")
        do {
            if !playing.isEmpty { try await applyPlaying(s) }
            try await flushQueue(s)
        } catch {
            logger("after logon: \(error)")
            if Self.isNetwork(error) { await dropSession(error); return nil }
        }
        return s
    }

    private func dropSession(_ error: Error) async {
        logger("Steam connection lost: \(error)")
        if let s = session { await s.disconnect() }
        session = nil
        ownedApps = nil
        lastFailure = Date()
        lastFailureReason = "\(error)"
    }

    /// App ids in the account's licensed packages, computed once per logon (package contents are
    /// cached with change numbers in cacheDir/packages.json).
    private func ownership(_ s: SteamSession) async throws -> Set<UInt32> {
        if let ownedApps { return ownedApps }
        let owned = try await SteamLibrary.ownedAppIDs(session: s, cacheURL: cacheDir.appendingPathComponent("packages.json"), log: logger)
        ownedApps = owned
        return owned
    }

    static let tokenRejected: Set<Int32> = [EResult.invalidPassword, EResult.accessDenied, EResult.expired,
                                             EResult.revoked, EResult.invalidSignature]

    static func isNetwork(_ error: Error) -> Bool {
        guard let e = error as? SteamDepotError else { return error is URLError }
        switch e {
        case .connectionFailed, .timeout: return true
        case .authFailed(let why): return why == "not logged on"
        default: return false
        }
    }

    // MARK: serialisation (FIFO; actor methods otherwise interleave at every await)

    private func serial<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: cache files

    var accountURL: URL { cacheDir.appendingPathComponent("account.json") }
    var queueURL: URL { cacheDir.appendingPathComponent("store-queue.json") }
    func statsURL(_ app: UInt32) -> URL { cacheDir.appendingPathComponent("stats-\(app).json") }

    func loadAccount() -> AccountCache? { load(AccountCache.self, from: accountURL) }
    func loadStats(_ app: UInt32) -> UserStatsSnapshot? { load(UserStatsSnapshot.self, from: statsURL(app)) }
    func loadQueue() -> [QueuedStore] { load([QueuedStore].self, from: queueURL) ?? [] }

    /// Pending offline stores (oldest first).
    public var pendingStoreCount: Int { loadQueue().count }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(value).write(to: url, options: .atomic)
    }

    // Test hooks (no network).
    func _enqueueForTesting(_ q: QueuedStore) throws { var all = loadQueue(); all.append(q); try save(all, to: queueURL) }
    func _saveStatsForTesting(_ s: UserStatsSnapshot) throws { try save(s, to: statsURL(s.appID)) }
    func _saveAccountForTesting(_ a: AccountCache) throws { try save(a, to: accountURL) }
    func _setOfflineForTesting() { lastFailure = Date(); lastFailureReason = "test"; retryInterval = 3600 }
}

public enum BridgeError: Error, CustomStringConvertible, Sendable {
    case badRequest(String)
    case noToken(String)
    case tokenRejected(String)
    case offlineNoCache(String)
    case iconFailed(String)

    public var description: String {
        switch self {
        case .badRequest(let s): return "bad request: \(s)"
        case .noToken(let s), .tokenRejected(let s), .offlineNoCache(let s), .iconFailed(let s): return s
        }
    }
}

extension SteamLibrary {
    /// App ids of every licensed package (package 0 excluded, as in `fetch`). Package app lists
    /// are cached with change numbers at `cacheURL` and only refetched when they change.
    public static func ownedAppIDs(session: SteamSession, cacheURL: URL?,
                                   log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Set<UInt32> {
        await session.waitForLicenses()
        let licenses = await session.licenses
        guard !licenses.isEmpty else { throw SteamDepotError.timeout("license list") }
        let steamID = await session.steamID
        let cache = cacheURL.flatMap { LibraryCache.load($0, steamID: steamID) }
        var changed: Set<UInt32>?
        var current: UInt32 = 0
        if let cache, cache.changeNumber > 0 {
            if let ch = try? await session.picsChanges(since: cache.changeNumber, includeLists: true) {
                current = ch.currentChangeNumber
                if !ch.fullPackageUpdate { changed = Set(ch.packages.keys) }
            }
        } else {
            current = (try? await session.picsChanges(since: 0, includeLists: false).currentChangeNumber) ?? 0
        }
        var seen = Set<UInt32>()
        let owned = licenses.filter { $0.packageID != 0 && seen.insert($0.packageID).inserted }
            .map { (id: $0.packageID, token: $0.accessToken) }
        let staleIDs = try await stale(ids: owned.map(\.id), cached: cache?.packages.mapValues(\.changeNumber) ?? [:],
                                       changed: changed, session: session, packages: owned)
        var newCache = LibraryCache(steamID: steamID, changeNumber: current)
        for p in owned where !staleIDs.contains(p.id) { newCache.packages[p.id] = cache?.packages[p.id] }
        let toFetch = owned.filter { staleIDs.contains($0.id) }
        for start in stride(from: 0, to: toFetch.count, by: packageBatch) {
            let batch = Array(toFetch[start..<min(start + packageBatch, toFetch.count)])
            let info = try await session.productInfo(packages: batch, timeout: 90)
            for (id, item) in info.packages {
                guard let kv = item.kv else { continue }
                newCache.packages[id] = .init(changeNumber: item.changeNumber, appIDs: appIDs(inPackage: kv))
            }
        }
        log("ownership: \(owned.count) licenses, \(toFetch.count) packages fetched")
        if let cacheURL { try? newCache.save(cacheURL) }
        return Set(newCache.packages.values.flatMap(\.appIDs))
    }
}
