import XCTest
@testable import SteamDepot

/// Stats schema parsing, achievement bits, merge rules and the offline queue. Fixtures follow
/// the layout of the real SUPERHOT VR (617830) schema returned by ClientGetUserStatsResponse on
/// 2026-10-07 (stat 1 = ACHIEVEMENTS block, then INT stats Stat_*). No network.
final class UserStatsTests: XCTestCase {

    // MARK: fixtures

    /// Binary KeyValues writer (type 0 subtree, 1 string, 2 int32, 3 float, 8 end).
    enum KV {
        case node(String, [KV])
        case str(String, String)
        case int(String, Int32)
        case float(String, Float)

        var bytes: Data {
            var d = Data()
            func name(_ s: String) { d.append(contentsOf: Array(s.utf8)); d.append(0) }
            switch self {
            case .node(let n, let kids):
                d.append(0); name(n)
                for k in kids { d.append(k.bytes) }
                d.append(8)
            case .str(let n, let v): d.append(1); name(n); name(v)
            case .int(let n, let v): d.append(2); name(n); withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            case .float(let n, let v): d.append(3); name(n); withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            }
            return d
        }
    }

    static func display(_ english: String, hidden: Bool = false) -> KV {
        .node("display", [.node("name", [.str("english", english), .str("token", "TOKEN_" + english)]),
                          .int("hidden", hidden ? 1 : 0)])
    }

    /// Two achievement blocks (stat 1 bits 0, 1, 31; stat 9 bit 0), int / float / protected /
    /// old-format stats.
    static let schemaBlob: Data = {
        var d = KV.node("617830", [
            .node("stats", [
                .node("1", [
                    .str("type", "ACHIEVEMENTS"),
                    .node("bits", [
                        .node("0", [.str("name", "Achiv_YouArePrepared"), display("You Are Prepared")]),
                        .node("1", [.str("name", "Achiv_YouAreNowFree"), display("You Are Now Free")]),
                        .node("31", [.str("name", "Achiv_Last"), display("Last Bit", hidden: true)]),
                    ]),
                ]),
                .node("2", [.str("type", "INT"), .str("name", "Stat_YouArePrepared"), display("Prepared"),
                            .int("maxchange", 1), .int("incrementonly", 1), .int("min", 1), .int("max", 1), .int("default", 0)]),
                .node("3", [.str("type", "INT"), .str("name", "Stat_YouAreNowFree"), display("Free"),
                            .int("min", 0), .int("max", 524287), .int("default", 0)]),
                .node("4", [.str("type", "FLOAT"), .str("name", "Stat_Accuracy"), .float("default", 0.5)]),
                .node("5", [.str("type", "INT"), .str("name", "Stat_ServerOnly"), .int("permission", 2)]),
                .node("6", [.int("type_int", 1), .str("name", "Stat_OldFormat"), .int("default", 7)]),
                .node("9", [.int("type", 4), .node("bits", [.node("0", [.str("name", "Achiv_SecondBlock"), .int("bit", 0)])])]),
            ]),
            .int("version", 29),
            .str("gamename", "SUPERHOT VR"),
        ]).bytes
        d.append(8) // end of the outer (nameless) KV document, as Steam sends it
        return d
    }()

    static func schema() throws -> UserStatsSchema { try UserStatsSchema.parse(binary: schemaBlob) }

    /// A CMsgClientGetUserStatsResponse: Achiv_YouArePrepared (bit 0) and Achiv_Last (bit 31)
    /// unlocked, Stat_YouAreNowFree = 42, Stat_Accuracy = 0.75.
    static func responseBody(app: UInt32 = 617830, eresult: Int32 = 1) -> Data {
        var w = ProtoWriter()
        w.fixed64(1, UInt64(app))
        w.int(2, eresult)
        w.uint(3, UInt32(0xC0FFEE))
        w.bytes(4, schemaBlob)
        let values: [(UInt32, UInt32)] = [(1, 0x8000_0001), (2, 1), (3, 42), (4, Float(0.75).bitPattern)]
        for (id, v) in values { w.message(5) { s in s.uint(1, id); s.uint(2, v) } }
        w.message(6) { b in
            b.uint(1, UInt32(1))
            for bit in 0..<32 { b.fixed32(2, bit == 0 ? 1_600_000_000 : (bit == 31 ? 1_700_000_000 : 0)) }
        }
        return w.data
    }

    static func snapshot() throws -> UserStatsSnapshot { try SteamSession.parseUserStatsResponse(responseBody(), app: 617830) }

    // MARK: schema

    func testSchemaParsesStatsAndAchievementBits() throws {
        let s = try Self.schema()
        XCTAssertEqual(s.version, 29)
        XCTAssertEqual(s.achievements.map(\.name), ["Achiv_YouArePrepared", "Achiv_YouAreNowFree", "Achiv_Last", "Achiv_SecondBlock"])
        XCTAssertEqual(s.achievements.map(\.statID), [1, 1, 1, 9])
        XCTAssertEqual(s.achievements.map(\.bit), [0, 1, 31, 0])
        XCTAssertEqual(s.achievement(named: "Achiv_YouAreNowFree")?.displayName, "You Are Now Free")
        XCTAssertEqual(s.achievement(named: "Achiv_Last")?.hidden, true)

        let prepared = try XCTUnwrap(s.stat(named: "Stat_YouArePrepared"))
        XCTAssertEqual(prepared.type, .int)
        XCTAssertTrue(prepared.incrementOnly)
        XCTAssertEqual(prepared.min, 1)
        XCTAssertEqual(prepared.max, 1)
        XCTAssertEqual(s.stat(named: "Stat_Accuracy")?.type, .float)
        XCTAssertEqual(s.stat(named: "Stat_Accuracy")?.defaultValue, 0.5)
        XCTAssertEqual(s.stat(named: "Stat_ServerOnly")?.isProtected, true)
        XCTAssertEqual(s.stat(named: "Stat_OldFormat")?.type, .int) // type_int
        XCTAssertNil(s.stat(named: "Achiv_YouArePrepared"))
    }

    func testResponseMapsAchievementBitsAndTimes() throws {
        let snap = try Self.snapshot()
        XCTAssertEqual(snap.crc, 0xC0FFEE)
        let s = snap.schema
        func a(_ n: String) throws -> UserStatsSchema.Achievement { try XCTUnwrap(s.achievement(named: n)) }
        XCTAssertTrue(snap.isUnlocked(try a("Achiv_YouArePrepared")))
        XCTAssertFalse(snap.isUnlocked(try a("Achiv_YouAreNowFree")))
        XCTAssertTrue(snap.isUnlocked(try a("Achiv_Last")))
        XCTAssertFalse(snap.isUnlocked(try a("Achiv_SecondBlock"))) // block 9 absent = 0
        XCTAssertEqual(snap.unlockTime(try a("Achiv_YouArePrepared")), 1_600_000_000)
        XCTAssertEqual(snap.unlockTime(try a("Achiv_Last")), 1_700_000_000)
        XCTAssertEqual(snap.unlockTime(try a("Achiv_YouAreNowFree")), 0)
        XCTAssertEqual(snap.unlockedCount, 2)

        XCTAssertEqual(snap.value(try XCTUnwrap(s.stat(named: "Stat_YouAreNowFree"))), .int(42))
        XCTAssertEqual(snap.value(try XCTUnwrap(s.stat(named: "Stat_Accuracy"))), .float(0.75))
        XCTAssertEqual(snap.value(try XCTUnwrap(s.stat(named: "Stat_OldFormat"))), .int(7)) // default when absent
    }

    func testResponseErrors() {
        XCTAssertThrowsError(try SteamSession.parseUserStatsResponse(Self.responseBody(app: 1), app: 617830))
        XCTAssertThrowsError(try SteamSession.parseUserStatsResponse(Self.responseBody(eresult: 2), app: 617830))
    }

    func testStatsJSONShape() throws {
        let j = SteamBridgeService.statsJSON(try Self.snapshot(), offline: true)
        XCTAssertEqual(j["ok"] as? Bool, true)
        XCTAssertEqual(j["offline"] as? Bool, true)
        let stats = try XCTUnwrap(j["stats"] as? [String: [String: Any]])
        XCTAssertEqual(stats["Stat_YouAreNowFree"]?["type"] as? String, "int")
        XCTAssertEqual(stats["Stat_YouAreNowFree"]?["value"] as? Int, 42)
        XCTAssertEqual(stats["Stat_Accuracy"]?["type"] as? String, "float")
        XCTAssertEqual(stats["Stat_Accuracy"]?["value"] as? Double, 0.75)
        let ach = try XCTUnwrap(j["achievements"] as? [String: [String: Any]])
        XCTAssertEqual(ach.count, 4)
        XCTAssertEqual(ach["Achiv_YouArePrepared"]?["unlocked"] as? Bool, true)
        XCTAssertEqual(ach["Achiv_YouArePrepared"]?["time"] as? Int, 1_600_000_000)
        XCTAssertEqual(ach["Achiv_YouAreNowFree"]?["unlocked"] as? Bool, false)
    }

    // MARK: merge rules

    func testMergeSetsStatsAndUnlocksOnly() throws {
        let snap = try Self.snapshot()
        let (out, changed) = try snap.merging(stats: ["Stat_YouAreNowFree": 43, "Stat_Accuracy": 0.25],
                                              achievements: ["Achiv_YouAreNowFree": true, "Achiv_SecondBlock": true],
                                              now: 1_800_000_000)
        XCTAssertEqual(changed, [1, 3, 4, 9])
        XCTAssertEqual(out.values["3"], 43)
        XCTAssertEqual(out.values["4"], Float(0.25).bitPattern)
        XCTAssertEqual(out.values["1"], 0x8000_0003)
        XCTAssertEqual(out.values["9"], 1)
        XCTAssertEqual(out.unlockTime(try XCTUnwrap(out.schema.achievement(named: "Achiv_YouAreNowFree"))), 1_800_000_000)
        XCTAssertEqual(out.unlockTime(try XCTUnwrap(out.schema.achievement(named: "Achiv_YouArePrepared"))), 1_600_000_000)
        XCTAssertEqual(SteamBridgeService.unlocks(from: snap, to: out), ["Achiv_YouAreNowFree", "Achiv_SecondBlock"])
    }

    func testMergeNeverUnUnlocks() throws {
        let snap = try Self.snapshot()
        let (out, changed) = try snap.merging(stats: [:], achievements: ["Achiv_YouArePrepared": false, "Achiv_Last": true,
                                                                        "Achiv_YouAreNowFree": false])
        XCTAssertEqual(changed, [])
        XCTAssertEqual(out, snap)
    }

    func testMergeRejectsInvalidChanges() throws {
        let snap = try Self.snapshot()
        XCTAssertThrowsError(try snap.merging(stats: ["Nope": 1], achievements: [:])) {
            XCTAssertEqual($0 as? StatsMergeError, .unknownStat("Nope"))
        }
        XCTAssertThrowsError(try snap.merging(stats: [:], achievements: ["Nope": true])) {
            XCTAssertEqual($0 as? StatsMergeError, .unknownAchievement("Nope"))
        }
        XCTAssertThrowsError(try snap.merging(stats: ["Stat_ServerOnly": 5], achievements: [:])) {
            XCTAssertEqual($0 as? StatsMergeError, .protected("Stat_ServerOnly"))
        }
        XCTAssertThrowsError(try snap.merging(stats: ["Stat_YouAreNowFree": 1.5], achievements: [:])) {
            XCTAssertEqual($0 as? StatsMergeError, .badValue("Stat_YouAreNowFree", 1.5))
        }
        XCTAssertThrowsError(try snap.merging(stats: ["Stat_YouAreNowFree": 600_000], achievements: [:])) {
            XCTAssertEqual($0 as? StatsMergeError, .outOfRange("Stat_YouAreNowFree", 600_000))
        }
        // Increment-only, at 1: going to 0 is a decrement (and below min).
        let incOnly = try snap.merging(stats: [:], achievements: [:]).0
        var lowered = incOnly
        lowered.values["2"] = 1
        XCTAssertThrowsError(try lowered.merging(stats: ["Stat_YouArePrepared": 0], achievements: [:]))
    }

    func testIncrementOnlyCannotDecrease() throws {
        // Unbounded increment-only stat.
        let blob = KV.node("1", [.node("stats", [.node("2", [.str("type", "INT"), .str("name", "Kills"), .int("incrementonly", 1)])])]).bytes + Data([8])
        let schema = try UserStatsSchema.parse(binary: blob)
        let snap = UserStatsSnapshot(appID: 1, crc: 0, schema: schema, values: [2: 10], unlockTimes: [:])
        XCTAssertThrowsError(try snap.merging(stats: ["Kills": 9], achievements: [:])) {
            XCTAssertEqual($0 as? StatsMergeError, .decrement("Kills"))
        }
        XCTAssertEqual(try snap.merging(stats: ["Kills": 11], achievements: [:]).1, [2])
    }

    func testResendingCurrentValuesIsANoOp() throws {
        let snap = try Self.snapshot()
        var all: [String: Double] = [:]
        for s in snap.schema.stats where !s.type.isAchievementBlock { all[s.name] = snap.value(s).number }
        // Includes the protected stat and Stat_YouArePrepared's default-outside-range case.
        let (out, changed) = try snap.merging(stats: all, achievements: [:])
        XCTAssertEqual(changed, [])
        XCTAssertEqual(out, snap)
    }

    func testStoreBodyCarriesCRCAndOnlyChangedStats() throws {
        let (out, changed) = try Self.snapshot().merging(stats: ["Stat_YouAreNowFree": 50], achievements: [:])
        let body = SteamSession.storeUserStatsBody(out, statIDs: changed, steamID: 76561198000000042)
        let m = try ProtoMessage(body)
        XCTAssertEqual(m.u64(1), 617830)
        XCTAssertEqual(m.u64(2), 76561198000000042)
        XCTAssertEqual(m.u64(3), 76561198000000042)
        XCTAssertEqual(m.u32(4), 0xC0FFEE)
        XCTAssertEqual(m.bool(5), false)
        let stats = try m.messages(6)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].u32(1), 3)
        XCTAssertEqual(stats[0].u32(2), 50)
    }

    func testGamesPlayedBody() throws {
        let m = try ProtoMessage(SteamSession.gamesPlayedBody([617830]))
        let games = try m.messages(1)
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].u64(2), 617830)
        XCTAssertTrue(try ProtoMessage(SteamSession.gamesPlayedBody([])).messages(1).isEmpty)
    }

    // MARK: service offline: cache + queue (no network: the service is forced offline)

    func makeOfflineService(dir: URL) async throws -> SteamBridgeService {
        let token = dir.appendingPathComponent("token.json")
        try FileCredentialStore(url: token).save(SteamCredentials(accountName: "test", refreshToken: "not-a-token"))
        let svc = SteamBridgeService(tokenFile: token, cacheDir: dir.appendingPathComponent("cache"))
        await svc._setOfflineForTesting()
        return svc
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func call(_ svc: SteamBridgeService, _ json: String) async throws -> [String: Any] {
        let out = await svc.handle(Data(json.utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    func testOfflineQueuePersistsInOrderAndShowsInStats() async throws {
        let dir = try tempDir()
        let svc = try await makeOfflineService(dir: dir)
        try await svc._saveStatsForTesting(try Self.snapshot())

        var r = try await call(svc, #"{"op":"store","app":617830,"stats":{"Stat_YouAreNowFree":50},"achievements":{"Achiv_YouAreNowFree":true}}"#)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["queued"] as? Bool, true)
        XCTAssertEqual(r["stored"] as? Bool, false)
        r = try await call(svc, #"{"op":"store","app":617830,"stats":{"Stat_YouAreNowFree":60}}"#)
        XCTAssertEqual(r["queued"] as? Bool, true)
        // Invalid stores are rejected up front when the schema is cached.
        r = try await call(svc, #"{"op":"store","app":617830,"stats":{"Stat_ServerOnly":1}}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)

        // A fresh instance (next launch) sees the same queue, in order.
        let svc2 = try await makeOfflineService(dir: dir)
        let q = await svc2.loadQueue()
        XCTAssertEqual(q.map(\.app), [617830, 617830])
        XCTAssertEqual(q.map { $0.stats["Stat_YouAreNowFree"] }, [50, 60])
        XCTAssertEqual(q[0].achievements, ["Achiv_YouAreNowFree": true])

        // Offline stats = cached snapshot + queued stores.
        let s = try await call(svc2, #"{"op":"stats","app":617830}"#)
        XCTAssertEqual(s["offline"] as? Bool, true)
        let stats = try XCTUnwrap(s["stats"] as? [String: [String: Any]])
        XCTAssertEqual(stats["Stat_YouAreNowFree"]?["value"] as? Int, 60)
        let ach = try XCTUnwrap(s["achievements"] as? [String: [String: Any]])
        XCTAssertEqual(ach["Achiv_YouAreNowFree"]?["unlocked"] as? Bool, true)
    }

    func testOfflineDryRunNeitherQueuesNorSends() async throws {
        let dir = try tempDir()
        let svc = try await makeOfflineService(dir: dir)
        try await svc._saveStatsForTesting(try Self.snapshot())
        let r = try await call(svc, #"{"op":"store","app":617830,"achievements":{"Achiv_YouAreNowFree":true},"dry_run":true}"#)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["queued"] as? Bool, false)
        XCTAssertEqual(r["stored"] as? Bool, false)
        XCTAssertEqual(r["unlocks"] as? [String], ["Achiv_YouAreNowFree"])
        XCTAssertNotNil(r["message_hex"] as? String)
        let pending = await svc.pendingStoreCount
        XCTAssertEqual(pending, 0)

        // The serve --dry-run-stores switch turns every store into a dry run.
        await svc.setDryRunStores(true)
        let r2 = try await call(svc, #"{"op":"store","app":617830,"stats":{"Stat_YouAreNowFree":43}}"#)
        XCTAssertEqual(r2["dry_run"] as? Bool, true)
        XCTAssertEqual(r2["queued"] as? Bool, false)
        let pending2 = await svc.pendingStoreCount
        XCTAssertEqual(pending2, 0)
    }

    func testOfflineHelloAndMissingCache() async throws {
        let dir = try tempDir()
        let svc = try await makeOfflineService(dir: dir)
        var r = try await call(svc, #"{"op":"hello","app":617830}"#)
        XCTAssertEqual(r["ok"] as? Bool, false) // nothing cached yet
        XCTAssertNotNil(r["error"] as? String)
        r = try await call(svc, #"{"op":"stats","app":617830}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)

        try await svc._saveAccountForTesting(.init(steamID: 76561198000000042, personaName: "Tester",
                                                   ownedApps: [546560, 617830], updatedAt: Date()))
        r = try await call(svc, #"{"op":"hello","app":617830}"#)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["offline"] as? Bool, true)
        XCTAssertEqual(r["owned"] as? Bool, true)
        XCTAssertEqual(r["steamid"] as? String, "76561198000000042")
        XCTAssertEqual(r["name"] as? String, "Tester")
        r = try await call(svc, #"{"op":"hello","app":448280}"#)
        XCTAssertEqual(r["owned"] as? Bool, false)

        r = try await call(svc, #"{"op":"playing","app":617830,"on":true}"#)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["offline"] as? Bool, true)
    }

    func testNoTokenAndBadRequests() async throws {
        let dir = try tempDir()
        let svc = SteamBridgeService(tokenFile: dir.appendingPathComponent("missing.json"), cacheDir: dir)
        var r = try await call(svc, #"{"op":"hello","app":617830}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue((r["error"] as? String ?? "").contains("no saved Steam token"))
        r = try await call(svc, "not json")
        XCTAssertEqual(r["ok"] as? Bool, false)
        r = try await call(svc, #"{"op":"hello"}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
        r = try await call(svc, #"{"op":"store","app":1,"stats":{"x":true}}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
        r = try await call(svc, #"{"op":"nope","app":1}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
    }
}
