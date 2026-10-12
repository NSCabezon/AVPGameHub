// System background downloads for the hub (URLSessionConfiguration.background).
//
// What goes through the system, and why only that:
//
//  * Steam: YES. A depot's chunks are plain HTTPS GETs on Valve's content servers
//    (<server>/depot/<id>/chunk/<sha>) that need no credential — what proves ownership is
//    the depot KEY, and a chunk is useless without it (AES-256, then VZip/VZstd). So the
//    raw chunks a download is about to fetch are handed to a background session, which
//    nsurlsessiond runs while a game plays, while the hub sits in the background, and
//    after the process has exited. They land in a staging directory beside the depot
//    (<root>/.steamdepot/staging-<depot>/<chunk id>); the in-app downloader (SteamDepot)
//    takes them from there whenever it runs in the foreground — staged chunks FIRST, picked
//    up every couple of seconds as they land, then its own fetch from the start of the plan;
//    decrypt, decompress, Adler and size check, exactly as a chunk from the network. Each
//    staged chunk it assembles is deleted, which frees room under the staging cap, so in the
//    foreground both lanes run at once and staging never fills up and stalls the system's
//    share. The depot key never leaves the process and is never written anywhere.
//    A server that asks for a CDN auth token makes the lane stop (`needsToken`): such a
//    token is not handed to the system; the in-app download fetches those chunks itself.
//
//  * Meta: NO. securecdn.oculus.com answers the token-carrying request with the file
//    itself (HTTP 200), not with a redirect to a signed CDN address (checked with
//    `metastore resolve`). A background task would have to carry the Authorization
//    header, and nsurlsessiond keeps a background task's request — header included — in
//    its own storage on disk. The Meta token lives only in the Keychain, so Meta files
//    stay in-process: they keep going while a game runs in this process, and continue
//    by themselves (HTTP Range resume) the next time the hub opens.
//
// Nothing here writes a credential anywhere: lane files hold chunk ids, sizes and server
// host names. Log lines name hosts and counts, never an address with a query.
//
// The hub decides when: "Descargas en segundo plano" (on by default) in the hub's
// settings; off = exactly the in-process downloads as before. "Pausar descargas mientras
// juegas" suspends the session's tasks while a game runs (they continue at the next hub
// launch). While a game runs nothing heavy happens here either way: a finished chunk is
// one rename on a utility queue, and no chunk is decrypted or assembled until the hub's
// library is back in the foreground.
#if KL_HUB
import Foundation
import UIKit

/// The two settings (UserDefaults). Changing them applies to downloads started afterwards.
enum KLDownloadSettings {
    static let backgroundKey = "kl.hub.backgroundDownloads"
    static let pauseWhilePlayingKey = "kl.hub.pauseDownloadsWhilePlaying"

    /// "Descargas en segundo plano" — default ON.
    static var background: Bool {
        get { UserDefaults.standard.object(forKey: backgroundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: backgroundKey) }
    }
    /// "Pausar descargas mientras juegas" — default OFF.
    static var pauseWhilePlaying: Bool {
        get { UserDefaults.standard.bool(forKey: pauseWhilePlayingKey) }
        set { UserDefaults.standard.set(newValue, forKey: pauseWhilePlayingKey) }
    }
}

/// A game the player asked to download and that has not finished: resumed by itself the next
/// time the hub's library opens (background setting on). "store:target" in UserDefaults.
enum KLDownloadIntent {
    private static let key = "kl.hub.wantedDownloads"
    static func all() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func wants(_ store: String, _ target: String) -> Bool { all().contains("\(store):\(target)") }
    static func set(_ store: String, _ target: String, _ on: Bool) {
        var s = all()
        if on { s.insert("\(store):\(target)") } else { s.remove("\(store):\(target)") }
        UserDefaults.standard.set(s.sorted(), forKey: key)
    }
}

/// UIApplicationDelegate for the hub: the background session's launch events.
final class KLHubAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Reconnect to the background session at every launch (tasks that finished while the
        // app was gone are delivered now; suspended ones are resumed).
        KLBackgroundDownloads.shared.activate()
        return true
    }

    /// The system launched (or woke) the app because the session's tasks finished while it was
    /// not running. The handler is called once the session has delivered every event.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        NSLog("[bgdl] woken for background session events")
        KLBackgroundDownloads.shared.handleEvents(identifier: identifier, completion: completionHandler)
    }
}

/// The hub's one background URLSession and its Steam chunk lanes.
final class KLBackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = KLBackgroundDownloads()
    /// Posted on the main queue when a lane's numbers change (throttled).
    static let didChange = Notification.Name("KLBackgroundDownloadsDidChange")
    /// Posted on the main queue right before a game boots (HubLaunch.select).
    static let gameWillStart = Notification.Name("KLBackgroundDownloadsGameWillStart")

    let identifier = (Bundle.main.bundleIdentifier ?? "klepton") + ".background-downloads"
    /// Chunk tasks handed to the system at once, per lane. Each completion is one rename; the
    /// system wakes the app when all of a batch is done and the lane tops up from there.
    var window = 512
    /// Staged (not yet assembled) bytes a lane may hold before it waits for the hub.
    var stagingCap: Int64 = 4_000_000_000

    /// One depot being prefetched. Persisted as JSON (no credential: ids, sizes, hosts).
    struct Lane: Codable, Equatable {
        var target: String
        var depot: UInt32
        var appID: UInt32
        var manifest: UInt64
        /// HTTPS base URLs ("https://host"); chunks are spread over the first three.
        var servers: [String]
        /// Documents-relative staging directory (the container's absolute path can change).
        var stagingPath: String
        /// Chunks below this index the in-app run has taken (or is taking) itself.
        var front: Int
        /// Next chunk index to hand to the system; the lane works from the end backwards so
        /// the in-app run (from the start) and the system rarely fetch the same chunk.
        var nextTail: Int
        var count: Int
        var paused = false
        var needsToken = false
        /// Staged bytes this lane may hold: what the volume can spare beyond what the depot itself
        /// still needs (set at plan time), never more than `stagingCap`.
        var maxStaged: Int64? = nil
        /// Progress of the depot for the card while only the system works on it.
        var depotBytes: UInt64 = 0
        var doneBytes: UInt64 = 0
        var key: String { "\(target)/\(depot)" }
    }

    /// What the library shows per game.
    struct Status: Equatable {
        var lanes = 0
        var inFlight = 0
        var staged = 0
        var stagedBytes: UInt64 = 0          // uncompressed
        var remaining = 0                     // chunks not yet handed to the system
        var paused = false
        var needsToken = false
        var depotBytes: UInt64 = 0
        var doneBytes: UInt64 = 0
        /// Something is (or will be) fetched by the system for this game.
        var active: Bool { lanes > 0 && !paused && !needsToken && (inFlight > 0 || remaining > 0) }
        var fraction: Double? {
            guard depotBytes > 0 else { return nil }
            return min(1, Double(doneBytes + stagedBytes) / Double(depotBytes))
        }
    }

    private let q = DispatchQueue(label: "kl.bgdl", qos: .utility)
    private let delegateQueue: OperationQueue = {
        let o = OperationQueue()
        o.maxConcurrentOperationCount = 1
        o.qualityOfService = .utility
        o.name = "kl.bgdl.delegate"
        return o
    }()
    private var session: URLSession?
    private var lanes: [String: Lane] = [:]
    /// Per lane: chunk ids in order, with (compressed, uncompressed) sizes.
    private var chunks: [String: [(id: String, comp: UInt32, uncomp: UInt32)]] = [:]
    private var uncompressedByID: [String: [String: UInt32]] = [:]
    private var staged: [String: Set<String>] = [:]
    private var stagedBytes: [String: Int64] = [:]       // on-disk (compressed) bytes, for the cap
    private var stagedUncompressed: [String: UInt64] = [:]
    private var inFlight: [String: [String: URLSessionDownloadTask]] = [:]
    private var attempts: [String: Int] = [:]
    private var reconnected = false
    /// When each lane's staging directory was last listed (the in-app run deletes what it uses).
    private var lastScan: [String: Date] = [:]
    /// Lane key -> staging directory, readable WITHOUT `q`: the session's delegate moves a
    /// finished chunk with it. The delegate must never wait for `q` — `q` calls into the session
    /// (task creation, resume, suspend) while the session may be waiting for its delegate, and
    /// a `q.sync` there deadlocked the lanes on the headset (no progress noted, nothing topped up).
    private let dirLock = NSLock()
    private var stagingDirs: [String: URL] = [:]
    private var gameRunning = false
    private var events: (() -> Void)?
    private var notifyPending = false
    private var persistPending: Set<String> = []
    /// What the UI reads (main thread), rebuilt on `q` whenever something changes: reading
    /// never waits for `q`, which may be busy handing a batch of tasks to the system.
    private let snapLock = NSLock()
    private var snapshot: [String: Status] = [:]

    // MARK: Lifecycle

    /// Creates the session (reconnecting to its tasks) and reloads the lanes. Idempotent.
    func activate() {
        q.sync { self.activateLocked() }
    }

    private func activateLocked() {
        guard session == nil else { return }
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: delegateQueue)
        loadLanes()
        rebuildSnapshot()
        NSLog("[bgdl] session up, \(lanes.count) lane(s) on disk")
        session?.getAllTasks { tasks in
            self.q.async { self.reconnect(tasks) }
        }
    }

    private func reconnect(_ tasks: [URLSessionTask]) {
        var adopted = 0, dropped = 0, resumed = 0
        for case let t as URLSessionDownloadTask in tasks {
            guard let (laneKey, id) = Self.parse(t.taskDescription), let lane = lanes[laneKey] else {
                t.cancel(); dropped += 1; continue
            }
            if staged[laneKey]?.contains(id) == true { t.cancel(); dropped += 1; continue }
            inFlight[laneKey, default: [:]][id] = t
            adopted += 1
            if t.state == .suspended, !lane.paused, !holdForGame {
                t.resume(); resumed += 1
            }
        }
        reconnected = true
        NSLog("[bgdl] reconnected: \(adopted) task(s) adopted (\(resumed) resumed), \(dropped) dropped")
        for k in lanes.keys { topUp(k) }
        notify()
    }

    func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == self.identifier else { completion(); return }
        q.async {
            self.events = completion
            self.activateLocked()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        q.async {
            let c = self.events
            self.events = nil
            self.flushPersist()
            NSLog("[bgdl] background events delivered")
            if let c { DispatchQueue.main.async { c() } }
        }
    }

    /// A game is about to boot. With "Pausar descargas mientras juegas" every task is suspended
    /// until the next launch of the hub; otherwise the system keeps going.
    func noteGameWillStart() {
        let pause = KLDownloadSettings.background && KLDownloadSettings.pauseWhilePlaying
        q.async {
            self.gameRunning = true
            if pause {
                var n = 0
                for (_, ts) in self.inFlight { for t in ts.values where t.state == .running { t.suspend(); n += 1 } }
                NSLog("[bgdl] game starting: \(n) task(s) suspended until the hub opens again")
            } else {
                NSLog("[bgdl] game starting: background downloads continue")
            }
        }
        NotificationCenter.default.post(name: Self.gameWillStart, object: nil)
    }

    private var holdForGame: Bool { gameRunning && KLDownloadSettings.pauseWhilePlaying }

    // MARK: Lanes

    /// The in-app run's plan for one depot: hand its chunks (from the end) to the system.
    /// Replaces an earlier lane of the same depot; staged chunks and tasks in flight are kept.
    func setLane(target: String, depot: UInt32, appID: UInt32, manifest: UInt64, servers: [String],
                 staging: URL, chunks list: [(id: String, comp: UInt32, uncomp: UInt32)], workers: Int, needsToken: Bool,
                 depotBytes: UInt64 = 0, presentBytes: UInt64 = 0) {
        // The depot's files are sparse until written: free space must still hold everything the
        // plan writes, plus a margin, before any of it goes to staging.
        let need = list.reduce(Int64(0)) { $0 + Int64($1.uncomp) } + 2_000_000_000
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]     // same volume
        let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let spare = free.map { max(0, $0 - need) }
        let rel = Self.relativeToDocuments(staging)
        q.async {
            self.activateLocked()
            let key = "\(target)/\(depot)"
            let old = self.lanes[key]
            var lane = Lane(target: target, depot: depot, appID: appID, manifest: manifest,
                            servers: Array(servers.filter { $0.hasPrefix("https://") }.prefix(3)),
                            stagingPath: rel, front: min(list.count, workers), nextTail: list.count - 1,
                            count: list.count, paused: false, needsToken: needsToken)
            lane.maxStaged = spare.map { min(self.stagingCap, $0) }
            // What the depot weighs and what of it is on disk, from the plan itself: the card has a
            // figure before (and without) the in-app run's first progress report.
            lane.depotBytes = depotBytes > 0 ? depotBytes : old?.depotBytes ?? 0
            lane.doneBytes = depotBytes > 0 ? presentBytes : old?.doneBytes ?? 0
            if lane.servers.isEmpty { lane.needsToken = true }
            self.lanes[key] = lane
            self.setStagingDir(key, self.stagingURL(lane))
            self.chunks[key] = list
            self.uncompressedByID[key] = Dictionary(list.map { ($0.id, $0.uncomp) }, uniquingKeysWith: { a, _ in a })
            try? FileManager.default.createDirectory(at: self.stagingURL(lane), withIntermediateDirectories: true)
            self.scanStaging(key)
            self.writeChunkList(key)
            self.persist(key, now: true)
            // Tasks from an earlier plan for chunks this one no longer needs are dropped.
            if let ts = self.inFlight[key] {
                let wanted = Set(list.map(\.id))
                for (id, t) in ts where !wanted.contains(id) { t.cancel(); self.inFlight[key]?[id] = nil }
            }
            NSLog("[bgdl] lane \(key): \(list.count) chunk(s) planned, \(self.staged[key]?.count ?? 0) already staged, "
                  + "staging up to \(String(format: "%.1f GB", Double(lane.maxStaged ?? self.stagingCap) / 1e9)), "
                  + "servers \(lane.servers.compactMap { URL(string: $0)?.host }.joined(separator: ", "))"
                  + (lane.needsToken ? " — CDN token needed: the system does not fetch this depot" : ""))
            self.topUp(key)
            self.notify()
        }
    }

    /// The in-app run's position: chunks below `front` are its own; `done` of `depot` bytes are written.
    /// `chunksDone` counts only what it fetched itself in plan order — the staged chunks it took
    /// (from the lane's end) say nothing about how far its own cursor got.
    /// The staging directory is listed again now and then: every staged chunk the run assembled
    /// is gone from it, and that room goes back to the lane (top-up).
    func noteProgress(target: String, depot: UInt32, chunksDone: Int, workers: Int, doneBytes: UInt64, depotBytes: UInt64) {
        q.async {
            let key = "\(target)/\(depot)"
            guard var lane = self.lanes[key] else { return }
            lane.front = min(lane.count, max(lane.front, chunksDone + workers))
            lane.doneBytes = doneBytes
            lane.depotBytes = depotBytes
            self.lanes[key] = lane
            self.persist(key, now: false)
            if Date().timeIntervalSince(self.lastScan[key] ?? .distantPast) >= 3 {
                self.scanStaging(key)
                self.topUp(key)
            }
            self.notify()
        }
    }

    /// The depot is complete: the lane, its tasks and whatever is still staged go.
    func clearLane(target: String, depot: UInt32) {
        q.async { self.clearLocked("\(target)/\(depot)", why: "depot complete") }
    }

    /// Every lane of a game (its data is being deleted).
    func clearLanes(target: String) {
        q.async {
            for k in self.lanes.keys where self.lanes[k]?.target == target { self.clearLocked(k, why: "game data deleted") }
        }
    }

    private func clearLocked(_ key: String, why: String) {
        for t in (inFlight[key] ?? [:]).values { t.cancel() }
        inFlight[key] = nil
        if let lane = lanes[key] { try? FileManager.default.removeItem(at: stagingURL(lane)) }
        lanes[key] = nil; chunks[key] = nil; uncompressedByID[key] = nil; lastScan[key] = nil
        setStagingDir(key, nil)
        staged[key] = nil; stagedBytes[key] = nil; stagedUncompressed[key] = nil
        try? FileManager.default.removeItem(at: laneURL(key))
        try? FileManager.default.removeItem(at: listURL(key))
        NSLog("[bgdl] lane \(key) cleared (\(why))")
        notify()
    }

    /// Pause (suspend the tasks, hand out no more) or resume a game's lanes.
    func setPaused(target: String, _ paused: Bool) {
        q.async {
            for k in self.lanes.keys where self.lanes[k]?.target == target {
                self.lanes[k]?.paused = paused
                for t in (self.inFlight[k] ?? [:]).values {
                    if paused, t.state == .running { t.suspend() }
                    if !paused, t.state == .suspended, !self.holdForGame { t.resume() }
                }
                self.persist(k, now: true)
                if !paused { self.topUp(k) }
            }
            self.notify()
        }
    }

    /// Lanes on disk for a game (the hub resumes the in-app run to assemble them).
    func hasLanes(target: String) -> Bool { status(target: target).lanes > 0 }

    /// The staging directory the in-app run reads for `depot` (created on demand).
    func stagingDirectory(root: URL, depot: UInt32) -> URL {
        root.appendingPathComponent(".steamdepot/staging-\(depot)", isDirectory: true)
    }

    func status(target: String) -> Status { snapLock.withLock { snapshot[target] ?? Status() } }

    private func rebuildSnapshot() {
        var out: [String: Status] = [:]
        for (k, lane) in lanes {
            var s = out[lane.target] ?? Status()
            s.lanes += 1
            s.inFlight += inFlight[k]?.count ?? 0
            s.staged += staged[k]?.count ?? 0
            s.stagedBytes += stagedUncompressed[k] ?? 0
            s.remaining += max(0, lane.nextTail - lane.front + 1)
            s.paused = s.paused || lane.paused
            s.needsToken = s.needsToken || lane.needsToken
            s.depotBytes += lane.depotBytes
            s.doneBytes += lane.doneBytes
            out[lane.target] = s
        }
        snapLock.withLock { snapshot = out }
    }

    // MARK: Handing chunks to the system

    private func topUp(_ key: String) {
        guard reconnected, let session, var lane = lanes[key], let list = chunks[key] else { return }
        guard !lane.paused, !lane.needsToken, !holdForGame, !lane.servers.isEmpty else { return }
        var added = 0
        var flight = inFlight[key] ?? [:]
        let have = staged[key] ?? []
        var bytes = stagedBytes[key] ?? 0
        for t in flight.values { bytes += Int64(t.countOfBytesExpectedToReceive > 0 ? t.countOfBytesExpectedToReceive : 1_000_000) }
        let cap = min(stagingCap, lane.maxStaged ?? stagingCap)
        while flight.count < window, bytes < cap, lane.nextTail >= lane.front, lane.nextTail >= 0 {
            let i = lane.nextTail
            lane.nextTail -= 1
            guard i < list.count else { continue }
            let c = list[i]
            if have.contains(c.id) || flight[c.id] != nil { continue }
            let server = lane.servers[i % lane.servers.count]
            guard let url = URL(string: "\(server)/depot/\(lane.depot)/chunk/\(c.id)") else { continue }
            var r = URLRequest(url: url)
            r.setValue("Valve/Steam HTTP Client 1.0", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: r)
            task.taskDescription = "c|\(key)|\(c.id)"
            task.countOfBytesClientExpectsToReceive = Int64(c.comp)
            task.resume()
            flight[c.id] = task
            bytes += Int64(c.comp)
            added += 1
        }
        inFlight[key] = flight
        lanes[key] = lane
        if added > 0 {
            persist(key, now: true)
        }
        // One line per batch, not per chunk (a top-up follows every completion).
        if added >= 16 || (added > 0 && lane.nextTail < lane.front) {
            NSLog("[bgdl] lane \(key): \(added) chunk(s) handed to the system (\(flight.count) in flight, "
                  + "\(max(0, lane.nextTail - lane.front + 1)) left)")
        }
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone when this returns: move it now (one rename), on this queue.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard let (key, id) = Self.parse(downloadTask.taskDescription) else { return }
        var moved: URL?
        var size: Int64 = 0
        // Here, on the delegate queue, without `q` (see `stagingDirs`).
        if status == 200, let dir = stagingDir(key) {
            let dst = dir.appendingPathComponent(id)
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            if (try? fm.moveItem(at: location, to: dst)) != nil {
                moved = dst
                size = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        q.async {
            self.inFlight[key]?[id] = nil
            guard self.lanes[key] != nil else { return }
            if moved != nil {
                // A rescan may have counted it already.
                if self.staged[key, default: []].insert(id).inserted {
                    self.stagedBytes[key, default: 0] += size
                    self.stagedUncompressed[key, default: 0] += UInt64(self.uncompressedByID[key]?[id] ?? 0)
                }
            } else if status == 401 || status == 403 {
                // The server wants a CDN auth token: not something to hand to the system.
                self.lanes[key]?.needsToken = true
                for t in (self.inFlight[key] ?? [:]).values { t.cancel() }
                self.inFlight[key] = [:]
                self.persist(key, now: true)
                NSLog("[bgdl] lane \(key): HTTP \(status) from \(downloadTask.originalRequest?.url?.host ?? "?") — "
                      + "the server wants a CDN token; the in-app download fetches the rest")
            } else if status != 200 {
                NSLog("[bgdl] lane \(key): chunk HTTP \(status) — left to the in-app download")
            }
            self.topUp(key)
            self.notify()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (key, id) = Self.parse(task.taskDescription) else { return }
        let ns = error as NSError
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        q.async {
            guard self.inFlight[key]?[id]?.taskIdentifier == task.taskIdentifier else { return }
            self.inFlight[key]?[id] = nil
            if ns.code == NSURLErrorCancelled && resume == nil { return }
            let n = (self.attempts[id] ?? 0) + 1
            self.attempts[id] = n
            // Resume data stays in memory only (it names the chunk's address, nothing more).
            if let resume, n <= 3, let s = self.session, self.lanes[key] != nil {
                let t = s.downloadTask(withResumeData: resume)
                t.taskDescription = task.taskDescription
                self.inFlight[key, default: [:]][id] = t
                if !(self.lanes[key]?.paused ?? false), !self.holdForGame { t.resume() }
            } else if n <= 3, self.lanes[key] != nil, var lane = self.lanes[key] {
                // Hand it out again later (the cursor only moves down: put it back in reach).
                lane.nextTail = max(lane.nextTail, (self.chunks[key]?.firstIndex { $0.id == id }) ?? lane.nextTail)
                self.lanes[key] = lane
            }
            if n == 1 { NSLog("[bgdl] lane \(key): a chunk failed (\(ns.domain) \(ns.code)) — retried") }
            self.topUp(key)
        }
    }

    // MARK: Persistence (Application Support/bgdl)

    private var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bgdl", isDirectory: true)
    }
    private func fileStem(_ key: String) -> String { key.replacingOccurrences(of: "/", with: "-") }
    private func laneURL(_ key: String) -> URL { dir.appendingPathComponent(fileStem(key) + ".lane.json") }
    private func listURL(_ key: String) -> URL { dir.appendingPathComponent(fileStem(key) + ".chunks.tsv") }

    private func stagingURL(_ lane: Lane) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(lane.stagingPath, isDirectory: true)
    }

    static func relativeToDocuments(_ url: URL) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(docs + "/") ? String(p.dropFirst(docs.count + 1)) : p
    }

    private func persist(_ key: String, now: Bool) {
        if now { write(key) } else {
            let first = persistPending.isEmpty
            persistPending.insert(key)
            if first { q.asyncAfter(deadline: .now() + 2) { self.flushPersist() } }
        }
    }

    private func flushPersist() {
        let keys = persistPending
        persistPending = []
        for k in keys { write(k) }
    }

    private func write(_ key: String) {
        guard let lane = lanes[key] else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(lane) { try? d.write(to: laneURL(key), options: .atomic) }
    }

    private func writeChunkList(_ key: String) {
        guard let list = chunks[key] else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = list.map { "\($0.id)\t\($0.comp)\t\($0.uncomp)" }.joined(separator: "\n")
        try? Data(text.utf8).write(to: listURL(key), options: .atomic)
    }

    private func loadLanes() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where n.hasSuffix(".lane.json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                  let lane = try? JSONDecoder().decode(Lane.self, from: d) else { continue }
            let key = lane.key
            guard let text = try? String(contentsOf: listURL(key), encoding: .utf8) else { continue }
            let list: [(id: String, comp: UInt32, uncomp: UInt32)] = text.split(separator: "\n").compactMap { line in
                let p = line.split(separator: "\t")
                guard p.count == 3, let c = UInt32(p[1]), let u = UInt32(p[2]) else { return nil }
                return (String(p[0]), c, u)
            }
            lanes[key] = lane
            setStagingDir(key, stagingURL(lane))
            chunks[key] = list
            uncompressedByID[key] = Dictionary(list.map { ($0.id, $0.uncomp) }, uniquingKeysWith: { a, _ in a })
            scanStaging(key)
        }
    }

    private func setStagingDir(_ key: String, _ url: URL?) { dirLock.withLock { stagingDirs[key] = url } }
    private func stagingDir(_ key: String) -> URL? { dirLock.withLock { stagingDirs[key] } }

    private func scanStaging(_ key: String) {
        guard let lane = lanes[key] else { return }
        let fm = FileManager.default
        let d = stagingURL(lane)
        var ids = Set<String>(), bytes: Int64 = 0, unc: UInt64 = 0
        for n in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] {
            let size = (try? fm.attributesOfItem(atPath: d.appendingPathComponent(n).path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { continue }
            ids.insert(n)
            bytes += size
            unc += UInt64(uncompressedByID[key]?[n] ?? 0)
        }
        staged[key] = ids
        stagedBytes[key] = bytes
        stagedUncompressed[key] = unc
        lastScan[key] = Date()
    }

    // MARK: Helpers

    /// "c|<target>/<depot>|<chunk id>" -> (lane key, chunk id)
    static func parse(_ description: String?) -> (String, String)? {
        guard let p = description?.split(separator: "|", omittingEmptySubsequences: false), p.count == 3, p[0] == "c" else { return nil }
        return (String(p[1]), String(p[2]))
    }

    private func notify() {
        rebuildSnapshot()
        guard !notifyPending else { return }
        notifyPending = true
        q.asyncAfter(deadline: .now() + 0.5) {
            self.notifyPending = false
            self.rebuildSnapshot()
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }
}
#endif
