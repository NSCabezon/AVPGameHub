import Foundation
import SteamDepot

/// `steamdepot serve` / `steamdepot stats`: the real-Steam bridge for Klepton's Steamworks
/// stand-in. Both use the saved token only; neither starts an interactive login.
struct BridgeArgs {
    var tokenFile = "~/.steamdepot-token.json"
    var cacheDir = "~/.steamdepot/bridge-cache"
    var socket = "~/.steamdepot/bridge.sock"
    var app: UInt32 = 0
    var storeNoop = false
    var send = false
    var json = false
    var verbose = false
    /// Read another (public) user's stats instead: checks the parser against Steam Community.
    var forUser: UInt64?
    var dryRunStores = false
    /// Steam API language for achievement names/descriptions ("spanish", "latam"...).
    var lang: String?
    /// stats: also download every achievement icon into the cache.
    var icons = false
    /// Positional arguments (`steamdepot icon <url>`).
    var positional: [String] = []

    static func parse(_ argv: ArraySlice<String>) throws -> BridgeArgs {
        var a = BridgeArgs()
        var it = argv.makeIterator()
        func next(_ flag: String) throws -> String {
            guard let v = it.next() else { throw CLIError("missing value for \(flag)") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--token-file": a.tokenFile = try next(arg)
            case "--cache-dir": a.cacheDir = try next(arg)
            case "--socket": a.socket = try next(arg)
            case "--app": a.app = UInt32(try next(arg)) ?? 0
            case "--for": a.forUser = UInt64(try next(arg))
            case "--store-noop": a.storeNoop = true
            case "--dry-run-stores": a.dryRunStores = true
            case "--send": a.send = true
            case "--json": a.json = true
            case "--lang": a.lang = try next(arg)
            case "--icons": a.icons = true
            case "--verbose", "-v": a.verbose = true
            case "-h", "--help": print(usage); exit(0)
            default:
                guard !arg.hasPrefix("-") else { throw CLIError("unknown argument \(arg)\n\(usage)") }
                a.positional.append(arg)
            }
        }
        return a
    }

    func makeService() -> SteamBridgeService {
        let verbose = self.verbose
        return SteamBridgeService(tokenFile: URL(fileURLWithPath: expand(tokenFile)),
                                  cacheDir: URL(fileURLWithPath: expand(cacheDir)),
                                  log: { msg in if verbose { say("· \(msg)") } })
    }
}

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// MARK: stats

/// Read-only listing of the user's stats and achievements for one app. With --store-noop it
/// builds a store that re-sends the current values (dry run); --send actually sends it.
func runStats(_ argv: ArraySlice<String>) async throws {
    let a = try BridgeArgs.parse(argv)
    guard a.app != 0 else { throw CLIError("stats needs --app <id>") }
    guard a.positional.isEmpty else { throw CLIError("unexpected argument \(a.positional[0])\n\(usage)") }
    logToStderr = a.json
    if let user = a.forUser {
        guard let creds = try FileCredentialStore(url: URL(fileURLWithPath: expand(a.tokenFile))).load() else { throw CLIError("no saved token") }
        let session = SteamSession(log: { m in if a.verbose { say("· \(m)") } })
        try await session.connect()
        try await session.logOn(creds)
        printStats(try await session.userStats(app: a.app, steamID: user), offline: false, lang: a.lang)
        await session.disconnect()
        return
    }
    let service = a.makeService()
    let s = try await service.stats(app: a.app)
    let snap = s.snapshot
    if a.json {
        let obj = SteamBridgeService.statsJSON(snap, offline: s.offline, lang: a.lang)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        printStats(snap, offline: s.offline, lang: a.lang)
    }
    if a.icons { await downloadIcons(snap, service: service) }
    guard a.storeNoop else { await service.shutdown(); return }

    // Round-trip test: every client-writable, non-achievement stat at its current value. The
    // achievement bitfields are never included, so no achievement can change.
    let dry = try await service.storeCurrentValues(app: a.app, dryRun: true)
    let hex = dry.body.map { String(format: "%02x", $0) }.joined()
    say("store-noop dry run: ClientStoreUserStats2 re-sending \(dry.statCount) stats at their current values, crc \(dry.crcBefore), no achievement blocks")
    say("body (\(dry.body.count) bytes): \(hex)")
    if dry.defaultedCount > 0 {
        say("note: \(dry.defaultedCount) of them have no stored value on Steam yet (schema default); sending would store them explicitly")
    }
    guard a.send else { say("dry run only (pass --send to send it)"); await service.shutdown(); return }
    let sent = try await service.storeCurrentValues(app: a.app, dryRun: false)
    say("store-noop sent: EResult OK, \(sent.statCount) stats, crc \(sent.crcBefore) -> \(sent.crcAfter.map(String.init) ?? "?")"
        + (sent.reverted.isEmpty ? "" : ", Steam reverted \(sent.reverted)"))
    let after = try await service.stats(app: a.app)
    let same = after.snapshot.schema.stats.allSatisfy { after.snapshot.raw($0) == snap.raw($0) }
    say("re-read after store: values \(same ? "unchanged" : "CHANGED") (\(after.snapshot.unlockedCount)/\(after.snapshot.schema.achievements.count) achievements)")
    await service.shutdown()
}

func printStats(_ snap: UserStatsSnapshot, offline: Bool, lang: String? = nil) {
    let ach = snap.schema.achievements
    print("app \(snap.appID): schema v\(snap.schema.version), crc \(snap.crc)\(offline ? " (offline, from cache)" : "")")
    print("achievements: \(snap.unlockedCount)/\(ach.count) unlocked")
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
    for a in ach {
        let t = snap.unlockTime(a)
        let when = t > 0 ? df.string(from: Date(timeIntervalSince1970: TimeInterval(t))) : ""
        print("  [\(snap.isUnlocked(a) ? "x" : " ")] \(a.name)\(a.name(lang).map { "  \"\($0)\"" } ?? "")\(a.hidden ? "  (hidden)" : "")  \(when)")
        if let d = a.desc(lang) { print("        \(d)") }
    }
    let stats = snap.schema.stats.filter { !$0.type.isAchievementBlock }
    print("stats: \(stats.count)")
    for s in stats {
        let v: String
        switch snap.value(s) { case .int(let i): v = String(i); case .float(let f): v = String(f) }
        var flags: [String] = [s.type.rawValue]
        if s.incrementOnly { flags.append("increment-only") }
        if s.isProtected { flags.append("server-only") }
        print("  \(s.name) = \(v)  (\(flags.joined(separator: ", ")))")
    }
}

/// Download every achievement icon (normal and gray) into the bridge cache.
func downloadIcons(_ snap: UserStatsSnapshot, service: SteamBridgeService) async {
    var ok = 0, failed = 0
    for a in snap.schema.achievements {
        for file in [a.icon, a.iconGray] {
            guard let url = UserStatsSchema.iconURL(app: snap.appID, file: file) else { continue }
            do {
                let path = try await service.icon(url: url)
                ok += 1
                if file == a.icon { print("  icon \(a.name): \(path.path)") }
            } catch {
                failed += 1
                say("icon \(a.name): \(error)")
            }
        }
    }
    say("icons: \(ok) cached in \(service.cacheDir.appendingPathComponent("icons").path)" + (failed > 0 ? ", \(failed) failed" : ""))
}

/// `steamdepot icon <url>`: download one achievement icon into the cache and print its path.
func runIcon(_ argv: ArraySlice<String>) async throws {
    let a = try BridgeArgs.parse(argv)
    guard a.positional.count == 1, let url = a.positional.first else { throw CLIError("usage: steamdepot icon <url> [--cache-dir <dir>]") }
    print(try await a.makeService().icon(url: url).path)
}

// MARK: serve

/// Serve the bridge contract on a Unix domain socket: one thread per client connection,
/// newline-delimited JSON, requests answered in order (the service serialises Steam traffic).
func runServe(_ argv: ArraySlice<String>) async throws {
    let a = try BridgeArgs.parse(argv)
    let service = a.makeService()
    if a.dryRunStores {
        await service.setDryRunStores(true)
        say("--dry-run-stores: stores are validated and built but never sent or queued")
    }
    let path = expand(a.socket)
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let server = try UnixSocketServer(path: path)
    say("bridge listening on \(path)")

    let stop: @Sendable (Int32) -> Void = { sig in
        say("signal \(sig): shutting down")
        unlink(path)
        let sem = DispatchSemaphore(value: 0)
        Task { await service.shutdown(); sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
        exit(0)
    }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { stop(sig) }
        src.resume()
        sources.append(src)
    }
    signal(SIGPIPE, SIG_IGN)
    // accept() blocks, so keep it off the cooperative pool; this task then waits forever.
    Thread.detachNewThread { server.serve { fd in serveClient(fd: fd, service: service) } }
    while true {
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        withExtendedLifetime(sources) {}
    }
}

/// One client: read lines, answer each. If the client turned "playing" on and disconnects
/// without turning it off (game crashed), clear it so the profile does not stay "Playing".
func serveClient(fd: Int32, service: SteamBridgeService) {
    defer { close(fd) }
    var buffer = Data()
    var playingApps = Set<UInt32>()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    func call(_ line: Data) -> Data {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out = Data()
        Task { out = await service.handle(line); sem.signal() }
        sem.wait()
        return out
    }
    readLoop: while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            var resp = call(line)
            // Track playing state per connection for the cleanup below.
            if let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any], req["op"] as? String == "playing",
               let app = (req["app"] as? NSNumber)?.uint32Value, let on = req["on"] as? Bool,
               let r = try? JSONSerialization.jsonObject(with: resp) as? [String: Any], r["ok"] as? Bool == true {
                if on { playingApps.insert(app) } else { playingApps.remove(app) }
            }
            resp.append(0x0A)
            var off = 0
            while off < resp.count {
                let w = resp.withUnsafeBytes { write(fd, $0.baseAddress! + off, resp.count - off) }
                if w <= 0 { break readLoop }
                off += w
            }
        }
    }
    for app in playingApps {
        say("client left while playing \(app); clearing")
        _ = call(Data(#"{"op":"playing","app":\#(app),"on":false}"#.utf8))
    }
}

final class UnixSocketServer: @unchecked Sendable {
    let fd: Int32
    let path: String

    init(path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw CLIError("socket path too long: \(path)") }
        // Refuse to steal a live server's socket; remove a stale one.
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            var a2 = addr
            withUnsafeMutableBytes(of: &a2.sun_path) { p in p.copyBytes(from: bytes) }
            let alive = withUnsafePointer(to: &a2) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            } == 0
            close(probe)
            if alive { throw CLIError("another bridge is already serving \(path)") }
            unlink(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in p.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("socket(): \(String(cString: strerror(errno)))") }
        let old = umask(0o177) // socket file created 0600
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { throw CLIError("bind(\(path)): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { throw CLIError("listen(): \(String(cString: strerror(errno)))") }
        self.fd = fd
        self.path = path
    }

    /// Accept forever, one detached thread per connection.
    func serve(_ handler: @escaping @Sendable (Int32) -> Void) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; say("accept(): \(String(cString: strerror(errno)))"); return }
            Thread.detachNewThread { handler(c) }
        }
    }
}
