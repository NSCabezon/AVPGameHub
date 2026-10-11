import HubCore
import Observation
import SwiftUI

/// `build_run_vpro.sh hub` with the team / bundle / device from Settings.
@MainActor @Observable
final class BuildModel {
    let log = LogStore()
    var step: BuildStep?
    var running = false
    var exitStatus: Int32?
    var startedAt: Date?
    var buildOnly = false
    var stage = false
    var errors = 0
    @ObservationIgnored private let runner = ProcessRunner()

    init() {
        log.onLines = { [weak self] lines in
            guard let self else { return }
            for l in lines {
                if let s = BuildLog.step(in: l) { self.step = s }
                if BuildLog.isError(l) { self.errors += 1 }
            }
        }
    }

    func command(settings: AppSettings) -> ShellCommand? {
        guard let k = settings.kleptonURL else { return nil }
        var args = [k.appendingPathComponent("build_run_vpro.sh").path, "hub"]
        if buildOnly { args.append("--build-only") }
        if stage { args.append("--stage") }
        var env: [String: String] = [:]
        if !settings.team.isEmpty { env["KLEPTON_TEAM"] = settings.team }
        if !settings.bundleID.isEmpty { env["KLEPTON_BUNDLE_ID"] = settings.bundleID }
        if !settings.deviceID.isEmpty { env["KLEPTON_DEVICE"] = settings.deviceID }
        return ShellCommand("/bin/bash", args, environment: env, currentDirectory: k.path)
    }

    func start(settings: AppSettings) {
        guard !running, let cmd = command(settings: settings) else { return }
        log.clear()
        step = nil
        errors = 0
        exitStatus = nil
        startedAt = Date()
        let env = cmd.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.append("$ \(env) \(cmd.display)")
        running = true
        let sink = log.sink()
        do {
            try runner.start(cmd, onLine: sink, onExit: { status in
                Task { @MainActor in
                    self.running = false
                    self.exitStatus = status
                    sink(status == 0 ? "== OK" : "!! exit status \(status)")
                }
            })
        } catch {
            running = false
            log.append("!! \(error)")
        }
    }

    func cancel() { runner.cancel() }
}

struct BuildView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var build = app.build
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: L("Compilar e instalar", "Build & Install"),
                         subtitle: L("Ejecuta build_run_vpro.sh hub en Klepton con el equipo, bundle y visor de Ajustes.",
                                     "Runs build_run_vpro.sh hub in Klepton with the team, bundle and headset from Settings."))
            HStack(spacing: 16) {
                Toggle(L("Solo compilar (sin visor)", "Build only (no headset)"), isOn: $build.buildOnly)
                Toggle(L("Re-subir assets (--stage)", "Re-upload assets (--stage)"), isOn: $build.stage)
                Spacer()
                if build.running {
                    Button(L("Cancelar", "Cancel"), role: .destructive) { build.cancel() }
                } else {
                    Button(L("Compilar", "Build")) { build.start(settings: app.settings) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!app.settings.hasKlepton)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(build.running)
            summary
            steps
            LogConsoleView(store: build.log)
        }
        .padding(20)
    }

    private var summary: some View {
        let s = app.settings
        return HStack(spacing: 14) {
            Label(s.team.isEmpty ? L("equipo: auto", "team: auto") : "team \(s.team)", systemImage: "person.badge.key")
            Label(s.bundleID.isEmpty ? L("bundle: el de targets.py", "bundle: targets.py's") : s.bundleID, systemImage: "shippingbox")
            Label(s.deviceID.isEmpty ? L("visor: auto", "headset: auto") : s.deviceID, systemImage: "visionpro")
            if !s.hasKlepton { Badge(text: L("Klepton no encontrado", "Klepton not found"), color: .red) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var steps: some View {
        let build = app.build
        let titles = [L("traducciones", "translations"), L("proyecto", "project"), L("compilar", "build"),
                      L("instalar", "install"), L("lanzar", "launch")]
        let current = build.step?.index ?? 0
        let total = build.step?.total ?? 5
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(1...max(total, 5), id: \.self) { i in
                    let done = i < current || (i == current && build.exitStatus == 0)
                    let active = i == current && build.running
                    HStack(spacing: 4) {
                        if active { ProgressView().controlSize(.mini) }
                        else { Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary) }
                        Text("\(i). \(i <= titles.count ? titles[i - 1] : "")")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                }
            }
            HStack {
                if let s = build.step { Text("[\(s.index)/\(s.total)] \(s.title)").font(.callout.monospaced()) }
                Spacer()
                if build.errors > 0 { Badge(text: L("\(build.errors) errores", "\(build.errors) errors"), color: .red) }
                if let st = build.exitStatus {
                    Badge(text: st == 0 ? "OK" : "exit \(st)", color: st == 0 ? .green : .red)
                }
                if let t = build.startedAt {
                    if build.running {
                        Text(t, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
