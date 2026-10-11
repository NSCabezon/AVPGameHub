import HubCore
import Observation
import SwiftUI

/// What a Launch & Test run measured from its log (sessions .jsonl has no GPU time, so the
/// Sessions charts take GPU from these).
struct LaunchRunRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date
    var game: String
    var environment: [String: String]
    var gpuAvgMs: Double?
    var stalls: Int
    var fpsAvg: Double?

    static var file: URL { AppSettings.supportDir.appendingPathComponent("launch-runs.json") }

    static func load() -> [LaunchRunRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([LaunchRunRecord].self, from: data)) ?? []
    }

    static func append(_ r: LaunchRunRecord) {
        var all = load()
        all.append(r)
        if all.count > 500 { all.removeFirst(all.count - 500) }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: AppSettings.supportDir, withIntermediateDirectories: true)
        try? e.encode(all).write(to: file, options: .atomic)
    }
}

@MainActor @Observable
final class LaunchModel {
    var options: LaunchOptions { didSet { save() } }
    let log = LogStore()
    var stats = LiveStats()
    var running = false
    var startedAt: Date?
    var message = ""
    @ObservationIgnored private let runner = ProcessRunner()

    init() {
        if let data = UserDefaults.standard.data(forKey: "launchOptions"),
           let o = try? JSONDecoder().decode(LaunchOptions.self, from: data) {
            options = o
        } else {
            options = LaunchOptions()
        }
        log.onLines = { [weak self] lines in
            for l in lines { self?.stats.ingest(l) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "launchOptions") }
    }

    /// devicectl launch --console: the app's output streams here until it exits or Stop is pressed
    /// (stopping devicectl quits the app on the headset — devicectl forwards the signal).
    func start(settings: AppSettings) {
        guard !running else { return }
        let target: (device: String, bundle: String)
        do { target = try settings.deviceTarget() } catch { message = "\(error)"; return }
        var env = options.environment()
        env["KL_LOG_FILE"] = "0"   // as visionos/run.sh does for --console runs (the app still tees its log)
        let cmd = ShellCommand.devicectl(DeviceCtl.launchArgs(device: target.device, bundle: target.bundle,
                                                              environment: env, console: true))
        log.clear()
        stats = LiveStats()
        message = ""
        log.append("$ \(cmd.display)")
        running = true
        let started = Date()
        startedAt = started
        let sink = log.sink()
        let game = options.game
        do {
            try runner.start(cmd, onLine: sink, onExit: { status in
                Task { @MainActor in
                    self.running = false
                    sink("== devicectl exit \(status)")
                    LaunchRunRecord.append(LaunchRunRecord(start: started, end: Date(), game: game, environment: env,
                                                           gpuAvgMs: self.stats.gpuAvgMs, stalls: self.stats.stalls,
                                                           fpsAvg: self.stats.session?.fpsAvg))
                }
            })
        } catch {
            running = false
            message = "\(error)"
        }
    }

    func stop() { runner.cancel() }
}

struct LaunchView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var launch = app.launch
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: L("Lanzar y probar", "Launch & Test"),
                         subtitle: L("Lanza el hub en el visor con un juego y ajustes, y sigue el log en directo.",
                                     "Launch the hub on the headset with a game and presets, and follow the log live."))
            HStack(alignment: .top, spacing: 20) {
                LaunchPresetsGrid(options: $launch.options)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Variables extra (KEY=VALUE por línea)", "Extra variables (KEY=VALUE per line)")).font(.callout)
                    TextEditor(text: $launch.options.extra)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Text(launch.options.environment().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        if launch.running {
                            Button(L("Parar", "Stop"), role: .destructive) { launch.stop() }
                            if let t = launch.startedAt { Text(t, style: .timer).monospacedDigit() }
                        } else {
                            Button(L("Lanzar", "Launch")) { launch.start(settings: app.settings) }
                                .buttonStyle(.borderedProminent)
                        }
                        Text(launch.message).foregroundStyle(.red)
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            }
            MiniStats(stats: launch.stats)
            LogConsoleView(store: launch.log)
        }
        .padding(20)
    }
}

/// The presets as an aligned two-column grid: right-aligned labels, controls beside them.
/// Each hub-defaulted preset shows what the default actually is for the chosen game.
struct LaunchPresetsGrid: View {
    @Binding var options: LaunchOptions

    var body: some View {
        let def = LaunchOptions.hubDefaults(game: options.game)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            row(L("Juego", "Game")) {
                Picker("", selection: $options.game) {
                    ForEach(Catalog.entries) { Text($0.display).tag($0.target) }
                }
                .labelsHidden().frame(width: 220)
            }
            row("MSAA", env: "KL_ALYX_MSAA") {
                Picker("", selection: $options.msaa) {
                    Text(defaultLabel(def.msaa.map { "\($0)x" } ?? L("de la app", "app's"))).tag(LaunchOptions.MSAA.appDefault)
                    Text("2x").tag(LaunchOptions.MSAA.x2)
                    Text("4x").tag(LaunchOptions.MSAA.x4)
                }
                .labelsHidden().frame(width: 220)
            }
            row(L("Foveated", "Foveated"), env: "KL_FOVEATE") { tri($options.foveation, hubOn: def.foveated) }
            row(L("Ritmo 45 fps", "45 fps pace"), env: "KL_GUEST_PACE_HZ") { tri($options.pace, hubOn: def.pace45) }
            row("A/B", env: "KL_FOVEATE_AB") {
                HStack(spacing: 6) {
                    Stepper(value: $options.abSeconds, in: 0...120) {
                        Text(options.abSeconds == 0 ? L("Desactivado", "Off") : "\(options.abSeconds) s")
                            .monospacedDigit().frame(minWidth: 80, alignment: .leading)
                    }
                }
                .disabled(options.foveation == .off)
                .help(L("Alterna foveated / resolución completa cada N segundos. 0 = desactivado.",
                        "Flips foveated / full rate every N seconds. 0 = off."))
            }
            row("HUD", env: "KL_HUD") { Toggle("", isOn: $options.hud).labelsHidden() }
            row(L("Tiempo de GPU", "GPU timing"), env: "KL_GPU_TIME") { Toggle("", isOn: $options.gpuTime).labelsHidden() }
        }
    }

    private func defaultLabel(_ what: String) -> String { L("Por defecto (\(what))", "Default (\(what))") }

    private func tri(_ value: Binding<LaunchOptions.Tri>, hubOn: Bool) -> some View {
        Picker("", selection: value) {
            Text(defaultLabel(hubOn ? L("activado", "on") : L("desactivado", "off"))).tag(LaunchOptions.Tri.hubDefault)
            Text(L("Activado", "On")).tag(LaunchOptions.Tri.on)
            Text(L("Desactivado", "Off")).tag(LaunchOptions.Tri.off)
        }
        .labelsHidden().frame(width: 220)
    }

    private func row<C: View>(_ label: String, env: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
        GridRow {
            VStack(alignment: .trailing, spacing: 0) {
                Text(label)
                if let env { Text(env).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
            .gridColumnAlignment(.trailing)
            control()
        }
    }
}

struct MiniStats: View {
    let stats: LiveStats

    var body: some View {
        HStack(spacing: 10) {
            tile(L("GPU último", "GPU last"), stats.gpuLastMs.map { String(format: "%.2f ms", $0) })
            tile(L("GPU media", "GPU avg"), stats.gpuAvgMs.map { String(format: "%.2f ms", $0) })
            tile(L("GPU peor", "GPU worst"), stats.gpuWorstMs.map { String(format: "%.2f ms", $0) })
            tile(L("Tirones VK", "VK stalls"), stats.stalls > 0 ? String(format: "%d · %.0f ms", stats.stalls, stats.stallMsTotal) : "0")
            tile("FPS", stats.session?.fpsAvg.map { String(format: "%.1f", $0) })
            tile("1% low", stats.session?.fps1Low.map { String(format: "%.1f", $0) })
            tile(L("Memoria", "Memory"), stats.session?.peakFootprintMB.map { "\($0) MB" })
            if stats.abDeltaPercent != nil || stats.abFoveatedMs != nil {
                tile("A/B", stats.abDeltaPercent.map { String(format: "%+.1f%%", $0) })
            }
            tile(L("Errores", "Errors"), "\(stats.errors)")
        }
    }

    private func tile(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 90, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
