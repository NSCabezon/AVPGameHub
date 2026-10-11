import HubCore
import MetaStore
import Observation
import SteamDepot
import SwiftUI

struct GameRow: Identifiable {
    var entry: CatalogEntry
    var id: String { entry.target }
    var tree: String?
    var apkName: String?
    var translated: APKVersion?
    var frameworksBuilt = false
    var metaVersion: String?
    var steamBuild: String?
    var owned: [StoreKind: Bool] = [:]
}

/// Rate-limits progress lines from download callbacks.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    init(_ interval: TimeInterval = 1.5) { self.interval = interval }
    func ready() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

@MainActor @Observable
final class GamesModel {
    var rows: [GameRow] = Catalog.entries.map { GameRow(entry: $0) }
    let log = LogStore()
    var running: String?
    var checking = false
    var message = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runner = ProcessRunner()

    func refresh(settings: AppSettings) async {
        guard let k = settings.kleptonURL else { return }
        for i in rows.indices {
            let t = rows[i].entry.target
            let r = await ProcessRunner.capture(.bash("python3 visionos/targets.py \(t)", currentDirectory: k.path), timeout: 20)
            let vars = TargetVars.parse(r.output)
            rows[i].tree = vars["KLT_TREE"]
            rows[i].apkName = vars["KLT_APK"]
            if let tree = vars["KLT_TREE"],
               let yml = try? String(contentsOf: k.appendingPathComponent(tree).appendingPathComponent("apktool.yml"), encoding: .utf8) {
                rows[i].translated = APKVersion.parse(apktoolYML: yml)
            } else {
                rows[i].translated = nil
            }
            rows[i].frameworksBuilt = FileManager.default.fileExists(atPath: k.appendingPathComponent("visionos/Frameworks/\(t)").path)
            if let id = rows[i].entry.metaRecipe, let recipe = Recipes.recipe(id: id) {
                rows[i].metaVersion = "\(recipe.versionName) (\(recipe.versionCode))"
            }
        }
    }

    /// Asks each signed-in store whether the account owns each game (and Steam's current build id).
    func checkOwnership(app: AppModel) {
        guard !checking else { return }
        checking = true
        message = ""
        Task {
            var notes: [String] = []
            if app.meta.signedIn, let token = try? app.meta.token() {
                do {
                    let client = MetaClient(token: token)
                    let gate = RequestGate()
                    let user = try await gate.run { try await client.me() }
                    for i in rows.indices {
                        guard let id = rows[i].entry.metaRecipe, let recipe = Recipes.recipe(id: id) else { continue }
                        let appID = recipe.appId
                        rows[i].owned[.meta] = try await gate.run { try await client.ownsApp(appId: appID, userId: user) }
                    }
                } catch { notes.append("Meta: \(error)") }
            }
            if app.steam.signedIn {
                do {
                    let session = try await app.steam.loggedOnSession()
                    let library = try await SteamLibrary.fetch(session: session,
                                                               cacheURL: AppSettings.supportDir.appendingPathComponent("steam-library-cache.json"))
                    let owned = Set(library.map(\.appID))
                    for i in rows.indices {
                        guard let appID = rows[i].entry.steamApp else { continue }
                        rows[i].owned[.steam] = owned.contains(appID)
                        if let info = try? await session.appInfo(app: appID) {
                            rows[i].steamBuild = info["depots"]?["branches"]?["public"]?["buildid"]?.value
                        }
                    }
                    await session.disconnect()
                } catch { notes.append("Steam: \(error)") }
            }
            if !app.meta.signedIn && !app.steam.signedIn {
                notes.append(L("Inicia sesión en Cuentas primero", "Sign in under Accounts first"))
            }
            message = notes.joined(separator: " · ")
            checking = false
        }
    }

    /// Fetch the game's APK on this Mac from `store`, then run the translate script in Klepton.
    func update(_ entry: CatalogEntry, from store: StoreKind, app: AppModel) {
        guard running == nil else { return }
        running = entry.target
        log.clear()
        let sink = log.sink()
        task = Task {
            do {
                sink("== \(entry.display): \(L("descargando APK de", "fetching APK from")) \(store.label)")
                let apk = try await fetchAPK(entry, store: store, app: app, sink: sink)
                sink("== APK: \(apk.path)")
                try Task.checkCancellation()
                try await translate(entry, apk: apk, settings: app.settings, sink: sink)
                sink("== " + L("Hecho. Siguiente: Compilar e instalar.", "Done. Next: Build & Install."))
                await refresh(settings: app.settings)
            } catch is CancellationError {
                sink("!! " + L("cancelado", "cancelled"))
            } catch {
                sink("!! \(error)")
            }
            running = nil
        }
    }

    func cancel() {
        task?.cancel()
        runner.cancel()
    }

    private func fetchAPK(_ entry: CatalogEntry, store: StoreKind, app: AppModel,
                          sink: @escaping @Sendable (String) -> Void) async throws -> URL {
        let downloads = app.settings.expanded(app.settings.downloadsPath)
        let throttle = Throttle()
        switch store {
        case .meta:
            // TODO: when MetaStore grows its `fetch` library entry point (being added in another
            // worktree), call that instead of driving Fetcher here.
            guard let id = entry.metaRecipe, let recipe = Recipes.recipe(id: id), let apkFile = recipe.apk else {
                throw HubError(L("Sin receta de Meta", "No Meta recipe"))
            }
            let client = MetaClient(token: try app.meta.token())
            let gs = GameStore(root: downloads.appendingPathComponent("meta/\(entry.target)", isDirectory: true))
            let record = gs.loadRecord()
            // Only the APK: OBBs and add-ons are what the headset downloads itself.
            let plan = FetchPlan.plan(recipe: recipe, selection: FetchSelection(), record: record, state: gs.state(of:))
                .filter { $0.file.id == apkFile.id }
            let summary = try await Fetcher(client: client, store: gs).run(plan, recipe: recipe, progress: { p in
                guard throttle.ready() else { return }
                let pct = p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) * 100 : 0
                sink(String(format: "%@ %.1f%% (%@ / %@)%@", p.fileName, pct, formatBytes(p.bytesDone), formatBytes(p.bytesTotal),
                            p.verifying ? " verifying" : ""))
            }, log: sink)
            sink("Meta: \(summary.downloaded) downloaded, \(summary.kept) kept")
            return gs.url(for: apkFile)
        case .steam:
            guard let appID = entry.steamApp, let depot = entry.steamAPKDepot, let name = entry.steamAPKName else {
                throw HubError(L("La versión de Steam no es un APK (el visor la descarga)", "The Steam build is not an APK (the headset downloads it)"))
            }
            let session = try await app.steam.loggedOnSession(log: sink)
            let downloader = SteamDepotDownloader(session: session, log: sink)
            let dir = downloads.appendingPathComponent("steam/\(entry.target)", isDirectory: true)
            let wanted = name.lowercased()
            let opts = DepotDownloadOptions(appID: appID, depotID: depot, directory: dir,
                                            include: { $0.lowercased() == wanted },
                                            pinnedManifestID: SupportedTitles.byAppID[appID]?.manifestSelection(depot: depot).pinnedGID)
            let summary = try await downloader.download(opts) { p in
                guard p.phase == .downloading, throttle.ready() else { return }
                let pct = p.bytesToDownload > 0 ? Double(p.bytesDownloaded) / Double(p.bytesToDownload) * 100 : 100
                sink(String(format: "%.1f%% (%@ / %@)", pct, formatBytes(Int64(p.bytesDownloaded)), formatBytes(Int64(p.bytesToDownload))))
            }
            await session.disconnect()
            sink("Steam: manifest \(summary.manifestID), \(summary.files) files, \(formatBytes(Int64(summary.bytesDownloaded))) written")
            return dir.appendingPathComponent(name)
        }
    }

    private func translate(_ entry: CatalogEntry, apk: URL, settings: AppSettings, sink: @escaping @Sendable (String) -> Void) async throws {
        guard let k = settings.kleptonURL, settings.hasKlepton else { throw HubError(L("Ruta de Klepton no válida", "Invalid Klepton path")) }
        let cmd = ShellCommand.bash(settings.translateScript,
                                    environment: ["APK": apk.path, "KLEPTON_TARGET": entry.target],
                                    currentDirectory: k.path)
        sink("$ (translate script in \(k.path))")
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            do {
                try runner.start(cmd, onLine: sink, onExit: { cont.resume(returning: $0) })
            } catch { cont.resume(throwing: error) }
        }
        guard status == 0 else { throw HubError(L("el script de traducción salió con \(status)", "translate script exited with \(status)")) }
    }
}

struct GamesView: View {
    @Environment(AppModel.self) private var app
    @State private var confirm: (CatalogEntry, StoreKind)?

    var body: some View {
        let games = app.games
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: L("Juegos", "Games"),
                         subtitle: L("Catálogo del hub, propiedad en cada tienda y versión traducida frente a la de la tienda.",
                                     "The hub's catalog, ownership per store, and translated version vs store version.")) {
                HStack {
                    if games.checking { ProgressView().controlSize(.small) }
                    Button(L("Comprobar propiedad", "Check ownership")) { games.checkOwnership(app: app) }
                        .disabled(games.checking)
                    Button(L("Recargar", "Reload")) { Task { await games.refresh(settings: app.settings) } }
                }
            }
            if !games.message.isEmpty { Text(games.message).foregroundStyle(.secondary) }
            Table(games.rows) {
                TableColumn(L("Juego", "Game")) { r in
                    VStack(alignment: .leading) {
                        Text(r.entry.display).bold()
                        Text(r.entry.target).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn(L("Tiendas", "Stores")) { r in
                    HStack {
                        ForEach(r.entry.stores) { s in
                            Badge(text: s.label + ownedMark(r.owned[s]), color: ownedColor(r.owned[s]))
                        }
                    }
                }
                TableColumn(L("Traducido", "Translated")) { r in
                    VStack(alignment: .leading) {
                        Text(r.translated?.description ?? "—")
                        if r.frameworksBuilt { Text(L("frameworks listos", "frameworks built")).font(.caption).foregroundStyle(.green) }
                    }
                }
                TableColumn(L("En la tienda", "Store version")) { r in
                    VStack(alignment: .leading) {
                        if let m = r.metaVersion { Text("Meta \(m)") }
                        if let b = r.steamBuild { Text("Steam build \(b)") }
                        if r.metaVersion == nil && r.steamBuild == nil { Text("—") }
                    }
                }
                TableColumn("") { r in
                    HStack {
                        ForEach(r.entry.apkStores) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Button(L("Actualizar (\(s.label))", "Update (\(s.label))")) { confirm = (r.entry, s) }
                                    .disabled(games.running != nil || !signedIn(s))
                                    .help(signedIn(s) ? "" : L("Inicia sesión en \(s.label) en Cuentas", "Sign in to \(s.label) in Accounts"))
                                if !signedIn(s) {
                                    Text(L("Inicia sesión en \(s.label) (Cuentas)", "Sign in to \(s.label) (Accounts)"))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        if r.entry.apkStores.isEmpty {
                            Text(L("el visor lo descarga", "headset downloads it")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 260)
            HStack {
                Text(L("Salida", "Output")).font(.headline)
                if let t = games.running {
                    ProgressView().controlSize(.small)
                    Text(t).foregroundStyle(.secondary)
                    Button(L("Cancelar", "Cancel")) { games.cancel() }
                }
            }
            LogConsoleView(store: games.log, showFilters: false)
        }
        .padding(20)
        .task { await games.refresh(settings: app.settings) }
        .confirmationDialog(L("¿Actualizar este juego?", "Update this game?"), isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let (entry, store) = confirm {
                Button(L("Descargar y traducir", "Fetch and translate")) { games.update(entry, from: store, app: app) }
            }
        } message: {
            Text(L("Descarga el APK en este Mac y ejecuta el script de traducción (Ajustes) en Klepton. Sobrescribe el árbol del juego en Klepton.",
                   "Downloads the APK to this Mac and runs the translate script (Settings) in Klepton. It overwrites the game's tree in Klepton."))
        }
    }

    private func signedIn(_ s: StoreKind) -> Bool { s == .steam ? app.steam.signedIn : app.meta.signedIn }
    private func ownedMark(_ v: Bool?) -> String { v.map { $0 ? " ✓" : " ✗" } ?? "" }
    private func ownedColor(_ v: Bool?) -> Color { v.map { $0 ? .green : .red } ?? .secondary }
}
