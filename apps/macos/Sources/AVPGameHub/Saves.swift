import AppKit
import HubCore
import Observation
import SwiftUI

/// Save-game backups: headset → Mac and back, through devicectl. Which files are saves is
/// SaveTable's (HubCore); this side only runs devicectl and keeps the Mac copies.
///
/// Safety: a backup only reads from the headset. A restore writes only the files listed in a
/// verified backup that SaveTable accepts as saves of that game (never game data or tokens),
/// never deletes anything there, refuses while the hub runs, and first backs up what the
/// headset has now.
enum SaveOps {
    static let store = SaveBackupStore(base: AppSettings.supportDir.appendingPathComponent("saves", isDirectory: true))

    enum Outcome { case noSaves, created(SaveBackup), unchanged(SaveBackup) }

    private static func tempJSON() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("avpgamehub-saves-\(UUID().uuidString).json")
    }

    private static func tail(_ output: String) -> String {
        output.split(separator: "\n").suffix(2).joined(separator: " ")
    }

    /// The container listing under `subdirectory`; nil when devicectl could not list it.
    static func list(device: String, bundle: String, subdirectory: String) async -> [RemoteFile]? {
        let json = tempJSON()
        defer { try? FileManager.default.removeItem(at: json) }
        _ = await ProcessRunner.capture(.devicectl(DeviceCtl.listFilesArgs(device: device, bundle: bundle,
                                                                          subdirectory: subdirectory, jsonOutput: json.path)),
                                        timeout: 180)
        return (try? Data(contentsOf: json)).flatMap { DeviceJSON.files($0, subdirectory: subdirectory) }
    }

    /// The headset answers and the hub's container is there.
    static func checkReachable(device: String, bundle: String) async throws {
        guard await list(device: device, bundle: bundle, subdirectory: "Documents") != nil else {
            throw HubError(L("No se puede leer el visor: ¿encendido, desbloqueado y emparejado, y el hub instalado?",
                             "Cannot read the headset: is it on, unlocked and paired, with the hub installed?"))
        }
    }

    /// Whether the hub app runs on the headset now. Throws when that cannot be told.
    static func hubIsRunning(device: String, bundle: String) async throws -> Bool {
        let apps = tempJSON(), procs = tempJSON()
        defer { try? FileManager.default.removeItem(at: apps); try? FileManager.default.removeItem(at: procs) }
        _ = await ProcessRunner.capture(.devicectl(DeviceCtl.appInfoArgs(device: device, bundle: bundle, jsonOutput: apps.path)), timeout: 60)
        guard let url = (try? Data(contentsOf: apps)).flatMap({ DeviceJSON.appURL($0, bundle: bundle) }) else {
            throw HubError(L("El hub (\(bundle)) no está instalado en el visor, o el visor no responde",
                             "The hub (\(bundle)) is not installed on the headset, or the headset does not answer"))
        }
        _ = await ProcessRunner.capture(.devicectl(DeviceCtl.processesArgs(device: device, jsonOutput: procs.path)), timeout: 60)
        guard let exes = (try? Data(contentsOf: procs)).flatMap(DeviceJSON.processExecutables) else {
            throw HubError(L("No se pudo leer la lista de procesos del visor", "Could not read the headset's process list"))
        }
        return DeviceJSON.isRunning(appURL: url, executables: exes)
    }

    /// The game's save files on the headset now (empty = none yet).
    static func headsetSaves(_ target: String, device: String, bundle: String) async -> [RemoteFile] {
        guard let loc = SaveTable.location(for: target) else { return [] }
        var all: [RemoteFile] = []
        for root in loc.roots {
            // A root that cannot be listed does not exist yet (the device itself was checked first).
            all += await list(device: device, bundle: bundle, subdirectory: root.path) ?? []
        }
        return SaveTable.saveFiles(target, in: all)
    }

    /// Copies the game's saves off the headset into a new backup (read-only on the headset).
    static func backup(_ target: String, device: String, bundle: String, reason: String,
                       progress: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        let files = await headsetSaves(target, device: device, bundle: bundle)
        if files.isEmpty { return .noSaves }
        let staging = try store.begin(target)
        do {
            for (i, f) in files.enumerated() {
                await progress(L("Copiando \(i + 1)/\(files.count)…", "Copying \(i + 1)/\(files.count)…"))
                let dest = staging.appendingPathComponent("files").appendingPathComponent(f.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let r = await ProcessRunner.capture(.devicectl(DeviceCtl.copyFromArgs(device: device, bundle: bundle,
                                                                                     source: f.path, destination: dest.path)),
                                                    timeout: 300)
                guard r.status == 0, FileManager.default.fileExists(atPath: dest.path) else {
                    throw HubError(L("No se pudo copiar \(f.path): ", "Could not copy \(f.path): ") + tail(r.output))
                }
            }
            switch try store.finish(staging: staging, target: target, bundle: bundle, reason: reason, paths: files.map(\.path)) {
            case .created(let b): store.rotate(target); return .created(b)
            case .unchanged(let b): return .unchanged(b)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Writes `backup` back into the hub's container. Returns how many files were written.
    static func restore(_ source: SaveBackup, device: String, bundle: String,
                        progress: @escaping @MainActor (String) -> Void) async throws -> Int {
        let target = source.manifest.target
        await progress(L("Comprobando la copia…", "Checking the backup…"))
        let bad = store.verify(source)
        guard bad.isEmpty else {
            throw HubError(L("La copia está dañada (\(bad.count) ficheros no coinciden con el manifiesto); no se restaura",
                             "The backup is damaged (\(bad.count) files do not match its manifest); not restoring"))
        }
        let refused = source.manifest.files.filter { !SaveTable.isRestorable(target, path: $0.path, size: $0.size) }
        guard refused.isEmpty else {
            throw HubError(L("La copia contiene rutas que no son partidas de este juego (\(refused[0].path)); no se restaura",
                             "The backup holds paths that are not this game's saves (\(refused[0].path)); not restoring"))
        }
        await progress(L("Comprobando que el hub no está abierto…", "Checking the hub is not running…"))
        if try await hubIsRunning(device: device, bundle: bundle) {
            throw HubError(L("El hub está abierto en el visor. Ciérralo (o termina la partida) y vuelve a intentarlo.",
                             "The hub is running on the headset. Close it (or end the game) and try again."))
        }
        await progress(L("Guardando antes lo que hay en el visor…", "Backing up what the headset has first…"))
        _ = try await backup(target, device: device, bundle: bundle, reason: "pre-restore", progress: progress)
        // The source stays even if the pre-restore copy pushed it past the rotation limit.
        store.rotate(target, protecting: [source.directory])
        if try await hubIsRunning(device: device, bundle: bundle) {
            throw HubError(L("El hub se ha abierto en el visor; restauración cancelada (no se ha escrito nada).",
                             "The hub was opened on the headset; restore cancelled (nothing was written)."))
        }
        var written = 0
        for (i, f) in source.manifest.files.enumerated() {
            await progress(L("Restaurando \(i + 1)/\(source.manifest.files.count)…", "Restoring \(i + 1)/\(source.manifest.files.count)…"))
            let r = await ProcessRunner.capture(.devicectl(DeviceCtl.copyToArgs(device: device, bundle: bundle,
                                                                               source: source.localURL(f.path).path,
                                                                               destination: f.path)),
                                                timeout: 300)
            guard r.status == 0 else {
                throw HubError(L("Fallo al escribir \(f.path) tras \(written) ficheros: ", "Failed writing \(f.path) after \(written) files: ")
                               + tail(r.output))
            }
            written += 1
        }
        return written
    }
}

@MainActor @Observable
final class SavesModel {
    enum Headset: Equatable { case unknown, checking, ready(hubRunning: Bool), unreachable(String) }

    var backups: [String: [SaveBackup]] = [:]
    var busy: String?          // a target, or "all"
    var progress = ""
    var messages: [String: String] = [:]
    var headset: Headset = .unknown

    var running: Bool { busy != nil }

    func reload() {
        for e in Catalog.entries { backups[e.target] = SaveOps.store.list(e.target) }
    }

    func checkHeadset(settings: AppSettings) {
        guard headset != .checking else { return }
        let t: (device: String, bundle: String)
        do { t = try settings.deviceTarget() } catch { headset = .unreachable("\(error)"); return }
        headset = .checking
        Task {
            do {
                try await SaveOps.checkReachable(device: t.device, bundle: t.bundle)
                headset = .ready(hubRunning: try await SaveOps.hubIsRunning(device: t.device, bundle: t.bundle))
            } catch { headset = .unreachable("\(error)") }
        }
    }

    private func describe(_ o: SaveOps.Outcome) -> String {
        switch o {
        case .noSaves: return L("Sin partidas en el visor todavía", "No saves on the headset yet")
        case .created(let b):
            return L("Copiadas: \(b.manifest.files.count) ficheros, \(formatBytes(b.manifest.totalBytes))",
                     "Copied: \(b.manifest.files.count) files, \(formatBytes(b.manifest.totalBytes))")
        case .unchanged: return L("Sin cambios desde la última copia", "Unchanged since the last backup")
        }
    }

    func backup(_ targets: [String], settings: AppSettings) {
        guard busy == nil else { return }
        let t: (device: String, bundle: String)
        do { t = try settings.deviceTarget() } catch { for g in targets { messages[g] = "\(error)" }; return }
        busy = targets.count == 1 ? targets[0] : "all"
        Task {
            defer { busy = nil; progress = ""; reload() }
            progress = L("Comprobando el visor…", "Checking the headset…")
            do { try await SaveOps.checkReachable(device: t.device, bundle: t.bundle) } catch {
                headset = .unreachable("\(error)")
                for g in targets { messages[g] = "\(error)" }
                return
            }
            for g in targets {
                messages[g] = L("Buscando partidas…", "Looking for saves…")
                do {
                    let o = try await SaveOps.backup(g, device: t.device, bundle: t.bundle,
                                                     reason: targets.count == 1 ? "manual" : "all") { self.messages[g] = $0 }
                    messages[g] = describe(o)
                } catch { messages[g] = "\(error)" }
            }
        }
    }

    func restore(_ backup: SaveBackup, settings: AppSettings) {
        guard busy == nil else { return }
        let g = backup.manifest.target
        let t: (device: String, bundle: String)
        do { t = try settings.deviceTarget() } catch { messages[g] = "\(error)"; return }
        busy = g
        Task {
            defer { busy = nil; progress = ""; reload() }
            do {
                let n = try await SaveOps.restore(backup, device: t.device, bundle: t.bundle) { self.messages[g] = $0 }
                messages[g] = L("Restaurados \(n) ficheros en el visor", "Restored \(n) files on the headset")
            } catch { messages[g] = "\(error)" }
        }
    }
}

struct SavesView: View {
    @Environment(AppModel.self) private var app
    @State private var confirm: SaveBackup?

    var body: some View {
        let model = app.saves
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: L("Partidas", "Saves"),
                         subtitle: L("Copias de las partidas guardadas en el visor. Solo partidas y ajustes: nunca datos del juego ni tokens.",
                                     "Backups of the saves on the headset. Saves and settings only: never game data or tokens.")) {
                HStack {
                    if model.busy == "all" { ProgressView().controlSize(.small) }
                    Button(L("Copiar todo", "Back up all")) { model.backup(Catalog.entries.map(\.target), settings: app.settings) }
                        .disabled(model.running)
                    Button { NSWorkspace.shared.open(SaveOps.store.base) } label: { Image(systemName: "folder") }
                        .help(SaveOps.store.base.path)
                }
            }
            headsetLine(model)
            List(Catalog.entries) { e in
                row(e, model: model).padding(.vertical, 4)
            }
        }
        .padding(20)
        .onAppear {
            try? FileManager.default.createDirectory(at: SaveOps.store.base, withIntermediateDirectories: true)
            model.reload()
            if model.headset == .unknown { model.checkHeadset(settings: app.settings) }
        }
        .confirmationDialog(L("¿Restaurar en el visor?", "Restore on the headset?"),
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { b in
            Button(L("Restaurar", "Restore"), role: .destructive) { model.restore(b, settings: app.settings) }
            Button(L("Cancelar", "Cancel"), role: .cancel) {}
        } message: { b in
            Text(L("Se sobrescribirán las partidas de \(Catalog.entry(b.manifest.target)?.display ?? b.manifest.target) en el visor con la copia del \(b.manifest.created.formatted(date: .abbreviated, time: .shortened)). Antes se hará automáticamente una copia de lo que haya ahora. El hub debe estar cerrado en el visor.",
                   "This overwrites \(Catalog.entry(b.manifest.target)?.display ?? b.manifest.target)'s saves on the headset with the backup from \(b.manifest.created.formatted(date: .abbreviated, time: .shortened)). What is there now is backed up first. The hub must be closed on the headset."))
        }
    }

    @ViewBuilder private func headsetLine(_ model: SavesModel) -> some View {
        HStack(spacing: 6) {
            switch model.headset {
            case .unknown: CheckState.info.icon; Text(L("Visor sin comprobar", "Headset not checked"))
            case .checking: CheckState.checking.icon; Text(L("Comprobando el visor…", "Checking the headset…"))
            case .ready(let running):
                if running {
                    CheckState.warn.icon
                    Text(L("Visor accesible. El hub está abierto: se puede copiar, pero para restaurar hay que cerrarlo.",
                           "Headset reachable. The hub is running: backing up works, restoring needs it closed."))
                } else {
                    CheckState.ok.icon; Text(L("Visor accesible; el hub está cerrado", "Headset reachable; the hub is closed"))
                }
            case .unreachable(let why): CheckState.fail.icon; Text(why)
            }
            Button(L("Comprobar", "Check")) { model.checkHeadset(settings: app.settings) }
                .controlSize(.small).disabled(model.headset == .checking)
        }
        .font(.callout)
    }

    private func row(_ e: CatalogEntry, model: SavesModel) -> some View {
        let list = model.backups[e.target] ?? []
        let latest = list.first
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.display).font(.headline)
                if let b = latest {
                    Text(L("Última copia: \(b.manifest.created.formatted(date: .abbreviated, time: .shortened)) · \(b.manifest.files.count) ficheros · \(formatBytes(b.manifest.totalBytes)) · \(list.count) copias",
                           "Last backup: \(b.manifest.created.formatted(date: .abbreviated, time: .shortened)) · \(b.manifest.files.count) files · \(formatBytes(b.manifest.totalBytes)) · \(list.count) backups"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Sin copias en este Mac", "No backups on this Mac")).foregroundStyle(.secondary)
                }
                if let m = model.messages[e.target], !m.isEmpty {
                    Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if model.busy == e.target { ProgressView().controlSize(.small) }
            Button(L("Copiar del visor", "Back up from headset")) { model.backup([e.target], settings: app.settings) }
                .disabled(model.running)
            Menu(L("Restaurar en el visor", "Restore on headset")) {
                ForEach(list) { b in
                    Button("\(b.manifest.created.formatted(date: .abbreviated, time: .shortened)) — \(b.manifest.files.count) · \(formatBytes(b.manifest.totalBytes))\(b.manifest.reason == "pre-restore" ? L(" (antes de restaurar)", " (before a restore)") : "")") {
                        confirm = b
                    }
                }
            }
            .fixedSize()
            .disabled(model.running || list.isEmpty)
            Button { NSWorkspace.shared.open(latest?.directory ?? SaveOps.store.directory(e.target)) } label: { Image(systemName: "folder") }
                .disabled(latest == nil)
        }
    }
}
