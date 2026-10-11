import Foundation
import SteamDepot

/// `--library`: list owned games classified for Klepton. Uses the saved token only; it never
/// starts an interactive login.
func runLibrary(session: SteamSession, store: FileCredentialStore, args: Args) async throws {
    guard let creds = try store.load() else {
        throw CLIError("no saved Steam token at \(store.url.path); run `steamdepot --login-only` first"
                       + (args.tokenFile != nil ? " with the same --token-file" : ""))
    }
    say("connecting to Steam…")
    try await session.connect()
    do {
        try await session.logOn(creds)
    } catch SteamDepotError.logonFailed(let r) where [EResult.invalidPassword, EResult.accessDenied, EResult.expired, EResult.revoked, EResult.invalidSignature].contains(r) {
        throw CLIError("saved token rejected (EResult \(r)); run `steamdepot --login-only` to sign in again")
    }
    say("logged on as '\(creds.accountName)'; reading library…")
    // Cache beside the token: ~/.steamdepot-token.json -> ~/.steamdepot-token.library.json.
    let cacheURL = store.url.deletingPathExtension().appendingPathExtension("library.json")
    if args.refresh { try? FileManager.default.removeItem(at: cacheURL) }
    var entries = try await SteamLibrary.fetch(session: session, cacheURL: cacheURL, log: { say($0) })
    await session.disconnect()
    // Every Klepton port is a VR port, so playable titles stay even if Steam lists them flat.
    if args.vrOnly { entries = entries.filter { $0.isVR || $0.status == .playable } }

    if args.json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(entries), as: UTF8.self))
        return
    }
    printLibraryTable(entries)
}

func printLibraryTable(_ entries: [LibraryEntry]) {
    func gb(_ n: UInt64?) -> String { n.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "?" }
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    let nameWidth = min(44, max(4, entries.map(\.name.count).max() ?? 4))
    print(pad("STATUS", 12) + pad("APPID", 9) + pad("NAME", nameWidth + 2) + pad("VR", 4) + "ARM64 DEPOTS / NOTES")
    for e in entries {
        let name = e.name.count > nameWidth ? String(e.name.prefix(nameWidth - 1)) + "…" : e.name
        var notes = e.armDepots.map { "\($0.depotID) \($0.kind == .android ? "android" : "linux-arm64") \(gb($0.size))" }
        if let t = e.kleptonTarget {
            notes.append("klepton:\(t)" + (e.portUsesSteamBuild == false ? " (port uses the Quest APK)" : ""))
        }
        print(pad(e.status.rawValue, 12) + pad(String(e.appID), 9) + pad(name, nameWidth + 2)
              + pad(e.isVR ? "yes" : "-", 4) + notes.joined(separator: "; "))
    }
    let counts = LibraryStatus.allCases.map { s in "\(entries.filter { $0.status == s }.count) \(s.rawValue)" }
    print("\n\(entries.count) games: " + counts.joined(separator: ", "))
}
