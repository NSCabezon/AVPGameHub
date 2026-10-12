import CryptoKit
import Foundation
import XCTest
@testable import MetaStore

/// A scripted network: no request ever leaves the process.
final class MockTransport: MetaTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var contentRange: String? = nil }
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let handler: (URLRequest) -> Reply

    init(_ handler: @escaping (URLRequest) -> Reply) { self.handler = handler }

    func data(for request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { requests.append(request) }
        let r = handler(request)
        return (r.body, r.status)
    }

    func download(_ request: URLRequest, into sink: DownloadSink) async throws {
        lock.withLock { requests.append(request) }
        let r = handler(request)
        do {
            try sink.begin(status: r.status, contentRange: r.contentRange, expectedLength: Int64(r.body.count))
        } catch {
            sink.finish()
            throw error
        }
        var rest = r.body[...]
        while !rest.isEmpty {
            let n = min(1000, rest.count)
            try sink.write(Data(rest.prefix(n)))
            rest = rest.dropFirst(n)
        }
        sink.finish()
    }
}

/// Serves files by store id, honouring Range like the CDN.
func cdn(_ files: [String: Data], status: [String: Int] = [:]) -> (URLRequest) -> MockTransport.Reply {
    return { req in
        let id = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        if let s = status[id] { return .init(status: s, body: Data()) }
        guard let body = files[id] else { return .init(status: 404, body: Data()) }
        if let range = req.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
           let from = Int(range.dropFirst(6).dropLast()) {
            return .init(status: 206, body: body.subdata(in: from..<body.count),
                         contentRange: "bytes \(from)-\(body.count - 1)/\(body.count)")
        }
        return .init(status: 200, body: body)
    }
}

func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
let token = String(repeating: "A", count: 40) + "123"
let fastGate = RequestGate(minInterval: .zero)

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("metastore-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func makeRecipe(apk: Data, obb: Data, addon: Data? = nil) -> Recipe {
    Recipe(schema: 1, id: "game", title: "Game", package: "com.example.game", versionName: "1.0", versionCode: 10,
           appId: "1234567", target: "game",
           files: [
            RecipeFile(name: "game.apk", role: "apk", id: "111", size: Int64(apk.count), sha256: sha(apk), required: true, dest: "meta"),
            RecipeFile(name: "main.10.com.example.game.obb", role: "main-obb", id: "222", size: Int64(obb.count), sha256: sha(obb),
                       required: true, dest: "android-files/obb"),
           ],
           addons: Addons(kind: .deliveredAssets, dest: "android-files/obb", items: [
            AddonItem(sku: "SKU1", name: "song1", id: "333", size: addon.map { Int64($0.count) }, sha256: addon.map(sha), group: nil),
            AddonItem(sku: "SKU2", name: "song2", id: "444", size: nil, sha256: nil, group: nil),
           ]),
           origin: "test")
}

final class RecipeTests: XCTestCase {
    func testBuiltinRecipesAllValidate() throws {
        XCTAssertEqual(Recipes.all.count, BuiltinRecipes.json.count)
        for json in BuiltinRecipes.json { XCTAssertNoThrow(try Recipe.decode(Data(json.utf8))) }
        let bs = try XCTUnwrap(Recipes.recipe(id: "beatsaber"))
        XCTAssertEqual(bs.target, "beatsaber")
        XCTAssertEqual(bs.versionCode, 1716)
        XCTAssertEqual(bs.apk?.relativePath, "meta/beat-saber.apk")
        XCTAssertEqual(bs.files.first { $0.role == "main-obb" }?.relativePath, "android-files/obb/main.1716.com.beatgames.beatsaber.obb")
        XCTAssertEqual(bs.addons?.items.count, 248)
    }

    func testValidationRejectsUnsafeRecipes() {
        let good = makeRecipe(apk: Data("a".utf8), obb: Data("b".utf8))
        XCTAssertNoThrow(try good.validate())
        var r = good; r.files[1].dest = "../../etc"
        XCTAssertThrowsError(try r.validate())
        r = good; r.files[1].name = "../x"
        XCTAssertThrowsError(try r.validate())
        r = good; r.files[0].id = "12a"
        XCTAssertThrowsError(try r.validate())
        r = good; r.files[1].sha256 = nil
        XCTAssertThrowsError(try r.validate(), "required file without checksum")
        r = good; r.appId = "x"
        XCTAssertThrowsError(try r.validate())
        r = good; r.files[1].dest = "meta"; r.files[1].name = "game.apk"; r.files[1].role = "asset"
        XCTAssertThrowsError(try r.validate(), "duplicate path")
    }

    func testBatmanRecipe() throws {
        let b = try XCTUnwrap(Recipes.recipe(id: "batman"))
        XCTAssertNoThrow(try b.validate())
        XCTAssertEqual(b.target, "batman")
        XCTAssertEqual(b.package, "com.camouflaj.manta")
        XCTAssertEqual(b.versionCode, 350961)
        XCTAssertEqual(b.files.filter { $0.role == "apk" }.count, 1)
        XCTAssertEqual(b.apk?.dest, "meta")
        XCTAssertNil(b.apk?.localName)
        XCTAssertEqual(b.apk?.relativePath, "meta/Manta_ReleaseMaster_CL423077_379.apk")
        // avp-play's 91 files; the 6 packs it lists by id only were measured from Meta (2026-10-12).
        XCTAssertEqual(b.files.count, 91)
        XCTAssertEqual(b.files.filter(\.required).count, 83)
        XCTAssertEqual(b.files.filter(\.required).reduce(Int64(0)) { $0 + ($1.size ?? 0) }, 18_263_125_462)
        XCTAssertEqual(b.files.compactMap(\.locale).sorted(),
                       ["de-DE", "en-US", "es-419", "es-ES", "fr-FR", "it-IT", "ja-JP", "ko-KR"])
        // Every pack at the size the game's own localized-asset-manifest.txt gives it.
        let manifest: [String: Int64] = [
            "de-DE": 1_448_858_236, "en-US": 1_249_987_099, "es-419": 1_407_048_947, "es-ES": 1_343_813_242,
            "fr-FR": 1_257_389_086, "it-IT": 1_418_577_351, "ja-JP": 1_391_060_721, "ko-KR": 1_272_413_266,
        ]
        for f in b.files where f.locale != nil {
            XCTAssertEqual(f.size, manifest[f.locale!], f.name)
            XCTAssertEqual(f.name, "Audio_\(f.locale!).obb")
        }
        XCTAssertTrue(b.files.filter { $0.locale != nil }.allSatisfy { !$0.required && $0.sha256 != nil && $0.size != nil })
        XCTAssertTrue(b.files.filter { $0.role != "apk" }.allSatisfy { $0.dest == "android-files/obb" })
    }

    func testBatmanLanguagePacksAreOptIn() throws {
        let b = try XCTUnwrap(Recipes.recipe(id: "batman"))
        let base = FetchPlan.wantedFiles(recipe: b, selection: FetchSelection())
        XCTAssertEqual(base.count, 83)
        XCTAssertTrue(base.allSatisfy { $0.locale == nil })
        let en = FetchPlan.wantedFiles(recipe: b, selection: FetchSelection(locales: ["en-US"]))
        XCTAssertEqual(en.count, 84)
        XCTAssertEqual(en.filter { $0.locale != nil }.map(\.name), ["Audio_en-US.obb"])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: b, selection: FetchSelection(locales: ["xx-XX"])).count, 83)
        let enID = try XCTUnwrap(en.first { $0.locale == "en-US" }).id
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: b, selection: FetchSelection(withheld: [enID], locales: ["en-US"])).count, 83)
    }

    func testDefaultVoiceLocales() throws {
        let b = try XCTUnwrap(Recipes.recipe(id: "batman"))
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["es-ES"]), ["es-ES", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["es_ES"]), ["es-ES", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["es"]), ["es-ES", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["es-MX"]), ["es-419", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["es-419"]), ["es-419", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["fr-CA"]), ["fr-FR", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["en-GB"]), ["en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["ja-JP"]), ["ja-JP", "en-US"])
        // No pack in the first language: the next preferred one that has one.
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["pt-BR", "es-ES"]), ["es-ES", "en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: ["zh-Hans-CN"]), ["en-US"])
        XCTAssertEqual(b.defaultVoiceLocales(preferred: []), ["en-US"])
        let i = try XCTUnwrap(Recipes.recipe(id: "ieytd"))
        XCTAssertEqual(i.defaultVoiceLocales(preferred: ["es-ES"]), [])
        // The selection plans exactly those packs.
        let wanted = FetchPlan.wantedFiles(recipe: b, selection: FetchSelection(locales: b.defaultVoiceLocales(preferred: ["es-ES"])))
        XCTAssertEqual(wanted.compactMap(\.locale).sorted(), ["en-US", "es-ES"])
        XCTAssertEqual(b.files(locales: ["es-ES"]).count, 84)
    }

    func testIEYTDRecipe() throws {
        let r = try XCTUnwrap(Recipes.recipe(id: "ieytd"))
        XCTAssertNoThrow(try r.validate())
        XCTAssertEqual(r.target, "ieytd")
        XCTAssertEqual(r.appId, "1987283631365460")
        XCTAssertEqual(r.package, "com.schellgames.ieytdquest")
        XCTAssertEqual(r.versionCode, 74682)
        // APK only: no OBB, no add-ons, no language packs.
        XCTAssertEqual(r.files.count, 1)
        XCTAssertNil(r.addons)
        XCTAssertEqual(r.apk?.dest, "meta")
        XCTAssertEqual(r.apk?.relativePath, "meta/IEYTD.apk")
        XCTAssertEqual(r.apk?.size, 532_888_801)
        XCTAssertEqual(r.apk?.sha256, "c85d8ec6e9d99d2f6965b41c2152cfcd3a59b66dca17fc2fcbe9c588fdcb8102")
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: FetchSelection()).map(\.name), ["IEYTD.apk"])
    }

    func testKTANERecipe() throws {
        let r = try XCTUnwrap(Recipes.recipe(id: "ktane"))
        XCTAssertNoThrow(try r.validate())
        XCTAssertEqual(r.target, "ktane")
        XCTAssertEqual(r.appId, "2010043642376517")
        XCTAssertEqual(r.package, "com.steelcrategames.keeptalkingandnobodyexplodes")
        XCTAssertEqual(r.versionCode, 87)
        // APK only: no OBB, no add-ons, no language packs.
        XCTAssertEqual(r.files.count, 1)
        XCTAssertNil(r.addons)
        XCTAssertEqual(r.apk?.relativePath, "meta/KeepTalkingandNobodyExplodes.apk")
        XCTAssertEqual(r.apk?.size, 150_667_047)
        XCTAssertEqual(r.apk?.sha256, "a4484afbc11133ec94850c97b0c18393f7cde332f204dfc7d7e3df3e4c457c6d")
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: FetchSelection()).map(\.name), ["KeepTalkingandNobodyExplodes.apk"])
    }

    func testLanguagePackValidation() throws {
        var r = try XCTUnwrap(Recipes.recipe(id: "batman"))
        let i = try XCTUnwrap(r.files.firstIndex { $0.locale == "en-US" })
        let good = r
        r.files[i].required = true
        XCTAssertThrowsError(try r.validate(), "language pack must be optional")
        r = good; r.files[i].sha256 = nil
        XCTAssertThrowsError(try r.validate(), "language pack needs sha256")
        r = good; r.files[i].size = nil
        XCTAssertThrowsError(try r.validate(), "language pack needs size")
    }
}

final class ClientTests: XCTestCase {
    func testMeSendsTokenOnlyAsHeaderToGraph() async throws {
        let t = MockTransport { _ in .init(status: 200, body: Data(#"{"id":"42"}"#.utf8)) }
        let id = try await MetaClient(token: token, transport: t).me()
        XCTAssertEqual(id, "42")
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.url?.host, "graph.oculus.com")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(req.url!.absoluteString.contains(token))
    }

    func testTokenRejected() async {
        let t = MockTransport { _ in .init(status: 400, body: Data(#"{"error":{"message":"bad OC\#(String(repeating: "x", count: 30))","code":190}}"#.utf8)) }
        do {
            _ = try await MetaClient(token: token, transport: t).me()
            XCTFail("expected an error")
        } catch let e as MetaError {
            guard case .tokenRejected(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("<REDACTED>"), m)
        } catch { XCTFail("\(error)") }
    }

    func testOwnsAppPostsUserId() async throws {
        let t = MockTransport { _ in .init(status: 200, body: Data(#"{"success":true}"#.utf8)) }
        let owned = try await MetaClient(token: token, transport: t).ownsApp(appId: "2448060205267927", userId: "42")
        XCTAssertTrue(owned)
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/2448060205267927/verify_entitlement")
        XCTAssertEqual(String(data: req.httpBody ?? Data(), encoding: .utf8), "user_id=42")
    }

    func testPurchasesFollowSanitizedPagesAndDropExpired() async throws {
        let page2 = "https://graph.oculus.com/1/viewer_purchases?after=X&access_token=SECRET"
        let t = MockTransport { req in
            if req.url!.query!.contains("after=X") {
                return .init(status: 200, body: Data(#"{"data":[{"item":{"sku":"B"}}],"paging":{"next":"https://evil.example/x"}}"#.utf8))
            }
            return .init(status: 200, body: Data(#"{"data":[{"item":{"sku":"A"}},{"expiration_time":1000,"item":{"sku":"OLD"}}],"paging":{"next":"\#(page2)"}}"#.utf8))
        }
        let skus = try await MetaClient(token: token, transport: t).purchases(appId: "1", now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(skus, ["A", "B"])
        XCTAssertEqual(t.requests.count, 2, "the off-host next page is not followed")
        XCTAssertFalse(t.requests[1].url!.absoluteString.contains("SECRET"))
    }

    func testDownloadWholeResumeAndDenied() async throws {
        let body = Data((0..<5000).map { UInt8($0 % 251) })
        let t = MockTransport(cdn(["7": body]))
        let client = MetaClient(token: token, transport: t)
        let dir = tempDir()
        let dst = dir.appendingPathComponent("f")
        let o = try await client.download(id: "7", to: dst)
        XCTAssertEqual(try Data(contentsOf: dst), body)
        XCTAssertFalse(o.resumed)
        XCTAssertEqual(t.requests[0].url?.host, "securecdn.oculus.com")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")

        try body.prefix(1234).write(to: dst)
        let r = try await client.download(id: "7", to: dst, resumeFrom: 1234)
        XCTAssertTrue(r.resumed)
        XCTAssertEqual(r.totalSize, 5000)
        XCTAssertEqual(t.requests[1].value(forHTTPHeaderField: "Range"), "bytes=1234-")
        XCTAssertEqual(try Data(contentsOf: dst), body)

        let missing = dir.appendingPathComponent("g")
        do {
            _ = try await client.download(id: "8", to: missing)
            XCTFail("expected denied")
        } catch let e as MetaError { XCTAssertEqual(e, .denied(status: 404)) }
    }

    func testRedirectStripsAuthorizationOffHost() {
        var r = URLRequest(url: URL(string: "https://scontent.example.net/x")!)
        r.setValue("Bearer T", forHTTPHeaderField: "Authorization")
        XCTAssertNil(RedirectGuard.strip(r, authorizedHost: "securecdn.oculus.com").value(forHTTPHeaderField: "Authorization"))
        var same = URLRequest(url: URL(string: "https://securecdn.oculus.com/y")!)
        same.setValue("Bearer T", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(RedirectGuard.strip(same, authorizedHost: "securecdn.oculus.com").value(forHTTPHeaderField: "Authorization"), "Bearer T")
    }

    func testRedaction() {
        XCTAssertEqual(Redaction.redact("t=FRL\(String(repeating: "a", count: 40)) ok"), "t=<REDACTED> ok")
        XCTAssertEqual(Redaction.redact("?access_token=abc&x=1"), "?access_token=<REDACTED>&x=1")
    }
}

final class FetchTests: XCTestCase {
    let apk = Data(repeating: 1, count: 3000)
    let obb = Data(repeating: 2, count: 7000)
    let song = Data(repeating: 3, count: 500)

    func testPlanAddsOnlyOwnedAddons() {
        let r = makeRecipe(apk: apk, obb: obb, addon: song)
        let names = FetchPlan.wantedFiles(recipe: r, selection: FetchSelection(ownedSKUs: ["SKU1"])).map(\.name)
        XCTAssertEqual(names, ["game.apk", "main.10.com.example.game.obb", "song1"])
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: FetchSelection()).count, 2)
        XCTAssertEqual(FetchPlan.wantedFiles(recipe: r, selection: FetchSelection(ownedSKUs: ["SKU1"], withheld: ["333"])).count, 2)
    }

    func testFullDownloadVerifiesAndCompletes() async throws {
        let r = makeRecipe(apk: apk, obb: obb, addon: song)
        let t = MockTransport(cdn(["111": apk, "222": obb, "333": song]))
        let store = GameStore(root: tempDir())
        let sel = FetchSelection(ownedSKUs: ["SKU1"])
        let plan = FetchPlan.plan(recipe: r, selection: sel, record: store.loadRecord(), state: store.state(of:))
        XCTAssertEqual(plan.map(\.action), [.download, .download, .download])
        let progress = ProgressLog()
        let s = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate)
            .run(plan, recipe: r, progress: { progress.add($0) })
        XCTAssertEqual(s.downloaded, 3)
        XCTAssertTrue(store.isComplete(r))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("meta/game.apk")), apk)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("android-files/obb/song1")), song)
        XCTAssertEqual(progress.last?.bytesDone, progress.last?.bytesTotal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.metaDir.appendingPathComponent(".partial").path))

        // Second run: everything kept, nothing requested.
        let again = FetchPlan.plan(recipe: r, selection: sel, record: store.loadRecord(), state: store.state(of:))
        XCTAssertEqual(again.map(\.action), [.keep, .keep, .keep])
        let n = t.requests.count
        _ = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate).run(again, recipe: r)
        XCTAssertEqual(t.requests.count, n)
        XCTAssertTrue(store.isComplete(r))

        // A new build (version code) is not "complete" and re-fetches files it did not verify.
        var newer = r; newer.versionCode = 11
        XCTAssertFalse(store.isComplete(newer))
        XCTAssertEqual(FetchPlan.plan(recipe: newer, selection: FetchSelection(), record: store.loadRecord(), state: store.state(of:)).map(\.action),
                       [.download, .download])
    }

    func testCompletenessCountsTheChosenVoicePacks() async throws {
        var r = makeRecipe(apk: apk, obb: obb)
        r.addons = nil
        let voice = Data("hola".utf8)
        r.files.append(RecipeFile(name: "Audio_es-ES.obb", role: "audio-locale", id: "555", size: Int64(voice.count),
                                  sha256: sha(voice), required: false, dest: "android-files/obb", locale: "es-ES"))
        XCTAssertNoThrow(try r.validate())
        let t = MockTransport(cdn(["111": apk, "222": obb, "555": voice]))
        let store = GameStore(root: tempDir())
        let client = MetaClient(token: token, transport: t)
        // An install from before the packs: the base game only.
        let base = FetchPlan.plan(recipe: r, selection: FetchSelection(), record: nil, state: store.state(of:))
        _ = try await Fetcher(client: client, store: store, gate: fastGate).run(base, recipe: r)
        XCTAssertTrue(store.isComplete(r))
        XCTAssertFalse(store.isComplete(r, locales: ["es-ES"]), "the Spanish pack is not there yet")
        let p = store.requiredProgress(r, locales: ["es-ES"])
        XCTAssertEqual(p.total - p.have, Int64(voice.count))
        // Asking again with the pack: only the pack is fetched.
        let more = FetchPlan.plan(recipe: r, selection: FetchSelection(locales: ["es-ES"]), record: store.loadRecord(), state: store.state(of:))
        XCTAssertEqual(more.map(\.action), [.keep, .keep, .download])
        _ = try await Fetcher(client: client, store: store, gate: fastGate).run(more, recipe: r)
        XCTAssertTrue(store.isComplete(r, locales: ["es-ES"]))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("android-files/obb/Audio_es-ES.obb")), voice)
    }

    func testChecksumMismatchStopsAtFirstFile() async throws {
        let r = makeRecipe(apk: apk, obb: obb)
        let t = MockTransport(cdn(["111": Data(repeating: 9, count: apk.count), "222": obb]))
        let store = GameStore(root: tempDir())
        let plan = FetchPlan.plan(recipe: r, selection: FetchSelection(), record: nil, state: store.state(of:))
        do {
            _ = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate).run(plan, recipe: r)
            XCTFail("expected checksum mismatch")
        } catch let e as FetchError { XCTAssertEqual(e, .checksumMismatch(name: "game.apk")) }
        XCTAssertEqual(t.requests.count, 1, "nothing more is requested after an unexpected answer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: r.files[0]).path))
        XCTAssertFalse(store.isComplete(r))
    }

    func testDeniedRequiredFileStops() async throws {
        let r = makeRecipe(apk: apk, obb: obb)
        let t = MockTransport(cdn(["111": apk, "222": obb], status: ["111": 403]))
        let store = GameStore(root: tempDir())
        let plan = FetchPlan.plan(recipe: r, selection: FetchSelection(), record: nil, state: store.state(of:))
        do {
            _ = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate).run(plan, recipe: r)
            XCTFail("expected denied")
        } catch let e as MetaError { XCTAssertEqual(e, .denied(status: 403)) }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testWithheldAddonIsRememberedAndSkipped() async throws {
        let r = makeRecipe(apk: apk, obb: obb, addon: song)
        let t = MockTransport(cdn(["111": apk, "222": obb]))       // 333 -> 404
        let store = GameStore(root: tempDir())
        let sel = FetchSelection(ownedSKUs: ["SKU1"])
        let plan = FetchPlan.plan(recipe: r, selection: sel, record: nil, state: store.state(of:))
        let s = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate).run(plan, recipe: r)
        XCTAssertEqual(s.withheld, ["song1"])
        XCTAssertTrue(store.isComplete(r))
        XCTAssertEqual(store.loadRecord()?.withheld, ["333"])
    }

    func testResumeFromPartial() async throws {
        let r = makeRecipe(apk: apk, obb: obb)
        let t = MockTransport(cdn(["111": apk, "222": obb]))
        let store = GameStore(root: tempDir())
        let partial = store.partialURL(for: r.files[1])
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try obb.prefix(2500).write(to: partial)
        let plan = FetchPlan.plan(recipe: r, selection: FetchSelection(), record: nil, state: store.state(of:))
        XCTAssertEqual(plan.map(\.action), [.download, .resume(from: 2500)])
        _ = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate).run(plan, recipe: r)
        XCTAssertEqual(t.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=2500-")
        XCTAssertTrue(store.isComplete(r))
        XCTAssertEqual(GameStore.fileSize(store.url(for: r.files[1])), Int64(obb.count))
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Fetcher.Progress] = []
    func add(_ p: Fetcher.Progress) { lock.lock(); items.append(p); lock.unlock() }
    var last: Fetcher.Progress? { lock.lock(); defer { lock.unlock() }; return items.last }
}

final class AccountTests: XCTestCase {
    func testHandoffImportsAndDeletes() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent(TokenHandoff.fileName)
        try TokenHandoff.encode(token: token).write(to: file)
        let store = MemoryTokenStore()
        XCTAssertTrue(TokenHandoff.importIfPresent(in: dir, into: store))
        XCTAssertEqual(try store.load(), token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(TokenHandoff.importIfPresent(in: dir, into: store))
    }

    func testMalformedHandoffIsDeletedNotImported() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent(TokenHandoff.fileName)
        try Data(#"{"token":"short","created":"2026-01-01T00:00:00Z"}"#.utf8).write(to: file)
        let store = MemoryTokenStore()
        XCTAssertFalse(TokenHandoff.importIfPresent(in: dir, into: store))
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try TokenHandoff.encode(token: "has spaces in it and is long enough to pass length"))
    }

    func testOwnershipCheckUsesCacheAndRefreshesStale() async throws {
        let t = MockTransport { req in
            if req.url?.path == "/me" { return .init(status: 200, body: Data(#"{"id":"42"}"#.utf8)) }
            return .init(status: 200, body: Data(#"{"success":\#(req.url!.path.contains("111") ? "true" : "false")}"#.utf8))
        }
        let client = MetaClient(token: token, transport: t)
        let cache = OwnershipCache(url: tempDir().appendingPathComponent("ownership.json"))
        let now = Date()
        let a = try await OwnershipCheck.refresh(client: client, appIds: ["111", "222"], cache: cache, gate: fastGate, now: { now })
        XCTAssertEqual(a.apps["111"]?.owned, true)
        XCTAssertEqual(a.apps["222"]?.owned, false)
        XCTAssertEqual(t.requests.count, 3)
        _ = try await OwnershipCheck.refresh(client: client, appIds: ["111", "222"], cache: cache, gate: fastGate, now: { now })
        XCTAssertEqual(t.requests.count, 4, "fresh answers are not asked again (only /me)")
        let later = now.addingTimeInterval(25 * 3600)
        _ = try await OwnershipCheck.refresh(client: client, appIds: ["111"], cache: cache, gate: fastGate, now: { later })
        XCTAssertEqual(t.requests.count, 6)
        XCTAssertTrue(cache.load(userId: "other").isEmpty, "answers belong to one account")
    }

    func testRequestGateDelay() {
        let now = ContinuousClock.now
        XCTAssertEqual(RequestGate.delay(lastFinished: nil, now: now, minInterval: .seconds(5)), .zero)
        XCTAssertEqual(RequestGate.delay(lastFinished: now - .seconds(2), now: now, minInterval: .seconds(5)), .seconds(3))
        XCTAssertEqual(RequestGate.delay(lastFinished: now - .seconds(9), now: now, minInterval: .seconds(5)), .zero)
    }

    #if os(macOS)
    func testTokenSieveHoldsBackTheToken() {
        var s = TokenSieve()
        let tok = String(repeating: "Ab1", count: 30)
        var out = s.feed(Array("Token: \(tok)\n".utf8))
        out += s.finish()
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertFalse(text.contains(tok))
        XCTAssertTrue(text.contains(TokenSieve.placeholder))
        XCTAssertEqual(s.token, tok)
        // Typed characters (echo) show at once.
        var typed = TokenSieve()
        XCTAssertEqual(typed.feed(Array("a".utf8)), Array("a".utf8))
    }

    func testTeamIdentifierParsing() {
        XCTAssertEqual(MetaTool.teamIdentifier(in: "Identifier=x\nTeamIdentifier=HXH6UQBHD4\n"), "HXH6UQBHD4")
        XCTAssertNil(MetaTool.teamIdentifier(in: "Signature=adhoc\n"))
    }
    #endif
}

final class MacFetchTests: XCTestCase {
    func testBeatSaberApkOnlyDefaultsToKleptonFile() throws {
        let bs = try XCTUnwrap(Recipes.recipe(id: "beatsaber"))
        XCTAssertEqual(bs.versionCode, 1716)
        let klepton = URL(fileURLWithPath: "/tmp/avpgh/klepton", isDirectory: true)
        let out = MacFetch.defaultOut(recipe: bs, apkOnly: true, kleptonDir: klepton, cwd: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(out.path, "/tmp/avpgh/klepton/beatsaber-1.40.8.apk")
        let l = try MacFetch.layout(recipe: bs, apkOnly: true, out: out)
        XCTAssertEqual(l.recipe.files.map(\.role), ["apk"])
        XCTAssertNil(l.recipe.addons)
        XCTAssertEqual(l.apkFile, out)
        XCTAssertEqual(l.root.path, "/tmp/avpgh/klepton/.metastore-fetch-beatsaber")
        XCTAssertNoThrow(try l.recipe.validate())
    }

    func testFetchApkOnlyEndToEndWithMock() async throws {
        let apk = Data(repeating: 5, count: 4000)
        var r = makeRecipe(apk: apk, obb: Data(repeating: 6, count: 10))
        r.target = "other"
        let out = tempDir().appendingPathComponent("x.apk")
        let l = try MacFetch.layout(recipe: r, apkOnly: true, out: out)
        let t = MockTransport(cdn(["111": apk]))
        let store = GameStore(root: l.root)
        let plan = FetchPlan.plan(recipe: l.recipe, selection: FetchSelection(), record: nil, state: store.state(of:))
        _ = try await Fetcher(client: MetaClient(token: token, transport: t), store: store, gate: fastGate).run(plan, recipe: l.recipe)
        XCTAssertTrue(store.isComplete(l.recipe))
        XCTAssertEqual(t.requests.count, 1, "only the APK is requested")
        XCTAssertEqual(MacFetch.defaultOut(recipe: r, apkOnly: false, kleptonDir: URL(fileURLWithPath: "/k"), cwd: URL(fileURLWithPath: "/w")).path,
                       "/w/metastore-game")
    }
}
