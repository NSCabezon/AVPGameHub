import AppKit
import HubCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var devices: [DeviceInfo] = []

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Section("Klepton") {
                pathField(L("Checkout de Klepton", "Klepton checkout"), $s.kleptonPath, directory: true,
                          prompt: "~/Apps/Klepton")
                if !s.hasKlepton {
                    Text(L("No se encuentra build_run_vpro.sh ahí", "build_run_vpro.sh not found there")).foregroundStyle(.red).font(.callout)
                }
            }
            Section(L("Firma y visor", "Signing & headset")) {
                field(L("Equipo (KLEPTON_TEAM)", "Team (KLEPTON_TEAM)"), $s.team, prompt: "ABCDE12345") {
                    Button(L("Detectar", "Detect")) { Task { if let t = await AppSettings.detectTeam() { s.team = t } } }
                }
                field(L("Bundle id del hub (KLEPTON_BUNDLE_ID)", "Hub bundle id (KLEPTON_BUNDLE_ID)"), $s.bundleID,
                      prompt: "com.example.hub") {
                    Button(L("De targets.py", "From targets.py")) { Task { if let b = await s.detectBundleID() { s.bundleID = b } } }
                }
                field(L("Visor (KLEPTON_DEVICE)", "Headset (KLEPTON_DEVICE)"), $s.deviceID, prompt: "00008112-…") {
                    Menu(L("Elegir", "Pick")) {
                        ForEach(devices) { d in
                            Button("\(d.name) — \(d.platform) \(d.tunnelState)") { s.deviceID = d.id }
                        }
                        if devices.isEmpty { Text(L("Ninguno (pulsa Buscar)", "None (press Scan)")) }
                    }
                    .frame(width: 90)
                    Button(L("Buscar", "Scan")) { Task { devices = await DeviceOps.devices() } }
                }
            }
            Section(L("Cuentas y descargas", "Accounts & downloads")) {
                pathField("ovr-platform-util", $s.metaToolPath, directory: false)
                pathField(L("Token de Steam (fichero)", "Steam token (file)"), $s.steamTokenPath, directory: false)
                pathField(L("Descargas en este Mac", "Downloads on this Mac"), $s.downloadsPath, directory: true)
                pathField(L("Sesiones en este Mac", "Sessions on this Mac"), $s.sessionsPath, directory: true)
            }
            Section(L("Script de traducción (Juegos › Actualizar)", "Translate script (Games › Update)")) {
                TextEditor(text: $s.translateScript)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120)
                HStack {
                    Text(L("Se ejecuta en Klepton con $APK y $KLEPTON_TARGET.", "Runs in Klepton with $APK and $KLEPTON_TARGET."))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Restaurar", "Reset")) { s.translateScript = AppSettings.defaultTranslateScript }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
    }

    /// A labelled, editable text field with its helper buttons after it. The label is a separate
    /// view so the field always gets the row's remaining width (a TextField in an HStack inside a
    /// grouped Form otherwise collapses and only the buttons show).
    private func field<B: View>(_ title: String, _ binding: Binding<String>, prompt: String = "",
                                @ViewBuilder buttons: () -> B) -> some View {
        LabeledContent {
            HStack {
                TextField(title, text: binding, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(minWidth: 220, maxWidth: .infinity)
                buttons()
            }
        } label: {
            Text(title)
        }
    }

    private func pathField(_ title: String, _ binding: Binding<String>, directory: Bool, prompt: String = "") -> some View {
        field(title, binding, prompt: prompt) {
            Button(L("Elegir…", "Choose…")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory
                panel.canChooseFiles = !directory
                panel.canCreateDirectories = directory
                if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
            }
        }
    }
}
