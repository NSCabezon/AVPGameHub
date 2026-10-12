import XCTest
@testable import HubCore

final class StreamCommandTests: XCTestCase {
    private let klepton = URL(fileURLWithPath: "/k/Klepton")

    private var alyx: StreamHostInfo { Catalog.entry("alyx")!.stream! }

    func testCatalogStreamRows() {
        XCTAssertEqual(Catalog.streamable.map(\.target), ["alyx", "metro"])
        XCTAssertEqual(alyx.availability, .ready)
        XCTAssertEqual(Catalog.entry("metro")?.stream?.availability, .ready)
        XCTAssertEqual(Catalog.entry("metro")?.stream?.bootTarget, "metro")
        XCTAssertNil(Catalog.entry("beatsaber")?.stream)
    }

    func testAlyxCommandDefaults() {
        let cmd = StreamLaunch.command(klepton: klepton, info: alyx, contentDir: "/c/game", macName: "Test Mac",
                                       tmpDir: "/t/x", options: StreamOptions())
        XCTAssertEqual(cmd.executable, "/k/Klepton/build/m_boot")
        XCTAssertEqual(cmd.arguments, ["alyx"])
        XCTAssertEqual(cmd.currentDirectory, "/k/Klepton")
        XCTAssertEqual(cmd.environment, [
            "KL_STREAM_HOST": "1",
            "KL_STREAM_NAME": "Test Mac",
            "TMPDIR": "/t/x",
            "KL_GLIBC_CONTENT": "/c/game",
            "KL_GLIBC_ARGS": "-vr -vulkan -console +vr_fidelity_level_auto 0 +vr_fidelity_level 1",
        ])
        // Never set by default: KL_STREAM_SCALE turns auto-sizing off.
        XCTAssertNil(cmd.environment["KL_STREAM_SCALE"])
        XCTAssertNil(cmd.environment["KL_STREAM_BITRATE_KBPS"])
    }

    func testAdvancedOptions() {
        let o = StreamOptions(name: "  Salón  ", bitrateKbps: 60_000, scale: 0.75)
        let cmd = StreamLaunch.command(klepton: klepton, info: alyx, contentDir: "/c", macName: "Test Mac",
                                       tmpDir: "/t", options: o)
        XCTAssertEqual(cmd.environment["KL_STREAM_NAME"], "Salón")
        XCTAssertEqual(cmd.environment["KL_STREAM_BITRATE_KBPS"], "60000")
        XCTAssertEqual(cmd.environment["KL_STREAM_SCALE"], "0.75")
        // Out-of-range scale is ignored (the host clamps the same way).
        let bad = StreamLaunch.command(klepton: klepton, info: alyx, contentDir: "/c", macName: "M", tmpDir: "/t",
                                       options: StreamOptions(scale: 5))
        XCTAssertNil(bad.environment["KL_STREAM_SCALE"])
    }

    func testMetroCommandFromData() {
        let metro = Catalog.entry("metro")!.stream!
        let cmd = StreamLaunch.command(klepton: klepton, info: metro, contentDir: nil, macName: "M", tmpDir: "/t",
                                       options: StreamOptions())
        XCTAssertEqual(cmd.arguments, ["metro"])
        XCTAssertEqual(Set(cmd.environment.keys), ["KL_STREAM_HOST", "KL_STREAM_NAME", "TMPDIR"])
    }

    func testBuildCommand() {
        let cmd = StreamLaunch.buildCommand(klepton: klepton)
        XCTAssertEqual(cmd.executable, "/usr/bin/make")
        XCTAssertEqual(cmd.arguments, ["build/m_boot"])
        XCTAssertEqual(cmd.currentDirectory, "/k/Klepton")
    }

    func testContentDetection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("streamtest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let k = root.appendingPathComponent("repo/vendor/Klepton")
        try fm.createDirectory(at: k, withIntermediateDirectories: true)
        XCTAssertNil(StreamLaunch.detectContent(klepton: k, info: alyx, env: [:]))
        // Public layout: <repo>/local/game/content/game
        let pub = root.appendingPathComponent("repo/local/game/content/game")
        for m in ["hlvr", "core"] { try fm.createDirectory(at: pub.appendingPathComponent(m), withIntermediateDirectories: true) }
        XCTAssertEqual(StreamLaunch.detectContent(klepton: k, info: alyx, env: [:]), pub.standardizedFileURL.path)
        // The scripts' override wins.
        let other = root.appendingPathComponent("other")
        for m in ["hlvr", "core"] { try fm.createDirectory(at: other.appendingPathComponent(m), withIntermediateDirectories: true) }
        XCTAssertEqual(StreamLaunch.detectContent(klepton: k, info: alyx, env: ["KL_ALYX_CONTENT": other.path]), other.path)
        // Submodule layout: <repo>/klepton next to <repo>/local/game/content/game
        let sub = root.appendingPathComponent("repo/klepton")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(StreamLaunch.detectContent(klepton: sub, info: alyx, env: [:]), pub.standardizedFileURL.path)
        // A directory without the markers is not content.
        XCTAssertFalse(StreamLaunch.contentPresent(root.path, info: alyx))
    }

    func testBusyAndScrub() {
        XCTAssertTrue(StreamLaunch.isBusy(load1: 9, cores: 10))
        XCTAssertFalse(StreamLaunch.isBusy(load1: 3, cores: 10))
        let line = "[stream-host] Bonjour: 'Test Mac' _klepton-stream._udp. local. content /home/someone/x"
        let s = StreamLaunch.scrub(line, macName: "Test Mac", home: "/home/someone")
        XCTAssertFalse(s.contains("Test Mac"))
        XCTAssertFalse(s.contains("/home/someone"))
        XCTAssertTrue(s.contains("~/x"))
    }
}

final class StreamLogTests: XCTestCase {
    func testLifecycle() {
        var st = StreamStatus()
        st.ingest("[stream-host] listening on UDP :9944 (_klepton-stream._udp), guest 'alyx'")
        XCTAssertEqual(st.phase, .starting)
        XCTAssertEqual(st.port, 9944)
        st.ingest("[stream-host] Bonjour: 'Mi Mac' _klepton-stream._udp. local.")
        XCTAssertEqual(st.bonjourName, "Mi Mac")
        st.ingest("[stream-host] waiting for a client's HELLO before booting the guest (KL_STREAM_WAIT=0 boots now with Vision Pro defaults)")
        XCTAssertEqual(st.phase, .waitingForHeadset)
        st.ingest("[stream-host] display from 192.168.1.20:50000 (Apple Vision Pro): 90.0 Hz, eye 1888x1824, IPD 66.9 mm, tan L(l 1 r 1 u 1 d 1) R(l 1 r 1 u 1 d 1)")
        XCTAssertEqual(st.device, "Apple Vision Pro")
        st.ingest("[stream-host] client 192.168.1.20:50000 connected: streaming (until the guest submits) 3776x1824 HEVC at 100000 kbit/s, 45 fps target (locked)")
        XCTAssertEqual(st.phase, .booting)
        XCTAssertEqual(st.client, "192.168.1.20:50000")
        XCTAssertEqual(st.frame, "3776x1824")
        XCTAssertEqual(st.stats?.bitrateKbps, 100000)
        st.ingest("[stream-host] first frame to the encoder: stage 1, pose_id 3, tangents …")
        XCTAssertEqual(st.phase, .streaming)
        XCTAssertTrue(st.headline.contains("Apple Vision Pro"))
        st.ingest("[stream-host] 44.9 fps encoded, encode 6.2 ms (compose 1.1, send 0.8), render 9.0 ms, 52.3 Mbit/s, 4800 pkt/s, pose 90 Hz, pose age 12.5 ms, rtt 3.10 ms, client 192.168.1.20:50000, total 900 frames (3 key)")
        XCTAssertEqual(st.stats?.fps, 44.9)
        XCTAssertEqual(st.stats?.encodeMs, 6.2)
        XCTAssertEqual(st.stats?.mbps, 52.3)
        XCTAssertEqual(st.stats?.poseAgeMs, 12.5)
        XCTAssertEqual(st.stats?.rttMs, 3.1)
        // The indented sub-lines must not be read as the main stats line.
        st.ingest("[stream-host]   frames encoded: 30.0 fps, interval 33.3 ms, sd 1.00 ms, max 40.0 ms [locked]")
        XCTAssertEqual(st.stats?.fps, 44.9)
        st.ingest("[stream-host]   sender: 52.3 Mbit/s, P 44 avg 120 max 300 KB, key 1 avg 900 max 900 KB, queue max 2, busy skips 0, queue drops 2, IDR asked 0 forced 0 held 0, pace 4.0 ms, bitrate 90000 kbit/s -> down")
        XCTAssertEqual(st.stats?.droppedTotal, 2)
        XCTAssertEqual(st.stats?.bitrateKbps, 90000)
        st.ingest("[stream-host]   3 guest frames skipped: the encoder was already holding KL_STREAM_MAX_INFLIGHT frames")
        XCTAssertEqual(st.stats?.droppedTotal, 5)
        st.ingest("[stream-host] client said BYE — streaming stopped, the guest keeps running")
        XCTAssertEqual(st.phase, .headsetLeft)
        // Reconnect: the game is already up, so straight to streaming.
        st.ingest("[stream-host] client 192.168.1.20:50001 connected: streaming 3776x1824 HEVC at 100000 kbit/s, 45 fps target (locked)")
        XCTAssertEqual(st.phase, .streaming)
        st.ingest("[stream-host] the game is exiting (status 0): BYE sent to the headset")
        XCTAssertEqual(st.phase, .ended(status: nil, stoppedByUser: false))
        st.exited(status: 0, stoppedByUser: false)
        XCTAssertEqual(st.headline, L("Partida terminada", "Game over"))
    }

    func testStopAndFailures() {
        var st = StreamStatus()
        st.ingest("[stream-host] waiting for a client's HELLO before booting the guest")
        st.exited(status: -15, stoppedByUser: true)
        XCTAssertEqual(st.phase, .ended(status: -15, stoppedByUser: true))

        var bad = StreamStatus()
        bad.ingest("[stream-host] bind :9944 failed: Address already in use")
        guard case .failed(let why) = bad.phase else { return XCTFail("not failed") }
        XCTAssertTrue(why.contains("Address already in use"))
        bad.exited(status: 1, stoppedByUser: false)
        guard case .failed = bad.phase else { return XCTFail("exit overwrote the failure") }

        var crash = StreamStatus()
        crash.ingest("[stream-host] listening on UDP :9944 (x), guest 'alyx'")
        crash.exited(status: 1, stoppedByUser: false)
        guard case .failed = crash.phase else { return XCTFail("early non-zero exit is a failure") }

        var timeout = StreamStatus()
        timeout.ingest("[stream-host] client timed out (no POSE for 2.0 s) — streaming stopped, the guest keeps running")
        XCTAssertEqual(timeout.phase, .headsetLeft)
        // Lines without the host prefix are ignored.
        var other = StreamStatus()
        other.ingest("waiting for a client's HELLO")
        XCTAssertEqual(other.phase, .idle)
    }
}

final class ProcessTerminateTests: XCTestCase {
    func testTerminateSendsTERMToThePid() throws {
        let runner = ProcessRunner()
        let done = expectation(description: "exit")
        let code = Locked<Int32>()
        try runner.start(ShellCommand("/bin/sleep", ["30"]), onLine: { _ in }, onExit: { code.set($0); done.fulfill() })
        XCTAssertNotNil(runner.pid)
        runner.terminate(timeout: 5)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(code.get(), -SIGTERM)
    }

    func testKillAfterTimeoutWhenTERMIsIgnored() throws {
        let runner = ProcessRunner()
        let done = expectation(description: "exit")
        let code = Locked<Int32>()
        // A shell that ignores TERM and keeps running (exec keeps the same pid).
        try runner.start(.bash("trap '' TERM; echo ready; exec /bin/sleep 30"), onLine: { _ in }, onExit: { code.set($0); done.fulfill() })
        Thread.sleep(forTimeInterval: 0.3)
        runner.terminate(timeout: 0.5)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(code.get(), -SIGKILL)
    }

    func testTerminateAndWait() throws {
        let runner = ProcessRunner()
        try runner.start(ShellCommand("/bin/sleep", ["30"]), onLine: { _ in }, onExit: { _ in })
        let pid = runner.pid!
        runner.terminateAndWait(timeout: 2)
        XCTAssertFalse(runner.isRunning)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
