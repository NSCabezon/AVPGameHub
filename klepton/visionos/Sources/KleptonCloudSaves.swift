// Steam Cloud saves for the hub's games (EXPERIMENTAL).
//
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
//   launcher/App/AlyxLauncher/LauncherModel.swift (sync before play / on the next app open)
// The policy itself is SteamDepot's CloudSync (SteamDepot/Sources/SteamDepot/CloudSync.swift).
//
// Off per game until the person turns it on in the game's settings; then "download only" (the
// default) or "two-way". When it runs:
// - right before Play (after the ownership check, before the game's files are prepared), bounded:
//   a sync that has not finished in time is cancelled and awaited, so it never writes while the
//   game runs;
// - when the library appears, i.e. on the next app open after a session — quitting a game closes
//   Klepton (one game per process), so that is when a session's new saves go up (two-way only).
// Safety (CloudSync): local files are backed up (timestamped) before being replaced, nothing is
// ever deleted from the cloud, a file only goes up when it changed on the headset since the last
// sync baseline and the cloud still holds the version it came from, and conflicts keep both copies
// and upload nothing until resolved here.
//
// Where the saves are: Half-Life: Alyx writes them through kl_glibc's write layer,
// <home>/Library/Application Support/Klepton/userdata/alyx/gameroot/hlvr/save (on the headset,
// <home> is the app's data container), which is the Auto-Cloud rule gameinstall:game/hlvr/save.
#if KL_HUB && canImport(SteamDepot)
import SwiftUI
import Foundation
import SteamDepot

/// One game's cloud-save choice (UserDefaults `kl.cloudsaves.<target>`). Default: off.
struct KLCloudSaveSettings: Codable, Equatable {
    var enabled = false
    var mode: CloudSyncMode = .downloadOnly
}

enum KLCloudSaves {
    static func key(_ target: String) -> String { "kl.cloudsaves.\(target)" }

    static func settings(_ target: String) -> KLCloudSaveSettings {
        guard let d = UserDefaults.standard.data(forKey: key(target)),
              let s = try? JSONDecoder().decode(KLCloudSaveSettings.self, from: d) else { return KLCloudSaveSettings() }
        return s
    }

    static func save(_ s: KLCloudSaveSettings, for target: String) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key(target)) }
    }

    /// The save mapping for a hub game, or nil when cloud saves are not supported for it.
    static func profile(_ target: String) -> CloudSaveProfile? {
        SteamGames.descriptor(for: target).flatMap { CloudSaveProfile.forApp($0.appID) }
    }

    /// The guest's write layer (where the game writes its saves).
    static func writeLayer(_ target: String) -> URL {
        CloudSaveProfile.defaultWriteLayer(target: target, home: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// Sync state + backups, outside the game's data (deleting the game's data keeps them).
    static func stateDir(_ target: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klepton/cloudsaves/\(target)", isDirectory: true)
    }

    static func state(_ target: String) -> CloudSyncState {
        CloudSyncState.load(stateDir(target).appendingPathComponent("state.json"))
    }
}

@MainActor
final class KLCloudSaveModel: ObservableObject {
    static let shared = KLCloudSaveModel()

    /// Games whose sync is running.
    @Published private(set) var running: Set<String> = []
    /// Per game: the last run's one-line result, or why it failed.
    @Published private(set) var lastResult: [String: String] = [:]
    /// Per game: conflicts still open (both copies kept, nothing uploaded).
    @Published private(set) var conflicts: [String: [CloudConflict]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        for g in klHubGameRows where KLCloudSaves.profile(g.target) != nil { reloadState(g.target) }
    }

    func reloadState(_ target: String) {
        let st = KLCloudSaves.state(target)
        conflicts[target] = st.conflicts
        if lastResult[target] == nil, let t = st.lastRun {
            lastResult[target] = klL("Last sync ", "Última sincronización ")
                + t.formatted(date: .abbreviated, time: .shortened)
        }
    }

    /// Sync one game if its cloud saves are on (no-op otherwise, or while one is already running).
    func sync(_ target: String, why: String) {
        let settings = KLCloudSaves.settings(target)
        guard settings.enabled, tasks[target] == nil, let profile = KLCloudSaves.profile(target),
              let app = SteamGames.descriptor(for: target)?.appID else { return }
        running.insert(target)
        let layer = KLCloudSaves.writeLayer(target), dir = KLCloudSaves.stateDir(target)
        tasks[target] = Task {
            // Not detached: cancelling this task (Play's deadline) must reach the sync. runSync is
            // nonisolated, so it runs off the main actor anyway.
            let result = await Self.runSync(app: app, profile: profile, layer: layer, stateDir: dir, mode: settings.mode, why: why)
            lastResult[target] = result
            running.remove(target)
            tasks[target] = nil
            reloadState(target)
        }
    }

    /// Every game with cloud saves on (library shown = app (re)opened after a session).
    func syncAll(why: String) {
        for g in klHubGameRows { sync(g.target, why: why) }
    }

    /// Before Play: sync (if on), wait at most `limit` seconds, and only then boot. A sync still
    /// running at the deadline is cancelled AND awaited, so nothing writes saves under the game.
    func syncBeforePlay(_ target: String, limit: Double = 20, then play: @escaping () -> Void) {
        guard KLCloudSaves.settings(target).enabled, KLCloudSaves.profile(target) != nil else { play(); return }
        Task {
            if tasks[target] == nil { sync(target, why: "before play") }
            if let t = tasks[target] {
                let deadline = Task { try? await Task.sleep(nanoseconds: UInt64(limit * 1e9)); t.cancel() }
                await t.value
                deadline.cancel()
            }
            play()
        }
    }

    func resolve(_ target: String, _ c: CloudConflict, _ choice: CloudSyncState.Choice) {
        let url = KLCloudSaves.stateDir(target).appendingPathComponent("state.json")
        var st = CloudSyncState.load(url)
        st.resolve(c, choice)
        do { try st.save(url) } catch { NSLog("%@", "[cloud] \(target): could not save the resolution: \(error)") }
        NSLog("%@", "[cloud] \(target): conflict \(c.key) resolved: \(choice.rawValue)")
        reloadState(target)
    }

    nonisolated private static func runSync(app: UInt32, profile: CloudSaveProfile, layer: URL, stateDir: URL,
                                            mode: CloudSyncMode, why: String) async -> String {
        let store = KeychainCredentialStore(service: "SteamDepot.refreshToken", account: "steam")
        guard let creds = try? store.load() else { return klL("Not synced: sign in to Steam first.", "Sin sincronizar: inicia sesión en Steam.") }
        let session = SteamSession(log: { NSLog("[cloud] %@", $0) })
        do {
            try await session.connect()
            try await session.logOn(creds)
            let (rules, build) = try await session.cloudRules(app: app)
            guard !rules.isEmpty else {
                await session.disconnect()
                return klL("This game has no Steam Cloud saves.", "Este juego no tiene partidas en Steam Cloud.")
            }
            let remote = SteamCloud(session: session, appID: app, buildID: build, machineName: "AVP Game Hub (Apple Vision Pro)")
            var sync = profile.makeSync(remote: remote, rules: rules, writeLayer: layer, stateDir: stateDir, mode: mode)
            sync.log = { NSLog("[cloud] %@", $0) }
            let (report, _) = try await sync.run()
            await session.disconnect()
            NSLog("%@", "[cloud] app \(app) (\(why), \(mode.rawValue)): \(report.summary); down \(report.downloaded), up \(report.uploaded), "
                  + "backups \(report.backedUp), held \(report.held), conflicts \(report.conflicts.map(\.key))")
            return klL("Synced ", "Sincronizado ") + Date().formatted(date: .omitted, time: .shortened) + ": " + report.summary
        } catch {
            await session.disconnect()
            NSLog("%@", "[cloud] app \(app) (\(why)) failed: \(error)")
            return klL("Sync failed: ", "Error al sincronizar: ") + "\(error)"
        }
    }
}

/// The settings sheet's section for one game.
struct KLCloudSaveSection: View {
    let target: String
    @ObservedObject private var model = KLCloudSaveModel.shared
    @State private var s = KLCloudSaveSettings()

    var body: some View {
        if KLCloudSaves.profile(target) != nil {
            Section {
                Toggle(klL("Sync saves with Steam Cloud (experimental)", "Sincronizar partidas con Steam Cloud (experimental)"),
                       isOn: Binding(get: { s.enabled }, set: { s.enabled = $0; if $0 { s.mode = .downloadOnly }; save() }))
                if s.enabled {
                    Picker(klL("Direction", "Dirección"), selection: Binding(get: { s.mode }, set: { s.mode = $0; save() })) {
                        Text(klL("Download only", "Solo descargar")).tag(CloudSyncMode.downloadOnly)
                        Text(klL("Two-way", "En ambos sentidos")).tag(CloudSyncMode.twoWay)
                    }
                    HStack {
                        if model.running.contains(target) {
                            ProgressView().controlSize(.small)
                            Text(klL("Syncing…", "Sincronizando…")).foregroundStyle(.secondary)
                        } else if let r = model.lastResult[target] {
                            Text(r).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(klL("Sync now", "Sincronizar ahora")) { model.sync(target, why: "manual") }
                            .disabled(model.running.contains(target))
                    }
                }
                ForEach(model.conflicts[target] ?? [], id: \.key) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(CloudSync.split(c.key).path, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                        Text(c.reason == .bothChanged
                             ? klL("Changed here and in Steam Cloud since the last sync. Both copies are kept; nothing was uploaded.",
                                   "Ha cambiado aquí y en Steam Cloud desde la última sincronización. Se conservan las dos copias; no se ha subido nada.")
                             : klL("Differs from Steam Cloud and was never synced. Both copies are kept; nothing was uploaded.",
                                   "Es distinta de la de Steam Cloud y nunca se sincronizó. Se conservan las dos copias; no se ha subido nada."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(klL("Use the cloud copy", "Usar la copia de la nube")) { model.resolve(target, c, .useCloud) }
                            Button(klL("Keep this headset's copy", "Quedarme con la de este visor")) { model.resolve(target, c, .keepHeadset) }
                        }
                        .buttonStyle(.bordered).font(.caption)
                    }
                }
            } header: {
                Text("Steam Cloud")
            } footer: {
                Text(klL("Off by default. Download only brings your PC's saves here and never sends anything. "
                         + "Two-way also uploads saves this headset changed since the last sync (the first two-way sync only "
                         + "records where things stand). Every local save is backed up before it is replaced, nothing is ever "
                         + "deleted from Steam Cloud, and a save changed in both places is kept twice and never uploaded until "
                         + "you choose. Syncs before Play and when AVP Game Hub opens.",
                         "Desactivado por defecto. Solo descargar trae aquí las partidas de tu PC y nunca envía nada. "
                         + "En ambos sentidos también sube las partidas que este visor cambió desde la última sincronización "
                         + "(la primera solo registra el estado). Antes de sustituir una partida local se hace copia, nunca se "
                         + "borra nada de Steam Cloud, y una partida cambiada en los dos sitios se guarda dos veces y no se sube "
                         + "hasta que elijas. Se sincroniza antes de Jugar y al abrir AVP Game Hub."))
            }
            .onAppear { s = KLCloudSaves.settings(target); model.reloadState(target) }
        }
    }

    private func save() { KLCloudSaves.save(s, for: target) }
}

/// One line for the library card (nil = nothing to say).
@MainActor
func klCloudSaveCardLine(_ target: String) -> (String, Color)? {
    let m = KLCloudSaveModel.shared
    guard KLCloudSaves.settings(target).enabled else { return nil }
    if m.running.contains(target) { return (klL("Syncing saves with Steam Cloud…", "Sincronizando partidas con Steam Cloud…"), .blue) }
    if let n = m.conflicts[target]?.count, n > 0 {
        return (klL("Steam Cloud: \(n) save conflict\(n == 1 ? "" : "s") — see Settings",
                    "Steam Cloud: \(n) conflicto\(n == 1 ? "" : "s") de partida — ver Ajustes"), .orange)
    }
    return nil
}
#endif
