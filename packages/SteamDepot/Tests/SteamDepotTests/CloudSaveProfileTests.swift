// Steam Cloud save mappings per hub game (CloudSaveProfile): cloud name <-> local file, case kept,
// unmapped roots ignored, and full runs against a temp folder with the in-memory FakeCloud
// (CloudSyncTests.swift). No network.
import XCTest
@testable import SteamDepot

final class CloudSaveProfileTests: XCTestCase {
    // The rules as PICS `ufs/savefiles` lists them.
    static let alyxRule = CloudSaveRule(root: "gameinstall", path: "game/hlvr/save", pattern: "*", recursive: true)
    static let superhotRule = CloudSaveRule(root: "WinAppDataLocalLow", path: "SUPERHOT_Team/SUPERHOT_VR",
                                            pattern: "*.hot", recursive: false)
    static let metroRules = [
        CloudSaveRule(root: "WinAppDataLocal", path: "Impact/Saved/SaveGames", pattern: "*.sav", recursive: false),
        CloudSaveRule(root: "gameinstall", path: "Impact/Saved/SaveGames", pattern: "*.sav", recursive: false),
        CloudSaveRule(root: "AndroidExternalData",
                      path: "Android/data/com.vertigogames.ImpactDevelopment/files/UnrealGame/Impact/Impact/Saved/SaveGames",
                      pattern: "*.sav", recursive: false),
    ]
    static let shPrefix = "%WinAppDataLocalLow%SUPERHOT_Team/SUPERHOT_VR/"
    static let metroPrefix = "%AndroidExternalData%Android/data/com.vertigogames.ImpactDevelopment/files/UnrealGame/Impact/Impact/Saved/SaveGames/"

    var tmp: URL!
    var writeLayer: URL { tmp.appendingPathComponent("gameroot") }
    var androidFiles: URL { tmp.appendingPathComponent("android-files") }
    var stateDir: URL { tmp.appendingPathComponent("cloud") }
    var bases: [CloudSaveProfile.Base: URL] { [.writeLayer: writeLayer, .androidFiles: androidFiles] }
    var shDir: URL { androidFiles.appendingPathComponent("files") }
    var metroDir: URL { androidFiles.appendingPathComponent("UnrealGame/Impact/Impact/Saved/SaveGames") }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cloudprofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func sync(_ p: CloudSaveProfile, _ rules: [CloudSaveRule], _ cloud: FakeCloud, _ mode: CloudSyncMode) -> CloudSync {
        var s = p.makeSync(remote: cloud, rules: rules, bases: bases, stateDir: stateDir, mode: mode)
        let clock = TestClock()
        s.now = { clock.tick() }
        return s
    }
    func write(_ u: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    func read(_ u: URL) -> String? { (try? Data(contentsOf: u)).map { String(decoding: $0, as: UTF8.self) } }
    /// Names as the directory stores them (case as created).
    func names(_ d: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).sorted() }

    // MARK: - Mapping

    func testProfilesForApps() {
        XCTAssertEqual(CloudSaveProfile.forApp(546560)?.target, "alyx")
        XCTAssertEqual(CloudSaveProfile.forApp(617830)?.target, "superhot")
        XCTAssertEqual(CloudSaveProfile.forApp(2669410)?.target, "metro")
        XCTAssertNil(CloudSaveProfile.forApp(620))
        XCTAssertEqual(CloudSaveProfile.alyx.bases, [.writeLayer])
        XCTAssertEqual(CloudSaveProfile.superhot.bases, [.androidFiles])
        XCTAssertEqual(CloudSaveProfile.metro.bases, [.androidFiles])
        XCTAssertEqual(CloudSaveProfile.alyx.neverUpload, ["personal.cfg", "*.hl1", "*.hl2", "*.hl3"])
    }

    func testDefaultBases() {
        let home = URL(fileURLWithPath: "/home/x")
        let env = ProcessInfo.processInfo.environment
        if env["KL_FILES_DIR"] == nil, env["KL_GLIBC_WRITE"] == nil {
            XCTAssertEqual(CloudSaveProfile.metro.macBases(home: home)[.androidFiles]?.path,
                           "/home/x/Library/Application Support/Klepton/userdata/metro")
            XCTAssertEqual(CloudSaveProfile.alyx.macBases(home: home)[.writeLayer]?.path,
                           "/home/x/Library/Application Support/Klepton/userdata/alyx/gameroot")
            let hub = CloudSaveProfile.superhot.hubBases(home: home, gameRoot: home.appendingPathComponent("Documents/games/superhot"))
            XCTAssertEqual(hub[.androidFiles]?.path, "/home/x/Documents/games/superhot/android-files")
            XCTAssertEqual(hub[.writeLayer]?.path, "/home/x/Library/Application Support/Klepton/userdata/superhot/gameroot")
        }
    }

    func testAlyxMappingUnchanged() throws {
        let s = sync(.alyx, [Self.alyxRule], FakeCloud(), .downloadOnly)
        XCTAssertEqual(s.folder(for: Self.alyxRule)?.path, writeLayer.appendingPathComponent("hlvr/save").path)
        // Same as the mapping the profile had before (prefix "game/" stripped, write layer).
        let r = CloudSaveProfile.alyx.roots["gameinstall"]!
        XCTAssertEqual(r.localPath("game/hlvr/save"), "hlvr/save")
        XCTAssertEqual(r.localPath("game"), "")
        XCTAssertNil(r.localPath("gamex/hlvr"))
        XCTAssertNil(r.localPath("hlvr/save"))
        XCTAssertNil(s.folder(for: CloudSaveRule(root: "WinAppDataLocal", path: "game/hlvr/save")))

        try write(writeLayer.appendingPathComponent("hlvr/save/s0/autosave.sav"), "a")
        let scan = s.scanLocal()
        XCTAssertEqual(scan.files.map(\.cloudName), ["%GameInstall%game/hlvr/save/s0/autosave.sav"])
        XCTAssertEqual(scan.files.map(\.key), ["%gameinstall%game/hlvr/save/s0/autosave.sav"])
        let dest = s.destination(for: CloudFile(filename: "%GameInstall%game/hlvr/save/s1/quick.sav", timestamp: 1, sha1Hex: ""))
        XCTAssertEqual(dest?.path, writeLayer.appendingPathComponent("hlvr/save/s1/quick.sav").path)
    }

    func testSuperhotMapping() throws {
        let s = sync(.superhot, [Self.superhotRule], FakeCloud(), .downloadOnly)
        XCTAssertEqual(s.folder(for: Self.superhotRule)?.path, shDir.path)
        // Any spelling of the token / path maps (matched case-insensitively), to the same folder.
        XCTAssertEqual(s.folder(for: CloudSaveRule(root: "winappdatalocallow", path: "superhot_team/superhot_vr"))?.path, shDir.path)
        // Local -> cloud: only *.hot directly in the folder (not the game's .bak, not subfolders).
        try write(shDir.appendingPathComponent("VRsuper.hot"), "progress")
        try write(shDir.appendingPathComponent("VRsuper.hot.bak"), "backup")
        try write(shDir.appendingPathComponent("il2cpp/old.hot"), "nested")
        let scan = s.scanLocal()
        XCTAssertEqual(scan.files.map(\.cloudName), [Self.shPrefix + "VRsuper.hot"])
        XCTAssertEqual(scan.files.map(\.key), [(Self.shPrefix + "VRsuper.hot").lowercased()])
        // Cloud -> local.
        XCTAssertEqual(s.destination(for: CloudFile(filename: Self.shPrefix + "VRsuper.hot", timestamp: 1, sha1Hex: ""))?.path,
                       shDir.appendingPathComponent("VRsuper.hot").path)
        XCTAssertNil(s.destination(for: CloudFile(filename: Self.shPrefix + "VRsuper.hot.bak", timestamp: 1, sha1Hex: "")))
        XCTAssertNil(s.destination(for: CloudFile(filename: Self.shPrefix + "sub/x.hot", timestamp: 1, sha1Hex: "")))
    }

    func testMetroMappingIgnoresOtherPlatformsRules() throws {
        let s = sync(.metro, Self.metroRules, FakeCloud(), .downloadOnly)
        XCTAssertNil(s.folder(for: Self.metroRules[0]))
        XCTAssertNil(s.folder(for: Self.metroRules[1]))
        // The rule's own spelling, not lowercased (data containers are case-sensitive).
        XCTAssertEqual(s.folder(for: Self.metroRules[2])?.path, metroDir.path)
        XCTAssertTrue(s.folder(for: Self.metroRules[2])!.path.hasSuffix("/android-files/UnrealGame/Impact/Impact/Saved/SaveGames"))

        try write(metroDir.appendingPathComponent("S0PlayerSettings.sav"), "settings")
        try write(metroDir.appendingPathComponent("Global.sav"), "global")
        try write(metroDir.appendingPathComponent("notes.txt"), "not a save")
        // Where the gameinstall rule would point if it were mapped onto android files: must stay unseen.
        try write(androidFiles.appendingPathComponent("Impact/Saved/SaveGames/pc.sav"), "pc")
        let scan = s.scanLocal()
        XCTAssertEqual(Set(scan.files.map(\.cloudName)), [Self.metroPrefix + "S0PlayerSettings.sav", Self.metroPrefix + "Global.sav"])
        XCTAssertEqual(s.destination(for: CloudFile(filename: Self.metroPrefix + "S1.sav", timestamp: 1, sha1Hex: ""))?.path,
                       metroDir.appendingPathComponent("S1.sav").path)
        XCTAssertNil(s.destination(for: CloudFile(filename: "%WinAppDataLocal%Impact/Saved/SaveGames/S1.sav", timestamp: 1, sha1Hex: "")))
        XCTAssertNil(s.destination(for: CloudFile(filename: "%GameInstall%Impact/Saved/SaveGames/S1.sav", timestamp: 1, sha1Hex: "")))
    }

    func testNewDownloadKeepsTheCloudNamesSpelling() {
        let s = sync(.metro, Self.metroRules, FakeCloud(), .downloadOnly)
        // Even when the cloud spells the rule part differently, the folder is the rule's and the file
        // keeps the cloud's own spelling.
        let odd = "%androidexternaldata%android/data/com.vertigogames.impactdevelopment/files/unrealgame/impact/impact/saved/savegames/S0PlayerSettings.sav"
        XCTAssertEqual(s.destination(for: CloudFile(filename: odd, timestamp: 1, sha1Hex: ""))?.path,
                       metroDir.appendingPathComponent("S0PlayerSettings.sav").path)
    }

    // MARK: - Runs

    func testMetroFirstSyncDownloadOnly() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.metroPrefix + "S0PlayerSettings.sav", "settings")
        cloud.put(Self.metroPrefix + "Global.sav", "global")
        cloud.put(Self.metroPrefix + "S0_0.sav", "slot")
        // The PC build's saves (other rules): never come down, never planned.
        cloud.put("%WinAppDataLocal%Impact/Saved/SaveGames/S0_0.sav", "pc slot")
        cloud.put("%GameInstall%Impact/Saved/SaveGames/Global.sav", "pc global")
        let (r, plan) = try await sync(.metro, Self.metroRules, cloud, .downloadOnly).run()
        XCTAssertEqual(Set(r.downloaded), [Self.metroPrefix + "S0PlayerSettings.sav", Self.metroPrefix + "Global.sav",
                                           Self.metroPrefix + "S0_0.sav"])
        XCTAssertEqual(plan.actions.count, 3)
        XCTAssertFalse(cloud.downloads.contains { !$0.hasPrefix(Self.metroPrefix) })
        XCTAssertEqual(names(metroDir), ["Global.sav", "S0PlayerSettings.sav", "S0_0.sav"])
        XCTAssertEqual(names(androidFiles), ["UnrealGame"])
        XCTAssertEqual(names(androidFiles.appendingPathComponent("UnrealGame")), ["Impact"])
        XCTAssertEqual(read(metroDir.appendingPathComponent("S0PlayerSettings.sav")), "settings")
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
    }

    func testSuperhotFirstSyncDownloadOnly() async throws {
        let cloud = FakeCloud()
        cloud.put(Self.shPrefix + "VRsuper.hot", "pc progress")
        let (r, _) = try await sync(.superhot, [Self.superhotRule], cloud, .downloadOnly).run()
        XCTAssertEqual(r.downloaded, [Self.shPrefix + "VRsuper.hot"])
        XCTAssertEqual(names(androidFiles), ["files"])
        XCTAssertEqual(names(shDir), ["VRsuper.hot"])
        XCTAssertEqual(read(shDir.appendingPathComponent("VRsuper.hot")), "pc progress")
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
    }

    func testSuperhotTwoWayBaselineThenUpload() async throws {
        let cloud = FakeCloud()
        try write(shDir.appendingPathComponent("VRsuper.hot"), "headset")
        try write(shDir.appendingPathComponent("VRsuper.hot.bak"), "game's backup")
        var (r, _) = try await sync(.superhot, [Self.superhotRule], cloud, .twoWay).run()
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
        XCTAssertEqual(r.held, [Self.shPrefix + "VRsuper.hot"])
        try write(shDir.appendingPathComponent("VRsuper.hot"), "played")
        (r, _) = try await sync(.superhot, [Self.superhotRule], cloud, .twoWay).run()
        XCTAssertEqual(r.uploaded, ["%WinAppDataLocalLow%SUPERHOT_Team/SUPERHOT_VR/VRsuper.hot"])
        XCTAssertEqual(cloud.uploadBatches, [["%WinAppDataLocalLow%SUPERHOT_Team/SUPERHOT_VR/VRsuper.hot"]])
        XCTAssertEqual(cloud.text("%WinAppDataLocalLow%SUPERHOT_Team/SUPERHOT_VR/VRsuper.hot"), "played")
        XCTAssertEqual(cloud.count, 1)
    }

    func testMetroTwoWayBaselineThenUpload() async throws {
        let cloud = FakeCloud()
        cloud.put("%WinAppDataLocal%Impact/Saved/SaveGames/S0PlayerSettings.sav", "pc")
        try write(metroDir.appendingPathComponent("S0PlayerSettings.sav"), "headset")
        var (r, _) = try await sync(.metro, Self.metroRules, cloud, .twoWay).run()
        XCTAssertTrue(cloud.uploadBatches.isEmpty)
        XCTAssertEqual(r.held, [Self.metroPrefix + "S0PlayerSettings.sav"])
        try write(metroDir.appendingPathComponent("S0PlayerSettings.sav"), "changed")
        (r, _) = try await sync(.metro, Self.metroRules, cloud, .twoWay).run()
        let name = "%AndroidExternalData%Android/data/com.vertigogames.ImpactDevelopment/files/UnrealGame/Impact/Impact/Saved/SaveGames/S0PlayerSettings.sav"
        XCTAssertEqual(r.uploaded, [name])
        XCTAssertEqual(cloud.uploadBatches, [[name]])
        XCTAssertEqual(cloud.text(name), "changed")
        // The PC build's file is untouched and nothing came down from it.
        XCTAssertEqual(cloud.text("%WinAppDataLocal%Impact/Saved/SaveGames/S0PlayerSettings.sav"), "pc")
        XCTAssertTrue(cloud.downloads.isEmpty)
        // State keys stay lowercased.
        XCTAssertEqual(Array(CloudSyncState.load(stateDir.appendingPathComponent("state.json")).files.keys), [name.lowercased()])
    }
}
