import AppKit
import HubCore
import Observation
import SwiftUI

/// "Jugar desde el Mac": runs Klepton's stream host (`KL_STREAM_HOST=1 build/m_boot <game>`) and
/// follows its log. One server at a time (they all listen on the same UDP port).
@MainActor @Observable
final class StreamModel {
    var options: StreamOptions { didSet { save() } }
    let log = LogStore(limit: 3000)
    let buildLog = LogStore(limit: 3000)
    var status = StreamStatus()
    /// The game whose server is running (or last ran).
    var target: String?
    var running = false
    var pid: Int32?
    var startedAt: Date?
    var message = ""
    var building = false
    var buildStatus: Int32?
    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private let buildRunner = ProcessRunner()
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var tmpDir: URL?

    /// This Mac's name as the user set it (System Settings › General › Sharing).
    static let macName: String = Host.current().localizedName ?? "Mac"

    init() {
        if let data = UserDefaults.standard.data(forKey: "streamOptions"),
           let o = try? JSONDecoder().decode(StreamOptions.self, from: data) {
            options = o
        } else {
            options = StreamOptions()
        }
        log.onLines = { [weak self] lines in
            guard let self else { return }
            for l in lines { self.status.ingest(l) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "streamOptions") }
    }

    /// A sink that masks this Mac's name and the home directory before anything is stored.
    private func scrubbingSink(_ store: LogStore) -> @Sendable (String) -> Void {
        let sink = store.sink()
        let name = Self.macName
        return { sink(StreamLaunch.scrub($0, macName: name)) }
    }

    func start(entry: CatalogEntry, settings: AppSettings) {
        guard !running, !building, let info = entry.stream, info.canStart, let k = settings.kleptonURL else { return }
        let content = info.needsContent ? settings.expanded(settings.streamContentPath(for: entry)).path : nil
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("avpgamehub-stream-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            message = "\(error)"
            return
        }
        let cmd = StreamLaunch.command(klepton: k, info: info, contentDir: content, macName: Self.macName,
                                       tmpDir: tmp.path, options: options)
        log.clear()
        status = StreamStatus()
        status.phase = .starting
        message = ""
        target = entry.target
        stopRequested = false
        tmpDir = tmp
        let sink = scrubbingSink(log)
        let env = cmd.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        sink("$ \(env) \(cmd.display)")
        running = true
        startedAt = Date()
        do {
            try runner.start(cmd, onLine: sink, onExit: { status in
                Task { @MainActor in self.didExit(status) }
            })
            pid = runner.pid
            sink("== pid \(pid.map(String.init) ?? "?")")
        } catch {
            running = false
            status.phase = .failed("\(error)")
            cleanupTmp()
        }
    }

    private func didExit(_ code: Int32) {
        running = false
        status.exited(status: code, stoppedByUser: stopRequested)
        log.append("== m_boot (pid \(pid.map(String.init) ?? "?")) exit \(code)")
        cleanupTmp()
    }

    private func cleanupTmp() {
        if let t = tmpDir { try? FileManager.default.removeItem(at: t) }
        tmpDir = nil
    }

    /// SIGTERM to the server's own pid (the host sends the headset a BYE), SIGKILL after 8 s.
    func stop() {
        guard running else { return }
        stopRequested = true
        log.append("== SIGTERM pid \(pid.map(String.init) ?? "?")")
        runner.terminate(timeout: 8)
    }

    /// App quit: stop the server this app started and wait for it (bounded).
    func stopForQuit() {
        buildRunner.cancel()
        guard running else { return }
        stopRequested = true
        runner.terminateAndWait(timeout: 3)
        cleanupTmp()
    }

    /// `make build/m_boot` in Klepton.
    func buildHost(settings: AppSettings) {
        guard !building, !running, let k = settings.kleptonURL else { return }
        let cmd = StreamLaunch.buildCommand(klepton: k)
        buildLog.clear()
        buildStatus = nil
        building = true
        let sink = scrubbingSink(buildLog)
        sink("$ (cd Klepton) \(cmd.display)")
        do {
            try buildRunner.start(cmd, onLine: sink, onExit: { status in
                Task { @MainActor in
                    self.building = false
                    self.buildStatus = status
                    sink(status == 0 ? "== OK" : "!! exit status \(status)")
                }
            })
        } catch {
            building = false
            buildLog.append("!! \(error)")
        }
    }

    func cancelBuild() { buildRunner.cancel() }
}

// MARK: - View

struct StreamingView: View {
    @Environment(AppModel.self) private var app
    @State private var showLog = true
    @State private var showAdvanced = false
    @State private var load: Double?

    var body: some View {
        let stream = app.stream
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: L("Jugar en streaming", "Stream play"),
                             subtitle: L("El juego corre en este Mac y se ve en el visor. Inicia el servidor aquí y elige el juego en el visor.",
                                         "The game runs on this Mac and shows in the headset. Start the server here, then pick the game in the headset."))
                if let load, StreamLaunch.isBusy(load1: load, cores: ProcessInfo.processInfo.activeProcessorCount) {
                    Label(L("El Mac está ocupado (carga \(String(format: "%.1f", load))): el juego puede ir a tirones. Cierra lo que no uses.",
                            "This Mac is busy (load \(String(format: "%.1f", load))): the game may stutter. Quit what you don't need."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(Catalog.streamable) { entry in
                    StreamGameCard(entry: entry)
                }
                options
                if stream.building || stream.buildStatus != nil {
                    GroupBox(L("Compilar m_boot", "Build m_boot")) {
                        LogConsoleView(store: stream.buildLog, showFilters: false).frame(height: 180)
                    }
                }
                DisclosureGroup(isExpanded: $showLog) {
                    LogConsoleView(store: stream.log, showFilters: false).frame(height: 260)
                } label: {
                    Text(L("Log del servidor", "Server log")).font(.headline)
                }
            }
            .padding(20)
        }
        .task {
            while !Task.isCancelled {
                load = StreamLaunch.loadAverage()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var options: some View {
        @Bindable var stream = app.stream
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Nombre en el visor", "Name in the headset"))
                    TextField("", text: $stream.options.name, prompt: Text(L("Este Mac (por defecto)", "This Mac (default)")))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Text("KL_STREAM_NAME").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                DisclosureGroup(L("Avanzado", "Advanced"), isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        bitrateRow
                        scaleRow
                    }
                    .padding(.top, 6)
                }
            }
            .disabled(stream.running)
            .padding(4)
        } label: {
            Text(L("Opciones", "Options")).font(.headline)
        }
    }

    private var bitrateRow: some View {
        @Bindable var stream = app.stream
        let on = Binding<Bool>(
            get: { stream.options.bitrateKbps != nil },
            set: { stream.options.bitrateKbps = $0 ? StreamOptions.hostDefaultBitrateKbps : nil })
        let mbps = Binding<Double>(
            get: { Double(stream.options.bitrateKbps ?? StreamOptions.hostDefaultBitrateKbps) / 1000 },
            set: { stream.options.bitrateKbps = Int($0.rounded()) * 1000 })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(L("Bitrate fijo", "Fixed bitrate"), isOn: on).toggleStyle(.checkbox)
                Slider(value: mbps, in: 20...200, step: 5).frame(maxWidth: 260).disabled(!on.wrappedValue)
                Text(on.wrappedValue ? "\(Int(mbps.wrappedValue)) Mbit/s" : L("por defecto (100 Mbit/s)", "default (100 Mbit/s)"))
                    .monospacedDigit()
            }
            Text("KL_STREAM_BITRATE_KBPS — " + L("techo; el host lo baja solo si la red se satura.",
                                                 "a ceiling; the host lowers it by itself when the link congests."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scaleRow: some View {
        @Bindable var stream = app.stream
        let on = Binding<Bool>(
            get: { stream.options.scale != nil },
            set: { stream.options.scale = $0 ? 0.75 : nil })
        let scale = Binding<Double>(
            get: { stream.options.scale ?? 0.75 },
            set: { stream.options.scale = ($0 * 20).rounded() / 20 })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(L("Escala fija", "Fixed scale"), isOn: on).toggleStyle(.checkbox)
                Slider(value: scale, in: 0.5...1.0, step: 0.05).frame(maxWidth: 260).disabled(!on.wrappedValue)
                Text(on.wrappedValue ? String(format: "× %.2f", scale.wrappedValue) : L("automática", "automatic")).monospacedDigit()
            }
            Text("KL_STREAM_SCALE — " + L("desactiva el tamaño automático (a ×1,0 fueron 6144x2464 y 26 fps). Déjalo en automática salvo para pruebas.",
                                          "turns auto-sizing off (at ×1.0 that was 6144x2464 and 26 fps). Leave it automatic except for tests."))
                .font(.caption).foregroundStyle(on.wrappedValue ? .orange : .secondary)
        }
    }
}

/// One game: preconditions with their fixes, Start / Stop, live status.
struct StreamGameCard: View {
    @Environment(AppModel.self) private var app
    let entry: CatalogEntry

    private struct Check: Identifiable {
        let id: String
        let ok: Bool
        let text: String
    }

    var body: some View {
        let stream = app.stream
        let info = entry.stream!
        let checks = preconditions(info)
        let ready = info.canStart && checks.allSatisfy(\.ok)
        let mine = stream.target == entry.target
        let live = mine && stream.running
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.display).font(.title3.bold())
                    switch info.availability {
                    case .ready: EmptyView()
                    case .experimental: Badge(text: L("experimental", "experimental"), color: .orange)
                    case .soon: Badge(text: L("pronto", "soon"), color: .secondary)
                    }
                    Spacer()
                    if live {
                        if let pid = stream.pid { Text("pid \(pid)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let t = stream.startedAt { Text(t, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
                        Button(L("Detener", "Stop"), role: .destructive) { stream.stop() }
                    } else {
                        Button(L("Iniciar servidor", "Start server")) { stream.start(entry: entry, settings: app.settings) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!ready || stream.running || stream.building)
                    }
                }
                if info.canStart {
                    ForEach(checks) { c in checkRow(c, info: info) }
                    if mine && stream.status.phase != .idle { statusView }
                    Text(L("En el visor: \(entry.display) → Jugar desde el Mac", "In the headset: \(entry.display) → Play from Mac"))
                        .font(.callout).foregroundStyle(.secondary)
                    if info.availability == .experimental {
                        Text(L("Aún sin una sesión verificada en el visor.", "No verified headset session yet."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text(L("Pronto: Klepton aún no puede servir este juego desde el Mac.",
                           "Soon: Klepton cannot host this game on the Mac yet.")).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func preconditions(_ info: StreamHostInfo) -> [Check] {
        let s = app.settings
        let fm = FileManager.default
        var out: [Check] = []
        guard let k = s.kleptonURL, s.hasKlepton else {
            return [Check(id: "klepton", ok: false, text: L("Falta la ruta de Klepton", "Klepton path not set"))]
        }
        out.append(Check(id: "klepton", ok: true, text: "Klepton"))
        let mboot = k.appendingPathComponent(StreamLaunch.binary).path
        out.append(Check(id: "mboot", ok: fm.isExecutableFile(atPath: mboot),
                         text: fm.isExecutableFile(atPath: mboot) ? "build/m_boot" : L("Falta build/m_boot", "build/m_boot not built")))
        for p in StreamLaunch.missingKleptonPaths(klepton: k, info: info) {
            out.append(Check(id: "path-\(p)", ok: false,
                             text: L("Falta \(p) en Klepton (el árbol del juego traducido)", "\(p) missing in Klepton (the translated game tree)")))
        }
        if info.needsContent {
            let path = s.streamContentPath(for: entry)
            let ok = StreamLaunch.contentPresent(s.expanded(path).path, info: info)
            out.append(Check(id: "content", ok: ok, text: ok ? L("Contenido del juego", "Game content")
                                                            : L("No se encuentra el contenido del juego", "Game content not found")))
        }
        return out
    }

    @ViewBuilder
    private func checkRow(_ c: Check, info: StreamHostInfo) -> some View {
        let stream = app.stream
        HStack(spacing: 8) {
            (c.ok ? CheckState.ok : CheckState.fail).icon
            Text(c.text)
            switch c.id {
            case "klepton":
                if !c.ok { chooseButton { app.settings.kleptonPath = $0 } }
            case "mboot":
                if stream.building {
                    ProgressView().controlSize(.small)
                    Button(L("Cancelar", "Cancel")) { stream.cancelBuild() }
                } else if !c.ok || stream.buildStatus != nil {
                    Button(c.ok ? L("Recompilar", "Rebuild") : L("Compilar", "Build")) { stream.buildHost(settings: app.settings) }
                        .disabled(stream.running)
                    if let st = stream.buildStatus, st != 0 { Badge(text: "exit \(st)", color: .red) }
                }
            case "content":
                Text(abbreviated(app.settings.streamContentPath(for: entry)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                chooseButton { app.settings.streamContent[entry.target] = $0 }
                if app.settings.streamContent[entry.target] != nil {
                    Button(L("Detectar", "Detect")) { app.settings.streamContent[entry.target] = nil }
                }
            default: EmptyView()
            }
        }
        .font(.callout)
    }

    private func chooseButton(_ set: @escaping (String) -> Void) -> some View {
        Button(L("Elegir…", "Choose…")) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            if panel.runModal() == .OK, let url = panel.url { set(url.path) }
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.isEmpty ? "—" : (path as NSString).abbreviatingWithTildeInPath
    }

    private var statusView: some View {
        let st = app.stream.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                phaseIcon(st.phase)
                Text(st.headline).font(.headline)
                if let p = st.port, st.isLive { Text("UDP :\(p)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                if let f = st.frame, st.isLive { Text(f).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            if st.phase == .streaming, let s = st.stats {
                HStack(spacing: 10) {
                    tile("FPS", String(format: "%.1f", s.fps))
                    tile("Mbit/s", String(format: "%.1f", s.mbps))
                    tile(L("Codificar", "Encode"), String(format: "%.1f ms", s.encodeMs))
                    tile(L("Edad de pose", "Pose age"), String(format: "%.1f ms", s.poseAgeMs))
                    tile(L("Perdidos", "Dropped"), "\(s.droppedTotal)")
                    if let k = s.bitrateKbps { tile("Bitrate", "\(k / 1000) Mbit/s") }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func phaseIcon(_ p: StreamPhase) -> some View {
        switch p {
        case .starting, .waitingForHeadset, .booting: ProgressView().controlSize(.small)
        case .streaming: Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        case .headsetLeft: Image(systemName: "visionpro").foregroundStyle(.orange)
        case .failed: CheckState.fail.icon
        case .ended, .idle: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 84, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
