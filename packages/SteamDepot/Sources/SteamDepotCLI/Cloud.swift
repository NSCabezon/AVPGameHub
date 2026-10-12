// `steamdepot cloud`: read-only Steam Cloud tools — list an app's cloud files, and show the sync plan
// (dry run) for the game's local save folders. It never writes locally and never uploads: there is no apply here.
// Sync policy adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
// launcher/Sources/SteamLauncherKit/Cloud/SteamCloud.swift.
import Foundation
import SteamDepot

let cloudUsage = """
usage: steamdepot cloud [--app 546560] [--list] [--plan] [--local <folder>] [--state-dir <dir>]
                        [--mode download-only|two-way] [--token-file <path>] [--verbose]
  --list       list the app's Steam Cloud files (default when --plan is not given)
  --verify-download  also fetch the smallest and largest files into memory and check its SHA-1 (nothing saved)
  --plan       dry-run sync plan against the game's local folder (Mac run of the port); nothing is written.
               Apps with a save mapping and their default folder (under
               ~/Library/Application Support/Klepton/userdata):
                 546560  Half-Life: Alyx  alyx/gameroot (write layer)
                 617830  SUPERHOT VR      superhot (android files; saves in files/)
                 2669410 Metro Awakening  metro (android files; saves in UnrealGame/Impact/Impact/Saved/SaveGames)
  --local      that folder instead of the default
  --state-dir  sync state/backups folder whose history to plan with (default: none = first sync)
"""

func runCloud(_ argv: ArraySlice<String>) async throws {
    var app: UInt32 = 546560, list = false, plan = false, verbose = false, verifyDownload = false
    var local: String?, stateDir: String?, mode = CloudSyncMode.downloadOnly
    var tokenFile = "~/.steamdepot-token.json"
    var it = argv.makeIterator()
    func next(_ f: String) throws -> String {
        guard let v = it.next() else { throw CLIError("missing value for \(f)") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--app": app = UInt32(try next(a)) ?? 0
        case "--list": list = true
        case "--plan": plan = true
        case "--verify-download": verifyDownload = true
        case "--local": local = try next(a)
        case "--state-dir": stateDir = try next(a)
        case "--mode":
            switch try next(a) {
            case "download-only", "download": mode = .downloadOnly
            case "two-way", "twoway": mode = .twoWay
            case let m: throw CLIError("unknown mode \(m)")
            }
        case "--token-file": tokenFile = try next(a)
        case "--verbose", "-v": verbose = true
        case "-h", "--help": print(cloudUsage); return
        default: throw CLIError("unknown argument \(a)\n\(cloudUsage)")
        }
    }
    if !plan { list = true }

    let store = FileCredentialStore(url: URL(fileURLWithPath: (tokenFile as NSString).expandingTildeInPath))
    guard let creds = try store.load() else {
        throw CLIError("no saved Steam token at \(store.url.path); this command never starts an interactive login")
    }
    let chatty = verbose
    let session = SteamSession(log: { m in if chatty { say("· \(m)") } })
    say("connecting to Steam…")
    try await session.connect()
    try await session.logOn(creds)
    say("logged on as '\(creds.accountName)'")

    let (rules, buildID) = try await session.cloudRules(app: app)
    say("app \(app): build \(buildID), Auto-Cloud rules: "
        + (rules.isEmpty ? "none" : rules.map { "\($0.root):\($0.path)/\($0.pattern)\($0.recursive ? " (recursive)" : "")" }.joined(separator: "; ")))
    let remote = SteamCloud(session: session, appID: app, buildID: buildID)

    if list {
        let files = try await remote.list().sorted { $0.filename < $1.filename }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        for f in files {
            let when = df.string(from: Date(timeIntervalSince1970: TimeInterval(f.timestamp)))
            print("\(when)  \(String(format: "%10d", f.size))  \(f.sha1Hex.prefix(12))  \(f.filename)")
        }
        let total = files.reduce(0) { $0 + UInt64($1.size) }
        print("\(files.count) files, \(String(format: "%.1f MB", Double(total) / 1e6))")
        if verifyDownload, let small = files.min(by: { $0.size < $1.size }), let big = files.max(by: { $0.size < $1.size }) {
            // Read-only transport check: fetch in memory, hash-checked inside download(); nothing is saved.
            for f in Set([small, big]).sorted(by: { $0.size < $1.size }) {
                let d = try await remote.download(f)
                say("downloaded \(f.filename) in memory: \(d.count) bytes, SHA-1 matches the cloud's")
            }
        }
    }

    guard plan else { await session.disconnect(); return }
    guard let profile = CloudSaveProfile.forApp(app) else {
        let known = CloudSaveProfile.all.map { "\($0.appID) (\($0.target))" }.joined(separator: ", ")
        throw CLIError("no local save mapping for app \(app); apps with one: \(known)")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    var bases = profile.macBases(home: home)
    if let local {
        // Every profile maps its saves below one local folder; --local replaces it.
        guard profile.bases.count == 1, let b = profile.bases.first else {
            throw CLIError("--local is ambiguous for app \(app): it maps \(profile.bases.map(\.rawValue))")
        }
        bases[b] = URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
    }
    let layer = profile.bases.compactMap { bases[$0] }.map(\.path).joined(separator: ", ")
    // Without --state-dir: an empty, never-written temp state = what a first sync would do.
    let state = stateDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("steamdepot-cloud-plan-\(UUID().uuidString)")
    let sync = profile.makeSync(remote: remote, rules: rules, bases: bases, stateDir: state, mode: mode)
    say("dry run (\(mode == .twoWay ? "two-way" : "download only")) against \(layer)")
    for r in rules {
        say("  \(r.root):\(r.path) -> " + (sync.folder(for: r)?.path ?? "not mapped here (ignored)"))
    }
    let (report, p) = try await sync.run(dryRun: true)
    for r in p.relocations { print("RELOCATE  slot \(r.from) → \(r.to)  (collides with a different cloud slot)") }
    for a in p.actions {
        switch a {
        case .inSync(let k, _): if verbose { print("in sync   \(k)") }
        // Cloud names in their own spelling (what would go up or come down); state keys are lowercased.
        case .download(_, let r, let replacing): print("DOWNLOAD  \(r.filename)\(replacing != nil ? "  (replaces local, backed up first)" : "")")
        case .upload(_, let l, let over): print("UPLOAD    \(l.cloudName)\(over != nil ? "  (over the cloud copy, backed up first)" : "  (new)")")
        case .hold(_, let l, let why): print("hold      \(l.cloudName)  (\(why == .downloadOnly ? "download-only" : "first two-way run records the baseline"))")
        case .keepLocal(_, let l, let why): print("local     \(l.cloudName)  (\(why == .neverUpload ? "never uploaded" : "unchanged since baseline"))")
        case .conflict(let c, _, _): print("CONFLICT  \(c.key)  (\(c.reason == .bothChanged ? "both changed" : "differs, no sync history"); both kept, nothing uploaded)")
        case .skipDeletedLocally(let k): print("skip      \(k)  (deleted here after sync; cloud copy kept)")
        case .skipDeletedInCloud(let k): print("skip      \(k)  (gone from the cloud after sync; local copy kept)")
        }
    }
    print("plan: \(report.summary) — dry run, nothing written or uploaded")
    await session.disconnect()
}
