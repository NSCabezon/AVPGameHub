// Per-session performance summary: what one game session ran at, kept after
// the process is gone.
//
// MEASURED in the immersive compositor (KleptonCompositor.renderFrame), the one
// seam every guest kind passes through: each compositor frame reports the guest
// frame value it would show (the GL fence or the Vulkan frame serial — the same
// `frameValue` the stale-frame logic reads). A value that changed is a NEW guest
// frame; an unchanged one is a compositor frame that reused (reprojected) an
// old picture. Guest frame intervals are timed where the compositor sees them,
// so they are quantised to the display period (11.1 ms at 90 Hz) and a guest
// that submits FASTER than the display is counted at the display rate.
//
// Loading is not gameplay: the time before the first guest frame, and every gap
// of more than a second between two guest frames (Alyx's SuspendRendering
// stops submitting for the whole load; so does a shader prewarm, a paused
// layer, a guest that has ended), is counted as loading time and kept out of
// the frame-rate figures, together with the compositor frames that reused a
// picture during it.
//
// COST on the render thread: one os_unfair_lock round trip, a few integer adds
// and one histogram increment per compositor frame. No allocation: the
// histogram is a fixed buffer allocated once (0.25 ms bins up to 1 s), the
// counters are a plain struct.
//
// PERSISTED as one JSON line per session in
// Library/Application Support/sessions/<target>.jsonl (KLSessionRecord), the
// line rewritten in place (same `id`) every 30 s, when the render loop ends,
// on backgrounding (Lifecycle) and at exit — so a kill still leaves a summary
// at most 30 s old. A human-readable `[session]` line goes to stderr, which is
// Documents/klepton-boot.log, every 60 s and at the end. The hub reads the file
// (KLSessionHistory) for the card and the game's settings sheet.
import Foundation
import Darwin

/// One session as stored (one JSON line). Shared by the writer here and the
/// hub's reader. `final` is false for a periodic checkpoint: a session whose
/// last line is not final ended without a clean exit (a kill, a crash).
struct KLSessionRecord: Codable, Identifiable, Equatable {
    var v: Int = 1
    var id: String
    var target: String
    var build: String
    var start: Date
    var end: Date
    var final: Bool
    var endReason: String
    var durationS: Double
    var playS: Double
    var loadingS: Double
    var guestFrames: UInt64
    var fpsAvg: Double?
    var fps1Low: Double?
    var fps5Low: Double?
    var fpsMin5s: Double?
    var fpsMax5s: Double?
    var frameMsP50: Double?
    var displayHz: Double?
    var compositorFrames: UInt64
    var reprojectedFrames: UInt64
    var peakFootprintMB: Int
    /// The guest's GPU ms per frame, averaged over the frames that were timed
    /// (kl_gpu_time: KL_GPU_TIME, or while the performance overlay was on).
    /// nil when nothing was timed. Added later: older lines decode without it.
    var gpuMsAvg: Double? = nil
    var gpuFrames: UInt64? = nil
}

/// The session files: Application Support/sessions/<target>.jsonl.
enum KLSessionHistory {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
    }
    static func file(for target: String) -> URL {
        directory.appendingPathComponent("\(target).jsonl")
    }
    /// How many sessions a file keeps (oldest dropped first).
    static let keep = 100

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }

    /// Every session on file for `target`, oldest first. Lines that do not
    /// decode (a torn write, a future format) are skipped.
    static func load(_ target: String) -> [KLSessionRecord] {
        guard let data = try? Data(contentsOf: file(for: target)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(KLSessionRecord.self, from: Data($0.utf8)) }
    }

    /// Write `r`, replacing the line with the same id if there is one.
    static func upsert(_ r: KLSessionRecord) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(for: r.target)
        var lines: [String] = []
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            let marker = "\"id\":\"\(r.id)\""
            lines = text.split(separator: "\n").map(String.init).filter { !$0.contains(marker) }
        }
        guard let enc = try? encoder().encode(r), let line = String(data: enc, encoding: .utf8) else { return }
        lines.append(line)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func clear(_ target: String) {
        try? FileManager.default.removeItem(at: file(for: target))
    }
}

/// The live counters for this process's session (one game per process).
final class KLSessionStats {
    static let shared = KLSessionStats()

    // Histogram of guest frame intervals: 0.25 ms bins, 0 ... 1000 ms. An
    // interval over 1 s is loading and never lands here.
    private static let binsPerMs = 4
    private static let bins = 1000 * binsPerMs + 1
    private static let gapNs: UInt64 = 1_000_000_000
    private static let windowNs: UInt64 = 5_000_000_000

    private struct Counters {
        var started = false
        var startNs: UInt64 = 0
        var startWall = Date(timeIntervalSince1970: 0)
        var lastSerial: UInt64 = 0
        var lastNewNs: UInt64 = 0          // 0 until the first guest frame
        var guestFrames: UInt64 = 0        // play intervals counted
        var playNs: UInt64 = 0
        var loadingNs: UInt64 = 0          // closed loading spans
        var compFrames: UInt64 = 0
        var compLastNs: UInt64 = 0
        var compIntervalNs: UInt64 = 0     // sum of compositor intervals < 100 ms
        var compIntervals: UInt64 = 0
        var reprojected: UInt64 = 0
        var pendingReused: UInt64 = 0      // reused since the last new guest frame
        var winNs: UInt64 = 0, winFrames: UInt64 = 0
        var winMin = Double.infinity, winMax = 0.0
        var maxIntervalNs: UInt64 = 0      // worst play interval since the overlay last read it
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var c = Counters()
    private let hist = UnsafeMutablePointer<UInt32>.allocate(capacity: KLSessionStats.bins)
    // Snapshot side, touched only on `queue`.
    private let histCopy = UnsafeMutablePointer<UInt32>.allocate(capacity: KLSessionStats.bins)
    private let queue = DispatchQueue(label: "klepton.session-stats", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var peakFootprint: UInt64 = 0
    private var finished = false
    private let id = UUID().uuidString
    private var target = ""

    private init() {
        hist.initialize(repeating: 0, count: Self.bins)
        histCopy.initialize(repeating: 0, count: Self.bins)
    }

    private static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    // MARK: render thread

    /// The render loop has started. Idempotent: a second immersive space in the
    /// same process continues the same session.
    func begin() {
        os_unfair_lock_lock(lock)
        let first = !c.started
        if first { c.started = true; c.startNs = Self.nowNs(); c.startWall = Date() }
        os_unfair_lock_unlock(lock)
        guard first else { return }
        target = klTargetName()
        atexit { KLSessionStats.shared.finish(reason: "exit") }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        NSLog("[session] measuring this session (\(target)) -> \(KLSessionHistory.file(for: target).path)")
    }

    /// One presented compositor frame showing guest frame `serial` (0: the
    /// guest has no picture yet). Called once per compositor frame.
    func noteCompositorFrame(guestSerial serial: UInt64) {
        let now = Self.nowNs()
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard c.started else { return }
        if c.compLastNs != 0 {
            let d = now &- c.compLastNs
            if d < 100_000_000 { c.compIntervalNs &+= d; c.compIntervals &+= 1 }
        }
        c.compLastNs = now
        c.compFrames &+= 1
        guard serial != 0 else { return }
        if serial == c.lastSerial { c.pendingReused &+= 1; return }
        c.lastSerial = serial
        if c.lastNewNs == 0 {
            // The first guest frame: everything before it was boot / loading.
            c.loadingNs &+= now &- c.startNs
        } else {
            let d = now &- c.lastNewNs
            if d > Self.gapNs {
                c.loadingNs &+= d
                c.winNs = 0; c.winFrames = 0        // a window does not span a load
            } else {
                c.playNs &+= d
                c.guestFrames &+= 1
                if d > c.maxIntervalNs { c.maxIntervalNs = d }
                c.reprojected &+= c.pendingReused
                let bin = min(Int(d / 250_000), Self.bins - 1)
                hist[bin] &+= 1
                c.winNs &+= d; c.winFrames &+= 1
                if c.winNs >= Self.windowNs {
                    let fps = Double(c.winFrames) * 1e9 / Double(c.winNs)
                    if fps < c.winMin { c.winMin = fps }
                    if fps > c.winMax { c.winMax = fps }
                    c.winNs = 0; c.winFrames = 0
                }
            }
        }
        c.pendingReused = 0
        c.lastNewNs = now
    }

    // MARK: checkpoints

    /// Persist and log now, not final (the render loop ended; the process may
    /// open another immersive space). Asynchronous.
    func checkpoint(reason: String) {
        queue.async { self.persist(final: false, reason: reason, log: true) }
    }

    /// The session is over: persist a final line and log it, synchronously,
    /// before the caller exits. Once only (backgrounding exits, and the exit
    /// runs the atexit hook too).
    func finish(reason: String) {
        queue.sync {
            guard !finished else { return }
            os_unfair_lock_lock(lock); let started = c.started; os_unfair_lock_unlock(lock)
            guard started else { return }
            finished = true
            timer?.cancel()
            persist(final: true, reason: reason, log: true)
        }
        fflush(stderr)
    }

    // MARK: queue

    private func tick() {
        ticks += 1
        samplePeak()
        guard !finished else { return }
        let log = ticks % 60 == 0
        if ticks % 30 == 0 || log { persist(final: false, reason: "periodic", log: log) }
    }

    /// The process's physical footprint and the kernel's lifetime peak, bytes.
    static func footprint() -> (now: UInt64, peak: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    /// The running counters the performance overlay differentiates (two reads
    /// half a second apart give that half second's rates). One lock round trip.
    struct Live {
        var guestFrames: UInt64 = 0
        var playNs: UInt64 = 0
        var compFrames: UInt64 = 0
        var compIntervalNs: UInt64 = 0
        var compIntervals: UInt64 = 0
        var reprojected: UInt64 = 0
        var pendingReused: UInt64 = 0
        var lastNewNs: UInt64 = 0
    }
    func live() -> Live {
        os_unfair_lock_lock(lock)
        let s = c
        os_unfair_lock_unlock(lock)
        return Live(guestFrames: s.guestFrames, playNs: s.playNs, compFrames: s.compFrames,
                    compIntervalNs: s.compIntervalNs, compIntervals: s.compIntervals,
                    reprojected: s.reprojected, pendingReused: s.pendingReused, lastNewNs: s.lastNewNs)
    }
    static var nowNsPublic: UInt64 { nowNs() }

    /// The worst guest frame interval since the last call, ms (nil: none), and reset.
    func takeMaxIntervalMs() -> Double? {
        os_unfair_lock_lock(lock)
        let m = c.maxIntervalNs
        c.maxIntervalNs = 0
        os_unfair_lock_unlock(lock)
        return m > 0 ? Double(m) / 1e6 : nil
    }

    private func samplePeak() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        // The kernel's own lifetime peak as well as the sample: a spike between
        // two one-second samples still counts.
        peakFootprint = max(peakFootprint, info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    /// Snapshot the counters (under the lock: a struct copy and one memcpy) and
    /// turn them into a record. Runs on `queue`.
    private func snapshot(final: Bool, reason: String) -> KLSessionRecord {
        samplePeak()
        os_unfair_lock_lock(lock)
        let s = c
        histCopy.update(from: hist, count: Self.bins)
        os_unfair_lock_unlock(lock)
        let now = Self.nowNs()
        var loadingNs = s.loadingNs
        if s.lastNewNs == 0 {
            loadingNs = now &- s.startNs                       // still before the first frame
        } else if now &- s.lastNewNs > Self.gapNs {
            loadingNs &+= now &- s.lastNewNs                   // inside a load right now
        }
        // Percentiles of the frame interval, by frame count. "5% low" is the
        // frame rate the slowest 5% of frames ran at or below: 1000 / p95(ms).
        func intervalMs(atFraction f: Double) -> Double? {
            guard s.guestFrames > 0 else { return nil }
            let rank = UInt64((Double(s.guestFrames) * f).rounded(.up))
            var acc: UInt64 = 0
            for i in 0 ..< Self.bins {
                acc += UInt64(histCopy[i])
                if acc >= max(rank, 1) { return (Double(i) + 0.5) / Double(Self.binsPerMs) }
            }
            return nil
        }
        func fps(_ ms: Double?) -> Double? { ms.map { 1000 / $0 } }
        let playS = Double(s.playNs) / 1e9
        var gpuSum = 0.0, gpuN: UInt64 = 0
        kl_gpu_time_totals(&gpuSum, &gpuN)
        var r = KLSessionRecord(
            id: id, target: target, build: Self.buildStamp,
            start: s.startWall, end: Date(), final: final, endReason: reason,
            durationS: Double(now &- s.startNs) / 1e9,
            playS: playS, loadingS: Double(loadingNs) / 1e9,
            guestFrames: s.guestFrames,
            fpsAvg: playS > 0 ? Double(s.guestFrames) / playS : nil,
            fps1Low: fps(intervalMs(atFraction: 0.99)),
            fps5Low: fps(intervalMs(atFraction: 0.95)),
            fpsMin5s: s.winMin.isFinite ? s.winMin : nil,
            fpsMax5s: s.winMax > 0 ? s.winMax : nil,
            frameMsP50: intervalMs(atFraction: 0.5),
            displayHz: s.compIntervals > 0 ? Double(s.compIntervals) * 1e9 / Double(s.compIntervalNs) : nil,
            compositorFrames: s.compFrames,
            reprojectedFrames: s.reprojected,
            peakFootprintMB: Int(peakFootprint >> 20))
        if gpuN > 0 { r.gpuMsAvg = gpuSum / Double(gpuN); r.gpuFrames = gpuN }
        return r
    }

    private func persist(final: Bool, reason: String, log: Bool) {
        let r = snapshot(final: final, reason: reason)
        if r.durationS >= 5 { KLSessionHistory.upsert(r) }
        if log { fputs("[session] \(Self.describe(r))\n", stderr); fflush(stderr) }
    }

    static func describe(_ r: KLSessionRecord) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
        func dur(_ s: Double) -> String { let t = Int(s); return String(format: "%dm%02ds", t / 60, t % 60) }
        let reproj = r.compositorFrames > 0
            ? String(format: "%llu of %llu (%.0f%%)", r.reprojectedFrames, r.compositorFrames,
                     100 * Double(r.reprojectedFrames) / Double(r.compositorFrames))
            : "0"
        return "\(r.target) \(dur(r.durationS))\(r.final ? " FINAL (\(r.endReason))" : ""): "
            + "guest \(f(r.fpsAvg)) fps avg, 1% low \(f(r.fps1Low)), 5% low \(f(r.fps5Low)), "
            + "5s min/max \(f(r.fpsMin5s))/\(f(r.fpsMax5s)), median frame \(f(r.frameMsP50)) ms; "
            + "play \(dur(r.playS)), loading \(dur(r.loadingS)); display \(f(r.displayHz)) Hz, "
            + "reprojected \(reproj) compositor frames; peak footprint \(r.peakFootprintMB) MB; "
            + (r.gpuMsAvg.map { String(format: "GPU %.1f ms/frame over %llu timed frames; ", $0, r.gpuFrames ?? 0) } ?? "")
            + "build \(r.build)"
    }

    /// Version, build and the executable's date; the git commit too in a hub
    /// build (generated into its manifest by gen_xcodeproj.py).
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        var s = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        #if KL_HUB
        s += " \(klHubBuildCommit)"
        #endif
        if let exe = Bundle.main.executableURL,
           let d = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            s += " built \(fmt.string(from: d))"
        }
        return s
    }()
}
