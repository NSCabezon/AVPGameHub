import Foundation
import SteamDepot

let usage = """
usage: steamdepot --app <appid> [--depot <depotid>]... [--os linux] [--branch public]
                  --dir <out> [--user <account> | --qr-png <path>] [--token-file <path>]
                  [--filter <prefix>]... [--max-downloads N] [--info] [--verify] [--force-verify] [--login-only] [--verbose]
       steamdepot --library [--vr-only] [--json] [--refresh] [--token-file <path>] [--verbose]
       steamdepot serve [--socket <path>] [--dry-run-stores] [--cache-dir <dir>] [--token-file <path>] [--verbose]
       steamdepot stats --app <appid> [--lang <language>] [--icons] [--json] [--store-noop [--send]] [--cache-dir <dir>] [--token-file <path>] [--verbose]
       steamdepot icon <url> [--cache-dir <dir>]
       steamdepot cloud [--app <appid>] [--list] [--plan] [--local <dir>] [--mode download-only|two-way]  (read-only)
       steamdepot frame-scan [--json <out>] [--manifests] [--dump-dir <dir>]  (read-only)
"""

struct Args {
    var app: UInt32 = 546560
    var depots: [UInt32] = []
    var os: String?
    var branch = "public"
    var dir: String?
    var qrPNG: String?
    var tokenFile: String?
    var filters: [String] = []
    var maxDownloads = 12
    var infoOnly = false
    var verbose = false
    var loginOnly = false
    var verify = false
    var forceVerify = false
    var user: String?
    var library = false
    var vrOnly = false
    var json = false
    var refresh = false
}

func parseArgs() throws -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ flag: String) throws -> String {
        guard let v = it.next() else { throw CLIError("missing value for \(flag)") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--app": a.app = UInt32(try next(arg)) ?? 0
        case "--depot": a.depots.append(UInt32(try next(arg)) ?? 0)
        case "--os": a.os = try next(arg)
        case "--branch": a.branch = try next(arg)
        case "--dir": a.dir = try next(arg)
        case "--qr-png": a.qrPNG = try next(arg)
        case "--token-file": a.tokenFile = try next(arg)
        case "--filter": a.filters.append(try next(arg))
        case "--max-downloads": a.maxDownloads = Int(try next(arg)) ?? 12
        case "--info": a.infoOnly = true
        case "--login-only": a.loginOnly = true
        case "--verify": a.verify = true
        case "--force-verify": a.forceVerify = true
        case "--user": a.user = try next(arg)
        case "--library": a.library = true
        case "--vr-only": a.vrOnly = true
        case "--json": a.json = true
        case "--refresh": a.refresh = true
        case "--verbose", "-v": a.verbose = true
        case "-h", "--help": print(usage); exit(0)
        default: throw CLIError("unknown argument \(arg)\n\(usage)")
        }
    }
    return a
}

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

/// Progress goes to stderr instead when stdout carries machine-readable output (--json).
nonisolated(unsafe) var logToStderr = false

func say(_ s: String) {
    if logToStderr {
        FileHandle.standardError.write("[\(stamp())] \(s)\n".data(using: .utf8)!)
    } else {
        print("[\(stamp())] \(s)")
        fflush(stdout)
    }
}

func run() async throws {
    switch CommandLine.arguments.dropFirst().first {
    case "serve": return try await runServe(CommandLine.arguments.dropFirst(2))
    case "stats": return try await runStats(CommandLine.arguments.dropFirst(2))
    case "icon": return try await runIcon(CommandLine.arguments.dropFirst(2))
    case "cloud": return try await runCloud(CommandLine.arguments.dropFirst(2))
    case "frame-scan": return try await runFrameScan(CommandLine.arguments.dropFirst(2))
    default: break
    }
    let args = try parseArgs()
    let verbose = args.verbose
    let session = SteamSession(log: { msg in if verbose { say("· \(msg)") } })
    let tokenPath = ((args.tokenFile ?? "~/.steamdepot-token.json") as NSString).expandingTildeInPath
    let store = FileCredentialStore(url: URL(fileURLWithPath: tokenPath))
    if args.library {
        logToStderr = args.json
        try await runLibrary(session: session, store: store, args: args)
        return
    }

    say("connecting to Steam…")
    try await session.connect()

    var creds = try store.load()
    if let user = args.user, creds == nil || creds!.accountName.lowercased() != user.lowercased() {
        creds = try await credentialsLogin(session: session, user: user, guardData: creds?.guardData)
        try store.save(creds!)
        say("signed in as '\(creds!.accountName)'; refresh token saved to \(store.url.path)")
    }
    if creds == nil {
        say("no saved token; starting QR login")
        let qrPath = args.qrPNG
        let deadline = Date().addingTimeInterval(20 * 60)
        while creds == nil {
            do {
                creds = try await session.authenticateWithQR(deviceName: "SteamDepot (\(Host.current().localizedName ?? "Mac"))") { url in
                    say("QR challenge URL: \(url)")
                    if let qrPath {
                        do {
                            try QRCode.writePNG(url, to: qrPath)
                            say("QR written to \(qrPath) — scan it with the Steam mobile app")
                        } catch { say("could not write QR PNG: \(error)") }
                    }
                }
            } catch let e as SteamDepotError {
                guard case .steamResult = e, Date() < deadline else { throw e }
                say("QR session ended (\(e)); starting a new one")
            }
        }
        try store.save(creds!)
        say("login approved for '\(creds!.accountName)'; refresh token saved to \(store.url.path)")
    } else {
        say("using saved token for '\(creds!.accountName)'")
    }

    do {
        try await session.logOn(creds!)
    } catch SteamDepotError.logonFailed(let r) where [EResult.invalidPassword, EResult.accessDenied, EResult.expired, EResult.revoked, EResult.invalidSignature].contains(r) {
        try? store.clear()
        throw CLIError("saved token rejected (EResult \(r)); token file removed, re-run to log in with QR")
    }
    say("logged on (steamid \(await session.steamID))")
    if args.loginOnly { await session.disconnect(); return }

    try await runDownload(session: session, args: args)
    await session.disconnect()
}

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        try await run()
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exitCode = 1
    }
    sem.signal()
}
sem.wait()
exit(exitCode)

/// Username/password sign-in (like the Steam Deck). The password is read without echo,
/// RSA-encrypted for Steam and never stored.
func credentialsLogin(session: SteamSession, user: String, guardData: String?) async throws -> SteamCredentials {
    guard let raw = getpass("Steam password for \(user): ") else { throw CLIError("no password") }
    var password = String(cString: raw)
    memset(raw, 0, strlen(raw))
    let device = "SteamDepot (\(Host.current().localizedName ?? "Mac"))"
    let auth = try await session.beginCredentialsAuth(accountName: user, password: password, deviceName: device,
                                                      guardData: guardData)
    password = ""
    say("Steam Guard options: \(auth.allowedTypes.map(\.description).joined(separator: ", "))")
    let poller = Task { try await session.waitForCredentialsAuth(auth) }
    if let codeType = auth.needsCode {
        if auth.canApproveOnDevice {
            say("Approve the sign-in in the Steam app on your phone, or type the \(codeType) and press Enter:")
        } else {
            say("Type the \(codeType) and press Enter:")
        }
        // Read codes on a background thread so phone approval can finish the poll meanwhile.
        Thread.detachNewThread {
            while let line = readLine(), !poller.isCancelled {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.isEmpty else { continue }
                let sem = DispatchSemaphore(value: 0)
                Task {
                    do { try await session.submitGuardCode(auth, code: code, type: codeType); say("code accepted; finishing sign-in…") }
                    catch { say("code rejected (\(error)); try again:") }
                    sem.signal()
                }
                sem.wait()
            }
        }
    } else if auth.canApproveOnDevice {
        say("Approve the sign-in in the Steam app on your phone…")
    } else if auth.canApproveByEmail {
        say("Approve the sign-in from the e-mail Steam sent you…")
    }
    return try await poller.value
}
