import XCTest
@testable import SaveKit

final class SaveTableTests: XCTestCase {
    func testUnityKeepsSavesAndPrefsButNotGameData() {
        let a = "Documents/games/superhot/android-files"
        let listing = [
            RemoteFile(path: "\(a)/files", size: 96, isDirectory: true),
            RemoteFile(path: "\(a)/files/save.dat", size: 1200),
            RemoteFile(path: "\(a)/files/Settings/options.json", size: 300),
            RemoteFile(path: "\(a)/files/Unity/abc/Analytics/values", size: 50),
            RemoteFile(path: "\(a)/files/il2cpp/Metadata/global-metadata.dat", size: 9000),
            RemoteFile(path: "\(a)/shared_prefs/com.superhot.v2.playerprefs.xml", size: 800),
            RemoteFile(path: "\(a)/cloudstorage/slot1", size: 64),
            RemoteFile(path: "\(a)/obb/main.1.com.superhot.obb", size: 900_000_000),
            RemoteFile(path: "\(a)/cache/vk.foz", size: 4000),
            RemoteFile(path: "\(a)/files/pipeline.foz", size: 4000),
            RemoteFile(path: "\(a)/files/addressables.bundle", size: 4000),
            RemoteFile(path: "\(a)/files/link", size: 4, isSymbolicLink: true),
            RemoteFile(path: "Documents/games/superhot/steam/shvr.apk", size: 600_000_000),
            RemoteFile(path: "Documents/games/superhot/steam/vrpreferences.json", size: 169),
            RemoteFile(path: "Documents/games/superhot/superhot.apk", size: 600_000_000),
            RemoteFile(path: "Documents/steamdepot-token.json", size: 100),
        ]
        XCTAssertEqual(SaveTable.saveFiles("superhot", in: listing).map(\.path), [
            "\(a)/cloudstorage/slot1",
            "\(a)/files/Settings/options.json",
            "\(a)/files/save.dat",
            "\(a)/shared_prefs/com.superhot.v2.playerprefs.xml",
        ])
    }

    func testBeatSaberSkipsCustomSongs() {
        let f = "Documents/games/beatsaber/android-files/files"
        let kept = SaveTable.saveFiles("beatsaber", in: [
            RemoteFile(path: "\(f)/PlayerData.dat", size: 5000),
            RemoteFile(path: "\(f)/CustomLevels/song/info.dat", size: 5000),
        ]).map(\.path)
        XCTAssertEqual(kept, ["\(f)/PlayerData.dat"])
    }

    func testAlyxOnlySaveAndCfg() {
        let g = "Library/Application Support/Klepton/userdata/alyx/gameroot"
        let kept = SaveTable.saveFiles("alyx", in: [
            RemoteFile(path: "\(g)/hlvr/save/s1.sav", size: 4_000_000),
            RemoteFile(path: "\(g)/hlvr/save/s1.hl1", size: 100),
            RemoteFile(path: "\(g)/hlvr/cfg/machine_convars.vcfg", size: 2000),
            RemoteFile(path: "\(g)/hlvr/gameinfo.gi", size: 2000),
            RemoteFile(path: "\(g)/hlvr/shadercache/x.vcs", size: 2000),
            RemoteFile(path: "\(g)/hlvr/savex/other", size: 1),
            RemoteFile(path: "\(g)/console.log", size: 2000),
            RemoteFile(path: "Documents/games/alyx/android-files/alyx/game/hlvr/pak01_000.vpk", size: 100),
        ]).map(\.path)
        XCTAssertEqual(kept, ["\(g)/hlvr/cfg/machine_convars.vcfg", "\(g)/hlvr/save/s1.hl1", "\(g)/hlvr/save/s1.sav"])
    }

    func testMetroSaveGamesAndConfigOnly() {
        let u = "Documents/games/metro/android-files/UnrealGame/Impact/Impact/Saved"
        let kept = SaveTable.saveFiles("metro", in: [
            RemoteFile(path: "\(u)/SaveGames/Slot0.sav", size: 30000),
            RemoteFile(path: "\(u)/Config/Android/GameUserSettings.ini", size: 300),
            RemoteFile(path: "\(u)/Logs/Impact.log", size: 300),
            RemoteFile(path: "\(u)/Impact_arm64.upipelinecache", size: 300),
            RemoteFile(path: "Documents/games/metro/android-files/UnrealGame/Impact/Impact/Content/Paks/x.pak", size: 300),
            RemoteFile(path: "Documents/games/metro/android-files/Android/obb/com.vertigogames.ImpactDevelopment/main.944116.com.vertigogames.ImpactDevelopment.obb", size: 3_000_000_000),
        ]).map(\.path)
        XCTAssertEqual(kept, ["\(u)/Config/Android/GameUserSettings.ini", "\(u)/SaveGames/Slot0.sav"])
    }

    func testRE4SaveGamesAndConfigOnly() {
        let u = "Documents/games/re4/android-files/UE4Game/VR4/VR4/Saved"
        let kept = SaveTable.saveFiles("re4", in: [
            RemoteFile(path: "\(u)/SaveGames/System.sav", size: 3000),
            RemoteFile(path: "\(u)/Config/Android/GameUserSettings.ini", size: 300),
            RemoteFile(path: "\(u)/Logs/VR4.log", size: 300),
            RemoteFile(path: "Documents/games/re4/android-files/UE4Game/VR4/Engine/Saved/Config/Android/Engine.ini", size: 300),
            RemoteFile(path: "Documents/games/re4/android-files/Android/obb/com.Armature.VR4/main.203.com.Armature.VR4.obb", size: 4_278_854_071),
        ]).map(\.path)
        XCTAssertEqual(kept, ["\(u)/Config/Android/GameUserSettings.ini", "\(u)/SaveGames/System.sav"])
    }

    func testHugeFileAndUnsafePathsAreRejected() {
        let f = "Documents/games/ktane/android-files/files"
        XCTAssertFalse(SaveTable.isRestorable("ktane", path: "\(f)/huge.dat", size: SaveTable.maxFileBytes + 1))
        XCTAssertFalse(SaveTable.isRestorable("ktane", path: "\(f)/../../meta/KTANE.apk", size: 10))
        XCTAssertFalse(SaveTable.isRestorable("ktane", path: "/\(f)/x", size: 10))
        XCTAssertFalse(SaveTable.isRestorable("ktane", path: "Documents/games/ieytd/android-files/files/x", size: 10))
        XCTAssertFalse(SaveTable.isRestorable("nope", path: "\(f)/x", size: 10))
        XCTAssertTrue(SaveTable.isRestorable("ktane", path: "\(f)/x", size: 10))
    }
}

final class SaveBackupStoreTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("savestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    func make(_ store: SaveBackupStore, _ files: [String: String], at date: Date, reason: String = "manual") throws -> SaveBackupStore.Finish {
        let staging = try store.begin("ktane", date: date)
        for (p, s) in files {
            let u = staging.appendingPathComponent("files").appendingPathComponent(p)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: u)
        }
        return try store.finish(staging: staging, target: "ktane", bundle: "com.example.Hub", reason: reason,
                                paths: Array(files.keys), date: date)
    }

    func testManifestHashesAndSizes() throws {
        let store = SaveBackupStore(base: tmp)
        let p = "Documents/games/ktane/android-files/shared_prefs/prefs.xml"
        guard case .created(let b) = try make(store, [p: "abc"], at: Date(timeIntervalSince1970: 1_000)) else {
            return XCTFail("expected a new backup")
        }
        XCTAssertEqual(b.manifest.files, [.init(path: p, size: 3,
                                                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")])
        XCTAssertEqual(b.manifest.totalBytes, 3)
        XCTAssertEqual(b.directory.lastPathComponent, "1970-01-01T00-16-40Z")
        XCTAssertEqual(store.list("ktane").map(\.directory.lastPathComponent), [b.directory.lastPathComponent])
        XCTAssertEqual(store.verify(b), [])
        try Data("tampered".utf8).write(to: b.localURL(p))
        XCTAssertEqual(store.verify(b), [p])
    }

    func testUnchangedIsNotStoredTwice() throws {
        let store = SaveBackupStore(base: tmp)
        try make(store, ["a/x": "1"], at: Date(timeIntervalSince1970: 1_000))
        guard case .unchanged = try make(store, ["a/x": "1"], at: Date(timeIntervalSince1970: 2_000)) else {
            return XCTFail("identical contents should not make a second backup")
        }
        guard case .created = try make(store, ["a/x": "2"], at: Date(timeIntervalSince1970: 3_000)) else {
            return XCTFail("changed contents make a new backup")
        }
        XCTAssertEqual(store.list("ktane").count, 2)
        // No staging directories are left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory("ktane").path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") })
    }

    func testRotationKeepsNewestAndProtected() throws {
        let store = SaveBackupStore(base: tmp)
        for i in 0..<5 { try make(store, ["a/x": "\(i)"], at: Date(timeIntervalSince1970: Double(1_000 * (i + 1)))) }
        let all = store.list("ktane")
        XCTAssertEqual(all.count, 5)
        let oldest = all.last!.directory
        let removed = store.rotate("ktane", keep: 2, protecting: [oldest])
        XCTAssertEqual(removed.count, 2)
        let left = store.list("ktane").map(\.directory)
        XCTAssertEqual(left, [all[0].directory, all[1].directory, oldest])
    }

    func testPartialBackupsAreIgnoredAndCleaned() throws {
        let store = SaveBackupStore(base: tmp)
        let staging = try store.begin("ktane", date: Date(timeIntervalSince1970: 500))
        XCTAssertTrue(store.list("ktane").isEmpty)
        _ = try store.begin("ktane", date: Date(timeIntervalSince1970: 600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}
