import XCTest
@testable import HubCore

final class LogParsingTests: XCTestCase {
    func testBuildSteps() {
        XCTAssertEqual(BuildLog.step(in: "[1/5] runtime + guest translations (hub)…"),
                       BuildStep(index: 1, total: 5, title: "runtime + guest translations (hub)…"))
        XCTAssertEqual(BuildLog.step(in: "  [3/5] building for device 0000-XYZ…")?.index, 3)
        XCTAssertEqual(BuildLog.step(in: "[4/5] installing…")?.title, "installing…")
        XCTAssertNil(BuildLog.step(in: "[perf] gpu time over 90 frames"))
        XCTAssertNil(BuildLog.step(in: "[6/5] nonsense"))
        XCTAssertNil(BuildLog.step(in: "x [2/5] not at the start"))
    }

    func testErrors() {
        XCTAssertTrue(BuildLog.isError("!! no physical Vision Pro — pair it in Xcode"))
        XCTAssertTrue(BuildLog.isError("/x/y.swift:3:1: error: cannot find 'foo'"))
        XCTAssertTrue(BuildLog.isError("** BUILD FAILED **"))
        XCTAssertFalse(BuildLog.isError("[2/5] project…"))
    }

    func testGPUTime() {
        let line = "  [perf] gpu time over 45 frames: 11.52 ms avg / 19.40 ms worst per frame (union of the guest's Metal command buffers; KL_GPU_TIME)"
        XCTAssertEqual(LogParser.parse(line), .gpuTime(frames: 45, avgMs: 11.52, worstMs: 19.40))
    }

    func testPipelineStall() {
        let line = "  [vk] pipeline stall: graphics batch of 12 took 48 ms (stalls so far: 7, 310 ms total)"
        XCTAssertEqual(LogParser.parse(line), .pipelineStall(ms: 48, count: 7, totalMs: 310))
        XCTAssertEqual(LogParser.parse("  [vk] pipeline stall: compute batch of 1 took 5 ms"),
                       .pipelineStall(ms: 5, count: nil, totalMs: nil))
    }

    func testSessionLine() {
        let line = "[session] alyx 12m05s FINAL (quit): guest 44.9 fps avg, 1% low 38.2, 5% low 41.0, "
            + "5s min/max 40.0/45.1, median frame 22.3 ms; play 11m50s, loading 0m15s; display 90.0 Hz, "
            + "reprojected 123 of 4567 (3%) compositor frames; peak footprint 4600 MB; build 1.0 (42)"
        guard case .session(let s)? = LogParser.parse(line) else { return XCTFail("not a session line") }
        XCTAssertEqual(s.target, "alyx")
        XCTAssertEqual(s.fpsAvg, 44.9)
        XCTAssertEqual(s.fps1Low, 38.2)
        XCTAssertEqual(s.fps5Low, 41.0)
        XCTAssertEqual(s.frameMsP50, 22.3)
        XCTAssertEqual(s.displayHz, 90.0)
        XCTAssertEqual(s.peakFootprintMB, 4600)
        XCTAssertTrue(s.final)
    }

    func testSessionLineWithoutFrames() {
        let line = "[session] superhot 0m10s: guest - fps avg, 1% low -, 5% low -, 5s min/max -/-, median frame - ms; "
            + "play 0m00s, loading 0m10s; display - Hz, reprojected 0 compositor frames; peak footprint 900 MB; build x"
        guard case .session(let s)? = LogParser.parse(line) else { return XCTFail("not a session line") }
        XCTAssertNil(s.fpsAvg)
        XCTAssertEqual(s.peakFootprintMB, 900)
        XCTAssertFalse(s.final)
    }

    func testFoveateAB() {
        let line = "[mvk-fov] A/B so far: foveated 9.80 GPU ms/frame at 45.0 fps | full rate 11.20 GPU ms/frame at 45.0 fps | -12.5% GPU time"
        XCTAssertEqual(LogParser.parse(line), .foveateAB(foveatedMs: 9.8, fullMs: 11.2, deltaPercent: -12.5))
    }

    func testLiveStats() {
        var s = LiveStats()
        s.ingest("[perf] gpu time over 45 frames: 10.00 ms avg / 12.00 ms worst per frame")
        s.ingest("[perf] gpu time over 45 frames: 12.00 ms avg / 14.00 ms worst per frame")
        s.ingest("  [vk] pipeline stall: graphics batch of 3 took 20 ms")
        s.ingest("  [vk] pipeline stall: graphics batch of 3 took 30 ms")
        s.ingest("!! something broke")
        s.ingest("plain line")
        XCTAssertEqual(s.lines, 6)
        XCTAssertEqual(s.errors, 1)
        XCTAssertEqual(s.gpuLastMs, 12)
        XCTAssertEqual(s.gpuWorstMs, 14)
        XCTAssertEqual(s.gpuAvgMs, 11)
        XCTAssertEqual(s.stalls, 2)
        XCTAssertEqual(s.stallMsTotal, 50)
        for _ in 0..<(LiveStats.historyLimit + 10) { s.ingest("[perf] gpu time over 1 frames: 1.00 ms avg") }
        XCTAssertEqual(s.gpuHistory.count, LiveStats.historyLimit)
    }

    func testFilters() {
        XCTAssertTrue(LogFilter.matches("[perf] gpu time", category: .perf, search: ""))
        XCTAssertFalse(LogFilter.matches("[vk] x", category: .perf, search: ""))
        XCTAssertTrue(LogFilter.matches("[vk] pipeline stall", category: .vulkan, search: "STALL"))
        XCTAssertFalse(LogFilter.matches("[vk] pipeline stall", category: .all, search: "gpu"))
        XCTAssertTrue(LogFilter.matches("!! oops", category: .errors, search: ""))
    }

    func testLineBuffer() {
        let b = LineBuffer()
        XCTAssertEqual(b.append(Data("one\ntw".utf8)), ["one"])
        XCTAssertEqual(b.append(Data("o\r\nthree\rfour".utf8)), ["two", "three"])
        XCTAssertEqual(b.flush(), ["four"])
        XCTAssertEqual(b.flush(), [])
    }
}

final class SessionDecodingTests: XCTestCase {
    let line1 = #"{"build":"1.0 (7) abc","compositorFrames":54000,"displayHz":90,"durationS":620.5,"end":"2026-10-11T18:10:20Z","endReason":"quit","final":true,"fps1Low":38.2,"fps5Low":41,"fpsAvg":44.9,"fpsMax5s":45.1,"fpsMin5s":40,"frameMsP50":22.3,"guestFrames":26000,"id":"A1","loadingS":15,"peakFootprintMB":4600,"playS":600,"reprojectedFrames":27000,"start":"2026-10-11T18:00:00Z","target":"alyx","v":1}"#
    let checkpoint = #"{"id":"B2","target":"superhot","start":"2026-10-11T19:00:00Z","end":"2026-10-11T19:00:30Z","final":false,"endReason":"","fpsAvg":70,"compositorFrames":0,"reprojectedFrames":0,"peakFootprintMB":900}"#
    let checkpointLater = #"{"id":"B2","target":"superhot","start":"2026-10-11T19:00:00Z","end":"2026-10-11T19:01:00Z","final":true,"endReason":"background","fpsAvg":72,"compositorFrames":100,"reprojectedFrames":10,"peakFootprintMB":950}"#

    func testDecodesFullRecord() throws {
        let rs = SessionDecoding.decode(jsonl: line1 + "\n")
        XCTAssertEqual(rs.count, 1)
        let r = try XCTUnwrap(rs.first)
        XCTAssertEqual(r.target, "alyx")
        XCTAssertEqual(r.fpsAvg, 44.9)
        XCTAssertEqual(r.peakFootprintMB, 4600)
        XCTAssertEqual(r.reprojectedShare ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertTrue(r.endedCleanly)
        XCTAssertEqual(r.start, ISO8601DateFormatter().date(from: "2026-10-11T18:00:00Z"))
    }

    func testSkipsBadLinesAndKeepsLastCheckpoint() {
        let text = [line1, "{not json", checkpoint, "", checkpointLater, #"{"id":"x"}"#].joined(separator: "\n")
        let rs = SessionDecoding.decode(jsonl: text)
        XCTAssertEqual(rs.map(\.id), ["A1", "B2"])
        XCTAssertEqual(rs[1].fpsAvg, 72)
        XCTAssertEqual(rs[1].endReason, "background")
        XCTAssertNil(rs[1].frameMsP50)
    }

    func testFractionalDates() {
        let l = #"{"id":"F","target":"alyx","start":"2026-10-11T18:00:00.250Z"}"#
        XCTAssertEqual(SessionDecoding.decode(jsonl: l).count, 1)
    }

    func testLoadDirectorySortsByStart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hubcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try (checkpointLater + "\n").write(to: dir.appendingPathComponent("superhot.jsonl"), atomically: true, encoding: .utf8)
        try (line1 + "\n").write(to: dir.appendingPathComponent("alyx.jsonl"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionDecoding.load(directory: dir).map(\.id), ["A1", "B2"])
    }

    func testDeviceFileListing() {
        let json = #"{"info":{"outcome":"success"},"result":{"files":[{"name":"alyx.jsonl","path":"Library/Application Support/sessions/alyx.jsonl"},{"name":"superhot.jsonl"},{"name":".tmp.jsonl"},{"name":"other.txt"}]}}"#
        XCTAssertEqual(DeviceFileListing.jsonlNames(in: Data(json.utf8)), ["alyx.jsonl", "superhot.jsonl"])
    }
}

final class DeviceAndCatalogTests: XCTestCase {
    func testParseDevices() {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"AAA","deviceProperties":{"name":"iPhone"},"hardwareProperties":{"platform":"iOS","reality":"physical","marketingName":"iPhone 16"},"connectionProperties":{"tunnelState":"connected"}},
          {"identifier":"BBB","deviceProperties":{"name":"Vision Pro"},"hardwareProperties":{"platform":"visionOS","reality":"physical","marketingName":"Apple Vision Pro"},"connectionProperties":{"tunnelState":"disconnected"}},
          {"identifier":"CCC","deviceProperties":{"name":"Vision Pro 2"},"hardwareProperties":{"platform":"visionOS","reality":"physical"},"connectionProperties":{"tunnelState":"connected"}}
        ]}}
        """#
        let ds = DeviceCtl.parseDevices(Data(json.utf8))
        XCTAssertEqual(ds.map(\.id), ["AAA", "BBB", "CCC"])
        XCTAssertEqual(DeviceCtl.pick(ds, preferred: nil)?.id, "CCC")
        XCTAssertEqual(DeviceCtl.pick(ds, preferred: "BBB")?.id, "BBB")
        XCTAssertEqual(DeviceCtl.pick(ds, preferred: "ZZZ")?.id, "CCC")
    }

    func testLaunchArgs() {
        let a = DeviceCtl.launchArgs(device: "D", bundle: "com.example.hub", environment: ["KL_B": "2", "KL_A": "1"], console: true)
        XCTAssertEqual(a, ["device", "process", "launch", "--device", "D", "--terminate-existing", "--console",
                           "--environment-variables", #"{"KL_A":"1","KL_B":"2"}"#, "com.example.hub"])
    }

    func testLaunchOptions() {
        var o = LaunchOptions()
        o.game = "alyx"
        o.msaa = .x4
        o.pace = .on
        o.abSeconds = 20
        o.extra = "# comment\nKL_HUD=0\nbad line\nKL_X = 3"
        o.hud = true
        let env = o.environment()
        XCTAssertEqual(env["KL_HUB_GAME"], "alyx")
        XCTAssertEqual(env["KL_ALYX_MSAA"], "4")
        XCTAssertEqual(env["KL_GUEST_PACE_HZ"], "45")
        XCTAssertNil(env["KL_FOVEATE"], "Alyx foveates by default; no override needed for the A/B")
        XCTAssertEqual(env["KL_FOVEATE_AB"], "20")
        XCTAssertEqual(env["KL_GPU_TIME"], "1")
        XCTAssertEqual(env["KL_HUD"], "0", "extra lines win over presets")
        XCTAssertEqual(env["KL_X"], "3")
    }

    func testLaunchOptionsDefaultsSendNoOverrides() {
        let env = LaunchOptions().environment()
        XCTAssertNil(env["KL_ALYX_MSAA"])
        XCTAssertNil(env["KL_FOVEATE"])
        XCTAssertNil(env["KL_GUEST_PACE_HZ"])
        XCTAssertNil(env["KL_FOVEATE_AB"])
        XCTAssertEqual(LaunchOptions.hubDefaults(game: "alyx"), .init(msaa: 4, foveated: true, pace45: true))
    }

    func testLaunchOptionsForcedOff() {
        var o = LaunchOptions()
        o.foveation = .off
        o.pace = .off
        o.abSeconds = 10
        let env = o.environment()
        XCTAssertEqual(env["KL_FOVEATE"], "0")
        XCTAssertEqual(env["KL_GUEST_PACE_HZ"], "0")
        XCTAssertNil(env["KL_FOVEATE_AB"], "no A/B with foveation forced off")
        o.game = "superhot"; o.foveation = .hubDefault
        XCTAssertEqual(o.environment()["KL_FOVEATE"], "1", "A/B on a game that doesn't foveate by default")
    }

    func testLaunchOptionsDecodesOldFormat() throws {
        let old = #"{"game":"alyx","msaa":2,"foveated":true,"pace45":true,"hud":true,"gpuTime":false,"abTest":false,"abSeconds":10,"extra":"KL_A=1"}"#
        let o = try JSONDecoder().decode(LaunchOptions.self, from: Data(old.utf8))
        XCTAssertEqual(o.msaa, .x2)
        XCTAssertEqual(o.foveation, .hubDefault)
        XCTAssertEqual(o.abSeconds, 0)
        XCTAssertTrue(o.hud)
        XCTAssertFalse(o.gpuTime)
        XCTAssertEqual(o.extra, "KL_A=1")
        var n = LaunchOptions(); n.foveation = .on; n.abSeconds = 12
        XCTAssertEqual(try JSONDecoder().decode(LaunchOptions.self, from: JSONEncoder().encode(n)), n)
    }

    func testTargetVarsAndAPKVersion() {
        let vars = TargetVars.parse("KLT_LIBS='libmain libunity'\nKLT_TREE=superhot\nexport KLT_APK=\"superhot.apk\"\n# x=y\n")
        XCTAssertEqual(vars["KLT_LIBS"], "libmain libunity")
        XCTAssertEqual(vars["KLT_TREE"], "superhot")
        XCTAssertEqual(vars["KLT_APK"], "superhot.apk")
        XCTAssertNil(vars["# x"])
        let yml = "version: 3.0.3\nsdkInfo:\n  minSdkVersion: 23\nversionInfo:\n  versionCode: 1598\n  versionName: 1.40.4_5283\n"
        XCTAssertEqual(APKVersion.parse(apktoolYML: yml), APKVersion(name: "1.40.4_5283", code: 1598))
        XCTAssertEqual(APKVersion.parse(apktoolYML: yml)?.description, "1.40.4_5283 (1598)")
        XCTAssertNil(APKVersion.parse(apktoolYML: "nothing: here"))
    }

    func testCatalog() {
        XCTAssertEqual(Catalog.entry("superhot")?.apkStores, [.steam, .meta])
        XCTAssertEqual(Catalog.entry("alyx")?.apkStores, [])
        XCTAssertEqual(Catalog.entry("beatsaber")?.stores, [.meta])
    }

    func testToolchainHelpers() {
        XCTAssertEqual(Toolchain.teamID(fromSubject: "subject=UID=X, CN=Apple Development: A B (XYZ), OU=AB12CD34EF, O=A B, C=ES"), "AB12CD34EF")
        XCTAssertEqual(Toolchain.teamID(fromSubject: "OU = ZZ99YY88XX"), "ZZ99YY88XX")
        XCTAssertEqual(Toolchain.visionOSSDK(inShowSDKs: "visionOS 27.0   -sdk xros27.0\nSimulator - visionOS 27.0 -sdk xrsimulator27.0"), "27.0")
        XCTAssertNil(Toolchain.visionOSSDK(inShowSDKs: "macOS 27.0 -sdk macosx27.0"))
        XCTAssertEqual(Toolchain.environmentDefaults(["KLEPTON_TEAM": "T", "KLEPTON_DEVICE": ""]), ["team": "T"])
    }

    func testPlaceholderBundleIDs() {
        for id in ["", "  ", "com.example.avpgamehub", "com.yourname.avpgamehub", "COM.YourName.hub"] {
            XCTAssertTrue(Toolchain.isPlaceholderBundleID(id), id)
        }
        for id in ["com.jdoe.avpgamehub", "dev.klepton.hub", "com.examples.hub"] {
            XCTAssertFalse(Toolchain.isPlaceholderBundleID(id), id)
        }
    }

    func testParseHubCheck() {
        let out = "alyx\tHalf-Life: Alyx\tmissing\tno build/alyx_images.txt\trun --gap\n"
            + "ktane\tKeep Talking\tok\t\t\n" + "metro\tMetro Awakening\tskip\tKLEPTON_HUB_GAMES\t\n" + "garbage line\n"
        let rows = Toolchain.parseHubCheck(out)
        XCTAssertEqual(rows.map(\.game), ["alyx", "ktane", "metro"])
        XCTAssertEqual(rows.map(\.state), [.missing, .ok, .skip])
        XCTAssertEqual(rows[0].missing, "no build/alyx_images.txt")
        XCTAssertEqual(rows[0].hint, "run --gap")
        XCTAssertEqual(rows[1].display, "Keep Talking")
        XCTAssertEqual(rows[1].hint, "")
    }

    func testProcessRunnerCapture() async {
        let r = await ProcessRunner.capture(.bash("echo one; echo two >&2; exit 3"))
        XCTAssertEqual(r.status, 3)
        XCTAssertTrue(r.output.contains("one") && r.output.contains("two"))
    }

    func testProcessRunnerCancel() async {
        let runner = ProcessRunner()
        let exp = expectation(description: "exit")
        try? runner.start(.bash("sleep 30 & wait"), onLine: { _ in }, onExit: { status in
            XCTAssertNotEqual(status, 0)
            exp.fulfill()
        })
        try? await Task.sleep(nanoseconds: 300_000_000)
        runner.cancel()
        await fulfillment(of: [exp], timeout: 10)
    }
}

final class ANSITests: XCTestCase {
    func testStrip() {
        XCTAssertEqual(ANSI.strip("\u{1B}[1;32mOK\u{1B}[0m done"), "OK done")
        XCTAssertEqual(ANSI.strip("plain"), "plain")
    }
}

final class MetaToolTests: XCTestCase {
    func testCandidateNames() {
        XCTAssertTrue(MetaToolFiles.isCandidateName("ovr-platform-util"))
        XCTAssertTrue(MetaToolFiles.isCandidateName("ovr-platform-util (1)"))
        XCTAssertTrue(MetaToolFiles.isCandidateName("ovr-platform-util.zip"))
        XCTAssertTrue(MetaToolFiles.isCandidateName("ovr-platform-util-mac.zip"))
        XCTAssertFalse(MetaToolFiles.isCandidateName("ovr-platform-util.crdownload"))
        XCTAssertFalse(MetaToolFiles.isCandidateName("ovr-platform-util.exe"))
        XCTAssertFalse(MetaToolFiles.isCandidateName("something.zip"))
    }

    func testArm64Slice() {
        // thin arm64: CF FA ED FE, cputype 0x0100000C little-endian
        XCTAssertEqual(MetaToolFiles.hasArm64Slice(header: Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])), true)
        // thin x86_64: cputype 0x01000007
        XCTAssertEqual(MetaToolFiles.hasArm64Slice(header: Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])), false)
        // fat with x86_64 then arm64
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        fat += Data([0x01, 0, 0, 0x07]) + Data(count: 16)
        fat += Data([0x01, 0, 0, 0x0C]) + Data(count: 16)
        XCTAssertEqual(MetaToolFiles.hasArm64Slice(header: fat), true)
        XCTAssertNil(MetaToolFiles.hasArm64Slice(header: Data("#!/bin/sh\n".utf8)))
    }

    func testToolInsideZipFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("mac/bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("__MACOSX/ovr-platform-util").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mac/bin/ovr-platform-util").path, contents: Data())
        XCTAssertEqual(MetaToolFiles.toolInside(dir)?.path.hasSuffix("mac/bin/ovr-platform-util"), true)
    }

    func testPrompts() {
        XCTAssertEqual(MetaPrompt.detect(in: "Enter Meta Quest user credentials\n\nEmail: "), .email)
        XCTAssertEqual(MetaPrompt.detect(in: "Password <hidden>: "), .password)
        XCTAssertEqual(MetaPrompt.detect(in: "Logging in\nTwo-factor authentication required.\n\nEnter two-factor authentication code: "), .code)
        XCTAssertEqual(MetaPrompt.detect(in: "A passcode has been sent to your email to confirm this login.\nEnter 6 Digit Code: "), .code)
        XCTAssertEqual(MetaPrompt.detect(in: "Enter verification code:"), .code)
        XCTAssertNil(MetaPrompt.detect(in: "Logging in"))
        XCTAssertNil(MetaPrompt.detect(in: "Emai"))
        XCTAssertTrue(MetaPrompt.isValidCode("123456"))
        XCTAssertTrue(MetaPrompt.isValidCode("123 456"))
        XCTAssertTrue(MetaPrompt.isValidCode("12345678"))
        XCTAssertFalse(MetaPrompt.isValidCode("12345"))
        XCTAssertFalse(MetaPrompt.isValidCode("123456789"))
        XCTAssertFalse(MetaPrompt.isValidCode("12a456"))
        XCTAssertEqual(MetaPrompt.errorTail("Logging in\nEnter two-factor authentication code: \nError: Invalid code\n"), "Logging in Error: Invalid code")
    }

    func testLocalConfigParse() {
        let c = Toolchain.parseConfig("# comment\nKLEPTON_TEAM=ABCDE12345\nexport KLEPTON_DEVICE=\"0000-1111\"\n\nKLEPTON_BUNDLE_ID='com.example.hub'\n")
        XCTAssertEqual(c, ["KLEPTON_TEAM": "ABCDE12345", "KLEPTON_DEVICE": "0000-1111", "KLEPTON_BUNDLE_ID": "com.example.hub"])
        XCTAssertEqual(Toolchain.environmentDefaults(c), ["team": "ABCDE12345", "deviceID": "0000-1111", "bundleID": "com.example.hub"])
    }

    func testPrivacyMask() {
        XCTAssertEqual(Privacy.mask("jdoe1234"), "jd•••")
        XCTAssertEqual(Privacy.redact("logged on as JDoe1234 (76561198000000000)", secrets: ["jdoe1234", "76561198000000000"]),
                       "logged on as JD••• (76•••)")
        XCTAssertEqual(Privacy.redact("ab", secrets: ["ab"]), "ab")
    }
}
