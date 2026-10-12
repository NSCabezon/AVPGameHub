// Game content from Meta's store, on the headset (the hub's Meta source).
//
// The MetaStore package (../../packages/MetaStore) downloads a game's exact
// Quest build — the files a recipe names by store id, size and sha256 — with the
// player's own Meta account: Meta only hands a file to an account that owns it.
//
// Sign-in happens on the Mac, never here: `metastore login` runs Meta's own
// signed ovr-platform-util (the password goes to Meta's tool only), then
// `metastore push-token` copies the token into this app's Documents/ as a
// one-time file, which MetaAccountModel moves into the Keychain and deletes.
// The token is only ever sent as a header to graph.oculus.com and
// securecdn.oculus.com, and never logged.
//
// Every request to Meta goes through ONE gate (5 s apart; avp-play's lesson: a
// burst of ~140 requests locked an account out), and a download stops at the
// first unexpected answer. Files land where the target reads them: the APK in
// <container>/meta/ (HubPrep derives <row.apk> and <tree>/assets from it), the
// OBB and bought DLC packs in <container>/android-files/obb/.
#if KL_HUB && canImport(MetaStore)
import SwiftUI
import UIKit
import MetaStore

/// The Meta account on this headset and what it owns.
@MainActor
final class MetaAccountModel: ObservableObject {
    static let shared = MetaAccountModel()

    let tokens = KeychainTokenStore()
    /// Every request the hub sends to Meta waits its turn here.
    let gate = RequestGate(minInterval: .seconds(5))
    let cache: OwnershipCache
    @Published private(set) var signedIn = false
    @Published private(set) var userId: String?
    /// Last answers by store app id.
    @Published private(set) var owned: [String: OwnershipRecord] = [:]
    @Published private(set) var checking = false
    @Published var error: String?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cache = OwnershipCache(url: support.appendingPathComponent("metastore/ownership.json"))
        importHandoff()
        signedIn = (try? tokens.load()) != nil
        if let any = cache.loadAny() { userId = any.userId; owned = any.apps }
    }

    /// `metastore push-token` leaves Documents/metastore-token.json: into the Keychain, file deleted.
    func importHandoff() {
        if TokenHandoff.importIfPresent(in: Paths.documents, into: tokens) {
            NSLog("[meta] imported a Meta token from Documents/\(TokenHandoff.fileName) into the Keychain (file deleted)")
            cache.clear()
            owned = [:]; userId = nil
        }
        signedIn = (try? tokens.load()) != nil
    }

    func token() -> String? { (try? tokens.load()) ?? nil }

    /// nil = no answer yet.
    func owns(appId: String) -> Bool? { owned[appId]?.owned }

    /// The store app ids of the catalog's Meta sources this build carries.
    var catalogAppIds: [String] {
        klHubGameRows.compactMap { KLCatalog.metaRecipe($0.target)?.appId }
    }

    /// Ask Meta about every catalog game whose answer is older than a day (or all, `force`).
    func refresh(force: Bool = false, then: (() -> Void)? = nil) {
        importHandoff()
        guard !checking, let token = token() else {
            if !checking { NSLog("[meta] no Meta token on this headset: ownership unknown (sign in on the Mac and push the token)") }
            then?(); return
        }
        let ids = catalogAppIds
        guard !ids.isEmpty else { then?(); return }
        NSLog("[meta] ownership check (\(force ? "forced" : "answers older than a day")) for app(s) \(ids.joined(separator: ", "))")
        checking = true
        error = nil
        let cache = self.cache, gate = self.gate
        Task {
            do {
                let r = try await OwnershipCheck.refresh(client: MetaClient(token: token), appIds: ids, cache: cache,
                                                         gate: gate, force: force)
                userId = r.userId
                owned = r.apps
                NSLog("[meta] user \(KLAccountPrivacy.mask(r.userId)): " + r.apps.map { "\($0.key)=\($0.value.owned ? "owned" : "not owned")" }.sorted().joined(separator: ", "))
            } catch MetaError.tokenRejected(let why) {
                NSLog("[meta] token rejected: \(why)")
                error = klL("Meta rejected the saved sign-in. Sign in to Meta again on your Mac (AVP Game Hub → Accounts).",
                            "Meta rechazó la sesión guardada. Vuelve a iniciar sesión en Meta en tu Mac (AVP Game Hub → Cuentas).")
            } catch {
                NSLog("[meta] ownership check failed: \(error)")
                self.error = "\(error)"
            }
            checking = false
            then?()
        }
    }

    func signOut() {
        try? tokens.clear()
        cache.clear()
        signedIn = false
        userId = nil
        owned = [:]
        NSLog("[meta] signed out (Keychain token and ownership answers removed)")
    }
}

/// Download / verify of one game's Meta recipe.
@MainActor
final class MetaContentModel: ObservableObject {
    enum Stage: Equatable { case idle, working(String), paused, complete, failed(String) }

    let target: String
    let recipe: Recipe
    let store: GameStore
    @Published var stage: Stage = .idle
    @Published var progress: Fetcher.Progress?
    @Published var speed: Double = 0
    @Published var freeBytes: UInt64?
    @Published private(set) var complete = false
    @Published private(set) var hasAnything = false
    /// The base game's required files are all verified (voice packs aside).
    @Published private(set) var baseComplete = false
    /// The voice-language packs this game is installed with (KLCatalog.metaVoiceLocales): fetched
    /// with the game, part of "installed". Changed on the game's page ("Voice languages").
    @Published private(set) var voiceLocales: Set<String> = []
    /// The voice packs on disk, verified at their exact size.
    @Published private(set) var installedVoiceLocales: Set<String> = []
    /// A pack the game asked the platform for during a session and did not get (the runtime's
    /// note in android-files/, see klplat_langpack_note_request), until it is installed.
    @Published private(set) var requestedVoiceLocale: String?
    private var samples: [(t: Date, b: Int64)] = []
    private var task: Task<Void, Never>?
    /// Bytes of the running plan before each of its files (by file name): one file's own progress.
    private var planBase: [String: Int64] = [:]
    /// A pack was added while a download ran (its plan was made without it): go again after.
    private var rerun = false
    var interruptedByBackground = false

    init(target: String, recipe: Recipe) {
        self.target = target
        self.recipe = recipe
        self.store = KLCatalog.metaStore(target)
        self.voiceLocales = KLCatalog.metaVoiceLocales(target, recipe)
        refreshLocal()
        if complete { stage = .complete }
    }

    var account: MetaAccountModel { MetaAccountModel.shared }
    var isBusy: Bool { task != nil }
    var requiredBytes: Int64 { recipe.files(locales: voiceLocales).reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: Voice-language packs

    /// The recipe's optional voice packs, in the recipe's order. Empty for most games.
    var voicePacks: [RecipeFile] { recipe.files.filter { $0.locale != nil } }

    /// The pack for the player's language (game setting, else headset).
    var recommendedVoiceLocale: String? { KLCatalog.metaRecommendedVoiceLocale(target, recipe) }

    /// The pack's own progress while the running download is on it (0...1), else nil.
    func voicePackFraction(_ f: RecipeFile) -> Double? {
        guard isBusy, let p = progress, p.fileName == f.name, !p.verifying,
              let base = planBase[f.name], let size = f.size, size > 0 else { return nil }
        return min(1, max(0, Double(p.bytesDone - base) / Double(size)))
    }

    /// The pack is being checksummed after its download.
    func voicePackVerifying(_ f: RecipeFile) -> Bool {
        isBusy && progress?.fileName == f.name && progress?.verifying == true
    }

    /// Add a pack to the game. Base game installed and nothing running: downloaded now (the
    /// same path as the game's own download: ownership asked fresh, one request at a time through
    /// the account's gate, checksum verified). A download running: fetched right after it. Base
    /// game not downloaded yet: fetched with it.
    func addVoicePack(_ locale: String) {
        guard recipe.voiceLocales.contains(locale) else { return }
        voiceLocales.insert(locale)
        KLCatalog.setMetaVoiceLocales(voiceLocales, for: target)
        log("voice pack \(locale) added (now \(voiceLocales.sorted().joined(separator: ", ")))")
        refreshLocal()
        if isBusy { rerun = true }
        else if baseComplete { start() }
    }

    /// Take a pack off the game: no longer part of "installed", and its file (finished or
    /// partial) deleted. Not while a download runs (its plan may be writing it).
    func removeVoicePack(_ locale: String) {
        guard !isBusy, let f = voicePacks.first(where: { $0.locale == locale }) else { return }
        voiceLocales.remove(locale)
        KLCatalog.setMetaVoiceLocales(voiceLocales, for: target)
        let fm = FileManager.default
        try? fm.removeItem(at: store.url(for: f))
        try? fm.removeItem(at: store.partialURL(for: f))
        if var r = store.loadRecord(), r.files.removeValue(forKey: f.relativePath) != nil {
            r.updated = Date()
            try? store.save(r)
        }
        log("voice pack \(locale) removed (now \(voiceLocales.sorted().joined(separator: ", ")))")
        refreshLocal()
        if !isBusy, complete { stage = .complete }
    }

    /// The runtime's note: the tag on the first line, the file name on the second.
    private var requestNoteURL: URL { store.root.appendingPathComponent("android-files/klepton-voicepack-request.txt") }

    private func readVoicePackRequest() -> String? {
        guard !voicePacks.isEmpty, let text = try? String(contentsOf: requestNoteURL, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let pack = voicePacks.first { f in lines.contains { $0 == f.locale || $0 == f.name || $0 == f.localFileName } }
        guard let locale = pack?.locale else { return nil }
        if installedVoiceLocales.contains(locale) {
            try? FileManager.default.removeItem(at: requestNoteURL)    // answered: the pack is there now
            return nil
        }
        return locale
    }

    /// Fraction for the library card while working.
    var activeFraction: Double? {
        guard isBusy, let p = progress, p.bytesTotal > 0 else { return isBusy ? 0 : nil }
        return Double(p.bytesDone) / Double(p.bytesTotal)
    }

    func refreshLocal() {
        complete = store.isComplete(recipe, locales: voiceLocales)
        baseComplete = store.isComplete(recipe)
        hasAnything = store.hasAnything(recipe)
        if !voicePacks.isEmpty {
            let verified = store.loadRecord().flatMap { $0.versionCode == recipe.versionCode ? $0.files : nil } ?? [:]
            installedVoiceLocales = Set(voicePacks.compactMap { f in
                guard let l = f.locale, let size = f.size, verified[f.relativePath]?.size == size,
                      GameStore.fileSize(store.url(for: f)) == size else { return nil }
                return l
            })
            requestedVoiceLocale = readVoicePackRequest()
        }
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        if let v = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage { freeBytes = UInt64(v) }
        if !isBusy, case .complete = stage, !complete { stage = .idle }
    }

    func start() {
        guard task == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        samples = []
        task = Task { [weak self] in
            await self?.run()
            await MainActor.run {
                guard let self else { return }
                self.task = nil
                self.planBase = [:]
                UIApplication.shared.isIdleTimerDisabled = false
                self.refreshLocal()
                // A pack added while it ran: its turn now (same MainActor turn, so "Download
                // all" never sees this game idle in between).
                if self.rerun {
                    self.rerun = false
                    if case .idle = self.stage { self.start() }
                }
            }
        }
    }

    func pause() {
        task?.cancel()
        stage = .paused
    }

    private func log(_ s: String) { NSLog("[meta] \(target): \(s)") }

    private func run() async {
        account.importHandoff()
        guard let token = account.token() else {
            stage = .failed(HubLibraryModel.metaSignInHint)
            return
        }
        let client = MetaClient(token: token)
        let gate = account.gate
        let recipe = self.recipe, store = self.store
        do {
            // Ownership, asked fresh right before downloading (the cache only decides what is shown).
            stage = .working(klL("Checking your Meta library…", "Comprobando tu biblioteca de Meta…"))
            let user = try await gate.run { try await client.me() }
            let owns = try await gate.run { try await client.ownsApp(appId: recipe.appId, userId: user) }
            guard owns else { throw MetaError.notOwned(recipe.title) }

            // Add-ons: only what the store confirms as bought.
            var skus: Set<String> = []
            if let addons = recipe.addons, !addons.items.isEmpty {
                stage = .working(klL("Reading your purchases…", "Leyendo tus compras…"))
                do {
                    skus = Set(try await gate.run { try await client.purchases(appId: recipe.appId) })
                    log("\(skus.count) purchase(s) on the account")
                } catch {
                    log("purchases not readable (\(error)); add-ons skipped this time")
                }
            }
            let record = store.loadRecord()
            let locales = voiceLocales
            if !locales.isEmpty {
                // What this download is made with stays the game's packs from now on (a later
                // change of the game's or the headset's language does not silently add one).
                if !KLCatalog.hasStoredMetaVoiceLocales(target) { KLCatalog.setMetaVoiceLocales(locales, for: target) }
                log("voice-language packs: \(locales.sorted().joined(separator: ", "))")
            }
            let selection = FetchSelection(ownedSKUs: skus, withheld: Set(record?.withheld ?? []), locales: locales)
            let plan = FetchPlan.plan(recipe: recipe, selection: selection, record: record, state: store.state(of:))
            let missing = plan.reduce(Int64(0)) { sum, p in
                switch p.action {
                case .keep: return sum
                case .resume(let from): return sum + max(0, (p.file.size ?? 0) - from)
                case .download: return sum + (p.file.size ?? 0)
                }
            }
            var base: Int64 = 0
            planBase = [:]
            for p in plan { planBase[p.file.name] = base; base += p.file.size ?? 0 }
            refreshLocal()
            if let free = freeBytes, UInt64(max(0, missing)) + 1_000_000_000 > free {
                stage = .failed(klL("Not enough space: \(gb(missing)) to download, \(gb(Int64(free))) free.",
                                    "No hay espacio: \(gb(missing)) por descargar, \(gb(Int64(free))) libres."))
                return
            }
            stage = .working(klL("Downloading from Meta…", "Descargando de Meta…"))
            log("plan: " + plan.map { "\($0.file.name)=\($0.action)" }.joined(separator: ", "))
            let summary = try await Fetcher(client: client, store: store, gate: gate)
                .run(plan, recipe: recipe, progress: { p in
                    Task { @MainActor [weak self] in self?.update(p) }
                }, log: { [target] s in NSLog("[meta] \(target): \(s)") })
            log("done: \(summary.downloaded) downloaded, \(summary.kept) kept, \(summary.withheld.count) withheld")
            refreshLocal()
            if complete { stage = .complete }
            else if voiceLocales != locales, rerun { stage = .idle }   // a pack added meanwhile: start() goes again
            else {
                stage = .failed(klL("Download finished but the files are not complete.",
                                    "La descarga terminó pero faltan archivos."))
            }
        } catch is CancellationError {
            stage = .paused
        } catch {
            if Task.isCancelled { stage = .paused; return }
            log("failed: \(Redaction.redact("\(error)"))")
            stage = .failed(Redaction.redact("\(error)"))
        }
    }

    private func update(_ p: Fetcher.Progress) {
        guard task != nil else { return }
        progress = p
        let now = Date()
        samples.append((now, p.bytesDone))
        samples.removeAll { now.timeIntervalSince($0.t) > 15 }
        if let first = samples.first, let last = samples.last, last.t.timeIntervalSince(first.t) > 1 {
            speed = Double(last.b - first.b) / last.t.timeIntervalSince(first.t)
        }
    }
}

private func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
private func mbps(_ b: Double) -> String { String(format: "%.1f MB/s", b / 1e6) }

/// Download / progress for one game's Meta source (the hub's detail view).
struct MetaContentView: View {
    @ObservedObject var model: MetaContentModel
    @ObservedObject var account = MetaAccountModel.shared
    let onPlay: () -> Void
    let onBack: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            page.padding(32)
        }
        .onAppear { model.refreshLocal() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.isBusy { model.interruptedByBackground = true }
            if phase == .active, model.interruptedByBackground {
                model.interruptedByBackground = false
                if case .failed = model.stage { model.start() }
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Button { onBack() } label: { Label(klL("Library", "Biblioteca"), systemImage: "chevron.left") }
                Text(model.recipe.title).font(.largeTitle.bold())
                Spacer()
                if account.signedIn { Text(KLAccountPrivacy.metaLabel).font(.footnote).foregroundStyle(.secondary) }
            }
            Text(klL("Quest build \(model.recipe.versionName) from Meta's store · \(gb(model.requiredBytes))",
                     "Versión de Quest \(model.recipe.versionName) de la tienda de Meta · \(gb(model.requiredBytes))"))
                .foregroundStyle(.secondary)
            content
            if !model.voicePacks.isEmpty { MetaVoicePacksSection(model: model) }
            if model.isBusy {
                Label(klL("Keep this window open and the headset on: visionOS pauses apps in the background, "
                          + "and the download stops with it. It resumes where it left off.",
                          "Deja esta ventana abierta y el visor puesto: visionOS pausa las apps en segundo plano "
                          + "y la descarga se para con ellas. Sigue donde se quedó."),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if !account.signedIn {
            VStack(alignment: .leading, spacing: 8) {
                Text(klL("Not signed in to Meta", "Sin sesión en Meta")).font(.title3)
                Text(HubLibraryModel.metaSignInHint + klL(", then open this page again.", " y vuelve a abrir esta página."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            switch model.stage {
            case .idle:
                VStack(alignment: .leading, spacing: 12) {
                    if model.hasAnything {
                        Text(klL("Part of the game is already on this headset; only what is missing is downloaded.",
                                 "Parte del juego ya está en este visor; solo se descarga lo que falta."))
                    }
                    if let free = model.freeBytes {
                        Text(klL("Free space: \(gb(Int64(free)))", "Espacio libre: \(gb(Int64(free)))")).font(.footnote)
                            .foregroundStyle(Int64(free) < model.requiredBytes + 1_000_000_000 ? .orange : .secondary)
                    }
                    Button(model.hasAnything ? klL("Complete download from Meta", "Completar descarga de Meta")
                                             : klL("Download \(model.recipe.title) from Meta", "Descargar \(model.recipe.title) de Meta")) { model.start() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text(klL("Add-on packs are downloaded only when Meta confirms them as bought on this account.",
                             "Los paquetes adicionales solo se descargan si Meta confirma que los compraste con esta cuenta."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .working(let what):
                VStack(alignment: .leading, spacing: 12) {
                    if let p = model.progress, p.bytesTotal > 0 {
                        Text(p.verifying ? klL("Verifying \(p.fileName)…", "Verificando \(p.fileName)…") : what).font(.title3)
                        ProgressView(value: Double(p.bytesDone), total: Double(p.bytesTotal))
                        Text(klL("\(gb(p.bytesDone)) of \(gb(p.bytesTotal)) · file \(p.fileIndex)/\(p.fileCount) · \(mbps(model.speed))",
                                 "\(gb(p.bytesDone)) de \(gb(p.bytesTotal)) · archivo \(p.fileIndex)/\(p.fileCount) · \(mbps(model.speed))"))
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) { ProgressView(); Text(what) }
                    }
                    Button(klL("Pause", "Pausar")) { model.pause() }
                }
            case .paused:
                VStack(alignment: .leading, spacing: 12) {
                    Text(klL("Paused.", "En pausa.")).font(.title3)
                    Button(klL("Resume", "Reanudar")) { model.start() }.buttonStyle(.borderedProminent)
                }
            case .complete:
                VStack(alignment: .leading, spacing: 12) {
                    Label(klL("\(model.recipe.title) is installed and verified.", "\(model.recipe.title) está instalado y verificado."),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.title3)
                    HStack(spacing: 16) {
                        Button(klL("Play", "Jugar")) { onPlay() }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button(klL("Check for new add-ons", "Buscar contenido adicional nuevo")) { model.start() }
                    }
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 12) {
                    Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    Button(klL("Retry", "Reintentar")) { model.start() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// "Voice languages" on a Meta game's page, for a recipe with optional voice-language packs
/// (Batman): one row per pack with its size, whether it is on the headset, and Download / Delete.
/// The game's own download fetches the packs chosen here (by default the player's language plus
/// en-US); a pack added here later goes through that same download.
struct MetaVoicePacksSection: View {
    @ObservedObject var model: MetaContentModel
    @State private var confirmDelete: RecipeFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(klL("Voice languages", "Idiomas de voz")).font(.title3.bold())
            Text(klL("The game's spoken dialogue comes in one pack per language. The game plays the pack for its "
                     + "language setting and falls back to English; it cannot download one itself.",
                     "Los diálogos hablados del juego vienen en un paquete por idioma. El juego usa el del idioma "
                     + "que tenga configurado y, si falta, el inglés; no puede descargarlo él mismo."))
                .font(.footnote).foregroundStyle(.secondary)
            if let req = model.requestedVoiceLocale {
                Label(klL("The game asked for the \(KLCatalog.voicePackName(req)) voice pack — download it here.",
                          "El juego pidió el paquete de voz \(KLCatalog.voicePackName(req)) — descárgalo aquí."),
                      systemImage: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.voicePacks.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider() }
                    row(f).padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.top, 8)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmDelete != nil },
                                                               set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { f in
            Button(klL("Delete", "Borrar"), role: .destructive) {
                if let l = f.locale { model.removeVoicePack(l) }
            }
        } message: { f in Text(confirmMessage(f)) }
    }

    @ViewBuilder private func row(_ f: RecipeFile) -> some View {
        let locale = f.locale ?? ""
        let installed = model.installedVoiceLocales.contains(locale)
        let chosen = model.voiceLocales.contains(locale)
        let fraction = model.voicePackFraction(f)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(KLCatalog.voicePackName(locale)).font(.body.bold())
                    Text(locale).font(.caption).foregroundStyle(.secondary)
                    ForEach(badges(locale), id: \.self) { b in
                        Text(b).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
                Text("\(gb(f.size ?? 0)) · " + stateText(f, installed: installed, chosen: chosen, fraction: fraction))
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(installed ? Color.green : fraction != nil ? Color.blue : Color.secondary)
                if let fraction { ProgressView(value: fraction) }
            }
            Spacer(minLength: 8)
            button(f, locale: locale, installed: installed, chosen: chosen)
        }
    }

    private func badges(_ locale: String) -> [String] {
        var out: [String] = []
        if locale == model.recommendedVoiceLocale {
            out.append(KLGameSettingsStore.language(for: model.target).locale != nil
                       ? klL("Recommended: the game's language", "Recomendado: idioma del juego")
                       : klL("Recommended: the headset's language", "Recomendado: idioma del visor"))
        }
        if locale == "en-US", locale != model.recommendedVoiceLocale {
            out.append(klL("Recommended: the game's fallback", "Recomendado: idioma base del juego"))
        }
        return out
    }

    private func stateText(_ f: RecipeFile, installed: Bool, chosen: Bool, fraction: Double?) -> String {
        if let fraction { return klL("Downloading \(Int((fraction * 100).rounded())) %", "Descargando \(Int((fraction * 100).rounded())) %") }
        if model.voicePackVerifying(f) { return klL("Verifying…", "Verificando…") }
        if installed { return klL("Installed", "Instalado") }
        if chosen && model.isBusy { return klL("Queued", "En cola") }
        if chosen && !model.baseComplete { return klL("Not installed · downloads with the game", "No instalado · se descarga con el juego") }
        return klL("Not installed", "No instalado")
    }

    @ViewBuilder private func button(_ f: RecipeFile, locale: String, installed: Bool, chosen: Bool) -> some View {
        if installed {
            Button(klL("Delete", "Borrar"), role: .destructive) { confirmDelete = f }
                .disabled(model.isBusy)
        } else if chosen && (model.isBusy || !model.baseComplete) {
            // Queued (with the running download, or with the game's own): can be taken off while
            // nothing runs.
            Button(klL("Remove", "Quitar")) { model.removeVoicePack(locale) }
                .disabled(model.isBusy)
        } else if chosen {
            // Chosen but not there (a failed or paused download): fetch it now.
            Button(klL("Download", "Descargar")) { model.start() }.buttonStyle(.borderedProminent)
        } else {
            Button(klL("Download", "Descargar")) { model.addVoicePack(locale) }.buttonStyle(.borderedProminent)
        }
    }

    private var confirmTitle: String {
        guard let l = confirmDelete?.locale else { return "" }
        return klL("Delete the \(KLCatalog.voicePackName(l)) voices?", "¿Borrar las voces en \(KLCatalog.voicePackName(l))?")
    }

    /// Frees the pack's size; and says so plainly when the game would be left without the voices
    /// it plays (the pack for its language, or the last pack on the headset).
    private func confirmMessage(_ f: RecipeFile) -> String {
        let l = f.locale ?? ""
        var m = klL("Frees \(gb(f.size ?? 0)). You can download it again here at any time.",
                    "Libera \(gb(f.size ?? 0)). Puedes volver a descargarlo aquí cuando quieras.")
        let others = model.installedVoiceLocales.subtracting([l])
        if others.isEmpty {
            m += klL("\n\nWarning: this is the last voice pack on the headset — the game will have no spoken dialogue.",
                     "\n\nAtención: es el último paquete de voz del visor — el juego se quedará sin diálogos hablados.")
        } else if l == model.recommendedVoiceLocale {
            m += klL("\n\nWarning: the game is set to this language. Without it the game asks to download it "
                     + "(which it cannot do itself) and plays another language.",
                     "\n\nAtención: el juego está en este idioma. Sin él, el juego pedirá descargarlo "
                     + "(no puede hacerlo él mismo) y usará otro idioma.")
        }
        return m
    }
}

/// The settings sheet's Meta account section.
struct MetaAccountSection: View {
    @ObservedObject var account = MetaAccountModel.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if account.signedIn {
                LabeledContent(klL("Signed in", "Sesión iniciada"),
                               value: account.userId != nil ? KLAccountPrivacy.metaLabel : klL("(not checked yet)", "(aún sin comprobar)"))
                HStack {
                    Button(account.checking ? klL("Checking…", "Comprobando…") : klL("Check Meta library now", "Comprobar biblioteca de Meta ahora")) {
                        account.refresh(force: true)
                    }
                        .disabled(account.checking)
                    Spacer()
                    Button(klL("Sign out of Meta", "Cerrar sesión de Meta"), role: .destructive) { confirmSignOut = true }
                }
                if let e = account.error { Text(e).font(.caption).foregroundStyle(.orange) }
            } else {
                Text(klL("Not signed in. ", "Sin sesión. ") + HubLibraryModel.metaSignInHint + ".")
                    .foregroundStyle(.secondary)
            }
        } header: { Text(klL("Meta account", "Cuenta de Meta")) } footer: {
            Text(klL("Only a sign-in token is kept, in this headset's Keychain; it is sent only to Meta's own servers. "
                     + "Unofficial store access: personal use with your own purchases.",
                     "Solo se guarda un token de sesión, en el llavero de este visor; solo se envía a los servidores de Meta. "
                     + "Acceso no oficial a la tienda: uso personal con tus propias compras."))
        }
        .confirmationDialog(klL("Sign out of Meta?", "¿Cerrar sesión de Meta?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(klL("Sign out", "Cerrar sesión"), role: .destructive) { account.signOut() }
        }
    }
}
#endif
