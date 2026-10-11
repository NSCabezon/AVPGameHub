// `steamdepot frame-scan`: read-only scan of the owned library for ARM-runnable builds
// (Steam Frame Android APK depots, Linux arm64). Saved token only; never logs in interactively,
// never downloads content chunks (manifest file lists only, with --manifests).
import Foundation
import SteamDepot

let frameScanUsage = """
usage: steamdepot frame-scan [--json <out.json>] [--manifests [--all-linux]] [--dump-dir <dir>] [--token-file <path>] [--verbose]
  --json        also write the candidates as JSON to <out.json>
  --manifests   fetch each candidate depot's manifest (file list only, no chunks) to guess the engine
  --apps        comma-separated app ids to scan instead of the owned library (implies --all-linux)
  --all-linux   probe every owned game's Linux depots, not only VR / Frame-native ones (slow)
  --dump-dir    save every owned app's raw PICS app info as <dir>/<appid>.vdf (for inspection)
"""

func runFrameScan(_ argv: ArraySlice<String>) async throws {
    var jsonOut: String?, dumpDir: String?, manifests = false, verbose = false, allLinux = false
    var apps: [UInt32] = []
    var tokenFile = "~/.steamdepot-token.json"
    var it = argv.makeIterator()
    func next(_ f: String) throws -> String {
        guard let v = it.next() else { throw CLIError("missing value for \(f)") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--json": jsonOut = try next(a)
        case "--dump-dir": dumpDir = try next(a)
        case "--manifests": manifests = true
        case "--all-linux": allLinux = true
        case "--apps": apps = try next(a).split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }; allLinux = true
        case "--token-file": tokenFile = try next(a)
        case "--verbose", "-v": verbose = true
        case "-h", "--help": print(frameScanUsage); return
        default: throw CLIError("unknown argument \(a)\n\(frameScanUsage)")
        }
    }
    let store = FileCredentialStore(url: URL(fileURLWithPath: (tokenFile as NSString).expandingTildeInPath))
    guard let creds = try store.load() else {
        throw CLIError("no saved Steam token at \(store.url.path); frame-scan never logs in interactively. "
                       + "Run `steamdepot --login-only` first.")
    }
    let isVerbose = verbose
    let session = SteamSession(log: { msg in if isVerbose { say("· \(msg)") } })
    say("connecting to Steam…")
    try await session.connect()
    do {
        try await session.logOn(creds)
    } catch SteamDepotError.logonFailed(let r) where [EResult.invalidPassword, EResult.accessDenied, EResult.expired, EResult.revoked, EResult.invalidSignature].contains(r) {
        throw CLIError("saved token rejected (EResult \(r)); run `steamdepot --login-only` to sign in again")
    }
    say("logged on as '\(creds.accountName)'; reading owned apps…")
    let infos = apps.isEmpty ? try await FrameScanFetch.ownedAppInfo(session: session, log: { say($0) })
                             : try await FrameScanFetch.appInfo(session: session, apps: apps, log: { say($0) })
    if let dumpDir {
        let dir = URL(fileURLWithPath: (dumpDir as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (id, kv) in infos { try kv.description.write(to: dir.appendingPathComponent("\(id).vdf"), atomically: true, encoding: .utf8) }
        say("dumped \(infos.count) app infos to \(dir.path)")
    }
    let games = infos.filter { $0.value["common"]?["type"]?.value?.lowercased() == "game" }.count
    var found = infos.compactMap { FrameScan.detect(appID: $0.key, appInfo: $0.value, probeAllLinux: allLinux) }
    say("\(infos.count) \(apps.isEmpty ? "owned " : "")apps (\(games) games) scanned; \(found.filter(\.hasARMBuild).count) with an ARM build in PICS, "
        + "\(found.filter { !$0.hasARMBuild }.count) Linux depots to probe")

    if manifests {
        let dl = SteamDepotDownloader(session: session, log: { msg in if isVerbose { say("· \(msg)") } })
        // Public first, then newer branches, so apply() sees them in that order per depot.
        var jobs: [(i: Int, depot: UInt32, branch: String, gid: UInt64)] = []
        for i in found.indices {
            for d in found[i].depots {
                if let g = d.publicGID { jobs.append((i, d.depotID, "public", g)) }
                for (b, g) in d.newerBranchGIDs.sorted(by: { $0.key < $1.key }) { jobs.append((i, d.depotID, b, g)) }
            }
        }
        say("listing \(jobs.count) manifests (file lists only)…")
        var results = [[String]?](repeating: nil, count: jobs.count)
        try await withThrowingTaskGroup(of: (Int, [String]?).self) { g in
            var next = 0, done = 0
            func launch() {
                guard next < jobs.count else { return }
                let k = next, j = jobs[k], app = found[j.i].appID; next += 1
                g.addTask {
                    var last: Error?
                    for _ in 0..<3 {
                        do {
                            let m = try await dl.fetchManifest(app: app, depot: j.depot, manifest: j.gid, branch: j.branch)
                            return (k, m.files.filter { !$0.isDirectory }.map(\.name))
                        } catch SteamDepotError.notOwned(let w) {
                            last = SteamDepotError.notOwned(w); break
                        } catch { last = error }
                    }
                    say("manifest \(app) / \(j.depot) [\(j.branch)]: \(last.map { "\($0)" } ?? "?")")
                    return (k, nil)
                }
            }
            for _ in 0..<4 { launch() }
            while let (k, names) = try await g.next() {
                results[k] = names
                done += 1
                if done % 25 == 0 || done == jobs.count { say("manifests \(done)/\(jobs.count)") }
                launch()
            }
        }
        for (k, j) in jobs.enumerated() {
            if let names = results[k] { FrameScan.apply(fileNames: names, depot: j.depot, branch: j.branch, to: &found[j.i]) }
        }
    }
    await session.disconnect()

    found.sort(by: FrameCandidate.effortOrder)
    printFrameTable(found, showX86: !allLinux || !apps.isEmpty)
    let x86 = found.filter { !$0.hasARMBuild && $0.depots.allSatisfy { $0.kind != .linuxProbe } }.count
    say("\(found.filter(\.hasARMBuild).count) apps with an ARM build; \(x86) probed x86-only"
        + (allLinux ? " (not listed)" : "") + "; \(found.count - x86 - found.filter(\.hasARMBuild).count) unprobed")
    if let jsonOut {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: (jsonOut as NSString).expandingTildeInPath)
        try enc.encode(found).write(to: url, options: .atomic)
        say("wrote \(url.path)")
    }
}

func printFrameTable(_ cs: [FrameCandidate], showX86: Bool) {
    func gb(_ n: UInt64?) -> String { n.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "?" }
    for c in cs {
        let probed = c.depots.allSatisfy { $0.kind != .linuxProbe }
        if !c.hasARMBuild, probed, !showX86 { continue }
        let head = "\(c.hasARMBuild ? "ARM  " : (probed ? "x86  " : "probe")) \(c.appID) \(c.name)  [\(c.support.rawValue)\(c.kleptonTarget.map { ":" + $0 } ?? "")]"
            + "  engine=\(c.engine.rawValue) vr=\(c.isVR ? "yes" : "no")"
            + (c.frameRuntime.map { " frame=\(c.frameCategory.map(String.init) ?? "?")/\($0)" } ?? "")
        print(head)
        for h in c.hints { print("    hint: \(h)") }
        for d in c.depots {
            print("    depot \(d.depotID) \(d.kind.rawValue) \(gb(d.size)) branches=\(d.branches.joined(separator: ",")) (\(d.reasons.joined(separator: "; ")))")
            for e in d.evidence { print("        \(e)") }
        }
        for l in c.launches {
            print("    launch \(l.executable) type=\(l.type ?? "-") os=\(l.oslist ?? "-")\(l.betakey.map { " beta=" + $0 } ?? "")")
        }
    }
}
