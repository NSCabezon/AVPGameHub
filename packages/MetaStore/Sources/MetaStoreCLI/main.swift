// metastore — the Mac side of MetaStore: sign in with Meta's own tool, inspect the account,
// and hand the token to the hub on the headset (which then downloads the games itself).
//
//   metastore login [--tool PATH]      sign in via ovr-platform-util (signature checked: Meta, HXH6UQBHD4)
//   metastore logout                   forget the token on this Mac
//   metastore whoami                   the Meta user id the token belongs to
//   metastore owned                    which built-in recipes this account owns (5 s between requests)
//   metastore recipes                  the built-in recipes (offline)
//   metastore fetch <recipe> [--apk-only] [--locale CODE]... [--out DIR|FILE.apk]
//                                      a recipe's files to the Mac, verified + resumable — for building
//                                      a port (translation) ONLY; the headset downloads game data itself
//                                      (--locale en-US: also that voice-language pack, repeatable; off by default)
//   metastore push-token [--device ID] [--bundle ID]
//                                      copy the token into the hub's container (one-time import file)
//
// Login flow adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/avpplay/main.swift.
#if os(macOS)
import Darwin
import Foundation
import MetaStore

// No personal defaults: the headset and the hub's bundle id come from --device / --bundle or
// the environment the build scripts use (KLEPTON_DEVICE, KLEPTON_BUNDLE_ID; local/config.env).
let defaultDevice = ProcessInfo.processInfo.environment["KLEPTON_DEVICE"] ?? ""
let defaultBundle = ProcessInfo.processInfo.environment["KLEPTON_BUNDLE_ID"] ?? ""
/// KLEPTON_DIR, else ./klepton, else the current directory.
func kleptonDir(_ cwd: URL) -> URL {
    if let d = ProcessInfo.processInfo.environment["KLEPTON_DIR"], !d.isEmpty {
        return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
    }
    let sub = cwd.appendingPathComponent("klepton", isDirectory: true)
    return FileManager.default.fileExists(atPath: sub.path) ? sub : cwd
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("metastore: \(Redaction.redact(message))\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let store = SecurityCLITokenStore()

func token() -> String {
    do {
        guard let t = try store.load() else { fail("not signed in — run `metastore login` first") }
        return t
    } catch { fail("\(error)") }
}

final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func exchange(_ v: Int) -> Int { lock.withLock { let old = value; value = v; return old } }
}

func usage() -> Never {
    print("""
    usage: metastore <command>
      login [--tool PATH]                 sign in with Meta's ovr-platform-util (default ~/Downloads/ovr-platform-util)
      logout                              forget the token on this Mac
      whoami                              print the Meta user id
      owned                               built-in recipes this account owns
      owns <appId>...                     whether this account owns the given Meta app ids
      recipes                             list built-in recipes (offline)
      fetch <recipe> [--apk-only] [--locale CODE]... [--out DIR|FILE.apk]
                                          download a recipe's files to the Mac for TRANSLATION only
                                          (beatsaber --apk-only defaults to $KLEPTON_DIR/beatsaber-<version>.apk)
                                          --locale CODE: also a voice-language pack (e.g. en-US), repeatable
      push-token [--device ID] [--bundle ID]
                                          copy the token to the hub on the headset (default $KLEPTON_DEVICE, $KLEPTON_BUNDLE_ID)
    """)
    exit(2)
}

func runAsync(_ body: @escaping @Sendable () async throws -> Void) -> Never {
    let done = DispatchSemaphore(value: 0)
    Task {
        do { try await body() } catch { fail("\(error)") }
        done.signal()
    }
    done.wait()
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "login":
    let tool = MetaTool(url: option("--tool", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                        ?? MetaTool.defaultURL)
    do {
        try tool.verify()
        print("ovr-platform-util is signed by Meta (team \(MetaTool.expectedTeam)). Sign in below; "
              + "your e-mail, password and code go straight to Meta's tool and are not stored.\n")
        let t = try MetaLogin.run(tool: tool.url)
        try store.save(t)
        print("\nSigned in. Token stored in the login Keychain (service \(store.service)). Next: metastore push-token")
    } catch { fail("\(error)") }

case "logout":
    try? store.clear()
    print("Token removed from this Mac. (The hub keeps its own copy until you sign out there.)")

case "whoami":
    let t = token()
    runAsync { print(try await MetaClient(token: t).me()) }

case "owned":
    let t = token()
    runAsync {
        let client = MetaClient(token: t)
        let gate = RequestGate()
        let user = try await gate.run { try await client.me() }
        print("Meta user \(user)")
        for r in Recipes.all {
            let owned = try await gate.run { try await client.ownsApp(appId: r.appId, userId: user) }
            print("\(owned ? "owned    " : "not owned") \(r.title) \(r.versionName) (app \(r.appId), Klepton target \(r.target))")
        }
    }

case "owns":
    // Ownership of arbitrary app ids (a candidate port), without printing the account's id.
    let ids = Array(args.dropFirst())
    guard !ids.isEmpty else { usage() }
    let t = token()
    runAsync {
        let client = MetaClient(token: t)
        let gate = RequestGate()
        let user = try await gate.run { try await client.me() }
        for id in ids {
            let owned = try await gate.run { try await client.ownsApp(appId: id, userId: user) }
            print("\(owned ? "owned    " : "not owned") app \(id)")
        }
    }

case "recipes":
    for r in Recipes.all {
        let bytes = r.files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        print("\(r.id): \(r.title) \(r.versionName) [\(r.package) \(r.versionCode)] app \(r.appId) -> target \(r.target), "
              + "\(r.files.count) files \(String(format: "%.2f GB", Double(bytes) / 1e9)), \(r.addons?.items.count ?? 0) add-ons")
    }

case "fetch":
    guard args.count >= 2, let recipe = Recipes.recipe(id: args[1]) else {
        fail("fetch needs a recipe id: " + Recipes.all.map(\.id).joined(separator: ", "))
    }
    let apkOnly = args.contains("--apk-only")
    var locales = Set<String>()
    for (i, a) in args.enumerated() where a == "--locale" {
        guard i + 1 < args.count else { fail("--locale needs a code") }
        locales.insert(args[i + 1])
    }
    if apkOnly { locales = [] }
    let available = Set(recipe.files.compactMap(\.locale))
    if let bad = locales.subtracting(available).sorted().first {
        fail("'\(bad)' is not a language of \(recipe.id); available: "
             + (available.isEmpty ? "none" : available.sorted().joined(separator: ", ")))
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let out = option("--out", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL }
        ?? MacFetch.defaultOut(recipe: recipe, apkOnly: apkOnly,
                               kleptonDir: kleptonDir(cwd), cwd: cwd)
    let layout: MacFetch.Layout
    do { layout = try MacFetch.layout(recipe: recipe, apkOnly: apkOnly, out: out) } catch { fail("\(error)") }
    let t = token()
    runAsync {
        let client = MetaClient(token: t)
        let gate = RequestGate()
        let r = layout.recipe
        let user = try await gate.run { try await client.me() }
        guard try await gate.run({ try await client.ownsApp(appId: r.appId, userId: user) }) else { throw MetaError.notOwned(r.title) }
        print("\(r.title) \(r.versionName) (\(r.versionCode)) is owned by Meta user \(user). For translation only.")
        let store = GameStore(root: layout.root)
        let record = store.loadRecord()
        let plan = FetchPlan.plan(recipe: r, selection: FetchSelection(withheld: Set(record?.withheld ?? []), locales: locales),
                                  record: record, state: store.state(of:))
        let last = LockedInt()
        let summary = try await Fetcher(client: client, store: store, gate: gate).run(plan, recipe: r, progress: { p in
            let pct = p.bytesTotal > 0 ? Int(p.bytesDone * 100 / p.bytesTotal) : 0
            if last.exchange(pct) != pct || p.verifying {
                print("\r[\(p.fileIndex)/\(p.fileCount)] \(p.fileName) \(pct)%\(p.verifying ? " verifying" : "")", terminator: "")
                fflush(stdout)
            }
        }, log: { print("\n" + $0) })
        guard store.isComplete(r, locales: locales) else { throw FetchError.sizeMismatch(name: r.id, expected: 0, actual: 0) }
        if let dst = layout.apkFile, let apk = r.apk {
            let fm = FileManager.default
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: store.url(for: apk), to: dst)
            try? fm.removeItem(at: layout.root)
            print("APK (sha256 \(apk.sha256 ?? "?")) -> \(dst.path)")
        } else {
            print("Files under \(layout.root.path) (\(summary.downloaded) downloaded, \(summary.kept) already there)")
        }
    }

case "push-token":
    let t = token()
    let device = option("--device", in: args) ?? defaultDevice
    let bundle = option("--bundle", in: args) ?? defaultBundle
    guard !device.isEmpty else { fail("no headset: pass --device <udid> or set KLEPTON_DEVICE") }
    guard !bundle.isEmpty else { fail("no hub bundle id: pass --bundle <id> or set KLEPTON_BUNDLE_ID") }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("metastore-\(UUID().uuidString)", isDirectory: true)
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent(TokenHandoff.fileName)
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try TokenHandoff.encode(token: t).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["devicectl", "device", "copy", "to", "--device", device,
                       "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                       "--source", file.path, "--destination", "Documents/\(TokenHandoff.fileName)"]
        try p.run()
        p.waitUntilExit()
        try? fm.removeItem(at: dir)          // fail() exits without running defer
        guard p.terminationStatus == 0 else { fail("devicectl exited with status \(p.terminationStatus)") }
        print("Token copied to \(bundle) on \(device). The hub imports it into its Keychain (and deletes the file) "
              + "the next time its library opens.")
    } catch {
        try? fm.removeItem(at: dir)
        fail("\(error)")
    }

default:
    usage()
}
#else
print("metastore runs on macOS only")
#endif
