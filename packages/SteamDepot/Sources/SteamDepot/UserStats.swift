import Foundation

// Steam user stats and achievements over the CM connection.
//
// Messages (SteamDatabase/Protobufs steam/steammessages_clientserver_userstats.proto, the same
// file SteamKit2 compiles into SteamKit2.Internal; EMsg values from SteamKit2 SteamLanguage.cs):
//   ClientGetUserStats (818)            CMsgClientGetUserStats
//   ClientGetUserStatsResponse (819)    CMsgClientGetUserStatsResponse (values + binary-KV schema)
//   ClientStoreUserStats2 (5466)        CMsgClientStoreUserStats2
//   ClientStoreUserStatsResponse (821)  CMsgClientStoreUserStatsResponse
// SteamKit2's SteamUserStats handler only covers leaderboards / player counts, so these are sent
// as raw protobuf messages, like SteamKit users do with ClientMsgProtobuf<CMsgClientGetUserStats>.
//
// Schema layout (UserGameStatsSchema_<app>.bin; parsing follows gibbed/SteamAchievementManager
// SAM.Game/Manager.cs LoadUserGameStatsSchema):
//   "<appid>" { "version" N  "stats" { "<statid>" { "type" ("int"|"float"|"avgrate"|"achievements"
//   |"groupachievements" or 1..5; older schemas "type_int"), "name", "min", "max", "default",
//   "incrementonly", "permission", "bits" { "<n>" { "name", "bit", "display" { "name", "desc",
//   "hidden", "icon", "icon_gray" } } } } } }
// display.name / display.desc are either a plain string or a table keyed by Steam API language
// name ({ "english" "...", "spanish" "...", "LATAM" "...", "token" "NEW_ACHIEVEMENT_1_0_NAME" });
// SAM resolves them as requested language, then "english", then the plain value
// (Manager.cs GetLocalizedString). icon / icon_gray are CDN file names with extension
// ("371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg"), see `UserStatsSchema.iconURL`.
// Achievements are bits of a stat of type achievements: unlocked = (value >> bit) & 1, and the
// response's achievement_blocks carry 32 unlock times per achievement stat (indexed by bit).

public struct UserStatsSchema: Codable, Sendable, Equatable {
    public enum StatType: String, Codable, Sendable {
        case int, float, avgRate, achievements, groupAchievements

        /// SAM's UserStatType: Integer/Int = 1, Float = 2, AverageRate = 3, Achievements = 4,
        /// GroupAchievements = 5; new schemas spell it, old ones store the number.
        init?(schemaValue: String) {
            switch schemaValue.lowercased() {
            case "1", "int", "integer": self = .int
            case "2", "float": self = .float
            case "3", "avgrate", "averagerate": self = .avgRate
            case "4", "achievements": self = .achievements
            case "5", "groupachievements": self = .groupAchievements
            default: return nil
            }
        }
        public var isAchievementBlock: Bool { self == .achievements || self == .groupAchievements }
        /// Values travel as uint32: two's-complement int32 or IEEE float bits.
        public var isFloat: Bool { self == .float || self == .avgRate }
    }

    public struct Stat: Codable, Sendable, Equatable {
        public let id: UInt32
        public let name: String
        public let type: StatType
        public let min: Double?
        public let max: Double?
        public let defaultValue: Double
        public let incrementOnly: Bool
        /// Bit 1 set = only a trusted game server may write it (SAM: `permission & 2`).
        public let permission: Int
        public var isProtected: Bool { permission & 2 != 0 }
    }

    /// display.name / display.desc: a plain string or a per-language table.
    public struct LocalizedText: Codable, Sendable, Equatable {
        /// The plain-string form (no table).
        public var plain: String?
        /// Lowercased Steam API language name ("english", "spanish", "latam"...) -> text; no "token".
        public var languages: [String: String]

        public init(plain: String? = nil, languages: [String: String] = [:]) {
            self.plain = plain
            self.languages = languages
        }

        /// Requested language, then english, then the plain string, then any language
        /// (alphabetically first, so the choice is stable).
        public func resolve(_ language: String?) -> String? {
            if let language, let v = languages[language.lowercased()], !v.isEmpty { return v }
            if let v = languages["english"], !v.isEmpty { return v }
            if let plain, !plain.isEmpty { return plain }
            return languages.sorted { $0.key < $1.key }.first { !$0.value.isEmpty }?.value
        }
    }

    public struct Achievement: Codable, Sendable, Equatable {
        public let name: String
        public let statID: UInt32
        public let bit: UInt32
        /// English (or fallback) display name; kept for older callers and caches.
        public let displayName: String?
        public let hidden: Bool
        public let permission: Int
        // Optional so stats caches written before these fields existed still decode.
        public var localizedName: LocalizedText?
        public var localizedDesc: LocalizedText?
        /// CDN file names (with extension), see `UserStatsSchema.iconURL`.
        public var icon: String?
        public var iconGray: String?

        public init(name: String, statID: UInt32, bit: UInt32, displayName: String?, hidden: Bool, permission: Int,
                    localizedName: LocalizedText? = nil, localizedDesc: LocalizedText? = nil,
                    icon: String? = nil, iconGray: String? = nil) {
            self.name = name
            self.statID = statID
            self.bit = bit
            self.displayName = displayName
            self.hidden = hidden
            self.permission = permission
            self.localizedName = localizedName
            self.localizedDesc = localizedDesc
            self.icon = icon
            self.iconGray = iconGray
        }

        public func name(_ language: String?) -> String? { localizedName?.resolve(language) ?? displayName }
        public func desc(_ language: String?) -> String? { localizedDesc?.resolve(language) }
    }

    /// Icon file name -> URL. Steam Community serves achievement icons from
    /// .../steamcommunity/public/images/apps/<appid>/<file> on its CDN hosts
    /// (cdn.cloudflare/fastly/akamai.steamstatic.com; the Community pages themselves link
    /// shared.fastly.steamstatic.com/community_assets/images/apps/<appid>/<file>, same files).
    /// A value that is already a URL is returned as is.
    public static func iconURL(app: UInt32, file: String?) -> String? {
        guard let file, !file.isEmpty else { return nil }
        if file.hasPrefix("https://") || file.hasPrefix("http://") { return file }
        return "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(app)/\(file)"
    }

    public let version: Int
    /// Non-achievement stats and achievement-block stats, by id order.
    public let stats: [Stat]
    public let achievements: [Achievement]

    public func stat(named name: String) -> Stat? { stats.first { $0.name == name && !$0.type.isAchievementBlock } }
    public func achievement(named name: String) -> Achievement? { achievements.first { $0.name == name } }

    /// Parse the binary KeyValues schema blob from ClientGetUserStatsResponse.schema.
    public static func parse(binary data: Data) throws -> UserStatsSchema {
        try parse(try KeyValue.parseBinary(data))
    }

    /// Parse a schema tree: the "<appid>" node (or any node holding "stats").
    public static func parse(_ kv: KeyValue) throws -> UserStatsSchema {
        guard let root = kv["stats"] != nil ? kv : kv.children.first(where: { $0["stats"] != nil }),
              let statsNode = root["stats"] else {
            throw SteamDepotError.protocolError("stats schema: no \"stats\" block")
        }
        var stats: [Stat] = []
        var achievements: [Achievement] = []
        for node in statsNode.children {
            guard let id = UInt32(node.name) ?? node["id"]?.value.flatMap({ UInt32($0) }) else { continue }
            let rawType = node["type"]?.value.flatMap(StatType.init(schemaValue:))
                ?? node["type_int"]?.value.flatMap(StatType.init(schemaValue:))
            guard let type = rawType else { continue }
            let permission = node["permission"]?.value.flatMap { Int($0) } ?? 0
            stats.append(Stat(id: id, name: node["name"]?.value ?? "stat_\(id)", type: type,
                              min: node["min"]?.value.flatMap(Double.init), max: node["max"]?.value.flatMap(Double.init),
                              defaultValue: node["default"]?.value.flatMap(Double.init) ?? 0,
                              incrementOnly: boolValue(node["incrementonly"]?.value),
                              permission: permission))
            guard type.isAchievementBlock else { continue }
            for bitNode in node["bits"]?.children ?? [] {
                guard let bit = bitNode["bit"]?.value.flatMap({ UInt32($0) }) ?? UInt32(bitNode.name), bit < 32,
                      let name = bitNode["name"]?.value, !name.isEmpty else { continue }
                let display = bitNode["display"]
                let localizedName = localizedText(display?["name"])
                achievements.append(Achievement(name: name, statID: id, bit: bit,
                                                displayName: localizedName?.resolve("english"),
                                                hidden: boolValue(display?["hidden"]?.value),
                                                permission: bitNode["permission"]?.value.flatMap { Int($0) } ?? permission,
                                                localizedName: localizedName,
                                                localizedDesc: localizedText(display?["desc"]),
                                                icon: nonEmpty(display?["icon"]?.value),
                                                iconGray: nonEmpty(display?["icon_gray"]?.value)))
            }
        }
        return UserStatsSchema(version: root["version"]?.value.flatMap { Int($0) } ?? 0,
                               stats: stats.sorted { $0.id < $1.id },
                               achievements: achievements.sorted { ($0.statID, $0.bit) < ($1.statID, $1.bit) })
    }

    static func boolValue(_ s: String?) -> Bool {
        guard let s = s?.lowercased() else { return false }
        return s == "1" || s == "true"
    }

    /// display.name / display.desc: a plain string or { "english" "...", "token" "...", ... }.
    static func localizedText(_ node: KeyValue?) -> LocalizedText? {
        guard let node else { return nil }
        if let v = node.value { return v.isEmpty ? nil : LocalizedText(plain: v) }
        var langs: [String: String] = [:]
        for c in node.children where c.name.lowercased() != "token" {
            if let v = c.value, !v.isEmpty { langs[c.name.lowercased()] = v }
        }
        return langs.isEmpty ? nil : LocalizedText(languages: langs)
    }

    static func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
}

/// One user's stats for one app: schema, raw uint32 values and achievement unlock times.
public struct UserStatsSnapshot: Codable, Sendable, Equatable {
    public enum Value: Equatable, Sendable {
        case int(Int32)
        case float(Float)
        public var number: Double {
            switch self { case .int(let i): return Double(i); case .float(let f): return Double(f) }
        }
    }

    public let appID: UInt32
    /// crc_stats from the last ClientGetUserStatsResponse / ClientStoreUserStatsResponse;
    /// ClientStoreUserStats2 must echo it.
    public var crc: UInt32
    public let schema: UserStatsSchema
    /// stat id (decimal string) -> raw uint32 value.
    public var values: [String: UInt32]
    /// achievement stat id (decimal string) -> unlock times indexed by bit (unix seconds, 0 = none).
    public var unlockTimes: [String: [UInt32]]
    public var fetchedAt: Date

    public init(appID: UInt32, crc: UInt32, schema: UserStatsSchema, values: [UInt32: UInt32],
                unlockTimes: [UInt32: [UInt32]], fetchedAt: Date = Date()) {
        self.appID = appID
        self.crc = crc
        self.schema = schema
        self.values = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
        self.unlockTimes = Dictionary(uniqueKeysWithValues: unlockTimes.map { (String($0.key), $0.value) })
        self.fetchedAt = fetchedAt
    }

    /// Steam omits stats still at their default.
    public func raw(_ stat: UserStatsSchema.Stat) -> UInt32 {
        if let v = values[String(stat.id)] { return v }
        return Self.encode(stat.defaultValue, as: stat.type) ?? 0
    }

    public func value(_ stat: UserStatsSchema.Stat) -> Value { Self.decode(raw(stat), as: stat.type) }

    public func isUnlocked(_ a: UserStatsSchema.Achievement) -> Bool {
        let block = values[String(a.statID)] ?? 0
        return (block >> a.bit) & 1 == 1
    }

    public func unlockTime(_ a: UserStatsSchema.Achievement) -> UInt32 {
        guard isUnlocked(a), let times = unlockTimes[String(a.statID)], Int(a.bit) < times.count else { return 0 }
        return times[Int(a.bit)]
    }

    public var unlockedCount: Int { schema.achievements.filter(isUnlocked).count }

    static func decode(_ raw: UInt32, as type: UserStatsSchema.StatType) -> Value {
        type.isFloat ? .float(Float(bitPattern: raw)) : .int(Int32(bitPattern: raw))
    }

    /// nil when the number does not fit the type (non-integral or outside Int32 for ints).
    static func encode(_ number: Double, as type: UserStatsSchema.StatType) -> UInt32? {
        if type.isFloat { return Float(number).bitPattern }
        guard number.isFinite, number.rounded() == number, number >= Double(Int32.min), number <= Double(Int32.max) else { return nil }
        return UInt32(bitPattern: Int32(number))
    }

    /// Apply a store request. Rules: unknown names are errors; a changed value must not touch a
    /// server-protected stat, int stats need integral numbers inside [min, max], increment-only
    /// stats cannot go down (Steam itself enforces maxchange, reverting what exceeds it);
    /// achievements only go false -> true (`false` and already-unlocked ones are ignored).
    /// Returns the new snapshot and the stat ids whose raw value changed.
    public func merging(stats: [String: Double], achievements: [String: Bool],
                        now: UInt32 = UInt32(Date().timeIntervalSince1970)) throws -> (UserStatsSnapshot, [UInt32]) {
        var out = self
        var changed = Set<UInt32>()
        for (name, number) in stats.sorted(by: { $0.key < $1.key }) {
            guard let stat = schema.stat(named: name) else { throw StatsMergeError.unknownStat(name) }
            guard number.isFinite, let newRaw = Self.encode(number, as: stat.type) else { throw StatsMergeError.badValue(name, number) }
            // Re-sending the current value is always fine (even a default outside [min, max]).
            if newRaw == raw(stat) { continue }
            guard !stat.isProtected else { throw StatsMergeError.protected(name) }
            let stored = Self.decode(newRaw, as: stat.type).number
            if let lo = stat.min, stored < lo { throw StatsMergeError.outOfRange(name, number) }
            if let hi = stat.max, stored > hi { throw StatsMergeError.outOfRange(name, number) }
            if stat.incrementOnly && stored < value(stat).number { throw StatsMergeError.decrement(name) }
            out.values[String(stat.id)] = newRaw
            changed.insert(stat.id)
        }
        for (name, unlock) in achievements.sorted(by: { $0.key < $1.key }) {
            guard let a = schema.achievement(named: name) else { throw StatsMergeError.unknownAchievement(name) }
            guard unlock, !out.isUnlocked(a) else { continue }
            guard a.permission & 2 == 0 else { throw StatsMergeError.protected(name) }
            let key = String(a.statID)
            out.values[key] = (out.values[key] ?? 0) | (1 << a.bit)
            var times = out.unlockTimes[key] ?? []
            if times.count < 32 { times += Array(repeating: 0, count: 32 - times.count) }
            times[Int(a.bit)] = now
            out.unlockTimes[key] = times
            changed.insert(a.statID)
        }
        return (out, changed.sorted())
    }
}

public enum StatsMergeError: Error, CustomStringConvertible, Sendable, Equatable {
    case unknownStat(String)
    case unknownAchievement(String)
    case protected(String)
    case badValue(String, Double)
    case outOfRange(String, Double)
    case decrement(String)

    public var description: String {
        switch self {
        case .unknownStat(let n): return "unknown stat \(n)"
        case .unknownAchievement(let n): return "unknown achievement \(n)"
        case .protected(let n): return "\(n) can only be set by a trusted game server"
        case .badValue(let n, let v): return "bad value \(v) for stat \(n)"
        case .outOfRange(let n, let v): return "value \(v) out of range for stat \(n)"
        case .decrement(let n): return "stat \(n) is increment-only"
        }
    }
}

/// Result of ClientStoreUserStats2.
public struct StoreUserStatsResult: Sendable {
    public let eresult: Int32
    public let crc: UInt32
    /// stat id -> value Steam reverted it to.
    public let failedValidation: [UInt32: UInt32]
    public let statsOutOfDate: Bool
}

extension SteamSession {
    /// The CM socket is up (it may still be logged off).
    public var isConnected: Bool { get async { await cm.isConnected } }

    /// ClientGetUserStats -> ClientGetUserStatsResponse. Requests the schema too
    /// (schema_local_version -1, crc 0: "I have nothing cached").
    public func userStats(app: UInt32, steamID user: UInt64? = nil) async throws -> UserStatsSnapshot {
        guard isLoggedOn else { throw SteamDepotError.authFailed("not logged on") }
        var w = ProtoWriter()
        w.fixed64(1, UInt64(app))         // game_id (a plain app's GameID is its app id)
        w.uint(2, UInt32(0))              // crc_stats
        w.int(3, -1)                      // schema_local_version
        w.fixed64(4, user ?? steamID)     // steam_id_for_user
        let resp = try await cm.sendAndWait(emsg: EMsg.clientGetUserStats, body: w.data,
                                            responseEmsg: EMsg.clientGetUserStatsResponse, timeout: 20)
        let snap = try Self.parseUserStatsResponse(resp.body, app: app)
        logger("user stats for \(app): \(snap.values.count) stored values, \(snap.unlockTimes.count) achievement blocks, crc \(snap.crc)")
        return snap
    }

    static func parseUserStatsResponse(_ body: Data, app: UInt32) throws -> UserStatsSnapshot {
        let m = try ProtoMessage(body)
        let gameID = m.u64(1) ?? 0
        guard UInt32(truncatingIfNeeded: gameID) == app else {
            throw SteamDepotError.protocolError("user stats response for game \(gameID), expected \(app)")
        }
        let r = m.i32(2) ?? EResult.fail
        guard r == EResult.ok else {
            if r == EResult.fail || r == EResult.fileNotFound { throw SteamDepotError.steamResult("GetUserStats(\(app)) (no stats for this app?)", r) }
            throw SteamDepotError.steamResult("GetUserStats(\(app))", r)
        }
        guard let blob = m.bytes(4), !blob.isEmpty else { throw SteamDepotError.protocolError("user stats for \(app): no schema") }
        let schema = try UserStatsSchema.parse(binary: blob)
        var values: [UInt32: UInt32] = [:]
        for s in try m.messages(5) { if let id = s.u32(1) { values[id] = s.u32(2) ?? 0 } }
        var times: [UInt32: [UInt32]] = [:]
        for b in try m.messages(6) { if let id = b.u32(1) { times[id] = b.u32s(2) } }
        return UserStatsSnapshot(appID: app, crc: m.u32(3) ?? 0, schema: schema, values: values, unlockTimes: times)
    }

    /// Body of ClientStoreUserStats2 for the given stat ids (settor = settee = us).
    static func storeUserStatsBody(_ snap: UserStatsSnapshot, statIDs: [UInt32], steamID: UInt64) -> Data {
        var w = ProtoWriter()
        w.fixed64(1, UInt64(snap.appID))  // game_id
        w.fixed64(2, steamID)             // settor_steam_id
        w.fixed64(3, steamID)             // settee_steam_id
        w.uint(4, snap.crc)               // crc_stats
        w.bool(5, false)                  // explicit_reset
        for id in statIDs {
            w.message(6) { s in
                s.uint(1, id)
                s.uint(2, snap.values[String(id)] ?? 0)
            }
        }
        return w.data
    }

    /// ClientStoreUserStats2 -> ClientStoreUserStatsResponse. Sends `statIDs` with their values
    /// in `snap`. With `dryRun`, returns the message body without sending anything.
    public func storeUserStats(_ snap: UserStatsSnapshot, statIDs: [UInt32], dryRun: Bool) async throws -> (body: Data, result: StoreUserStatsResult?) {
        guard isLoggedOn || dryRun else { throw SteamDepotError.authFailed("not logged on") }
        let body = Self.storeUserStatsBody(snap, statIDs: statIDs, steamID: steamID)
        if dryRun { return (body, nil) }
        let resp = try await cm.sendAndWait(emsg: EMsg.clientStoreUserStats2, body: body,
                                            responseEmsg: EMsg.clientStoreUserStatsResponse, timeout: 20)
        let m = try ProtoMessage(resp.body)
        var failed: [UInt32: UInt32] = [:]
        for f in try m.messages(4) { if let id = f.u32(1) { failed[id] = f.u32(2) ?? 0 } }
        return (body, StoreUserStatsResult(eresult: m.i32(2) ?? EResult.fail, crc: m.u32(3) ?? 0,
                                           failedValidation: failed, statsOutOfDate: m.bool(5) ?? false))
    }

    /// ClientGamesPlayedWithDataBlob (what SteamKit-based ASF and node-steam-user send today):
    /// one GamePlayed per app shows "Playing X" and counts playtime; an empty list stops.
    public func setGamesPlayed(_ apps: [UInt32]) async throws {
        guard isLoggedOn else { throw SteamDepotError.authFailed("not logged on") }
        try await cm.send(emsg: EMsg.clientGamesPlayedWithDataBlob, body: Self.gamesPlayedBody(apps))
    }

    /// ClientChangeStatus (SteamKit2 SteamFriends.SetPersonaState): 1 = Online, 0 = Offline.
    /// A session starts Offline; without Online the game only counts playtime and friends and
    /// the profile do not show "Playing X".
    public func setPersonaState(_ state: UInt32) async throws {
        guard isLoggedOn else { throw SteamDepotError.authFailed("not logged on") }
        var w = ProtoWriter()
        w.uint(1, state) // persona_state
        try await cm.send(emsg: EMsg.clientChangeStatus, body: w.data)
    }

    static func gamesPlayedBody(_ apps: [UInt32]) -> Data {
        var w = ProtoWriter()
        for app in apps {
            w.message(1) { g in g.fixed64(2, UInt64(app)) } // games_played { game_id }
        }
        w.uint(2, UInt32(bitPattern: 16))                  // client_os_type (Windows 10, as at logon)
        return w.data
    }
}
