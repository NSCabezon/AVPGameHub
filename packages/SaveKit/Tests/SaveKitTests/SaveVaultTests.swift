import XCTest
@testable import SaveKit

final class SaveVaultTests: XCTestCase {
    var tmp: URL!
    var container: URL!
    var vault: SaveVault!
    let files = "Documents/games/ktane/android-files/files"
    let prefs = "Documents/games/ktane/android-files/shared_prefs"
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("savevault-\(UUID().uuidString)")
        container = tmp.appendingPathComponent("container", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        vault = SaveVault(root: tmp.appendingPathComponent("Partidas", isDirectory: true), bundle: "com.example.Hub")
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func write(_ path: String, _ s: String, in base: URL? = nil) throws {
        let u = (base ?? container).appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }
    func read(_ path: String) -> String? {
        (try? Data(contentsOf: container.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }
    func at(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }
    func manifest(_ stamp: String) throws -> SaveManifest {
        let u = vault.directory("ktane").appendingPathComponent(stamp).appendingPathComponent("manifest.json")
        return try SaveFormat.decoder().decode(SaveManifest.self, from: Data(contentsOf: u))
    }
    /// Replaces a vault item by its iCloud placeholder, as iCloud does before downloading it.
    func evict(_ item: URL) throws {
        try fm.moveItem(at: item, to: SaveVault.placeholderURL(for: item))
    }

    func testSnapshotNoSavesCreatedUnchanged() throws {
        XCTAssertEqual(try vault.snapshot(target: "ktane", containerRoot: container, device: "AVP", reason: "manual"), .noSaves)
        XCTAssertFalse(vault.hasLocalSaves(target: "ktane", containerRoot: container))
        // Only game data: still no saves, and no directory is written.
        try write("Documents/games/ktane/ktane.apk", "apk")
        XCTAssertEqual(try vault.snapshot(target: "ktane", containerRoot: container, device: "AVP", reason: "manual"), .noSaves)
        XCTAssertFalse(fm.fileExists(atPath: vault.directory("ktane").path))

        try write("\(files)/save.dat", "abc")
        try write("\(prefs)/prefs.xml", "<p/>")
        XCTAssertTrue(vault.hasLocalSaves(target: "ktane", containerRoot: container))
        let r = try vault.snapshot(target: "ktane", containerRoot: container, device: "AVP", reason: "auto", date: at(1_000))
        XCTAssertEqual(r, .created("1970-01-01T00-16-40Z"))
        let m = try manifest("1970-01-01T00-16-40Z")
        XCTAssertEqual(m.device, "AVP")
        XCTAssertEqual(m.reason, "auto")
        XCTAssertEqual(m.bundle, "com.example.Hub")
        XCTAssertEqual(m.files.map(\.path), ["\(files)/save.dat", "\(prefs)/prefs.xml"])
        XCTAssertEqual(m.files[0].sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // The Mac reader reads it too.
        XCTAssertEqual(SaveBackupStore(base: vault.root).list("ktane").map(\.manifest), [m])

        XCTAssertEqual(try vault.snapshot(target: "ktane", containerRoot: container, device: "AVP", reason: "auto", date: at(2_000)),
                       .unchanged("1970-01-01T00-16-40Z"))
        try write("\(files)/save.dat", "abd")
        XCTAssertEqual(try vault.snapshot(target: "ktane", containerRoot: container, device: "AVP", reason: "auto", date: at(3_000)),
                       .created("1970-01-01T00-50-00Z"))
        // No staging directory left behind.
        let names = try fm.contentsOfDirectory(atPath: vault.directory("ktane").path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".tmp-") })
        XCTAssertThrowsError(try vault.snapshot(target: "nope", containerRoot: container, device: nil, reason: "manual"))
    }

    func testSnapshotExcludes() throws {
        let small = SaveVault(root: vault.root, bundle: "b", maxFileBytes: 10)
        try write("\(files)/save.dat", "ok")
        try write("\(files)/cache/x.bin", "c")
        try write("\(files)/Caches/y.bin", "c")
        try write("\(files)/obb/main.obb", "o")
        try write("\(files)/game.apk", "a")
        try write("\(files)/big.dat", "0123456789ABC")
        try write("Documents/games/ktane/android-files/obb/main.1.obb", "o")
        try write("Documents/games/ktane/meta/token", "t")
        try fm.createSymbolicLink(at: container.appendingPathComponent("\(files)/link.dat"),
                                  withDestinationURL: container.appendingPathComponent("\(files)/save.dat"))
        XCTAssertEqual(try small.snapshot(target: "ktane", containerRoot: container, device: nil, reason: "manual", date: at(1_000)),
                       .created("1970-01-01T00-16-40Z"))
        XCTAssertEqual(try manifest("1970-01-01T00-16-40Z").files.map(\.path), ["\(files)/save.dat"])
    }

    func testListNewestFirstSkipsJunk() throws {
        try write("\(files)/save.dat", "1")
        _ = try vault.snapshot(target: "ktane", containerRoot: container, device: "A", reason: "manual", date: at(1_000))
        try write("\(files)/save.dat", "22")
        _ = try vault.snapshot(target: "ktane", containerRoot: container, device: "B", reason: "auto", date: at(3_000))
        try write("\(files)/save.dat", "333")
        _ = try vault.snapshot(target: "ktane", containerRoot: container, device: "C", reason: "all", date: at(2_000))
        // Junk: a staging dir, a partial Mac backup, a dir without manifest, a broken manifest.
        let d = vault.directory("ktane")
        try write(".tmp-x/manifest.json", "{}", in: d)
        try write("1970-01-01T01-00-00Z.partial/manifest.json", "{}", in: d)
        try fm.createDirectory(at: d.appendingPathComponent("1970-01-01T02-00-00Z"), withIntermediateDirectories: true)
        try write("1970-01-01T03-00-00Z/manifest.json", "not json", in: d)
        let l = vault.list(target: "ktane")
        XCTAssertEqual(l.map(\.device), ["B", "C", "A"])
        XCTAssertEqual(l.map(\.reason), ["auto", "all", "manual"])
        XCTAssertEqual(l.map(\.totalBytes), [2, 3, 1])
        XCTAssertEqual(l.map(\.fileCount), [1, 1, 1])
        XCTAssertTrue(l.allSatisfy(\.isDownloaded))
        XCTAssertEqual(l[0].date, at(3_000))
        XCTAssertEqual(vault.list(target: "superhot"), [])
    }

    func testRestoreMakesPreRestoreSnapshotAndOverwrites() throws {
        try write("\(files)/save.dat", "old")
        try write("\(prefs)/prefs.xml", "p1")
        guard case .created(let stamp) = try vault.snapshot(target: "ktane", containerRoot: container, device: "A",
                                                           reason: "manual", date: at(1_000)) else { return XCTFail() }
        try write("\(files)/save.dat", "new")
        try write("\(files)/extra.dat", "x")
        try fm.removeItem(at: container.appendingPathComponent(prefs))

        try vault.restore(target: "ktane", stamp: stamp, containerRoot: container, device: "A")
        XCTAssertEqual(read("\(files)/save.dat"), "old")
        XCTAssertEqual(read("\(prefs)/prefs.xml"), "p1")
        XCTAssertEqual(read("\(files)/extra.dat"), "x", "files not in the backup stay")
        let l = vault.list(target: "ktane")
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0].reason, "pre-restore")
        let pre = try manifest(l[0].stamp)
        XCTAssertEqual(pre.files.map(\.path), ["\(files)/extra.dat", "\(files)/save.dat"])
        // No leftovers of the copy-then-swap.
        let left = try fm.contentsOfDirectory(atPath: container.appendingPathComponent(files).path)
        XCTAssertEqual(left.sorted(), ["extra.dat", "save.dat"])
    }

    func testRestoreIntoEmptyContainerSkipsPreRestore() throws {
        try write("\(files)/save.dat", "old")
        guard case .created(let stamp) = try vault.snapshot(target: "ktane", containerRoot: container, device: nil,
                                                           reason: "manual", date: at(1_000)) else { return XCTFail() }
        let fresh = tmp.appendingPathComponent("fresh", isDirectory: true)
        try vault.restore(target: "ktane", stamp: stamp, containerRoot: fresh, device: nil)
        XCTAssertEqual(try String(contentsOf: fresh.appendingPathComponent("\(files)/save.dat"), encoding: .utf8), "old")
        XCTAssertEqual(vault.list(target: "ktane").count, 1)
    }

    func testRestoreRefusesShaMismatch() throws {
        try write("\(files)/save.dat", "old")
        guard case .created(let stamp) = try vault.snapshot(target: "ktane", containerRoot: container, device: nil,
                                                           reason: "manual", date: at(1_000)) else { return XCTFail() }
        try write("\(stamp)/files/\(files)/save.dat", "tampered", in: vault.directory("ktane"))
        try write("\(files)/save.dat", "current")
        XCTAssertThrowsError(try vault.restore(target: "ktane", stamp: stamp, containerRoot: container, device: nil)) {
            XCTAssertEqual($0 as? SaveVaultError, .corrupt(["\(files)/save.dat"]))
        }
        XCTAssertEqual(read("\(files)/save.dat"), "current")
        XCTAssertEqual(vault.list(target: "ktane").count, 1, "refused before the pre-restore snapshot")
    }

    func testRestoreRefusesUnsafePaths() throws {
        try write("\(files)/save.dat", "old")
        guard case .created(let stamp) = try vault.snapshot(target: "ktane", containerRoot: container, device: nil,
                                                           reason: "manual", date: at(1_000)) else { return XCTFail() }
        let d = vault.directory("ktane").appendingPathComponent(stamp)
        let original = try manifest(stamp)
        for bad in ["\(files)/../../../../../outside.dat", "Documents/games/ktane/ktane.apk", "Documents/steamdepot-token.json"] {
            var m = original
            m.files.append(.init(path: bad, size: 1, sha256: "x"))
            try SaveFormat.encoder().encode(m).write(to: d.appendingPathComponent("manifest.json"))
            XCTAssertThrowsError(try vault.restore(target: "ktane", stamp: stamp, containerRoot: container, device: nil)) {
                XCTAssertEqual($0 as? SaveVaultError, .unsafePaths([bad]))
            }
        }
        XCTAssertThrowsError(try vault.restore(target: "ktane", stamp: "../x", containerRoot: container, device: nil))
        XCTAssertThrowsError(try vault.restore(target: "ktane", stamp: "1999-01-01T00-00-00Z", containerRoot: container, device: nil)) {
            XCTAssertEqual($0 as? SaveVaultError, .noSuchBackup("1999-01-01T00-00-00Z"))
        }
    }

    func testPlaceholders() throws {
        try write("\(files)/save.dat", "old")
        try write("\(prefs)/prefs.xml", "p")
        guard case .created(let s1) = try vault.snapshot(target: "ktane", containerRoot: container, device: nil,
                                                        reason: "manual", date: at(1_000)) else { return XCTFail() }
        try write("\(files)/save.dat", "newer")
        guard case .created(let s2) = try vault.snapshot(target: "ktane", containerRoot: container, device: nil,
                                                        reason: "manual", date: at(2_000)) else { return XCTFail() }
        let d1 = vault.directory("ktane").appendingPathComponent(s1)
        let d2 = vault.directory("ktane").appendingPathComponent(s2)
        // s2: whole backup not downloaded (manifest is a placeholder). s1: one file not downloaded.
        try evict(d2.appendingPathComponent("manifest.json"))
        try evict(d1.appendingPathComponent("files/\(prefs)/prefs.xml"))

        let l = vault.list(target: "ktane")
        XCTAssertEqual(l.map(\.stamp), [s2, s1])
        XCTAssertEqual(l.map(\.isDownloaded), [false, false])
        XCTAssertEqual(l[0].date, at(2_000))
        XCTAssertEqual(l[1].fileCount, 2)
        XCTAssertEqual(vault.pendingDownloads(target: "ktane").map(\.path).sorted(),
                       [d1.appendingPathComponent("files/\(prefs)/prefs.xml").path,
                        d2.appendingPathComponent("manifest.json").path].sorted())
        XCTAssertEqual(vault.pendingDownloads(target: "ktane", stamp: s1).count, 1)

        XCTAssertThrowsError(try vault.restore(target: "ktane", stamp: s2, containerRoot: container, device: nil)) {
            XCTAssertEqual($0 as? SaveVaultError, .notDownloaded(["\(s2)/manifest.json"]))
        }
        XCTAssertThrowsError(try vault.restore(target: "ktane", stamp: s1, containerRoot: container, device: nil)) {
            XCTAssertEqual($0 as? SaveVaultError, .notDownloaded(["\(s1)/files/\(prefs)/prefs.xml"]))
        }
        XCTAssertEqual(read("\(files)/save.dat"), "newer")
        // A placeholder newest backup cannot be compared: a snapshot is made rather than skipped.
        guard case .created = try vault.snapshot(target: "ktane", containerRoot: container, device: nil,
                                                 reason: "manual", date: at(3_000)) else { return XCTFail() }
    }

    func testPruneKeepsTenAndNewest() throws {
        for i in 0..<13 {
            try write("\(files)/save.dat", "\(i)")
            let reason = i % 3 == 0 ? "pre-restore" : "auto"
            _ = try vault.snapshot(target: "ktane", containerRoot: container, device: nil, reason: reason,
                                   date: at(Double(1_000 * (i + 1))))
        }
        let all = vault.list(target: "ktane")
        XCTAssertEqual(all.count, 13)
        let removed = vault.prune(target: "ktane")
        XCTAssertEqual(removed, all.suffix(3).map(\.stamp))
        XCTAssertEqual(vault.list(target: "ktane").map(\.stamp), Array(all.prefix(10).map(\.stamp)))
        XCTAssertEqual(vault.prune(target: "ktane", keep: 0), Array(all[1..<10].map(\.stamp)))
        XCTAssertEqual(vault.list(target: "ktane").map(\.stamp), [all[0].stamp])
    }

    func testStagingRootKeepsVaultClean() throws {
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        let v = SaveVault(root: vault.root, bundle: "com.example.Hub", stagingRoot: staging)
        try write("\(files)/save.dat", "abc")
        let r = try v.snapshot(target: "ktane", containerRoot: container, device: nil, reason: "auto", date: at(1_000))
        XCTAssertEqual(r, .created("1970-01-01T00-16-40Z"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: v.directory("ktane").path), ["1970-01-01T00-16-40Z"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging.path), [])
        XCTAssertNotNil(SaveFormat.readBackup(v.directory("ktane").appendingPathComponent("1970-01-01T00-16-40Z"), target: "ktane"))
    }

    func testUnchangedSnapshotWithStagingRootWritesNothingInVault() throws {
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        let v = SaveVault(root: vault.root, bundle: "com.example.Hub", stagingRoot: staging)
        try write("\(files)/save.dat", "abc")
        _ = try v.snapshot(target: "ktane", containerRoot: container, device: nil, reason: "auto", date: at(1_000))
        let before = try fm.contentsOfDirectory(atPath: v.directory("ktane").path)
        XCTAssertEqual(try v.snapshot(target: "ktane", containerRoot: container, device: nil, reason: "auto", date: at(2_000)),
                       .unchanged("1970-01-01T00-16-40Z"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: v.directory("ktane").path), before)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging.path), [])
    }

    func testPruneProtectingKeepsProtectedOldest() throws {
        for i in 0..<5 {
            try write("\(files)/save.dat", "\(i)")
            _ = try vault.snapshot(target: "ktane", containerRoot: container, device: nil, reason: "auto", date: at(Double(1_000 * (i + 1))))
        }
        let all = vault.list(target: "ktane")
        let oldest = all.last!.stamp
        let removed = vault.prune(target: "ktane", keep: 2, protecting: [oldest])
        XCTAssertEqual(removed, [all[2].stamp, all[3].stamp])
        XCTAssertEqual(vault.list(target: "ktane").map(\.stamp), [all[0].stamp, all[1].stamp, oldest])
    }

    func testOldManifestDecodes() throws {
        let json = """
        {"bundle":"com.example.Hub","created":"2026-10-12T18:30:05Z","files":[
          {"path":"Documents/games/ktane/android-files/files/a","sha256":"00","size":3}],
         "reason":"manual","target":"ktane","version":1}
        """
        let m = try SaveFormat.decoder().decode(SaveManifest.self, from: Data(json.utf8))
        XCTAssertNil(m.device)
        XCTAssertEqual(m.reason, "manual")
        XCTAssertEqual(m.totalBytes, 3)
        // Written back with a device, it round-trips.
        var n = m; n.device = "AVP"
        XCTAssertEqual(try SaveFormat.decoder().decode(SaveManifest.self, from: SaveFormat.encoder().encode(n)), n)
    }

    func testStampParsing() {
        XCTAssertEqual(SaveFormat.date(fromStamp: "1970-01-01T00-16-40Z"), at(1_000))
        XCTAssertEqual(SaveFormat.date(fromStamp: "1970-01-01T00-16-40Z-2"), at(1_000))
        XCTAssertNil(SaveFormat.date(fromStamp: "nope"))
        XCTAssertEqual(SaveVault.itemURL(forPlaceholder: URL(fileURLWithPath: "/a/.b.json.icloud"))?.path, "/a/b.json")
        XCTAssertNil(SaveVault.itemURL(forPlaceholder: URL(fileURLWithPath: "/a/b.json")))
    }
}
