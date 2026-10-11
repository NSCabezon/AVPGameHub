// Steam Cloud sync policy tests: pure planner + executor on a temp folder with a fake cloud.
// No network. Policy adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
// launcher/Sources/SteamLauncherKit/Cloud/SteamCloud.swift.
import XCTest
@testable import SteamDepot

/// In-memory Steam Cloud. Records every upload; has no delete (neither does CloudRemote).
final class FakeCloud: CloudRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, time: UInt64)] = [:]
    private(set) var uploadBatches: [[String]] = []
    private(set) var downloads: [String] = []

    func put(_ name: String, _ text: String, time: UInt64 = 1_700_000_000) {
        lock.lock(); defer { lock.unlock() }
        files[name] = (Data(text.utf8), time)
    }
    func text(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[name].map { String(decoding: $0.data, as: UTF8.self) }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return files.count }

    func list() async throws -> [CloudFile] {
        lock.withLock {
            files.map { CloudFile(filename: $0.key, timestamp: $0.value.time, size: UInt32($0.value.data.count),
                                  sha1Hex: CloudSHA.hex($0.value.data)) }
        }
    }
    func download(_ file: CloudFile) async throws -> Data {
        try lock.withLock {
            downloads.append(file.filename)
            guard let f = files[file.filename] else { throw SteamDepotError.protocolError("no such file") }
            return f.data
        }
    }
    func upload(_ batch: [CloudUpload]) async throws {
        lock.withLock {
            uploadBatches.append(batch.map(\.name))
            for f in batch { files[f.name] = (f.data, UInt64(f.time.timeIntervalSince1970)) }
        }
    }
}

/// Distinct, increasing timestamps so each run gets its own backup folder.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0.0
    func tick() -> Date { lock.withLock { n += 1; return Date(timeIntervalSince1970: 1_800_000_000 + n) } }
}

final class CloudSyncTests: XCTestCase {
    static let prefix = "%gameinstall%game/hlvr/save/"
    static let rule = CloudSaveRule(root: "gameinstall", path: "game/hlvr/save", pattern: "*", recursive: true)
    static func name(_ sub: String) -> String { "%GameInstall%game/hlvr/save/\(sub)" }
    static func sha(_ s: String) -> String { CloudSHA.hex(Data(s.utf8)) }
    static func remote(_ sub: String, _ text: String, time: UInt64 = 1) -> CloudFile {
        CloudFile(filename: name(sub), timestamp: time, sha1Hex: sha(text))
    }
    static func local(_ sub: String, _ text: String) -> CloudLocalFile {
        CloudLocalFile(prefix: prefix, sub: sub, cloudName: name(sub), sha: sha(text))
    }
    static func key(_ sub: String) -> String { prefix + sub }

    // MARK: - Planner (pure)

    func testParseRulesFromPICS() throws {
        let kv = try KeyValue.parse(text: """
        "appinfo" { "ufs" { "quota" "1000000000" "savefiles" {
          "0" { "root" "gameinstall" "path" "game/hlvr/save/" "pattern" "*" "recursive" "1" } } } }
        """)
        XCTAssertEqual(CloudSaveRule.parse(appInfo: kv), [Self.rule])
    }

    func testSameContentIsInSync() {
        let p = CloudSyncPlanner.plan(remote: [Self.remote("a.sav", "x")], local: [Self.local("a.sav", "x")],
                                      state: .init(), mode: .twoWay)
        XCTAssertEqual(p.actions, [.inSync(key: Self.key("a.sav"), sha: Self.sha("x"))])
    }

    func testCloudOnlyFileDownloadsAndDeletedLocallyIsNotResurrected() {
        var st = CloudSyncState()
        st.files[Self.key("gone.sav")] = .init(synced: Self.sha("g"), local: Self.sha("g"))
        let p = CloudSyncPlanner.plan(remote: [Self.remote("new.sav", "n"), Self.remote("gone.sav", "g")], local: [],
                                      state: st, mode: .downloadOnly)
        XCTAssertEqual(p.actions, [.skipDeletedLocally(key: Self.key("gone.sav")),
                                   .download(key: Self.key("new.sav"), remote: Self.remote("new.sav", "n"), replacing: nil)])
    }

    func testCloudChangedOnlyDownloadsReplacingLocal() {
        var st = CloudSyncState()
        st.files[Self.key("a.sav")] = .init(synced: Self.sha("old"), local: Self.sha("old"))
        let l = Self.local("a.sav", "old"), r = Self.remote("a.sav", "new")
        let p = CloudSyncPlanner.plan(remote: [r], local: [l], state: st, mode: .downloadOnly)
        XCTAssertEqual(p.actions, [.download(key: Self.key("a.sav"), remote: r, replacing: l)])
    }

    func testUploadGating() {
        // Headset changed, cloud still at the synced version.
        let r = Self.remote("a.sav", "old"), l = Self.local("a.sav", "mine")
        var st = CloudSyncState()
        st.files[Self.key("a.sav")] = .init(synced: Self.sha("old"), local: Self.sha("old"))
        // Download-only: never uploads.
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: st, mode: .downloadOnly).actions,
                       [.hold(key: Self.key("a.sav"), local: l, reason: .downloadOnly)])
        // Two-way, no baseline yet: the first run only records.
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: st, mode: .twoWay).actions,
                       [.hold(key: Self.key("a.sav"), local: l, reason: .baselineRun)])
        // Two-way with a baseline and a local change: uploads over the cloud version.
        st.uploadBaseline = true
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: st, mode: .twoWay).actions,
                       [.upload(key: Self.key("a.sav"), local: l, over: r)])
        // ...but not when the local content is the baseline (unchanged since the last sync).
        st.files[Self.key("a.sav")]?.local = Self.sha("mine")
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: st, mode: .twoWay).actions,
                       [.keepLocal(key: Self.key("a.sav"), local: l, reason: .unchangedSinceBaseline)])
    }

    func testLocalOnlyFiles() {
        var st = CloudSyncState(); st.uploadBaseline = true
        let fresh = Self.local("new.sav", "n"), cfg = Self.local("personal.cfg", "c"), old = Self.local("kept.sav", "k")
        let dropped = Self.local("dropped.sav", "d")
        st.files[Self.key("kept.sav")] = .init(synced: nil, local: Self.sha("k"))
        st.files[Self.key("dropped.sav")] = .init(synced: Self.sha("d"), local: Self.sha("d"))
        let p = CloudSyncPlanner.plan(remote: [], local: [fresh, cfg, old, dropped], state: st, mode: .twoWay,
                                      neverUpload: ["personal.cfg"])
        XCTAssertEqual(p.actions, [
            .skipDeletedInCloud(key: Self.key("dropped.sav")),
            .keepLocal(key: Self.key("kept.sav"), local: old, reason: .unchangedSinceBaseline),
            .upload(key: Self.key("new.sav"), local: fresh, over: nil),
            .keepLocal(key: Self.key("personal.cfg"), local: cfg, reason: .neverUpload),
        ])
    }

    func testBothChangedIsConflictAndNeverUploads() {
        var st = CloudSyncState(); st.uploadBaseline = true
        st.files[Self.key("autosave.sav")] = .init(synced: Self.sha("base"), local: Self.sha("base"))
        let r = Self.remote("autosave.sav", "pc"), l = Self.local("autosave.sav", "headset")
        let p = CloudSyncPlanner.plan(remote: [r], local: [l], state: st, mode: .twoWay)
        XCTAssertEqual(p.uploads, 0); XCTAssertEqual(p.downloads, 0)
        XCTAssertEqual(p.conflicts.map(\.reason), [.bothChanged])
    }

    func testNoHistoryLooseFileIsConflictButNeverUploadFileComesDown() {
        let p = CloudSyncPlanner.plan(remote: [Self.remote("autosave.sav", "pc"), Self.remote("personal.cfg", "pc")],
                                      local: [Self.local("autosave.sav", "hs"), Self.local("personal.cfg", "hs")],
                                      state: .init(), mode: .twoWay, neverUpload: ["personal.cfg"])
        XCTAssertEqual(p.conflicts.map(\.key), [Self.key("autosave.sav")])
        XCTAssertEqual(p.conflicts.first?.reason, .noHistory)
        XCTAssertEqual(p.actions.last, .download(key: Self.key("personal.cfg"), remote: Self.remote("personal.cfg", "pc"),
                                                 replacing: Self.local("personal.cfg", "hs")))
    }

    func testCollidingSlotRelocatesToFreeNumber() {
        // Headset started a game in s0; the cloud has a different s0 and an s1. Local s2 folder holds files.
        let p = CloudSyncPlanner.plan(
            remote: [Self.remote("s0/autosave.sav", "pc0"), Self.remote("s1/autosave.sav", "pc1")],
            local: [Self.local("s0/autosave.sav", "hs0"), Self.local("s0/autosave.jpg", "img")],
            state: .init(), mode: .twoWay, occupiedSlots: [Self.prefix: ["s0", "s2"]])
        XCTAssertEqual(p.relocations, [CloudRelocation(prefix: Self.prefix, from: "s0", to: "s3")])
        XCTAssertTrue(p.conflicts.isEmpty)
        XCTAssertEqual(p.downloads, 2)   // cloud s0 and s1 come down
        XCTAssertEqual(p.uploads, 0)     // the moved slot is baselined, not uploaded
        XCTAssertTrue(p.actions.contains(.keepLocal(key: Self.key("s3/autosave.sav"),
                                                    local: Self.local("s3/autosave.sav", "hs0"), reason: .unchangedSinceBaseline)))
    }

    func testFreeSlotAndSlotNames() {
        XCTAssertEqual(CloudSyncPlanner.freeSlot(after: "s0", taken: ["s0", "s1", "s3"]), "s2")
        XCTAssertEqual(CloudSyncPlanner.slot(of: "s12/autosave.sav"), "s12")
        XCTAssertNil(CloudSyncPlanner.slot(of: "autosave.sav"))
        XCTAssertNil(CloudSyncPlanner.slot(of: "maps/x.sav"))
    }

    func testResolveConflict() {
        let c = CloudConflict(key: Self.key("a.sav"), cloudName: Self.name("a.sav"), localSHA: Self.sha("hs"),
                              cloudSHA: Self.sha("pc"), reason: .bothChanged, cloudCopy: nil)
        let r = Self.remote("a.sav", "pc"), l = Self.local("a.sav", "hs")
        var useCloud = CloudSyncState(); useCloud.conflicts = [c]
        useCloud.resolve(c, .useCloud)
        XCTAssertTrue(useCloud.conflicts.isEmpty)
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: useCloud, mode: .downloadOnly).actions,
                       [.download(key: c.key, remote: r, replacing: l)])
        var keep = CloudSyncState()
        keep.resolve(c, .keepHeadset)
        // Explicit choice: uploads on the next two-way run even before a baseline exists...
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: keep, mode: .twoWay).actions,
                       [.upload(key: c.key, local: l, over: r)])
        // ...never in download-only mode.
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [r], local: [l], state: keep, mode: .downloadOnly).actions,
                       [.hold(key: c.key, local: l, reason: .downloadOnly)])
        // If the headset file changed again since, it is a conflict again rather than an upload of
        // something the person didn't choose.
        let l2 = Self.local("a.sav", "hs-later")
        XCTAssertEqual(CloudSyncPlanner.plan(remote: [Self.remote("a.sav", "pc2")], local: [l2], state: keep, mode: .twoWay).conflicts.count, 1)
    }

    // MARK: - Executor on disk

    var tmp: URL!
    var saveDir: URL { tmp.appendingPathComponent("gameroot/hlvr/save") }
    var backups: URL { tmp.appendingPathComponent("cloud/backups") }
    var stateURL: URL { tmp.appendingPathComponent("cloud/state.json") }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cloudsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func sync(_ cloud: FakeCloud, _ mode: CloudSyncMode) -> CloudSync {
        let base = tmp.appendingPathComponent("gameroot")
        var s = CloudSync(remote: cloud, rules: [Self.rule], rootFolder: { $0 == "gameinstall" ? base : nil },
                          localPath: { $0.hasPrefix("game/") ? String($0.dropFirst(5)) : nil },
                          stateURL: stateURL, backupRoot: backups)
        s.mode = mode
        s.neverUpload = ["personal.cfg"]
        let clock = TestClock()
        s.now = { clock.tick() }
        return s
    }
    func write(_ sub: String, _ text: String) throws {
        let u = saveDir.appendingPathComponent(sub)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    func read(_ sub: String) -> String? {
        (try? Data(contentsOf: saveDir.appendingPathComponent(sub))).map { String(decoding: $0, as: UTF8.self) }
    }
    func backupFiles() -> [String] {
        ((FileManager.default.enumerator(atPath: backups.path)?.allObjects as? [String]) ?? [])
            .filter { !$0.hasSuffix("/") && (try? backups.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted()
    }

    func testDryRunChangesNothing() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.name("autosave.sav"), "pc")
        try write("autosave.sav", "hs")
        let (report, plan) = try await sync(cloud, .twoWay).run(dryRun: true)
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(read("autosave.sav"), "hs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertTrue(cloud.downloads.isEmpty); XCTAssertTrue(cloud.uploadBatches.isEmpty)
    }

    func testDownloadOnlyBacksUpBeforeReplacingAndNeverUploads() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.name("s0/autosave.sav"), "v1")
        // First run: fresh headset -> cloud save comes down.
        var (r, _) = try await sync(cloud, .downloadOnly).run()
        XCTAssertEqual(r.downloaded, [Self.name("s0/autosave.sav")])
        XCTAssertEqual(read("s0/autosave.sav"), "v1")
        // PC plays on: cloud changes; headset untouched -> replaced, old copy backed up.
        cloud.put(Self.name("s0/autosave.sav"), "v2", time: 2)
        try write("new.sav", "made on headset")
        (r, _) = try await sync(cloud, .downloadOnly).run()
        XCTAssertEqual(read("s0/autosave.sav"), "v2")
        XCTAssertEqual(r.held, [Self.name("new.sav")])
        let b = backupFiles()
        XCTAssertEqual(b.count, 1)
        XCTAssertTrue(b[0].hasSuffix("headset/game/hlvr/save/s0/autosave.sav"))
        XCTAssertEqual(String(decoding: try Data(contentsOf: backups.appendingPathComponent(b[0])), as: UTF8.self), "v1")
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
        XCTAssertNil(cloud.text(Self.name("new.sav")))
    }

    func testConflictKeepsBothAndResolves() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.name("autosave.sav"), "base")
        try await sync(cloud, .twoWay).run()                  // baseline: in sync
        cloud.put(Self.name("autosave.sav"), "pc", time: 5)   // both change
        try write("autosave.sav", "headset")
        let (r, _) = try await sync(cloud, .twoWay).run()
        XCTAssertEqual(r.conflicts.count, 1)
        XCTAssertEqual(read("autosave.sav"), "headset")       // local untouched
        XCTAssertEqual(cloud.text(Self.name("autosave.sav")), "pc")  // cloud untouched
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
        let copy = try XCTUnwrap(r.conflicts[0].cloudCopy)
        XCTAssertEqual(String(decoding: try Data(contentsOf: backups.appendingPathComponent(copy)), as: UTF8.self), "pc")
        var st = CloudSyncState.load(stateURL)
        XCTAssertEqual(st.conflicts.count, 1)

        // The person keeps the headset copy: next two-way run uploads it, backing up the cloud's first.
        st.resolve(st.conflicts[0], .keepHeadset)
        try st.save(stateURL)
        let (r2, _) = try await sync(cloud, .twoWay).run()
        XCTAssertEqual(r2.uploaded, [Self.name("autosave.sav")])
        XCTAssertEqual(cloud.text(Self.name("autosave.sav")), "headset")
        XCTAssertTrue(r2.backedUp.contains { $0.hasSuffix("/cloud/game/hlvr/save/autosave.sav") })
        XCTAssertTrue(CloudSyncState.load(stateURL).conflicts.isEmpty)
    }

    func testTwoWayUploadsOnlyChangesSinceBaselineAndNeverDeletesRemote() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.name("s0/autosave.sav"), "pc")
        try write("s0/autosave.sav", "pc")
        try write("old.sav", "was here before sync was enabled")
        try write("personal.cfg", "headset settings")
        // First two-way run: records the baseline, uploads nothing.
        var (r, _) = try await sync(cloud, .twoWay).run()
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
        XCTAssertEqual(Set(r.held), [Self.name("old.sav")])
        // Play: the game rewrites s0 and makes a new file.
        try write("s0/autosave.sav", "progress")
        try write("s1/quick.sav", "new")
        try write("personal.cfg", "changed settings")
        (r, _) = try await sync(cloud, .twoWay).run()
        XCTAssertEqual(Set(r.uploaded), [Self.name("s0/autosave.sav"), Self.name("s1/quick.sav")])
        XCTAssertEqual(cloud.text(Self.name("s0/autosave.sav")), "progress")
        XCTAssertNil(cloud.text(Self.name("old.sav")))
        XCTAssertNil(cloud.text(Self.name("personal.cfg")))
        XCTAssertEqual(backupFiles().filter { $0.contains("/cloud/") }.count, 1)   // the overwritten cloud s0
        // The game deletes a save locally: the cloud keeps it, and it is not brought back either.
        try FileManager.default.removeItem(at: saveDir.appendingPathComponent("s1/quick.sav"))
        let before = cloud.count
        (r, _) = try await sync(cloud, .twoWay).run()
        XCTAssertEqual(cloud.count, before)
        XCTAssertNil(read("s1/quick.sav"))
        XCTAssertTrue(r.uploaded.isEmpty && r.downloaded.isEmpty)
    }

    func testRelocationOnDiskKeepsBothGames() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.name("s0/autosave.sav"), "pc game")
        try write("s0/autosave.sav", "headset game")
        try FileManager.default.createDirectory(at: saveDir.appendingPathComponent("s1"), withIntermediateDirectories: true) // empty slot dir
        let (r, _) = try await sync(cloud, .twoWay).run()
        XCTAssertEqual(r.relocated, ["s0 → s1"])
        XCTAssertEqual(read("s1/autosave.sav"), "headset game")
        XCTAssertEqual(read("s0/autosave.sav"), "pc game")
        XCTAssertTrue(r.conflicts.isEmpty)
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
    }
}
