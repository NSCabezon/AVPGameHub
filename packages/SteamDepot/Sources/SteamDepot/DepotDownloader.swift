import Foundation
import CryptoKit

public struct DepotDownloadOptions: Sendable {
    public var appID: UInt32
    public var depotID: UInt32
    public var branch: String
    /// Fetch exactly this manifest gid instead of `branch`'s latest (SupportedTitle.pinned).
    /// nil = latest on `branch`.
    public var pinnedManifestID: UInt64?
    /// Install root. Depot paths are relative to it (e.g. "game/hlvr/…").
    public var directory: URL
    /// Only files whose path starts with one of these prefixes (case-insensitive). Empty = all.
    public var filters: [String]
    /// Optional extra predicate on the depot-relative path ('/' separators). false = skip the file.
    public var include: (@Sendable (String) -> Bool)?
    public var maxConcurrentDownloads: Int
    /// Parallel hashing width for the verify/adopt phase.
    public var verifyConcurrency: Int
    /// Re-hash every finished file with SHA-1 after download (chunks are always checked on arrival).
    public var verifyFiles: Bool
    /// Ignore the resume state and re-verify every file on disk against the manifest.
    public var forceVerify: Bool
    /// Refuse to start when the volume cannot hold what remains (+ margin).
    public var checkFreeSpace: Bool
    public var freeSpaceMargin: UInt64
    /// Raw CDN chunk files (encrypted + compressed, exactly as the CDN serves them) fetched by
    /// someone else — the hub's system background downloads — named by chunk id (hex). Each is
    /// decrypted, decompressed and checked like a network chunk, then deleted; one that fails
    /// is deleted and fetched from the network instead. nil = network only.
    public var stagingDirectory: URL?
    /// Called once, after the verify/adopt phase, with the chunks this run is about to fetch (in
    /// the order the workers take them) and the CDN servers it uses. Not called when nothing is
    /// missing.
    public var onChunkPlan: (@Sendable (ChunkPlan) -> Void)?

    public init(appID: UInt32, depotID: UInt32, branch: String = "public", directory: URL,
                filters: [String] = [], include: (@Sendable (String) -> Bool)? = nil,
                maxConcurrentDownloads: Int = 12, verifyConcurrency: Int = 4, verifyFiles: Bool = false,
                forceVerify: Bool = false, checkFreeSpace: Bool = true, freeSpaceMargin: UInt64 = 1 << 30,
                pinnedManifestID: UInt64? = nil) {
        self.appID = appID
        self.pinnedManifestID = pinnedManifestID
        self.depotID = depotID
        self.branch = branch
        self.directory = directory
        self.filters = filters
        self.include = include
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.verifyConcurrency = verifyConcurrency
        self.verifyFiles = verifyFiles
        self.forceVerify = forceVerify
        self.checkFreeSpace = checkFreeSpace
        self.freeSpaceMargin = freeSpaceMargin
    }
}

/// What a run is about to fetch: enough for another HTTP client to fetch the same raw chunks
/// (`<server>/depot/<depot>/chunk/<id>`). Holds no credential: the chunks are encrypted with the
/// depot key, which never leaves the downloader. `needsCDNToken` = a server asked for a CDN auth
/// token while this run planned (such chunks cannot be fetched without one).
public struct ChunkPlan: Sendable {
    public struct Chunk: Sendable, Equatable {
        public let id: String
        public let compressedLength: UInt32
        public let uncompressedLength: UInt32
    }
    public let appID: UInt32
    public let depotID: UInt32
    public let manifestID: UInt64
    /// HTTPS base URLs ("https://host"), best first. Plain-HTTP servers are left out.
    public let servers: [String]
    public let chunks: [Chunk]
    /// How many chunks the run fetches at once: it is about `workers` chunks past `chunksDone`.
    public let workers: Int
    public let needsCDNToken: Bool
    /// Uncompressed bytes of the whole (filtered) depot, and what of it was already on disk when
    /// this run planned (depotBytes minus what `chunks` writes).
    public var depotBytes: UInt64 = 0
    public var presentBytes: UInt64 = 0

    public static func chunkPath(depot: UInt32, id: String) -> String { "depot/\(depot)/chunk/\(id)" }
}

public struct DownloadProgress: Sendable {
    public enum Phase: String, Sendable { case preparing, verifying, downloading, finished }
    public var phase: Phase = .preparing
    public var message = ""
    public var totalFiles = 0
    public var completedFiles = 0
    /// Uncompressed bytes the whole (filtered) depot occupies.
    public var depotBytes: UInt64 = 0
    // verify / adopt phase
    public var verifyFilesTotal = 0
    public var verifyFilesDone = 0
    public var verifyBytesTotal: UInt64 = 0
    public var verifyBytesDone: UInt64 = 0
    public var verifyElapsed: TimeInterval = 0
    // download phase
    /// Uncompressed bytes that had to be fetched this run.
    public var bytesToDownload: UInt64 = 0
    public var bytesDownloaded: UInt64 = 0
    /// Bytes received over the network (compressed+encrypted).
    public var networkBytes: UInt64 = 0
    /// Chunks taken from `stagingDirectory` instead of the network.
    public var chunksFromStaging = 0
    public var chunksTotal = 0
    public var chunksDone = 0
    /// Seconds since the download phase started.
    public var elapsed: TimeInterval = 0

    public init() {}
}

public struct DownloadSummary: Sendable {
    public let manifestID: UInt64
    public let files: Int
    public let skippedFiles: Int
    public let bytesDownloaded: UInt64
    public let networkBytes: UInt64
    public let verifiedBytes: UInt64
    public let verifyElapsed: TimeInterval
    public let elapsed: TimeInterval
    public let chunkFormats: [String: Int]
}

public struct DepotInfo: Sendable {
    public let depotID: UInt32
    public let name: String?
    public let osList: [String]
    public let manifestID: UInt64?
    public let maxSize: UInt64?
}

/// What is on disk for a depot, judged without any network access.
public struct LocalContentStatus: Sendable {
    /// A completion marker exists (written after a successful download/verify).
    public let markerManifestID: UInt64?
    /// A file list from a previous manifest fetch exists.
    public let hasFileList: Bool
    public let totalFiles: Int
    public let presentFiles: Int          // present with the exact expected size
    public let totalBytes: UInt64
    /// Bytes actually written. A download pre-sizes every file it plans (sparse until its chunks
    /// land), so a file at the expected size is not yet a downloaded file: until the depot is
    /// complete this counts the blocks a file holds (capped at its size), not its length.
    public let presentBytes: UInt64
    /// Marker present and every listed file present at the right size.
    public var isComplete: Bool { markerManifestID != nil && hasFileList && presentFiles == totalFiles }
}

/// Downloads a depot from the Steam CDN into a directory, resumably, adopting
/// any byte-identical files already there (e.g. copied in by other means).
public final class SteamDepotDownloader: @unchecked Sendable {
    public let session: SteamSession
    private let log: @Sendable (String) -> Void

    public init(session: SteamSession, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session
        self.log = log
    }

    // MARK: depot discovery

    public func depots(app: UInt32, branch: String = "public") async throws -> [DepotInfo] {
        let info = try await session.appInfo(app: app)
        guard let depots = info["depots"] else { return [] }
        return depots.children.compactMap { d in
            guard let id = UInt32(d.name) else { return nil }
            let os = d["config"]?["oslist"]?.value?.split(separator: ",").map(String.init) ?? []
            return DepotInfo(depotID: id, name: d["name"]?.value, osList: os,
                             manifestID: Self.manifestGID(d, branch: branch),
                             maxSize: d["maxsize"]?.value.flatMap { UInt64($0) })
        }
    }

    /// Whether Steam's public build moved past a title's pins. Reads PICS only; downloads nothing.
    public func updateStatus(app: UInt32, pins: ManifestPins) async throws -> ManifestUpdateStatus {
        ManifestUpdateStatus.check(pins: pins, appInfo: try await session.appInfo(app: app))
    }

    static func manifestGID(_ depot: KeyValue, branch: String) -> UInt64? {
        guard let b = depot["manifests"]?[branch] else { return nil }
        if let gid = b["gid"]?.value { return UInt64(gid) }
        return b.value.flatMap { UInt64($0) }
    }

    // MARK: offline status

    static func stateDir(_ root: URL) -> URL { root.appendingPathComponent(".steamdepot", isDirectory: true) }
    static func markerURL(_ root: URL, depot: UInt32) -> URL { stateDir(root).appendingPathComponent("\(depot).complete") }
    static func fileListURL(_ root: URL, depot: UInt32) -> URL { stateDir(root).appendingPathComponent("\(depot).files.tsv") }

    /// Fast, offline check (stat only) of what is installed under `directory` for `depot`.
    public static func localStatus(directory: URL, depot: UInt32) -> LocalContentStatus {
        var marker: UInt64?
        if let s = try? String(contentsOf: markerURL(directory, depot: depot), encoding: .utf8) {
            marker = s.split(separator: "\n").first.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard let list = try? String(contentsOf: fileListURL(directory, depot: depot), encoding: .utf8) else {
            return LocalContentStatus(markerManifestID: marker, hasFileList: false, totalFiles: 0, presentFiles: 0,
                                      totalBytes: 0, presentBytes: 0)
        }
        var total = 0, present = 0
        var totalBytes: UInt64 = 0, presentBytes: UInt64 = 0
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let size = UInt64(parts[0]) else { continue }
            total += 1
            totalBytes += size
            var st = stat()
            let path = directory.appendingPathComponent(String(parts[2])).path
            guard stat(path, &st) == 0 else { continue }
            if UInt64(st.st_size) == size { present += 1 }
            // Complete depot (marker): every file counts whole (a copy may keep holes for zero runs).
            // Otherwise what the file holds: a planned file is sparse until its chunks are written.
            presentBytes += marker != nil && UInt64(st.st_size) == size
                ? size : min(size, UInt64(st.st_size), UInt64(max(0, st.st_blocks)) * 512)
        }
        return LocalContentStatus(markerManifestID: marker, hasFileList: true, totalFiles: total, presentFiles: present,
                                  totalBytes: totalBytes, presentBytes: presentBytes)
    }

    // MARK: download

    public func download(_ opt: DepotDownloadOptions,
                         progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> DownloadSummary {
        let fm = FileManager.default
        try fm.createDirectory(at: opt.directory, withIntermediateDirectories: true)
        let stateDir = Self.stateDir(opt.directory)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        var prog = DownloadProgress()
        func status(_ m: String) { prog.message = m; progress(prog); log(m) }

        // 1. Resolve manifest id from PICS.
        status("Reading app info…")
        let info = try await session.appInfo(app: opt.appID)
        guard let depotNode = info["depots"]?[String(opt.depotID)] else {
            throw SteamDepotError.notOwned("depot \(opt.depotID) not listed in app \(opt.appID)")
        }
        let gid: UInt64
        if let pinned = opt.pinnedManifestID {
            gid = pinned
            log("depot \(opt.depotID) manifest \(gid) (pinned)")
        } else {
            guard let latest = Self.manifestGID(depotNode, branch: opt.branch) else {
                throw SteamDepotError.notOwned("no manifest for depot \(opt.depotID) branch \(opt.branch)")
            }
            gid = latest
            log("depot \(opt.depotID) manifest \(gid) (branch \(opt.branch))")
        }

        // 2. Depot key (proves ownership).
        status("Checking ownership…")
        let key = try await session.depotKey(depot: opt.depotID, app: opt.appID)

        // 3. CDN servers.
        let servers = try await cdnServers(app: opt.appID)
        log("CDN servers: " + servers.prefix(4).map(\.description).joined(separator: ", "))
        let cdn = CDNClient(servers: servers, depot: opt.depotID, app: opt.appID, session: session,
                            maxConnections: opt.maxConcurrentDownloads, log: log)

        // 4. Manifest (cached on disk; request codes expire after a few minutes).
        status("Fetching manifest…")
        let manifestCache = stateDir.appendingPathComponent("\(opt.depotID)_\(gid).manifest")
        let raw: Data
        if let cached = try? Data(contentsOf: manifestCache) {
            raw = cached
            log("using cached manifest")
        } else {
            let code = try await session.manifestRequestCode(app: opt.appID, depot: opt.depotID, manifest: gid, branch: opt.branch)
            let path = code > 0 ? "depot/\(opt.depotID)/manifest/\(gid)/5/\(code)" : "depot/\(opt.depotID)/manifest/\(gid)/5"
            let zipped = try await cdn.get(path, worker: 0)
            raw = try Inflate.unzipFirst(zipped)
            try raw.write(to: manifestCache, options: .atomic)
        }
        var manifest = try DepotManifest.parse(raw)
        try manifest.decryptFilenames(key: key)
        log("manifest: \(manifest.files.count) entries, \(manifest.totalUncompressed) bytes, created \(manifest.creationTime)")

        let filters = opt.filters.map { $0.lowercased().replacingOccurrences(of: "\\", with: "/") }
        let files = manifest.files.filter { f in
            (filters.isEmpty || filters.contains { f.name.lowercased().hasPrefix($0) }) && (opt.include?(f.name) ?? true)
        }
        let regular = files.filter { !$0.isDirectory && !$0.isSymlink }

        // The (filtered) file list for offline status checks. A new manifest invalidates the marker.
        let listData = Data(regular.map { "\($0.size)\t\($0.shaContent.hex)\t\($0.name)" }.joined(separator: "\n").utf8)
        let markerURL = Self.markerURL(opt.directory, depot: opt.depotID)
        if (try? Data(contentsOf: Self.fileListURL(opt.directory, depot: opt.depotID))) != listData {
            try? fm.removeItem(at: markerURL)
            try listData.write(to: Self.fileListURL(opt.directory, depot: opt.depotID), options: .atomic)
        }

        // 5. Directories, symlinks.
        for f in files where f.isDirectory {
            try fm.createDirectory(at: opt.directory.appendingPathComponent(f.name), withIntermediateDirectories: true)
        }
        for f in files where f.isSymlink {
            let url = opt.directory.appendingPathComponent(f.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
            if let target = f.linkTarget { try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target) }
        }

        // 6. Verify / adopt what is already on disk.
        prog.totalFiles = regular.count
        prog.depotBytes = regular.reduce(0) { $0 + $1.size }
        let state = ResumeState(url: stateDir.appendingPathComponent("\(opt.depotID)_\(gid).done"))
        defer { state.flush() }
        let plans = try await planFiles(regular, root: opt.directory, state: state, force: opt.forceVerify,
                                        width: max(1, opt.verifyConcurrency), base: prog, progress: progress)
        var skipped = 0
        for (i, p) in plans.enumerated() where p.missing.isEmpty {
            skipped += 1
            if !p.fromState {
                state.markDone(regular[i])
                if regular[i].isExecutable { Self.setExecutable(opt.directory.appendingPathComponent(regular[i].name)) }
            }
        }
        state.flush()
        prog.verifyFilesTotal = plans.filter(\.hashed).count
        prog.verifyFilesDone = prog.verifyFilesTotal
        prog.verifyBytesTotal = plans.reduce(0) { $0 + $1.hashedBytes }
        prog.verifyBytesDone = prog.verifyBytesTotal
        prog.verifyElapsed = plans.first?.verifyElapsed ?? 0

        // 7. Group missing chunks by chunk id (chunks are deduplicated across files).
        struct Target { let file: Int; let offset: UInt64 }
        var jobs: [String: (chunk: DepotManifest.Chunk, targets: [Target])] = [:]
        var order: [String] = []
        var remainingPerFile = [Int](repeating: 0, count: regular.count)
        for (i, p) in plans.enumerated() {
            remainingPerFile[i] = p.missing.count
            for c in p.missing {
                if jobs[c.id] == nil { jobs[c.id] = (c, []); order.append(c.id) }
                jobs[c.id]!.targets.append(Target(file: i, offset: c.offset))
            }
        }
        prog.completedFiles = skipped
        prog.chunksTotal = order.count
        prog.bytesToDownload = order.reduce(0) { $0 + UInt64(jobs[$1]!.chunk.uncompressedLength) }
        log("\(skipped)/\(regular.count) files already complete; \(order.count) chunks (\(prog.bytesToDownload) bytes) to fetch")

        // 8. Free space (files are sparse until written, so what remains is what is needed).
        if opt.checkFreeSpace, prog.bytesToDownload > 0, let free = Self.availableCapacity(opt.directory) {
            let needed = prog.bytesToDownload + opt.freeSpaceMargin
            if free < needed { throw SteamDepotError.insufficientSpace(needed: needed, available: free) }
        }

        if let onPlan = opt.onChunkPlan, !order.isEmpty {
            let https = servers.filter { $0.baseURL.hasPrefix("https://") }.map(\.baseURL)
            onPlan(ChunkPlan(appID: opt.appID, depotID: opt.depotID, manifestID: gid, servers: https,
                             chunks: order.map { id in
                                 let c = jobs[id]!.chunk
                                 return .init(id: id, compressedLength: c.compressedLength, uncompressedLength: c.uncompressedLength)
                             },
                             workers: max(1, opt.maxConcurrentDownloads), needsCDNToken: cdn.usedAuthToken,
                             depotBytes: prog.depotBytes,
                             presentBytes: prog.depotBytes - min(prog.depotBytes, prog.bytesToDownload)))
        }

        // 9. Download with bounded concurrency.
        prog.phase = .downloading
        prog.message = order.isEmpty ? "All files verified" : "Downloading…"
        progress(prog)
        let start = Date()
        let tracker = Tracker(progress: prog, remainingPerFile: remainingPerFile, start: start, callback: progress)
        let queue = JobQueue(order, staging: opt.stagingDirectory)
        let root = opt.directory
        let verify = opt.verifyFiles
        let staging = opt.stagingDirectory
        let workers = max(1, opt.maxConcurrentDownloads)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for w in 0..<workers {
                group.addTask {
                    while let id = await queue.next() {
                        try Task.checkCancellation()
                        let job = jobs[id]!
                        let (data, net, format) = try await cdn.fetchChunk(job.chunk, key: key, worker: w, staging: staging)
                        for t in job.targets {
                            try Self.write(data, to: root.appendingPathComponent(regular[t.file].name), offset: t.offset)
                        }
                        let finished = tracker.chunkDone(bytes: UInt64(data.count), network: UInt64(net), format: format,
                                                         files: job.targets.map(\.file), staged: net == 0)
                        for fi in finished {
                            let f = regular[fi]
                            let url = root.appendingPathComponent(f.name)
                            if verify {
                                let sha = try Self.sha1(of: url)
                                if sha != f.shaContent { throw SteamDepotError.corrupt("SHA-1 mismatch for \(f.name)") }
                            }
                            if f.isExecutable { Self.setExecutable(url) }
                            state.markDone(f)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        state.flush()
        // Completion marker: manifest id on the first line.
        try "\(gid)\n\(regular.count) files\n\(prog.depotBytes) bytes\n\(ISO8601DateFormatter().string(from: Date()))\n"
            .write(to: markerURL, atomically: true, encoding: .utf8)
        let final = tracker.finish()
        return DownloadSummary(manifestID: gid, files: regular.count, skippedFiles: skipped,
                               bytesDownloaded: final.bytesDownloaded, networkBytes: final.networkBytes,
                               verifiedBytes: prog.verifyBytesTotal, verifyElapsed: prog.verifyElapsed,
                               elapsed: Date().timeIntervalSince(start), chunkFormats: tracker.formats)
    }

    /// A depot's manifest (file list) only: depot key + manifest request code + one CDN
    /// fetch, decrypted filenames. Writes nothing and downloads no content chunks.
    public func fetchManifest(app: UInt32, depot: UInt32, manifest gid: UInt64, branch: String = "public") async throws -> DepotManifest {
        let key = try await session.depotKey(depot: depot, app: app)
        // One server list for many listings (frame-scan lists hundreds); filtered per app below.
        var all = lock.withLock { cachedServers }
        if all == nil {
            let fetched = try await session.cdnServers()
            lock.withLock { cachedServers = fetched }
            all = fetched
        }
        let servers = all!.filter { ($0.type == "SteamCache" || $0.type == "CDN") && ($0.allowedAppIDs.isEmpty || $0.allowedAppIDs.contains(app)) }
            .sorted { $0.weightedLoad < $1.weightedLoad }
        guard !servers.isEmpty else { throw SteamDepotError.cdn("no usable CDN servers") }
        let cdn = CDNClient(servers: servers, depot: depot, app: app, session: session, maxConnections: 4, log: log)
        let code = try await session.manifestRequestCode(app: app, depot: depot, manifest: gid, branch: branch)
        let path = code > 0 ? "depot/\(depot)/manifest/\(gid)/5/\(code)" : "depot/\(depot)/manifest/\(gid)/5"
        var manifest = try DepotManifest.parse(try Inflate.unzipFirst(try await cdn.get(path, worker: 0)))
        try manifest.decryptFilenames(key: key)
        return manifest
    }

    private let lock = NSLock()
    private var cachedServers: [CDNServer]?

    private func cdnServers(app: UInt32) async throws -> [CDNServer] {
        let all = try await session.cdnServers()
        let ok = all.filter { ($0.type == "SteamCache" || $0.type == "CDN") && ($0.allowedAppIDs.isEmpty || $0.allowedAppIDs.contains(app)) }
            .sorted { $0.weightedLoad < $1.weightedLoad }
        guard !ok.isEmpty else { throw SteamDepotError.cdn("no usable CDN servers (got \(all.map(\.description)))") }
        return ok
    }

    static func availableCapacity(_ url: URL) -> UInt64? {
        #if os(macOS)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity { return UInt64(v) }
        return nil
        #else
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage { return UInt64(v) }
        return nil
        #endif
    }

    // MARK: verify / adopt

    struct FilePlan {
        var missing: [DepotManifest.Chunk]
        var fromState: Bool
        var hashed = false
        var hashedBytes: UInt64 = 0
        var verifyElapsed: TimeInterval = 0
    }

    /// Decide per file what is missing. Files recorded in the resume state with the right size are
    /// trusted; anything else on disk is checked chunk by chunk (SHA-1 of each chunk == chunk id), so
    /// byte-identical content copied in by other means is adopted and only bad/missing chunks are fetched.
    private func planFiles(_ files: [DepotManifest.File], root: URL, state: ResumeState, force: Bool, width: Int,
                           base: DownloadProgress, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> [FilePlan] {
        let doneSet = force ? [] : state.load()
        // Cheap stat pre-pass to size the hashing work.
        var onDisk = [UInt64?](repeating: nil, count: files.count)
        var hashTotal: UInt64 = 0, hashFiles = 0
        for (i, f) in files.enumerated() {
            var st = stat()
            let path = root.appendingPathComponent(f.name).path
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                let size = UInt64(st.st_size)
                onDisk[i] = size
                if !(size == f.size && doneSet.contains(ResumeState.key(f))) && size > 0 && f.size > 0 {
                    hashTotal += min(size, f.size)
                    hashFiles += 1
                }
            }
        }
        var p = base
        p.phase = .verifying
        p.message = hashFiles > 0 ? "Verifying existing files…" : "Preparing…"
        p.verifyFilesTotal = hashFiles
        p.verifyBytesTotal = hashTotal
        progress(p)
        let meter = VerifyMeter(progress: p, callback: progress)
        let doneSetCopy = doneSet
        let onDiskCopy = onDisk

        let results: [FilePlan] = try await withThrowingTaskGroup(of: (Int, FilePlan).self) { group in
            var results = [FilePlan?](repeating: nil, count: files.count)
            var next = 0
            func add() {
                guard next < files.count else { return }
                let i = next, f = files[i]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (i, try Self.plan(f, root: root, onDisk: onDiskCopy[i], done: doneSetCopy, meter: meter))
                }
            }
            // Big files first would starve the meter; manifest order (alphabetical) is fine.
            for _ in 0..<width { add() }
            while let (i, plan) = try await group.next() {
                results[i] = plan
                add()
            }
            return results.map { $0! }
        }
        let elapsed = meter.finish()
        var out = results
        if !out.isEmpty { out[0].verifyElapsed = elapsed }
        return out
    }

    static func plan(_ f: DepotManifest.File, root: URL, onDisk: UInt64?, done: Set<String>, meter: VerifyMeter) throws -> FilePlan {
        let url = root.appendingPathComponent(f.name)
        let path = url.path
        if let size = onDisk, size == f.size, done.contains(ResumeState.key(f)) {
            return FilePlan(missing: [], fromState: true)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw SteamDepotError.corrupt("cannot open \(path): errno \(errno)") }
        defer { close(fd) }
        let existing = onDisk ?? 0
        if existing != f.size { ftruncate(fd, off_t(f.size)) }
        if existing == 0 || f.size == 0 { return FilePlan(missing: f.chunks, fromState: false) }

        // Per-chunk SHA-1 of what is there; only chunks entirely inside the old size can be good.
        var missing: [DepotManifest.Chunk] = []
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var hashed: UInt64 = 0
        for c in f.chunks {
            try Task.checkCancellation()
            let len = Int(c.uncompressedLength)
            guard c.offset + UInt64(len) <= existing else { missing.append(c); continue }
            // A planned file is pre-sized and stays sparse until its chunks land: a chunk that
            // lies entirely in a hole was never written, no need to read and hash it (a resumed
            // 70 GB download would otherwise hash ~70 GB of zeros before fetching anything).
            if len > 0 {
                let data = lseek(fd, off_t(c.offset), SEEK_DATA)
                if data < 0 ? errno == ENXIO : UInt64(data) >= c.offset + UInt64(len) { missing.append(c); continue }
            }
            if buf.count < len { buf = [UInt8](repeating: 0, count: len) }
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, len, off_t(c.offset)) }
            hashed += UInt64(max(0, n))
            meter.add(UInt64(max(0, n)))
            let ok = n == len && buf.withUnsafeBytes { Data(Insecure.SHA1.hash(data: UnsafeRawBufferPointer(rebasing: $0[0..<len]))) } == c.sha
            if !ok { missing.append(c) }
        }
        meter.fileDone()
        // Chunks normally tile the file; if they don't, also require the whole-file hash.
        if missing.isEmpty && !chunksTile(f) {
            if (try? sha1(of: url)) != f.shaContent { missing = f.chunks }
        }
        return FilePlan(missing: missing, fromState: false, hashed: true, hashedBytes: hashed)
    }

    static func chunksTile(_ f: DepotManifest.File) -> Bool {
        var pos: UInt64 = 0
        for c in f.chunks {
            guard c.offset == pos else { return false }
            pos += UInt64(c.uncompressedLength)
        }
        return pos == f.size
    }

    // MARK: file helpers

    static func write(_ data: Data, to url: URL, offset: UInt64) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw SteamDepotError.corrupt("cannot open \(url.path): errno \(errno)") }
        defer { close(fd) }
        let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard n == data.count else { throw SteamDepotError.corrupt("short write to \(url.path): errno \(errno)") }
    }

    static func sha1(of url: URL) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = Insecure.SHA1()
        while let d = try fh.read(upToCount: 4 << 20), !d.isEmpty { h.update(data: d) }
        return Data(h.finalize())
    }

    static func setExecutable(_ url: URL) { chmod(url.path, 0o755) }
}

/// Work queue of chunk ids. With a staging directory, chunks someone else already fetched (the
/// hub's background session, which works from the END of the plan) go first, whatever their place
/// in the plan: they cost no network, assembling them frees the staging space that other client
/// needs to go on, and the bytes show up in the game's files right away instead of only when the
/// in-order run reaches the tail. The directory is listed again every `rescan` seconds, so chunks
/// staged while this run is going are taken as they land.
actor JobQueue {
    private let items: [String]
    private var idx = 0
    private let staging: URL?
    private let rescan: TimeInterval
    private let wanted: Set<String>
    private var taken = Set<String>()
    private var staged: [String] = []
    private var lastScan = Date.distantPast

    init(_ items: [String], staging: URL? = nil, rescan: TimeInterval = 2) {
        self.items = items
        self.staging = staging
        self.rescan = rescan
        self.wanted = staging == nil ? [] : Set(items)
    }

    func next() -> String? {
        if staging != nil {
            if Date().timeIntervalSince(lastScan) >= rescan { scan() }
            while let id = staged.popLast() {
                if taken.insert(id).inserted { return id }
            }
        }
        while idx < items.count {
            let id = items[idx]
            idx += 1
            if staging == nil || taken.insert(id).inserted { return id }
        }
        return nil
    }

    private func scan() {
        lastScan = Date()
        guard let staging, let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path) else { return }
        staged = names.filter { wanted.contains($0) && !taken.contains($0) }
    }
}

/// Thread-safe progress for the verify phase.
final class VerifyMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var p: DownloadProgress
    private let start = Date()
    private var last = Date.distantPast
    private let callback: @Sendable (DownloadProgress) -> Void

    init(progress: DownloadProgress, callback: @escaping @Sendable (DownloadProgress) -> Void) {
        p = progress
        self.callback = callback
    }

    func add(_ bytes: UInt64) {
        lock.lock()
        p.verifyBytesDone += bytes
        let now = Date()
        var snap: DownloadProgress?
        if now.timeIntervalSince(last) > 0.25 {
            last = now
            p.verifyElapsed = now.timeIntervalSince(start)
            snap = p
        }
        lock.unlock()
        if let snap { callback(snap) }
    }

    func fileDone() { lock.lock(); p.verifyFilesDone += 1; lock.unlock() }

    func finish() -> TimeInterval {
        lock.lock()
        p.verifyElapsed = Date().timeIntervalSince(start)
        let s = p
        lock.unlock()
        callback(s)
        return s.verifyElapsed
    }
}

/// Thread-safe progress accounting for the download phase.
final class Tracker: @unchecked Sendable {
    private let lock = NSLock()
    private var p: DownloadProgress
    private var remaining: [Int]
    private let start: Date
    private let callback: @Sendable (DownloadProgress) -> Void
    private var lastReport = Date.distantPast
    private(set) var formats: [String: Int] = [:]

    init(progress: DownloadProgress, remainingPerFile: [Int], start: Date, callback: @escaping @Sendable (DownloadProgress) -> Void) {
        self.p = progress
        self.remaining = remainingPerFile
        self.start = start
        self.callback = callback
    }

    /// Returns indices of files that just became complete.
    func chunkDone(bytes: UInt64, network: UInt64, format: DepotChunk.Format, files: [Int], staged: Bool = false) -> [Int] {
        lock.lock()
        p.chunksDone += 1
        if staged { p.chunksFromStaging += 1 }
        p.bytesDownloaded += bytes
        p.networkBytes += network
        formats[format.rawValue, default: 0] += 1
        var finished: [Int] = []
        for f in files {
            remaining[f] -= 1
            if remaining[f] == 0 { finished.append(f); p.completedFiles += 1 }
        }
        let now = Date()
        var snapshot: DownloadProgress?
        if now.timeIntervalSince(lastReport) > 0.5 {
            lastReport = now
            p.elapsed = now.timeIntervalSince(start)
            snapshot = p
        }
        lock.unlock()
        if let snapshot { callback(snapshot) }
        return finished
    }

    func finish() -> DownloadProgress {
        lock.lock()
        p.phase = .finished
        p.message = "Complete"
        p.elapsed = Date().timeIntervalSince(start)
        let s = p
        lock.unlock()
        callback(s)
        return s
    }
}

/// Append-only list of files known complete for a given manifest ("<sha> <size> <name>").
final class ResumeState: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var pending: [String] = []

    init(url: URL) { self.url = url }

    static func key(_ f: DepotManifest.File) -> String { "\(f.shaContent.hex) \(f.size) \(f.name)" }

    func load() -> Set<String> {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").map(String.init))
    }

    func markDone(_ f: DepotManifest.File) {
        lock.lock()
        pending.append(Self.key(f))
        let flushNow = pending.count >= 16
        lock.unlock()
        if flushNow { flush() }
    }

    func flush() {
        lock.lock()
        let lines = pending
        pending = []
        defer { lock.unlock() }
        guard !lines.isEmpty else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}
