import XCTest
@testable import SteamDepot

/// Achievement display data (names, descriptions, icons) for the "Achievement unlocked" toast:
/// schema parsing, language fallback, the store response's "unlocked" list and the icon cache.
/// Fixtures follow the real SUPERHOT VR (617830) and Half-Life: Alyx (546560) schemas from
/// ClientGetUserStatsResponse (2026-10-07). No network.
final class AchievementDisplayTests: XCTestCase {
    typealias KV = UserStatsTests.KV

    static let app: UInt32 = 617830

    /// bit 0: localised tables (as SUPERHOT/Alyx ship them, incl. "token" and uppercase "LATAM"),
    /// icons, hidden. bit 1: plain-string name/desc. bit 2: table without english.
    /// bit 3: no display block at all.
    static let schemaBlob: Data = {
        var d = KV.node("617830", [
            .node("stats", [
                .node("1", [
                    .str("type", "ACHIEVEMENTS"),
                    .node("bits", [
                        .node("0", [.str("name", "Achiv_YouArePrepared"),
                                    .node("display", [
                                        .node("name", [.str("english", "You Are Prepared"), .str("token", "NEW_ACHIEVEMENT_1_0_NAME"),
                                                       .str("spanish", "Estás preparado"), .str("LATAM", "Estás listo")]),
                                        .node("desc", [.str("english", "Complete the tutorial."), .str("token", "NEW_ACHIEVEMENT_1_0_DESC"),
                                                       .str("spanish", "Completa el tutorial.")]),
                                        .str("hidden", "1"),
                                        .str("icon", "371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg"),
                                        .str("icon_gray", "3bf80c8fb274cf220c4dc0c203a976c89d73dbcc.jpg"),
                                    ])]),
                        .node("1", [.str("name", "Achiv_Plain"),
                                    .node("display", [.str("name", "Plain Name"), .str("desc", "Plain description"),
                                                      .int("hidden", 0), .str("icon", "aaaa.png")])]),
                        .node("2", [.str("name", "Achiv_NoEnglish"),
                                    .node("display", [.node("name", [.str("token", "T"), .str("german", "Nur Deutsch"),
                                                                     .str("french", "Seulement français")])])]),
                        .node("3", [.str("name", "Achiv_Bare")]),
                    ]),
                ]),
                .node("2", [.str("type", "INT"), .str("name", "Kills"), .int("default", 0)]),
            ]),
            .int("version", 29),
        ]).bytes
        d.append(8)
        return d
    }()

    static func schema() throws -> UserStatsSchema { try UserStatsSchema.parse(binary: schemaBlob) }

    /// Achiv_YouArePrepared unlocked, the rest locked.
    static func snapshot() throws -> UserStatsSnapshot {
        UserStatsSnapshot(appID: app, crc: 7, schema: try schema(), values: [1: 0b0001, 2: 3],
                          unlockTimes: [1: [1_600_000_000] + Array(repeating: 0, count: 31)])
    }

    // MARK: parsing

    func testParsesLocalisedTable() throws {
        let a = try XCTUnwrap(try Self.schema().achievement(named: "Achiv_YouArePrepared"))
        XCTAssertEqual(a.localizedName?.languages, ["english": "You Are Prepared", "spanish": "Estás preparado", "latam": "Estás listo"])
        XCTAssertNil(a.localizedName?.plain)
        XCTAssertEqual(a.localizedDesc?.languages["spanish"], "Completa el tutorial.")
        XCTAssertNil(a.localizedDesc?.languages["token"])
        XCTAssertEqual(a.displayName, "You Are Prepared")
        XCTAssertTrue(a.hidden)
        XCTAssertEqual(a.icon, "371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg")
        XCTAssertEqual(a.iconGray, "3bf80c8fb274cf220c4dc0c203a976c89d73dbcc.jpg")
    }

    func testParsesPlainStrings() throws {
        let s = try Self.schema()
        let a = try XCTUnwrap(s.achievement(named: "Achiv_Plain"))
        XCTAssertEqual(a.localizedName, .init(plain: "Plain Name"))
        XCTAssertEqual(a.name("spanish"), "Plain Name")
        XCTAssertEqual(a.desc("spanish"), "Plain description")
        XCTAssertEqual(a.displayName, "Plain Name")
        XCTAssertFalse(a.hidden)
        XCTAssertEqual(a.icon, "aaaa.png")
        XCTAssertNil(a.iconGray)

        let bare = try XCTUnwrap(s.achievement(named: "Achiv_Bare"))
        XCTAssertNil(bare.localizedName)
        XCTAssertNil(bare.name("english"))
        XCTAssertNil(bare.icon)
    }

    func testIconURL() {
        XCTAssertEqual(UserStatsSchema.iconURL(app: 617830, file: "371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg"),
                       "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/617830/371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg")
        XCTAssertEqual(UserStatsSchema.iconURL(app: 1, file: "https://x.steamstatic.com/a.jpg"), "https://x.steamstatic.com/a.jpg")
        XCTAssertNil(UserStatsSchema.iconURL(app: 1, file: nil))
        XCTAssertNil(UserStatsSchema.iconURL(app: 1, file: ""))
    }

    // MARK: language fallback

    func testLanguageFallback() throws {
        let s = try Self.schema()
        let a = try XCTUnwrap(s.achievement(named: "Achiv_YouArePrepared"))
        XCTAssertEqual(a.name("spanish"), "Estás preparado")
        XCTAssertEqual(a.name("SPANISH"), "Estás preparado")         // case-insensitive
        XCTAssertEqual(a.name("latam"), "Estás listo")               // schema spells it "LATAM"
        XCTAssertEqual(a.name("french"), "You Are Prepared")         // missing -> english
        XCTAssertEqual(a.name(nil), "You Are Prepared")
        XCTAssertEqual(a.desc("latam"), "Complete the tutorial.")    // desc table lacks latam

        let noEnglish = try XCTUnwrap(s.achievement(named: "Achiv_NoEnglish"))
        XCTAssertEqual(noEnglish.name("german"), "Nur Deutsch")
        XCTAssertEqual(noEnglish.name("spanish"), "Seulement français") // no english: any (stable: alphabetical)
        XCTAssertEqual(noEnglish.displayName, "Seulement français")
    }

    func testOldCacheWithoutDisplayFieldsStillDecodes() throws {
        // A stats-<app>.json achievement as written before these fields existed.
        let old = #"{"name":"A","statID":1,"bit":0,"displayName":"Old Name","hidden":false,"permission":0}"#
        let a = try JSONDecoder().decode(UserStatsSchema.Achievement.self, from: Data(old.utf8))
        XCTAssertNil(a.localizedName)
        XCTAssertEqual(a.name("spanish"), "Old Name")
        XCTAssertNil(a.desc("spanish"))
    }

    // MARK: contract

    func testStatsJSONDisplay() throws {
        let snap = try Self.snapshot()
        let ach = try XCTUnwrap(SteamBridgeService.statsJSON(snap, offline: false, lang: "spanish")["achievements"] as? [String: [String: Any]])
        let d = try XCTUnwrap(ach["Achiv_YouArePrepared"]?["display"] as? [String: Any])
        XCTAssertEqual(d["name"] as? String, "Estás preparado")
        XCTAssertEqual(d["desc"] as? String, "Completa el tutorial.")
        XCTAssertEqual(d["hidden"] as? Bool, true)
        XCTAssertEqual(d["icon"] as? String,
                       "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/617830/371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg")
        XCTAssertEqual(d["icon_gray"] as? String,
                       "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/617830/3bf80c8fb274cf220c4dc0c203a976c89d73dbcc.jpg")
        // Existing fields unchanged.
        XCTAssertEqual(ach["Achiv_YouArePrepared"]?["unlocked"] as? Bool, true)
        XCTAssertEqual(ach["Achiv_YouArePrepared"]?["time"] as? Int, 1_600_000_000)

        let plain = try XCTUnwrap(ach["Achiv_Plain"]?["display"] as? [String: Any])
        XCTAssertEqual(plain["name"] as? String, "Plain Name")
        XCTAssertEqual(plain["hidden"] as? Bool, false)
        XCTAssertNil(plain["icon_gray"])
        XCTAssertNil(ach["Achiv_Bare"]?["display"])                  // nothing to show: key absent

        // No lang: english.
        let en = try XCTUnwrap(SteamBridgeService.statsJSON(snap, offline: false)["achievements"] as? [String: [String: Any]])
        XCTAssertEqual((en["Achiv_YouArePrepared"]?["display"] as? [String: Any])?["name"] as? String, "You Are Prepared")
    }

    func testUnlockedListOnlyHasFalseToTrue() throws {
        let snap = try Self.snapshot()
        let (merged, _) = try snap.merging(stats: [:], achievements: ["Achiv_YouArePrepared": true, "Achiv_Plain": true,
                                                                      "Achiv_NoEnglish": false], now: 1_700_000_000)
        let unlocked = SteamBridgeService.unlockedAchievements(from: snap, to: merged)
        XCTAssertEqual(unlocked.map(\.name), ["Achiv_Plain"])        // already-unlocked and false ones excluded
        let j = SteamBridgeService.unlockedJSON(unlocked[0], app: Self.app, lang: "spanish")
        XCTAssertEqual(j["api"] as? String, "Achiv_Plain")
        XCTAssertEqual(j["name"] as? String, "Plain Name")
        XCTAssertEqual(j["desc"] as? String, "Plain description")
        XCTAssertEqual(j["icon"] as? String, "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/617830/aaaa.png")

        // Steam reverting the achievement block (failed validation) means it did not unlock.
        var reverted = merged
        reverted.values["1"] = snap.values["1"]
        XCTAssertEqual(SteamBridgeService.unlockedAchievements(from: snap, to: reverted).map(\.name), [])

        // Bare achievement: name falls back to the API name, no desc/icon keys.
        let bare = try XCTUnwrap(snap.schema.achievement(named: "Achiv_Bare"))
        let bj = SteamBridgeService.unlockedJSON(bare, app: Self.app, lang: nil)
        XCTAssertEqual(bj["name"] as? String, "Achiv_Bare")
        XCTAssertNil(bj["desc"])
        XCTAssertNil(bj["icon"])
    }

    func testStoreResponseUnlockedOfflineAndDryRun() async throws {
        let t = UserStatsTests()
        let dir = try tempDir()
        let svc = try await t.makeOfflineService(dir: dir)
        try await svc._saveStatsForTesting(try Self.snapshot())

        // Dry run: what would unlock, localised.
        var r = try await t.call(svc, #"{"op":"store","app":617830,"achievements":{"Achiv_Plain":true,"Achiv_YouArePrepared":true},"dry_run":true,"lang":"spanish"}"#)
        XCTAssertEqual(r["ok"] as? Bool, true)
        var u = try XCTUnwrap(r["unlocked"] as? [[String: Any]])
        XCTAssertEqual(u.map { $0["api"] as? String }, ["Achiv_Plain"])

        // Queued offline: judged against cache + queue.
        r = try await t.call(svc, #"{"op":"store","app":617830,"achievements":{"Achiv_NoEnglish":true},"lang":"german"}"#)
        XCTAssertEqual(r["queued"] as? Bool, true)
        u = try XCTUnwrap(r["unlocked"] as? [[String: Any]])
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0]["api"] as? String, "Achiv_NoEnglish")
        XCTAssertEqual(u[0]["name"] as? String, "Nur Deutsch")
        // Same unlock again: already unlocked in the queued state, so nothing new.
        r = try await t.call(svc, #"{"op":"store","app":617830,"achievements":{"Achiv_NoEnglish":true}}"#)
        XCTAssertEqual(r["queued"] as? Bool, true)
        XCTAssertEqual((r["unlocked"] as? [Any])?.count, 0)
        // Stats-only store: empty list, key always present.
        r = try await t.call(svc, #"{"op":"store","app":617830,"stats":{"Kills":4}}"#)
        XCTAssertEqual((r["unlocked"] as? [Any])?.count, 0)

        r = try await t.call(svc, #"{"op":"stats","app":617830,"lang":5}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
    }

    // MARK: icon cache

    func testIconCacheStemAndImageType() {
        XCTAssertEqual(SteamBridgeService.iconCacheStem(
            "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/617830/371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg"),
            "617830_371bad0a46ec0fea56542bea94c05d8dcc3ed9ee")
        XCTAssertEqual(SteamBridgeService.iconCacheStem("https://shared.fastly.steamstatic.com/community_assets/images/apps/546560/abc.png"),
                       "546560_abc")
        XCTAssertNil(SteamBridgeService.iconCacheStem("http://cdn.cloudflare.steamstatic.com/a/1/abc.jpg"))   // not https
        XCTAssertNil(SteamBridgeService.iconCacheStem("https://evil.example.com/apps/1/abc.jpg"))            // not Steam
        XCTAssertNil(SteamBridgeService.iconCacheStem("https://steamstatic.com.evil.example/apps/1/abc.jpg"))
        XCTAssertNil(SteamBridgeService.iconCacheStem("https://cdn.cloudflare.steamstatic.com/apps/1/a%20b.jpg")) // unsafe name
        // An encoded slash only ever yields a whitelisted stem (no path separators).
        XCTAssertEqual(SteamBridgeService.iconCacheStem("https://cdn.cloudflare.steamstatic.com/apps/1/..%2Fx.jpg"), "x")

        XCTAssertEqual(SteamBridgeService.imageExtension(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])), "png")
        XCTAssertEqual(SteamBridgeService.imageExtension(Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertNil(SteamBridgeService.imageExtension(Data("<html>".utf8)))
    }

    func testIconOpServesCachedFileWithoutNetwork() async throws {
        let t = UserStatsTests()
        let dir = try tempDir()
        let svc = try await t.makeOfflineService(dir: dir)
        let url = "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/617830/371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg"
        let icons = svc.cacheDir.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let file = icons.appendingPathComponent("617830_371bad0a46ec0fea56542bea94c05d8dcc3ed9ee.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: file)

        var r = try await t.call(svc, #"{"op":"icon","url":"\#(url)"}"#)       // no "app" needed
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["path"] as? String, file.path)
        r = try await t.call(svc, #"{"op":"icon","url":"https://example.com/a.jpg"}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
        r = try await t.call(svc, #"{"op":"icon"}"#)
        XCTAssertEqual(r["ok"] as? Bool, false)
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("achdisplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
}
