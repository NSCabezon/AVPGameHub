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
        guard !checking, let token = token() else { then?(); return }
        let ids = catalogAppIds
        guard !ids.isEmpty else { then?(); return }
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
                error = "Meta rejected the saved sign-in. On the Mac: metastore login, then metastore push-token."
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
    private var samples: [(t: Date, b: Int64)] = []
    private var task: Task<Void, Never>?
    var interruptedByBackground = false

    init(target: String, recipe: Recipe) {
        self.target = target
        self.recipe = recipe
        self.store = KLCatalog.metaStore(target)
        refreshLocal()
        if complete { stage = .complete }
    }

    var account: MetaAccountModel { MetaAccountModel.shared }
    var isBusy: Bool { task != nil }
    var requiredBytes: Int64 { recipe.files.filter(\.required).reduce(0) { $0 + ($1.size ?? 0) } }

    /// Fraction for the library card while working.
    var activeFraction: Double? {
        guard isBusy, let p = progress, p.bytesTotal > 0 else { return isBusy ? 0 : nil }
        return Double(p.bytesDone) / Double(p.bytesTotal)
    }

    func refreshLocal() {
        complete = store.isComplete(recipe)
        hasAnything = store.hasAnything(recipe)
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

    private func log(_ s: String) { NSLog("[meta] \(target): \(s)") }

    private func run() async {
        account.importHandoff()
        guard let token = account.token() else {
            stage = .failed("Not signed in to Meta. On the Mac: metastore login, then metastore push-token.")
            return
        }
        let client = MetaClient(token: token)
        let gate = account.gate
        let recipe = self.recipe, store = self.store
        do {
            // Ownership, asked fresh right before downloading (the cache only decides what is shown).
            stage = .working("Checking your Meta library…")
            let user = try await gate.run { try await client.me() }
            let owns = try await gate.run { try await client.ownsApp(appId: recipe.appId, userId: user) }
            guard owns else { throw MetaError.notOwned(recipe.title) }

            // Add-ons: only what the store confirms as bought.
            var skus: Set<String> = []
            if let addons = recipe.addons, !addons.items.isEmpty {
                stage = .working("Reading your purchases…")
                do {
                    skus = Set(try await gate.run { try await client.purchases(appId: recipe.appId) })
                    log("\(skus.count) purchase(s) on the account")
                } catch {
                    log("purchases not readable (\(error)); add-ons skipped this time")
                }
            }
            let record = store.loadRecord()
            let selection = FetchSelection(ownedSKUs: skus, withheld: Set(record?.withheld ?? []))
            let plan = FetchPlan.plan(recipe: recipe, selection: selection, record: record, state: store.state(of:))
            let missing = plan.reduce(Int64(0)) { sum, p in
                switch p.action {
                case .keep: return sum
                case .resume(let from): return sum + max(0, (p.file.size ?? 0) - from)
                case .download: return sum + (p.file.size ?? 0)
                }
            }
            refreshLocal()
            if let free = freeBytes, UInt64(max(0, missing)) + 1_000_000_000 > free {
                stage = .failed("Not enough space: \(gb(missing)) to download, \(gb(Int64(free))) free.")
                return
            }
            stage = .working("Downloading from Meta…")
            log("plan: " + plan.map { "\($0.file.name)=\($0.action)" }.joined(separator: ", "))
            let summary = try await Fetcher(client: client, store: store, gate: gate)
                .run(plan, recipe: recipe, progress: { p in
                    Task { @MainActor [weak self] in self?.update(p) }
                }, log: { [target] s in NSLog("[meta] \(target): \(s)") })
            log("done: \(summary.downloaded) downloaded, \(summary.kept) kept, \(summary.withheld.count) withheld")
            refreshLocal()
            stage = complete ? .complete : .failed("Download finished but the files are not complete.")
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Button { onBack() } label: { Label("Library", systemImage: "chevron.left") }
                Text(model.recipe.title).font(.largeTitle.bold())
                Spacer()
                if account.signedIn { Text(KLAccountPrivacy.metaLabel).font(.footnote).foregroundStyle(.secondary) }
            }
            Text("Quest build \(model.recipe.versionName) from Meta's store · \(gb(model.requiredBytes))")
                .foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
            if model.isBusy {
                Label("Keep this window open and the headset on: visionOS pauses apps in the background, "
                      + "and the download stops with it. It resumes where it left off.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .onAppear { model.refreshLocal() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.isBusy { model.interruptedByBackground = true }
            if phase == .active, model.interruptedByBackground {
                model.interruptedByBackground = false
                if case .failed = model.stage { model.start() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !account.signedIn {
            VStack(alignment: .leading, spacing: 8) {
                Text("Not signed in to Meta").font(.title3)
                Text("Sign in on the Mac with Meta's own tool, then send the sign-in to this headset:\n"
                     + "  metastore login\n  metastore push-token\nThen open this page again.")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        } else {
            switch model.stage {
            case .idle:
                VStack(alignment: .leading, spacing: 12) {
                    if model.hasAnything { Text("Part of the game is already on this headset; only what is missing is downloaded.") }
                    if let free = model.freeBytes {
                        Text("Free space: \(gb(Int64(free)))").font(.footnote)
                            .foregroundStyle(Int64(free) < model.requiredBytes + 1_000_000_000 ? .orange : .secondary)
                    }
                    Button(model.hasAnything ? "Complete download from Meta" : "Download \(model.recipe.title) from Meta") { model.start() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Add-on packs are downloaded only when Meta confirms them as bought on this account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .working(let what):
                VStack(alignment: .leading, spacing: 12) {
                    if let p = model.progress, p.bytesTotal > 0 {
                        Text(p.verifying ? "Verifying \(p.fileName)…" : what).font(.title3)
                        ProgressView(value: Double(p.bytesDone), total: Double(p.bytesTotal))
                        Text("\(gb(p.bytesDone)) of \(gb(p.bytesTotal)) · file \(p.fileIndex)/\(p.fileCount) · \(mbps(model.speed))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) { ProgressView(); Text(what) }
                    }
                    Button("Pause") { model.pause() }
                }
            case .paused:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paused.").font(.title3)
                    Button("Resume") { model.start() }.buttonStyle(.borderedProminent)
                }
            case .complete:
                VStack(alignment: .leading, spacing: 12) {
                    Label("\(model.recipe.title) is installed and verified.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.title3)
                    HStack(spacing: 16) {
                        Button("Play") { onPlay() }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Check for new add-ons") { model.start() }
                    }
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 12) {
                    Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    Button("Retry") { model.start() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// The settings sheet's Meta account section.
struct MetaAccountSection: View {
    @ObservedObject var account = MetaAccountModel.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if account.signedIn {
                LabeledContent("Signed in", value: account.userId != nil ? KLAccountPrivacy.metaLabel : "(not checked yet)")
                HStack {
                    Button(account.checking ? "Checking…" : "Check Meta library now") { account.refresh(force: true) }
                        .disabled(account.checking)
                    Spacer()
                    Button("Sign out of Meta", role: .destructive) { confirmSignOut = true }
                }
                if let e = account.error { Text(e).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Not signed in. On the Mac: metastore login, then metastore push-token (one time).")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Meta account") } footer: {
            Text("Only a sign-in token is kept, in this headset's Keychain; it is sent only to Meta's own servers. "
                 + "Unofficial store access: personal use with your own purchases.")
        }
        .confirmationDialog("Sign out of Meta?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { account.signOut() }
        }
    }
}
#endif
