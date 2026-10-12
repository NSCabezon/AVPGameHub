import Foundation
import SteamDepot

func fmtBytes(_ b: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .binary
    return f.string(fromByteCount: Int64(b))
}

func runDownload(session: SteamSession, args: Args) async throws {
    let verbose = args.verbose
    let downloader = SteamDepotDownloader(session: session, log: { msg in if verbose { say("· \(msg)") } })

    await session.waitForLicenses(timeout: 5)
    say("licenses: \(await session.licenses.count)")

    let depots = try await downloader.depots(app: args.app, branch: args.branch)
    if args.infoOnly || args.depots.isEmpty && args.os == nil {
        for d in depots {
            say("depot \(d.depotID) \(d.name ?? "") os=\(d.osList.joined(separator: ",")) manifest=\(d.manifestID.map(String.init) ?? "-") maxsize=\(d.maxSize.map { fmtBytes($0) } ?? "-")")
        }
        if args.infoOnly { return }
    }

    var targets = args.depots
    if targets.isEmpty, let os = args.os {
        targets = depots.filter { $0.manifestID != nil && ($0.osList.isEmpty || $0.osList.contains(os)) }.map(\.depotID)
        say("depots for os \(os): \(targets)")
    }
    if let os = args.os {
        for t in targets {
            if let d = depots.first(where: { $0.depotID == t }), !d.osList.isEmpty, !d.osList.contains(os) {
                say("warning: depot \(t) oslist is \(d.osList), not \(os)")
            }
        }
    }
    guard let dir = args.dir else { throw CLIError("--dir is required to download") }
    guard !targets.isEmpty else { throw CLIError("no depots selected (use --depot or --os)") }

    for depot in targets {
        var opts = DepotDownloadOptions(appID: args.app, depotID: depot, branch: args.branch,
                                        directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath),
                                        filters: args.filters, maxConcurrentDownloads: args.maxDownloads,
                                        verifyFiles: args.verify, forceVerify: args.forceVerify,
                                        pinnedManifestID: SupportedTitles.byAppID[args.app]?
                                            .manifestSelection(depot: depot, branch: args.branch).pinnedGID)
        if let st = args.staging { opts.stagingDirectory = URL(fileURLWithPath: (st as NSString).expandingTildeInPath, isDirectory: true) }
        if let out = args.planOut {
            // The background-download plan: one "<url>\t<chunk id>" line per chunk, then stop.
            let path = (out as NSString).expandingTildeInPath
            opts.onChunkPlan = { plan in
                let server = plan.servers.first ?? ""
                let lines = plan.chunks.map { "\(server)/\(ChunkPlan.chunkPath(depot: plan.depotID, id: $0.id))\t\($0.id)" }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                say("plan: \(plan.chunks.count) chunks from \(plan.servers.count) https server(s), CDN token needed: \(plan.needsCDNToken) -> \(path)")
                exit(0)
            }
        }
        say("downloading depot \(depot) → \(opts.directory.path) (\(args.maxDownloads) parallel)")
        let lastLine = LastLine()
        let summary = try await downloader.download(opts) { p in
            if p.phase == .verifying {
                let rate = p.verifyElapsed > 0 ? Double(p.verifyBytesDone) / p.verifyElapsed : 0
                lastLine.print(String(format: "verifying %@ / %@  files %d/%d  %@/s", fmtBytes(p.verifyBytesDone),
                                      fmtBytes(p.verifyBytesTotal), p.verifyFilesDone, p.verifyFilesTotal, fmtBytes(UInt64(rate))))
                return
            }
            guard p.phase == .downloading || p.phase == .finished else { return }
            lastLine.noteStaged(p.chunksFromStaging)
            let pct = p.bytesToDownload > 0 ? Double(p.bytesDownloaded) / Double(p.bytesToDownload) * 100 : 100
            let rate = p.elapsed > 0 ? Double(p.networkBytes) / p.elapsed : 0
            let line = String(format: "%5.1f%%  %@ / %@  files %d/%d  chunks %d/%d  %@/s",
                              pct, fmtBytes(p.bytesDownloaded), fmtBytes(p.bytesToDownload),
                              p.completedFiles, p.totalFiles, p.chunksDone, p.chunksTotal, fmtBytes(UInt64(rate)))
            lastLine.print(line)
        }
        let rate = summary.elapsed > 0 ? Double(summary.networkBytes) / summary.elapsed : 0
        say("done depot \(depot) manifest \(summary.manifestID): \(summary.files) files (\(summary.skippedFiles) already complete), "
            + "\(fmtBytes(summary.bytesDownloaded)) written, \(fmtBytes(summary.networkBytes)) over network in "
            + String(format: "%.1fs (%@/s network)", summary.elapsed, fmtBytes(UInt64(rate))))
        if summary.verifiedBytes > 0 {
            say("verified \(fmtBytes(summary.verifiedBytes)) already on disk in " + String(format: "%.1fs (%@/s)", summary.verifyElapsed,
                fmtBytes(UInt64(Double(summary.verifiedBytes) / max(0.001, summary.verifyElapsed)))))
        }
        say("chunk formats: \(summary.chunkFormats)")
        if opts.stagingDirectory != nil { say("chunks taken from staging: \(lastLine.staged)") }
    }
}

final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var _staged = 0
    var staged: Int { lock.lock(); defer { lock.unlock() }; return _staged }
    func noteStaged(_ n: Int) { lock.lock(); _staged = max(_staged, n); lock.unlock() }
    func print(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) < 2 { return }
        last = now
        say(s)
    }
}
