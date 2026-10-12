// Game content from Steam, on the headset.
//
// Half-Life: Alyx's ~72 GB of content (depot 546561) used to be copied Mac ->
// headset with devicectl (stage_alyx.sh). This gate lets the app fetch a game's
// data itself, from the player's own Steam account (ownership is proved by Steam:
// no depot key without a licence), through the SteamDepot package
// (../../packages/SteamDepot).
//
// What a game needs is a DESCRIPTOR (SteamGameDescriptor, registry in
// SteamGames below): the Steam app id, the depots (or an OS filter to discover
// them), a file filter, where the depot root lands, and what counts as
// installed (SteamDepot's completion marker for every depot, plus every file of
// the last manifest present at its exact size). Half-Life: Alyx's descriptor is
// today's behaviour exactly.
//
// Shape (single-game alyx build): before the boot window does anything, the
// build checks — offline, stat only — whether the content is COMPLETE. If so, the
// window is the boot window as always. If not, this view takes the window: Steam
// sign-in, then verify / adopt whatever is already there (e.g. a partial devicectl
// copy, which has no SteamDepot resume state — every chunk is checked by SHA-1
// and kept if it matches), then download only what is missing. Play enters the
// existing boot path. In the HUB build (KleptonHub.swift) the same model and
// view run per game from the library instead. Compiled only where the SteamDepot
// module is linked (the alyx and hub builds).
#if canImport(SteamDepot)
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SteamDepot

/// Everything the in-app download needs to know about one game.
struct SteamGameDescriptor: Sendable {
    /// The Klepton target (visionos/targets.py row).
    let target: String
    let title: String
    let appID: UInt32
    /// Depots to download, in order. Empty = discover them from Steam: every depot
    /// of the app whose `oslist` contains `osFilter` (remembered once found).
    let depots: [UInt32]
    let osFilter: String?
    let branch: String
    /// Where the depot root lands, relative to the game's container
    /// (Paths.containerURL(for:)). Depot paths are relative to this root.
    let dataSubpath: String
    /// The same data's location before the hub existed, relative to Documents/.
    /// The hub adopts it with a rename (HubStorage); nil = nothing to adopt.
    let legacyDataSubpath: String?
    /// Depot-relative path filter (true = download the file).
    let include: @Sendable (String) -> Bool
    /// Depot-relative files whose presence means "a (maybe partial) copy is here".
    let presenceProbes: [String]
    /// Roughly what the filtered depots occupy, for the free-space hint and text.
    let approxBytes: UInt64
    /// UserDefaults key: "verify every file on the next launch".
    let verifyNextLaunchKey: String
    var maxConcurrentDownloads = 12
    var verifyConcurrency = 4
    /// An Android game's APK, depot-relative (nil = not an APK game). The runtime
    /// opens <container>/<target's apk> as a zip (getPackageCodePath) and reads
    /// <container>/<tree>/assets; the hub derives both from this file before boot
    /// (KleptonHubPrep.swift), so nothing is staged from a Mac.
    var apk: String? = nil

    /// <container>/<dataSubpath>.
    var root: URL { Paths.containerURL(for: target).appendingPathComponent(dataSubpath, isDirectory: true) }

    /// The Steam store header image (the library's cover art).
    var headerImageURL: URL { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")! }

    private var depotsKey: String { "kl.steam.depots.\(target)" }
    /// The depots this game is made of: the descriptor's, or the ones discovered and
    /// remembered by a previous download. Empty = not known yet (never downloaded).
    var knownDepots: [UInt32] {
        if !depots.isEmpty { return depots }
        return (UserDefaults.standard.array(forKey: depotsKey) as? [Int] ?? []).map(UInt32.init)
    }
    func rememberDepots(_ ids: [UInt32]) { UserDefaults.standard.set(ids.map(Int.init), forKey: depotsKey) }

    /// Offline (stat only): completion markers and file sizes for every known depot.
    func status() -> GameContentStatus {
        let ids = knownDepots
        var st = GameContentStatus()
        st.depotCount = ids.count
        for id in ids {
            let l = SteamDepotDownloader.localStatus(directory: root, depot: id)
            st.markers[id] = l.markerManifestID
            st.totalFiles += l.totalFiles; st.presentFiles += l.presentFiles
            st.totalBytes += l.totalBytes; st.presentBytes += l.presentBytes
            if !l.isComplete { st.allDepotsComplete = false }
        }
        if ids.isEmpty { st.allDepotsComplete = false }
        return st
    }

    /// Strict: every depot's marker + every listed file at the right size, and no
    /// verify scheduled. Anything else goes through the download gate.
    var isReady: Bool { status().isComplete && !UserDefaults.standard.bool(forKey: verifyNextLaunchKey) }

    /// Content that looks like a (possibly partial) copy — offered "Play anyway".
    var looksPresent: Bool {
        !presenceProbes.isEmpty && presenceProbes.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// Only one depot-wide test hook: KL_STEAM_FILTER=prefix[,prefix…] limits the download (sim tests).
    static var debugFilters: [String] {
        (ProcessInfo.processInfo.environment["KL_STEAM_FILTER"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// What is installed for a game, over all its depots (offline).
struct GameContentStatus {
    var depotCount = 0
    var allDepotsComplete = true
    var markers: [UInt32: UInt64?] = [:]
    var totalFiles = 0, presentFiles = 0
    var totalBytes: UInt64 = 0, presentBytes: UInt64 = 0
    var isComplete: Bool { depotCount > 0 && allDepotsComplete }
}

/// The games that can be downloaded in-app, by Klepton target.
enum SteamGames {
    /// Half-Life: Alyx — the linuxsteamrtarm64 build's CONTENT depot. The code is in
    /// the bundle (translated frameworks), so only data is fetched.
    static let alyx = SteamGameDescriptor(
        target: "alyx", title: "Half-Life: Alyx", appID: 546560,
        depots: [546561], osFilter: nil, branch: "public",
        /// <container>/android-files/alyx — the depot's own paths start with "game/",
        /// so the content lands in android-files/alyx/game exactly where kl_app.c
        /// (stage_files "alyx") makes the game root.
        dataSubpath: "android-files/alyx",
        legacyDataSubpath: "android-files/alyx",
        include: { alyxInclude($0) },
        presenceProbes: ["game/hlvr/gameinfo.gi", "game/core/pak01_dir.vpk"],
        approxBytes: 70_000_000_000,
        // The key the single-game build has always used, so a scheduled verify carries over.
        verifyNextLaunchKey: "kl.steam.verifyNextLaunch",
        maxConcurrentDownloads: 16, verifyConcurrency: 6)

    /// The same exclusions as visionos/stage_alyx.sh (default, without --include-extras):
    /// code (bundle frameworks), other-platform dirs, binaries/debug files, host junk,
    /// editor tools, workshop sample maps. `path` is depot-relative ("game/hlvr/…").
    static func alyxInclude(_ path: String) -> Bool {
        let p = path.lowercased()
        guard p.hasPrefix("game/") else { return false }
        let rel = String(p.dropFirst(5))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { return false }
        if parts.first == "bin" || (parts.count > 2 && parts[1] == "bin") { return false }
        let platformDirs: Set<String> = ["win64", "win32", "linuxsteamrt64", "linux64", "osx64"]
        if parts.dropLast().contains(where: platformDirs.contains) { return false }
        for ext in [".dll", ".exe", ".pdb", ".dbg", ".sym", ".so"] where last.hasSuffix(ext) { return false }
        if last.contains(".so.") || last.hasPrefix("vfxcompile") { return false }
        if last == ".ds_store" || last.hasPrefix("._") || parts.contains(".depotdownloader") { return false }
        if rel.hasPrefix("core/tools/") || rel.hasPrefix("hlvr/maps/workshop_examples/") { return false }
        return true
    }

    /// SUPERHOT VR — the Steam Frame build: the Android depot is one APK (code and
    /// data together, 646 MB) plus the Frame's display preferences. The code is in
    /// the bundle (translated frameworks); the APK is still needed on device,
    /// because Unity mounts it as a zip and reads its data out of it.
    static let superhot = SteamGameDescriptor(
        target: "superhot", title: "SUPERHOT VR", appID: 617830,
        depots: [617833], osFilter: nil, branch: "public",
        /// <container>/steam — the depot as Steam ships it, kept apart from what the
        /// hub derives from it (<container>/superhot.apk, <container>/superhot/).
        dataSubpath: "steam",
        legacyDataSubpath: nil,
        include: { ["shvr.apk", "vrpreferences.json"].contains($0.lowercased()) },
        presenceProbes: ["shvr.apk"],
        approxBytes: 650_000_000,
        verifyNextLaunchKey: "kl.steam.verifyNextLaunch.superhot",
        apk: "shvr.apk")

    /// Metro Awakening — the Steam Frame build: the Android depot is the APK
    /// (Impact-Android-Shipping-arm64.apk, 50 MB) and the game's 14 OBBs
    /// (main.944116 + chunk.1..12 + chunk.20, IoStore paks, stored zips). The
    /// depot root IS the OBB directory UE builds for itself
    /// (<files>/Android/obb/<package>, targets.py "obb"), so the OBBs are read
    /// where they land, with no second copy; the APK beside them is what the hub
    /// derives metro.apk and metro/assets from (KleptonHubPrep.swift). Ownership
    /// is Steam's (no depot key without a licence), and in game the real account
    /// answers through the Steam bridge.
    static let metro = SteamGameDescriptor(
        target: "metro", title: "Metro Awakening", appID: 2669410,
        depots: [2669412], osFilter: nil, branch: "public",
        dataSubpath: "android-files/Android/obb/com.vertigogames.ImpactDevelopment",
        legacyDataSubpath: nil,
        include: { _ in true },
        presenceProbes: ["Impact-Android-Shipping-arm64.apk",
                         "main.944116.com.vertigogames.ImpactDevelopment.obb"],
        approxBytes: 19_300_000_000,
        verifyNextLaunchKey: "kl.steam.verifyNextLaunch.metro",
        apk: "Impact-Android-Shipping-arm64.apk")

    /// One line per downloadable game.
    static let all: [String: SteamGameDescriptor] = [
        "alyx": alyx,
        "superhot": superhot,
        "metro": metro,
    ]

    static func descriptor(for target: String) -> SteamGameDescriptor? { all[target] }
}

@MainActor
final class SteamContentModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case connecting(String)
        /// Username/password form (primary sign-in). Optional message (e.g. wrong password).
        case signIn(String?)
        /// Steam Guard: a code is needed (and/or the phone can approve).
        case guardCode(type: String, canApprove: Bool, error: String?)
        /// Waiting for approval in the Steam app / by e-mail.
        case approve(String)
        case qr(String)
        case working
        case paused
        case complete
        case failed(String)
    }

    enum Method { case saved, password(String, String), qr }

    @Published var stage: Stage = .idle
    @Published var progress = DownloadProgress()
    @Published var account: String?
    @Published var local: GameContentStatus
    /// Which of several depots is downloading (1-based) — 0 when only one.
    @Published var depotIndex = 0
    @Published var depotCount = 0
    let game: SteamGameDescriptor
    @Published var freeBytes: UInt64?
    @Published var speed: Double = 0          // uncompressed bytes/s, smoothed
    @Published var networkSpeed: Double = 0
    @Published var verifySpeed: Double = 0
    private var samples: [(t: Date, b: UInt64, n: UInt64)] = []
    private var task: Task<Void, Never>?
    private var session: SteamSession?
    private var pendingAuth: CredentialsAuthSession?
    private var pendingCodeType: SteamGuardType?
    private var forceVerify = false
    private let store = KeychainCredentialStore(service: "SteamDepot.refreshToken", account: "steam")
    var interruptedByBackground = false

    init(game: SteamGameDescriptor) {
        self.game = game
        local = game.status()
        account = (try? store.load())?.accountName
        refreshLocal()
    }

    /// Fraction of the game's bytes on disk while downloading/verifying, for the
    /// library's "Downloading x%" — nil when nothing is running.
    var activeFraction: Double? {
        guard isBusy else { return nil }
        let p = progress
        switch p.phase {
        case .verifying: return p.verifyBytesTotal > 0 ? Double(p.verifyBytesDone) / Double(p.verifyBytesTotal) : 0
        case .downloading, .finished:
            return p.depotBytes > 0 ? Double(p.depotBytes - p.bytesToDownload + p.bytesDownloaded) / Double(p.depotBytes) : 0
        case .preparing: return 0
        }
    }

    var isBusy: Bool {
        switch stage { case .connecting, .qr, .working, .guardCode, .approve: return true; default: return false }
    }

    /// A start() is in flight, from the moment it is called (isBusy follows the stage, which
    /// the run sets a moment later) until its task has ended. The hub's "Download all" queue
    /// waits on this.
    var isRunning: Bool { task != nil }

    func refreshLocal() {
        local = game.status()
        let root = game.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage { freeBytes = UInt64(v) }
    }

    /// Main button: use the saved sign-in if there is one, otherwise show the sign-in form.
    func start(forceVerify: Bool = false) {
        self.forceVerify = forceVerify
        UserDefaults.standard.set(false, forKey: game.verifyNextLaunchKey)
        launch(.saved)
    }

    /// Primary sign-in: account name + password (used once, RSA-encrypted for Steam, never stored).
    func signIn(user: String, password: String) { launch(.password(user, password)) }

    func signInWithQR() { launch(.qr) }

    func submitCode(_ code: String) {
        guard let session, let auth = pendingAuth, let type = pendingCodeType else { return }
        stage = .connecting(klL("Checking code…", "Comprobando código…"))
        Task {
            do {
                try await session.submitGuardCode(auth, code: code, type: type)
                // The poller in run() finishes the sign-in.
                if case .connecting = stage { stage = .connecting(klL("Code accepted, signing in…", "Código aceptado, iniciando sesión…")) }
            } catch {
                stage = .guardCode(type: type.description, canApprove: auth.canApproveOnDevice,
                                   error: klL("That code was not accepted — try again.", "No se ha aceptado ese código. Inténtalo de nuevo."))
            }
        }
    }

    private func launch(_ method: Method) {
        guard task == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        samples = []
        task = Task { [weak self] in
            await self?.run(method)
            await MainActor.run {
                self?.task = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self?.refreshLocal()
            }
        }
    }

    func pause() {
        task?.cancel()
        stage = .paused
    }

    func cancelSignIn() {
        task?.cancel()
        stage = .signIn(nil)
    }

    func signOut() {
        task?.cancel()
        try? store.clear()
        account = nil
        KLAccountPrivacy.steamPersona = nil
        stage = .idle
    }

    private func log(_ s: String) { NSLog("[steam] \(s)") }

    /// Token hand-off from the Mac: `steamdepot` on the Mac writes ~/.steamdepot/token.json;
    /// copying it to <Documents>/steamdepot-token.json (devicectl) imports it into the Keychain.
    private func importHandoffToken() {
        let handoff = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("steamdepot-token.json")
        if let imported = try? FileCredentialStore(url: handoff).load() {
            try? store.save(imported)
            try? FileManager.default.removeItem(at: handoff)
            account = imported.accountName
            log("imported Steam token for '\(KLAccountPrivacy.mask(imported.accountName))' from Documents/steamdepot-token.json")
        }
    }

    private func run(_ method: Method) async {
        let session = SteamSession(log: { NSLog("[steam] %@", $0) })
        self.session = session
        defer { Task { await session.disconnect() } }
        do {
            importHandoffToken()
            var creds: SteamCredentials
            switch method {
            case .saved:
                guard let saved = try? store.load() else { stage = .signIn(nil); return }
                creds = saved
            case .password(let user, let password):
                stage = .connecting(klL("Contacting Steam…", "Conectando con Steam…"))
                try await session.connect()
                let device = "AVP Game Hub (\(UIDevice.current.name))"
                let auth: CredentialsAuthSession
                do {
                    auth = try await session.beginCredentialsAuth(accountName: user, password: password, deviceName: device,
                                                                  guardData: (try? store.load())?.guardData)
                } catch SteamDepotError.authFailed(let why) {
                    stage = .signIn(why.prefix(1).uppercased() + why.dropFirst() + ".")
                    return
                }
                pendingAuth = auth
                pendingCodeType = auth.needsCode
                if let code = auth.needsCode {
                    stage = .guardCode(type: code.description, canApprove: auth.canApproveOnDevice, error: nil)
                } else if auth.canApproveOnDevice {
                    stage = .approve(klL("Approve this sign-in in the Steam app on your phone.", "Aprueba este inicio de sesión en la app de Steam de tu móvil."))
                } else if auth.canApproveByEmail {
                    stage = .approve(klL("Approve this sign-in from the e-mail Steam just sent you.", "Aprueba este inicio de sesión desde el correo que te acaba de enviar Steam."))
                } else {
                    stage = .connecting(klL("Signing in…", "Iniciando sesión…"))
                }
                creds = try await session.waitForCredentialsAuth(auth)
                pendingAuth = nil
                try store.save(creds)
                log("signed in with account name/password as '\(KLAccountPrivacy.mask(creds.accountName))'")
            case .qr:
                stage = .connecting(klL("Contacting Steam…", "Conectando con Steam…"))
                try await session.connect()
                let device = "AVP Game Hub (\(UIDevice.current.name))"
                creds = try await session.authenticateWithQR(deviceName: device) { url in
                    // The Mac can render this from the device log.
                    NSLog("[steam] QR url: %@", url)
                    await MainActor.run { self.stage = .qr(url) }
                }
                try store.save(creds)
            }

            stage = .connecting(klL("Signing in to Steam…", "Iniciando sesión en Steam…"))
            if case .saved = method { try await session.connect() }
            do {
                try await session.logOn(creds)
            } catch SteamDepotError.logonFailed(let r) {
                log("saved sign-in rejected (EResult \(r))")
                try? store.clear()
                account = nil
                stage = .signIn(klL("Your saved Steam sign-in has expired. Please sign in again.", "Tu sesión guardada de Steam ha caducado. Inicia sesión de nuevo."))
                return
            }
            account = creds.accountName
            if let p = await session.personaName { KLAccountPrivacy.steamPersona = p }
            stage = .working
            let downloader = SteamDepotDownloader(session: session, log: { NSLog("[steam] %@", $0) })
            let game = self.game
            var depots = game.depots
            if depots.isEmpty {
                // Discovery: every depot of the app whose oslist matches the filter.
                stage = .connecting(klL("Finding \(game.title)'s files on Steam…", "Buscando los archivos de \(game.title) en Steam…"))
                let os = game.osFilter?.lowercased()
                depots = try await downloader.depots(app: game.appID, branch: game.branch)
                    .filter { d in os.map { o in d.osList.contains { $0.lowercased() == o } } ?? true }
                    .filter { $0.manifestID != nil }
                    .map(\.depotID)
                guard !depots.isEmpty else {
                    stage = .failed(klL("Steam lists no \(game.osFilter ?? "") depot for \(game.title) on this account.", "Steam no lista ningún depot \(game.osFilter ?? "") de \(game.title) en esta cuenta."))
                    return
                }
                game.rememberDepots(depots)
                stage = .working
            }
            depotCount = depots.count
            for (i, depot) in depots.enumerated() {
                depotIndex = depots.count > 1 ? i + 1 : 0
                let opts = DepotDownloadOptions(appID: game.appID, depotID: depot, branch: game.branch,
                                                directory: game.root, filters: SteamGameDescriptor.debugFilters,
                                                include: game.include,
                                                maxConcurrentDownloads: game.maxConcurrentDownloads,
                                                verifyConcurrency: game.verifyConcurrency,
                                                forceVerify: forceVerify)
                let summary = try await downloader.download(opts) { p in
                    Task { @MainActor in self.update(p) }
                }
                log("\(game.target) depot \(depot) done: \(summary.files) files, \(summary.skippedFiles) already there, "
                    + "\(summary.bytesDownloaded) bytes fetched, verified \(summary.verifiedBytes) in \(summary.verifyElapsed)s")
            }
            stage = .complete
        } catch is CancellationError {
            if case .signIn = stage { return }
            stage = .paused
        } catch SteamDepotError.cancelled {
            stage = .paused
        } catch {
            if Task.isCancelled { if case .signIn = stage { return }; stage = .paused; return }
            log("failed: \(error)")
            stage = .failed("\(error)")
        }
    }

    private func update(_ p: DownloadProgress) {
        guard task != nil else { return }
        progress = p
        if p.phase == .verifying, p.verifyElapsed > 0 {
            verifySpeed = Double(p.verifyBytesDone) / p.verifyElapsed
        }
        if p.phase == .downloading {
            let now = Date()
            samples.append((now, p.bytesDownloaded, p.networkBytes))
            samples.removeAll { now.timeIntervalSince($0.t) > 15 }
            if let first = samples.first, let last = samples.last, last.t.timeIntervalSince(first.t) > 1 {
                let dt = last.t.timeIntervalSince(first.t)
                speed = Double(last.b - first.b) / dt
                networkSpeed = Double(last.n - first.n) / dt
            }
        }
    }
}

private func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
private func gbD(_ b: Double) -> String { String(format: "%.1f GB", b / 1e9) }
private func mbps(_ b: Double) -> String { String(format: "%.1f MB/s", b / 1e6) }
private func eta(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "—" }
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : (m > 0 ? "\(m) min" : "<1 min")
}

func qrImage(_ string: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(string.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let margin: CGFloat = 40
    let canvas = CGRect(x: 0, y: 0, width: out.extent.width + 2 * margin, height: out.extent.height + 2 * margin)
    let padded = out.transformed(by: CGAffineTransform(translationX: margin, y: margin))
        .composited(over: CIImage(color: .white).cropped(to: canvas))
    guard let cg = CIContext().createCGImage(padded, from: canvas) else { return nil }
    return UIImage(cgImage: cg)
}

/// The single-game build's gate: the window shown instead of the boot window while
/// the content is not complete. Owns its model; the hub keeps one per game instead.
struct SteamContentGate: View {
    let onPlay: () -> Void
    @StateObject private var model: SteamContentModel
    init(game: SteamGameDescriptor, onPlay: @escaping () -> Void) {
        self.onPlay = onPlay
        _model = StateObject(wrappedValue: SteamContentModel(game: game))
    }
    var body: some View { SteamContentView(model: model, onPlay: onPlay) }
}

/// Sign-in + download/verify for one game. `onBack` (hub) adds a way back to the library.
struct SteamContentView: View {
    @ObservedObject var model: SteamContentModel
    let onPlay: () -> Void
    var onBack: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                if let onBack {
                    Button { onBack() } label: { Label(klL("Library", "Biblioteca"), systemImage: "chevron.left") }
                }
                Text(model.game.title).font(.largeTitle.bold())
                Spacer()
                if model.account != nil {
                    Text(KLAccountPrivacy.steamLabel).font(.footnote).foregroundStyle(.secondary)
                    Button(klL("Sign out", "Cerrar sesión")) { model.signOut() }.font(.footnote).disabled(model.isBusy)
                }
            }
            content
            Spacer(minLength: 0)
            if model.isBusy {
                Label(klL("Keep this window open and the headset on: visionOS pauses apps in the background, "
                      + "and the download stops with it. It resumes where it left off on the next launch.",
                      "Mantén esta ventana abierta y el visor puesto: visionOS pausa las apps en segundo plano "
                      + "y la descarga se detiene con ellas. Se reanuda donde se quedó en el siguiente arranque."),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .onAppear {
            Lifecycle.keepAlive = true
            // "Check for updates / Verify files on next launch" from the boot window.
            if UserDefaults.standard.bool(forKey: model.game.verifyNextLaunchKey) { model.start(forceVerify: true) }
            // Scripted runs (simulator tests): KL_STEAM_AUTOSTART=1 presses the main button.
            else if klEnvOn("KL_STEAM_AUTOSTART", default: false) { model.start() }
        }
        // The hub's library keeps the app alive itself (downloads go on while the
        // player looks at another game), so only the single-game gate lets go here.
        .onDisappear { if onBack == nil { Lifecycle.keepAlive = false } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.isBusy { model.interruptedByBackground = true }
            if phase == .active, model.interruptedByBackground {
                model.interruptedByBackground = false
                if case .failed = model.stage { model.start() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .idle: idle
        case .connecting(let s):
            HStack(spacing: 12) { ProgressView(); Text(s) }
        case .signIn(let message):
            SteamSignInForm(model: model, message: message)
        case .guardCode(let type, let canApprove, let error):
            SteamGuardCodeForm(model: model, type: type, canApprove: canApprove, error: error)
        case .approve(let text):
            VStack(alignment: .leading, spacing: 14) {
                Text(klL("Confirm the sign-in", "Confirma el inicio de sesión")).font(.title2.bold())
                HStack(spacing: 12) { ProgressView(); Text(text) }
                Button(klL("Cancel", "Cancelar")) { model.cancelSignIn() }
            }
        case .qr(let url):
            HStack(alignment: .top, spacing: 28) {
                if let img = qrImage(url) {
                    Image(uiImage: img).interpolation(.none).resizable().frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(klL("Sign in with a QR code", "Inicia sesión con un código QR")).font(.title2.bold())
                    Text(klL("Scan it with the Steam app on a phone (Steam Guard shield → “Scan a QR code”). "
                         + "A headset's own display can't be seen by a phone camera, so this mostly helps when "
                         + "mirroring the view; the same link is written to the device log as “[steam] QR url:”.",
                         "Escanéalo con la app de Steam en un móvil (escudo de Steam Guard → “Escanear un código QR”). "
                         + "La cámara de un móvil no puede ver la pantalla del visor, así que sirve sobre todo "
                         + "al duplicar la vista; el mismo enlace se escribe en el registro del dispositivo como “[steam] QR url:”."))
                    Button(klL("Back", "Atrás")) { model.cancelSignIn() }
                }
            }
        case .working: working
        case .paused:
            VStack(alignment: .leading, spacing: 12) {
                Text(klL("Paused.", "En pausa.")).font(.title3)
                progressSummary
                HStack {
                    Button(klL("Resume", "Reanudar")) { model.start() }.buttonStyle(.borderedProminent)
                    if model.game.looksPresent { Button(klL("Play anyway", "Jugar igualmente")) { onPlay() } }
                }
            }
        case .complete:
            VStack(alignment: .leading, spacing: 12) {
                Label(klL("\(model.game.title) is installed and verified.", "\(model.game.title) está instalado y verificado."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.title3)
                Text(klL("\(model.local.totalFiles) files, \(gb(model.local.totalBytes)).", "\(model.local.totalFiles) archivos, \(gb(model.local.totalBytes)).")).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button(klL("Play", "Jugar")) { onPlay() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button(klL("Check for updates / Verify files", "Buscar actualizaciones / Verificar archivos")) { model.start(forceVerify: true) }
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 12) {
                Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                HStack {
                    Button(klL("Retry", "Reintentar")) { model.start() }.buttonStyle(.borderedProminent)
                    if model.game.looksPresent { Button(klL("Play anyway", "Jugar igualmente")) { onPlay() } }
                }
            }
        }
    }

    @ViewBuilder private var idle: some View {
        let present = model.game.looksPresent
        VStack(alignment: .leading, spacing: 12) {
            if present {
                Text(klL("Game files were found on this device, but they have not been verified as complete.", "Se han encontrado archivos del juego en este dispositivo, pero no se han verificado como completos."))
                Text(klL("SteamDepot can check them against Steam (keeping every file that matches) and download only what is missing.", "SteamDepot puede compararlos con Steam (conservando cada archivo que coincida) y descargar solo lo que falta."))
                    .foregroundStyle(.secondary)
            } else {
                Text(klL("The game content (about \(Int((Double(model.game.approxBytes) / 1e9).rounded())) GB) is not on this device yet.", "El contenido del juego (unos \(Int((Double(model.game.approxBytes) / 1e9).rounded())) GB) aún no está en este dispositivo."))
                Text(klL("Download it from Steam with the account that owns \(model.game.title).", "Descárgalo de Steam con la cuenta que tiene \(model.game.title).")).foregroundStyle(.secondary)
            }
            if let free = model.freeBytes {
                Text(klL("Free space: \(gb(free))", "Espacio libre: \(gb(free))")).font(.footnote).foregroundStyle(free < model.game.approxBytes + 5_000_000_000 && !present ? .orange : .secondary)
            }
            HStack(spacing: 16) {
                Button(present ? klL("Complete download from Steam", "Completar descarga desde Steam") : klL("Download \(model.game.title) from Steam", "Descargar \(model.game.title) desde Steam")) { model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if present { Button(klL("Play anyway", "Jugar igualmente")) { onPlay() } }
            }
            if !SteamGameDescriptor.debugFilters.isEmpty {
                Text("KL_STEAM_FILTER: \(SteamGameDescriptor.debugFilters.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var working: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 12) {
            switch p.phase {
            case .preparing:
                HStack(spacing: 12) { ProgressView(); Text(p.message.isEmpty ? klL("Preparing…", "Preparando…") : p.message) }
            case .verifying:
                Text(klL("Verifying existing files…", "Verificando archivos existentes…")).font(.title3)
                ProgressView(value: Double(p.verifyBytesDone), total: Double(max(1, p.verifyBytesTotal)))
                Text(klL("\(gb(p.verifyBytesDone)) of \(gb(p.verifyBytesTotal)) checked · \(p.verifyFilesDone)/\(p.verifyFilesTotal) files · \(mbps(model.verifySpeed))", "\(gb(p.verifyBytesDone)) de \(gb(p.verifyBytesTotal)) comprobados · \(p.verifyFilesDone)/\(p.verifyFilesTotal) archivos · \(mbps(model.verifySpeed))"))
                    .monospacedDigit().foregroundStyle(.secondary)
            case .downloading, .finished:
                Text((p.chunksTotal == 0 ? klL("Finishing…", "Terminando…") : klL("Downloading from Steam…", "Descargando de Steam…"))
                     + (model.depotIndex > 0 ? klL(" (depot \(model.depotIndex) of \(model.depotCount))", " (depot \(model.depotIndex) de \(model.depotCount))") : "")).font(.title3)
                let have = Double(p.depotBytes - p.bytesToDownload + p.bytesDownloaded)
                ProgressView(value: have, total: Double(max(1, p.depotBytes)))
                Text(klL("\(gbD(have)) of \(gb(p.depotBytes)) · \(mbps(model.speed)) (network \(mbps(model.networkSpeed))) · ETA \(eta(Double(p.bytesToDownload - p.bytesDownloaded) / max(1, model.speed)))", "\(gbD(have)) de \(gb(p.depotBytes)) · \(mbps(model.speed)) (red \(mbps(model.networkSpeed))) · Quedan \(eta(Double(p.bytesToDownload - p.bytesDownloaded) / max(1, model.speed)))"))
                    .monospacedDigit()
                Text(klL("Files \(p.completedFiles)/\(p.totalFiles) · this session \(gb(p.bytesDownloaded)) of \(gb(p.bytesToDownload)) fetched", "Archivos \(p.completedFiles)/\(p.totalFiles) · en esta sesión \(gb(p.bytesDownloaded)) de \(gb(p.bytesToDownload)) descargados"))
                    .monospacedDigit().font(.footnote).foregroundStyle(.secondary)
            }
            Button(klL("Pause", "Pausar")) { model.pause() }
        }
    }

    @ViewBuilder private var progressSummary: some View {
        let p = model.progress
        if p.depotBytes > 0 {
            Text(klL("\(gbD(Double(p.depotBytes - p.bytesToDownload + p.bytesDownloaded))) of \(gb(p.depotBytes))", "\(gbD(Double(p.depotBytes - p.bytesToDownload + p.bytesDownloaded))) de \(gb(p.depotBytes))"))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Small panel in the boot window (games with a descriptor): schedule a full verify / update check.
struct SteamContentMaintenance: View {
    let game: SteamGameDescriptor
    @State private var scheduled = false
    var body: some View {
        HStack {
            Button(scheduled ? klL("Verify scheduled for next launch", "Verificación programada para el próximo arranque") : klL("Check for updates / Verify files on next launch", "Buscar actualizaciones / Verificar archivos en el próximo arranque")) {
                scheduled.toggle()
                UserDefaults.standard.set(scheduled, forKey: game.verifyNextLaunchKey)
            }
            Spacer()
        }
        .font(.callout)
        .onAppear { scheduled = UserDefaults.standard.bool(forKey: game.verifyNextLaunchKey) }
    }
}
#endif

#if canImport(SteamDepot)
/// Primary sign-in: Steam account name + password, with iCloud Keychain AutoFill.
/// The password lives only in this view's state until it is handed to SteamDepot, which
/// RSA-encrypts it for Steam; it is cleared right after and never written anywhere.
struct SteamSignInForm: View {
    @ObservedObject var model: SteamContentModel
    let message: String?
    @State private var user = UserDefaults.standard.string(forKey: "kl.steam.lastAccount") ?? ""
    @State private var password = ""
    @State private var showOther = false
    @FocusState private var focus: Field?
    enum Field { case user, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(klL("Sign in to Steam", "Inicia sesión en Steam")).font(.title2.bold())
            Text(klL("Use the Steam account that owns \(model.game.title).", "Usa la cuenta de Steam que tiene \(model.game.title).")).foregroundStyle(.secondary)
            if let message { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            TextField(klL("Steam account name", "Nombre de cuenta de Steam"), text: $user)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .user)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .frame(maxWidth: 420)
            SecureField(klL("Password", "Contraseña"), text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
                .frame(maxWidth: 420)
            HStack(spacing: 16) {
                Button(klL("Sign in", "Iniciar sesión"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                Button(showOther ? klL("Hide other ways", "Ocultar otras formas") : klL("Other ways to sign in…", "Otras formas de iniciar sesión…")) { showOther.toggle() }
            }
            Text(klL("Your password is sent to Steam encrypted and is never stored; only a sign-in token is kept, in this device's Keychain.", "Tu contraseña se envía cifrada a Steam y nunca se guarda; solo se conserva un token de sesión, en el llavero de este dispositivo."))
                .font(.footnote).foregroundStyle(.secondary)
            if showOther {
                VStack(alignment: .leading, spacing: 8) {
                    Button(klL("Show a QR code (scan with the Steam app)", "Mostrar un código QR (escanéalo con la app de Steam)")) { model.signInWithQR() }
                    Text(klL("From a Mac: sign in with the steamdepot tool, then copy its token.json into this app's "
                         + "Documents as steamdepot-token.json (devicectl) and press Download again.",
                         "Desde un Mac: inicia sesión con la herramienta steamdepot, copia su token.json en los "
                         + "Documentos de esta app como steamdepot-token.json (devicectl) y pulsa Descargar de nuevo."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .onAppear { focus = user.isEmpty ? .user : .password }
    }

    private func submit() {
        let u = user.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !password.isEmpty else { return }
        UserDefaults.standard.set(u, forKey: "kl.steam.lastAccount")
        let p = password
        password = ""
        model.signIn(user: u, password: p)
    }
}

struct SteamGuardCodeForm: View {
    @ObservedObject var model: SteamContentModel
    let type: String
    let canApprove: Bool
    let error: String?
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Steam Guard").font(.title2.bold())
            if canApprove {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(klL("Approve this sign-in in the Steam app on your phone — or enter the \(type) below.", "Aprueba este inicio de sesión en la app de Steam de tu móvil, o introduce abajo el \(type)."))
                }
            } else {
                Text(klL("Enter the \(type).", "Introduce el \(type)."))
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            TextField(klL("Code", "Código"), text: $code)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(submit)
                .frame(maxWidth: 220)
                .font(.title3.monospaced())
            HStack(spacing: 16) {
                Button(klL("Submit", "Enviar"), action: submit).buttonStyle(.borderedProminent).disabled(code.count < 5)
                Button(klL("Cancel", "Cancelar")) { model.cancelSignIn() }
            }
        }
        .onAppear { focused = !canApprove }
    }

    private func submit() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard c.count >= 5 else { return }
        code = ""
        model.submitCode(c)
    }
}
#endif
