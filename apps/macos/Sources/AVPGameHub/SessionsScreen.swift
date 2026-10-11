import Charts
import HubCore
import Observation
import SwiftUI

@MainActor @Observable
final class SessionsModel {
    var records: [SessionRecord] = []
    var runs: [LaunchRunRecord] = []
    var pulling = false
    var message = ""

    func reload(settings: AppSettings) {
        records = SessionDecoding.load(directory: settings.expanded(settings.sessionsPath))
        runs = LaunchRunRecord.load()
    }

    /// Copies Library/Application Support/sessions/*.jsonl off the headset into the local folder.
    func pull(settings: AppSettings) {
        guard !pulling else { return }
        let target: (device: String, bundle: String)
        do { target = try settings.deviceTarget() } catch { message = "\(error)"; return }
        pulling = true
        message = L("Listando ficheros en el visor…", "Listing files on the headset…")
        let local = settings.expanded(settings.sessionsPath)
        Task {
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let json = FileManager.default.temporaryDirectory.appendingPathComponent("avpgamehub-files-\(UUID().uuidString).json")
            _ = await ProcessRunner.capture(.devicectl(DeviceCtl.listFilesArgs(device: target.device, bundle: target.bundle,
                                                                              subdirectory: DeviceCtl.sessionsSubdirectory,
                                                                              jsonOutput: json.path)), timeout: 90)
            var names = (try? Data(contentsOf: json)).map(DeviceFileListing.jsonlNames(in:)) ?? []
            try? FileManager.default.removeItem(at: json)
            if names.isEmpty { names = Catalog.entries.map { "\($0.target).jsonl" } }   // listing failed: try the known games
            var copied = 0
            for (i, name) in names.enumerated() {
                message = L("Copiando \(name) (\(i + 1)/\(names.count))…", "Copying \(name) (\(i + 1)/\(names.count))…")
                let r = await ProcessRunner.capture(.devicectl(DeviceCtl.copyFromArgs(
                    device: target.device, bundle: target.bundle,
                    source: "\(DeviceCtl.sessionsSubdirectory)/\(name)",
                    destination: local.appendingPathComponent(name).path)), timeout: 120)
                if r.status == 0 { copied += 1 }
            }
            reload(settings: settings)
            message = L("\(copied) ficheros copiados, \(records.count) sesiones", "\(copied) files copied, \(records.count) sessions")
            pulling = false
        }
    }
}

struct SessionsView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: SessionRecord.ID?
    @State private var game = "all"

    var body: some View {
        let model = app.sessions
        let shown = model.records.filter { game == "all" || $0.target == game }
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: L("Sesiones", "Sessions"),
                         subtitle: L("Estadísticas de cada partida, guardadas por el hub en el visor.",
                                     "Per-session stats the hub records on the headset.")) {
                HStack {
                    Picker("", selection: $game) {
                        Text(L("Todos", "All")).tag("all")
                        ForEach(Array(Set(model.records.map(\.target))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 140)
                    if model.pulling { ProgressView().controlSize(.small) }
                    Button(L("Traer del visor", "Pull from headset")) { model.pull(settings: app.settings) }
                        .disabled(model.pulling)
                    Button { NSWorkspace.shared.open(app.settings.expanded(app.settings.sessionsPath)) } label: { Image(systemName: "folder") }
                }
            }
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.secondary) }
            if shown.isEmpty {
                ContentUnavailableView(L("Sin sesiones", "No sessions"), systemImage: "chart.xyaxis.line",
                                       description: Text(L("Pulsa «Traer del visor».", "Press “Pull from headset”.")))
            } else {
                charts(shown)
                HSplitView {
                    table(shown).frame(minWidth: 520)
                    if let id = selection, let r = shown.first(where: { $0.id == id }) {
                        SessionDetail(record: r).frame(minWidth: 260, maxWidth: 360)
                    }
                }
            }
        }
        .padding(20)
        .onAppear { model.reload(settings: app.settings) }
    }

    private func charts(_ rs: [SessionRecord]) -> some View {
        let runs = app.sessions.runs.filter { game == "all" || $0.game == game }
        return HStack(spacing: 14) {
            chartBox("FPS") {
                Chart {
                    ForEach(rs) { r in
                        if let v = r.fpsAvg {
                            LineMark(x: .value("Start", r.start), y: .value("FPS", v)).foregroundStyle(by: .value("Game", r.target))
                            PointMark(x: .value("Start", r.start), y: .value("FPS", v)).foregroundStyle(by: .value("Game", r.target))
                        }
                    }
                }
            }
            chartBox(L("GPU ms (pruebas)", "GPU ms (test runs)")) {
                Chart {
                    ForEach(runs) { r in
                        if let v = r.gpuAvgMs {
                            PointMark(x: .value("Start", r.start), y: .value("GPU", v)).foregroundStyle(by: .value("Game", r.game))
                        }
                    }
                    ForEach(rs) { r in
                        if let v = r.frameMsP50 {
                            LineMark(x: .value("Start", r.start), y: .value("Frame", v), series: .value("s", "frame-\(r.target)"))
                                .foregroundStyle(.gray.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                }
            }
            chartBox(L("Memoria pico (MB)", "Peak memory (MB)")) {
                Chart {
                    ForEach(rs) { r in
                        if let v = r.peakFootprintMB {
                            BarMark(x: .value("Start", r.start), y: .value("MB", v)).foregroundStyle(by: .value("Game", r.target))
                        }
                    }
                }
            }
        }
        .frame(height: 170)
    }

    private func chartBox<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func table(_ rs: [SessionRecord]) -> some View {
        Table(rs.reversed(), selection: $selection) {
            TableColumn(L("Inicio", "Start")) { r in Text(r.start, format: .dateTime.day().month().hour().minute()) }
            TableColumn(L("Juego", "Game"), value: \.target)
            TableColumn(L("Jugado", "Played")) { r in Text(duration(r.playS)) }
            TableColumn("FPS") { r in Text(num(r.fpsAvg)) }
            TableColumn("1% low") { r in Text(num(r.fps1Low)) }
            TableColumn(L("Frame p50", "Frame p50")) { r in Text(r.frameMsP50.map { String(format: "%.1f ms", $0) } ?? "—") }
            TableColumn("MB") { r in Text(r.peakFootprintMB.map(String.init) ?? "—") }
            TableColumn(L("Fin", "End")) { r in
                Text(r.endedCleanly ? (r.endReason ?? "") : L("sin cierre limpio", "no clean exit"))
                    .foregroundStyle(r.endedCleanly ? Color.primary : Color.orange)
            }
        }
    }
}

struct SessionDetail: View {
    let record: SessionRecord

    var body: some View {
        let r = record
        Form {
            Section(r.target) {
                row("ID", r.id)
                row("Build", r.build ?? "—")
                row(L("Inicio", "Start"), r.start.formatted(date: .abbreviated, time: .standard))
                row(L("Fin", "End"), r.end?.formatted(date: .abbreviated, time: .standard) ?? "—")
                row(L("Motivo", "Reason"), r.endReason ?? "—")
                row(L("Final", "Final"), r.endedCleanly ? "✓" : "✗")
            }
            Section(L("Tiempo", "Time")) {
                row(L("Duración", "Duration"), duration(r.durationS))
                row(L("Jugando", "Playing"), duration(r.playS))
                row(L("Cargando", "Loading"), duration(r.loadingS))
            }
            Section(L("Rendimiento", "Performance")) {
                row("FPS avg", num(r.fpsAvg))
                row("1% / 5% low", "\(num(r.fps1Low)) / \(num(r.fps5Low))")
                row("5s min / max", "\(num(r.fpsMin5s)) / \(num(r.fpsMax5s))")
                row("Frame p50", r.frameMsP50.map { String(format: "%.2f ms", $0) } ?? "—")
                row("Display", r.displayHz.map { String(format: "%.0f Hz", $0) } ?? "—")
                row(L("Reproyectados", "Reprojected"), r.reprojectedShare.map { String(format: "%.1f%% of %llu", $0 * 100, r.compositorFrames ?? 0) } ?? "—")
                row(L("Frames del juego", "Guest frames"), r.guestFrames.map(String.init) ?? "—")
                row(L("Memoria pico", "Peak memory"), r.peakFootprintMB.map { "\($0) MB" } ?? "—")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).textSelection(.enabled).monospacedDigit() }
    }
}

private func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
private func duration(_ s: Double?) -> String {
    guard let s else { return "—" }
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}
