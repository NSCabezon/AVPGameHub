// The guest's Steamworks stand-in, answered from the user's REAL Steam account.
//
// kl_steam.c (the stand-in) asks a backend for `hello` / `stats` / `store` /
// `playing` in newline-delimited JSON (kl_steam_bridge.h). On the Mac that is
// `steamdepot serve`'s Unix socket; here it is this file: a C function pointer,
// registered before the runtime boots, that hands each request line to
// SteamDepot's SteamBridgeService and blocks the calling GAME thread until the
// answer comes back (or the timeout the runtime passed runs out).
//
// Deliberately thin: the contract lives in SteamBridgeService.handle(_:), and
// everything here is plumbing. The service uses the same sign-in as the content
// gate (KleptonSteamContent.swift): the refresh token in the Keychain
// (service "SteamDepot.refreshToken"). It keeps its own logged-on session —
// the content model's sessions are per download and are closed when it ends —
// and caches hello/stats in Application Support/steam-bridge for offline runs.
//
// Compiled only where SteamDepot is linked (the alyx and hub builds).
#if canImport(SteamDepot)
import Foundation
import SteamDepot

enum KleptonSteamBridge {
    /// One service per process: the C backend and the hub's ownership check share it.
    static let service: SteamBridgeService = {
        let fm = FileManager.default
        let cache = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("steam-bridge", isDirectory: true)
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        return SteamBridgeService(
            credentials: KeychainCredentialStore(service: "SteamDepot.refreshToken", account: "steam"),
            tokenDescription: "Keychain (SteamDepot.refreshToken)",
            cacheDir: cache,
            log: { NSLog("[steam-bridge] %@", $0) })
    }()

    nonisolated(unsafe) private static var registered = false

    /// Hand the runtime its Steam backend. Before the guest boots: in the hub right
    /// after Play (HubLaunch.select), in a single-game build at startup.
    static func register() {
        guard !registered else { return }
        registered = true
        _ = service
        kl_steam_set_backend(backend)
        NSLog("[steam-bridge] backend registered (cache \(service.cacheDir.path))")
    }

    /// Does the signed-in account own `app`? Offline, the service answers from its
    /// cache. Throws when it cannot say at all (never signed in, no cache).
    static func owns(app: UInt32) async throws -> (owned: Bool, name: String, offline: Bool) {
        let h = try await service.hello(app: app)
        return (h.owned, h.name, h.offline)
    }

    /// The answer slot a game thread waits on. A late answer (after the timeout)
    /// lands here and is dropped with it.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// One request, synchronously. The service is an actor and never runs on the
    /// main actor, so even the teardown call (which comes from the main thread,
    /// Lifecycle.scenePhaseChanged) cannot deadlock — it waits at most `ms`.
    static func call(_ request: Data, timeoutMs ms: Int32) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        let slot = Slot()
        Task.detached {
            slot.set(await service.handle(request))
            sem.signal()
        }
        guard sem.wait(timeout: .now() + .milliseconds(Int(max(ms, 1)))) == .success else { return nil }
        return slot.get()
    }

    /// kl_steam_backend_fn: one request line in, one response line out (NUL-terminated).
    private static let backend: kl_steam_backend_fn = { req, resp, cap, timeoutMs in
        guard let req, let resp, cap > 1 else { return -1 }
        if Thread.isMainThread {
            NSLog("[steam-bridge] request on the main thread (teardown?); bounded by %d ms", timeoutMs)
        }
        guard var out = call(Data(bytes: req, count: strlen(req)), timeoutMs: timeoutMs) else {
            NSLog("[steam-bridge] no answer within %d ms", timeoutMs)
            return -1
        }
        if let nl = out.firstIndex(of: 0x0A) { out = out.prefix(upTo: nl) }
        guard out.count < cap else { return -1 }
        out.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(resp, base, out.count) }
        }
        resp[out.count] = 0
        return Int32(out.count)
    }
}
#endif
