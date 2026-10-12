import Foundation
import HubCore
import MetaStore
import Observation

/// Everything configurable, in UserDefaults. Nothing personal is baked in: first values come from
/// the environment the Klepton scripts already read (KLEPTON_DIR, KLEPTON_TEAM, KLEPTON_DEVICE,
/// KLEPTON_BUNDLE_ID), or are detected (Status screen) and then stored.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var kleptonPath: String { didSet { defaults.set(kleptonPath, forKey: "kleptonPath") } }
    var team: String { didSet { defaults.set(team, forKey: "team") } }
    var deviceID: String { didSet { defaults.set(deviceID, forKey: "deviceID") } }
    var bundleID: String { didSet { defaults.set(bundleID, forKey: "bundleID") } }
    var metaToolPath: String { didSet { defaults.set(metaToolPath, forKey: "metaToolPath") } }
    var steamTokenPath: String { didSet { defaults.set(steamTokenPath, forKey: "steamTokenPath") } }
    var downloadsPath: String { didSet { defaults.set(downloadsPath, forKey: "downloadsPath") } }
    var sessionsPath: String { didSet { defaults.set(sessionsPath, forKey: "sessionsPath") } }
    var translateScript: String { didSet { defaults.set(translateScript, forKey: "translateScript") } }

    nonisolated static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AVPGameHub", isDirectory: true)
    }()

    /// Run in the Klepton checkout after an APK was fetched. $APK is the fetched file and
    /// $KLEPTON_TARGET the game. Editable in Settings: this is the least-tested step.
    static let defaultTranslateScript = """
    set -euo pipefail
    eval "$(python3 visionos/targets.py "$KLEPTON_TARGET")"
    echo "[translate] $KLEPTON_TARGET: $APK -> $KLT_APK (tree $KLT_TREE)"
    cp "$APK" "$KLT_APK"
    apktool d -f -o "$KLT_TREE" "$KLT_APK"
    XROS_PLATFORMS=xros visionos/mkguest.sh
    echo "[translate] done — now Build & Install the hub"
    """

    init() {
        let d = UserDefaults.standard
        var env = Toolchain.environmentDefaults()
        func value(_ key: String, _ fallback: @autoclosure () -> String) -> String {
            if let v = d.string(forKey: key), !v.isEmpty { return v }
            return env[key] ?? fallback()
        }
        let klepton = value("kleptonPath", Toolchain.findKlepton(from: Bundle.main.bundleURL)?.path
                            ?? Toolchain.findKlepton(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))?.path ?? "")
        kleptonPath = klepton
        // Then <repo>/local/config.env (the file the build scripts read) for what the environment left unset.
        if !klepton.isEmpty {
            let file = Toolchain.localConfigDefaults(kleptonDir: URL(fileURLWithPath: (klepton as NSString).expandingTildeInPath))
            env.merge(file) { current, _ in current }
        }
        team = value("team", "")
        deviceID = value("deviceID", "")
        bundleID = value("bundleID", "")
        metaToolPath = value("metaToolPath", MetaTool.defaultURL.path)
        steamTokenPath = value("steamTokenPath", ("~/.steamdepot-token.json" as NSString).expandingTildeInPath)
        downloadsPath = value("downloadsPath", Self.supportDir.appendingPathComponent("downloads").path)
        sessionsPath = value("sessionsPath", Self.supportDir.appendingPathComponent("sessions").path)
        translateScript = value("translateScript", Self.defaultTranslateScript)
    }

    var kleptonURL: URL? {
        kleptonPath.isEmpty ? nil : URL(fileURLWithPath: (kleptonPath as NSString).expandingTildeInPath)
    }

    var hasKlepton: Bool {
        guard let k = kleptonURL else { return false }
        return FileManager.default.fileExists(atPath: k.appendingPathComponent("build_run_vpro.sh").path)
    }

    func expanded(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    /// ovr-platform-util bundled into the .app by scripts/make-app.sh (from a local copy; never in
    /// git). Used only if it verifies as Meta's (checked once, at first use after launch).
    nonisolated static let bundledMetaTool: URL? = {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("Tools/ovr-platform-util"),
              FileManager.default.fileExists(atPath: u.path),
              (try? MetaTool(url: u).verify()) != nil else { return nil }
        return u
    }()

    /// The tool sign-in runs: the verified bundled copy if there is one, else metaToolPath.
    var metaToolURL: URL { Self.bundledMetaTool ?? expanded(metaToolPath) }

    /// Device + bundle, or a message saying which one is missing.
    func deviceTarget() throws -> (device: String, bundle: String) {
        guard !deviceID.isEmpty else { throw HubError(L("Falta el visor: elígelo en Estado o Ajustes", "No headset set: pick it in Status or Settings")) }
        guard !Toolchain.isPlaceholderBundleID(bundleID) else {
            throw HubError(L("Falta el bundle id del hub, o es un ejemplo (Ajustes)", "No hub bundle id, or an example one (Settings)"))
        }
        return (deviceID, bundleID)
    }

    /// The hub's bundle id from Klepton's targets.py (`KLT_BUNDLE` of the `hub` row).
    func detectBundleID() async -> String? {
        guard let k = kleptonURL else { return nil }
        let r = await ProcessRunner.capture(.bash("python3 visionos/targets.py hub", currentDirectory: k.path))
        guard r.status == 0 else { return nil }
        // A placeholder (targets.py's com.example.* row in a fresh checkout) is not an id anyone can sign for.
        return TargetVars.parse(r.output)["KLT_BUNDLE"].flatMap { Toolchain.isPlaceholderBundleID($0) ? nil : $0 }
    }

    /// The team id in the login keychain's Apple Development certificate (gen_xcodeproj.py's rule).
    static func detectTeam() async -> String? {
        let r = await ProcessRunner.capture(.bash("security find-certificate -c 'Apple Development' -p | openssl x509 -noout -subject"))
        return Toolchain.teamID(fromSubject: r.output)
    }
}

struct HubError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ s: String) { description = s }
    var errorDescription: String? { description }
}
