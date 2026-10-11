import HubCore
import MetaStore
import Observation
import SwiftUI

struct StatusRow: Identifiable {
    let id: String
    var title: String
    var state: CheckState = .checking
    var detail = ""
    var fix = ""
    var actionTitle: String?
    var action: (() -> Void)?
}

@MainActor @Observable
final class StatusModel {
    var rows: [StatusRow] = []
    var devices: [DeviceInfo] = []
    var running = false

    private func set(_ id: String, _ title: String, _ state: CheckState, _ detail: String, fix: String = "",
                     actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let row = StatusRow(id: id, title: title, state: state, detail: detail, fix: fix, actionTitle: actionTitle, action: action)
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i] = row } else { rows.append(row) }
    }

    func run(app: AppModel) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let s = app.settings
        if rows.isEmpty {
            for (id, t) in [("xcode", "Xcode"), ("sdk", "visionOS SDK"), ("team", L("Equipo de firma", "Signing team")),
                            ("headset", L("Visor", "Headset")), ("bundle", L("Bundle del hub", "Hub bundle id")),
                            ("steam", "Steam"), ("meta", "Meta"), ("metatool", "ovr-platform-util"), ("python", "python3")] {
                rows.append(StatusRow(id: id, title: t))
            }
        }

        // Xcode + SDK
        let xc = await ProcessRunner.capture(ShellCommand("/usr/bin/xcodebuild", ["-version"]), timeout: 30)
        if xc.status == 0 {
            set("xcode", "Xcode", .ok, xc.output.split(separator: "\n").joined(separator: " · "))
        } else {
            set("xcode", "Xcode", .fail, xc.output, fix: L("Instala Xcode y ejecuta `sudo xcode-select -s /Applications/Xcode.app`",
                                                            "Install Xcode, then `sudo xcode-select -s /Applications/Xcode.app`"))
        }
        let sdks = await ProcessRunner.capture(ShellCommand("/usr/bin/xcodebuild", ["-showsdks"]), timeout: 60)
        if let v = Toolchain.visionOSSDK(inShowSDKs: sdks.output) {
            set("sdk", "visionOS SDK", .ok, "xros\(v)")
        } else {
            set("sdk", "visionOS SDK", .fail, L("no instalado", "not installed"),
                fix: L("Xcode › Ajustes › Componentes › visionOS", "Xcode › Settings › Components › visionOS"))
        }

        // Team
        let detected = await AppSettings.detectTeam()
        let teamTitle = L("Equipo de firma", "Signing team")
        if !s.team.isEmpty {
            let note = detected.map { $0 == s.team ? "" : L(" (llavero: \($0))", " (keychain: \($0))") } ?? ""
            set("team", teamTitle, .ok, s.team + note)
        } else if let d = detected {
            set("team", teamTitle, .warn, L("detectado \(d), sin guardar", "detected \(d), not saved"),
                fix: L("Se usará el detectado por el script", "The script will auto-detect it"),
                actionTitle: L("Usar", "Use")) { s.team = d }
        } else {
            set("team", teamTitle, .fail, L("sin certificado Apple Development", "no Apple Development certificate"),
                fix: L("Xcode › Ajustes › Cuentas: inicia sesión y crea un certificado; o pon el equipo en Ajustes",
                       "Xcode › Settings › Accounts: sign in and create a certificate; or set the team in Settings"))
        }

        // Headset
        devices = await DeviceOps.devices()
        let headsetTitle = L("Visor", "Headset")
        if let d = DeviceCtl.pick(devices, preferred: s.deviceID) {
            let saved = d.id == s.deviceID
            let state: CheckState = d.isConnected ? (saved ? .ok : .warn) : .warn
            set("headset", headsetTitle, state, "\(d.name) · \(d.id) · \(d.tunnelState)",
                fix: d.isConnected ? (saved ? "" : L("Guárdalo en Ajustes", "Save it in Settings"))
                    : L("Despierta el visor y ábrelo en Xcode › Dispositivos (misma red)", "Wake the headset; open Xcode › Devices (same network)"),
                actionTitle: saved ? nil : L("Usar", "Use")) { s.deviceID = d.id }
        } else {
            set("headset", headsetTitle, .fail, L("ningún Vision Pro emparejado", "no paired Vision Pro"),
                fix: L("Empareja el visor en Xcode › Dispositivos y simuladores (modo desarrollador activado)",
                       "Pair the headset in Xcode › Devices and Simulators (Developer Mode on)"))
        }

        // Bundle id
        let bundleTitle = L("Bundle del hub", "Hub bundle id")
        if !s.bundleID.isEmpty {
            set("bundle", bundleTitle, .ok, s.bundleID)
        } else if let b = await s.detectBundleID() {
            set("bundle", bundleTitle, .warn, L("targets.py dice \(b)", "targets.py says \(b)"),
                fix: L("Guárdalo para lanzar y traer sesiones", "Save it to launch and pull sessions"),
                actionTitle: L("Usar", "Use")) { s.bundleID = b }
        } else {
            set("bundle", bundleTitle, .fail, L("sin configurar", "not set"), fix: L("Ponlo en Ajustes", "Set it in Settings"))
        }

        // Accounts
        app.steam.refresh()
        if app.steam.signedIn {
            set("steam", "Steam", .ok, app.steam.personaName.map { "\($0) ✓" } ?? L("✓ conectado", "✓ signed in"))
        } else {
            set("steam", "Steam", .warn, L("sin sesión", "signed out"), fix: L("Cuentas › Steam", "Accounts › Steam"))
        }
        await app.meta.refresh()
        set("meta", "Meta", app.meta.signedIn ? .ok : .warn,
            app.meta.signedIn ? L("conectado", "signed in") : L("sin sesión", "signed out"),
            fix: app.meta.signedIn ? "" : L("Cuentas › Meta", "Accounts › Meta"))
        let tool = MetaTool(url: s.metaToolURL)
        let toolCheck: String? = await Task.detached { () -> String? in
            do { try tool.verify(); return nil } catch { return "\(error)" }
        }.value
        let setup = app.meta.toolSetup
        setup.refreshRosetta()
        if let err = toolCheck {
            set("metatool", "ovr-platform-util", .warn, err,
                fix: L("Solo hace falta para iniciar sesión en Meta", "Only needed to sign in to Meta"),
                actionTitle: L("Descargar herramienta de Meta", "Get Meta's tool")) { setup.getTool() }
        } else if setup.needsRosetta {
            set("metatool", "ovr-platform-util", .warn, tool.url.path,
                fix: L("Es solo para Intel y falta Rosetta: \(MetaToolFiles.rosettaCommand)",
                       "Intel-only and Rosetta is missing: \(MetaToolFiles.rosettaCommand)"),
                actionTitle: L("Instalar Rosetta", "Install Rosetta")) { setup.installRosetta() }
        } else {
            let bundled = AppSettings.bundledMetaTool != nil
            set("metatool", "ovr-platform-util", .ok,
                tool.url.path + (bundled ? L(" (incluido en la app, firmado por Meta)", " (bundled, signed by Meta)")
                                         : L(" (firmado por Meta)", " (signed by Meta)")))
        }

        let py = await ProcessRunner.capture(.bash("python3 --version"), timeout: 20)
        set("python", "python3", py.status == 0 ? .ok : .fail, py.output,
            fix: py.status == 0 ? "" : L("Instala las Command Line Tools o Homebrew python", "Install the Command Line Tools or Homebrew python"))

        // Klepton pieces
        let k = s.kleptonURL
        for piece in Toolchain.kleptonPieces {
            let id = "k-" + piece.name
            guard let k else {
                set(id, piece.name, .fail, L("ruta de Klepton sin configurar", "Klepton path not set"), fix: L("Ajustes", "Settings"))
                continue
            }
            let path = k.appendingPathComponent(piece.relativePath).path
            let ok = FileManager.default.fileExists(atPath: path)
            set(id, piece.name, ok ? .ok : .fail, path, fix: ok ? "" : piece.fix)
        }
    }
}

struct StatusView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let status = app.status
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: L("Estado", "Status"),
                         subtitle: L("Lo que hace falta para compilar, instalar y probar.", "What building, installing and testing needs.")) {
                HStack {
                    if status.running { ProgressView().controlSize(.small) }
                    Button(L("Comprobar", "Check again")) { Task { await status.run(app: app) } }.disabled(status.running)
                }
            }
            let setup = app.meta.toolSetup
            if setup.watching || setup.busy || setup.rosettaInstalling || !setup.note.isEmpty {
                HStack(alignment: .top) {
                    if setup.watching || setup.busy || setup.rosettaInstalling { ProgressView().controlSize(.small) }
                    Text("ovr-platform-util: " + setup.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    if setup.watching { Button(L("Dejar de vigilar", "Stop watching")) { setup.stopWatching() } }
                    if !setup.watching, !setup.busy, !setup.note.isEmpty {
                        Button(L("Comprobar", "Check again")) { Task { await status.run(app: app) } }
                    }
                }
            }
            List(status.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    row.state.icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).bold()
                        if !row.detail.isEmpty { Text(row.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if !row.fix.isEmpty { Text("→ " + row.fix).font(.callout).foregroundStyle(row.state == .ok ? Color.secondary : Color.orange) }
                    }
                    Spacer()
                    if let t = row.actionTitle, let a = row.action { Button(t, action: a) }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(20)
        .task { if status.rows.isEmpty { await status.run(app: app) } }
    }
}

extension CheckState: Equatable {}
