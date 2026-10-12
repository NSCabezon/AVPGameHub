import AppKit
import HubCore
import Observation
import SwiftUI

/// Every screen's state lives here so switching screens never loses a running build or log.
@MainActor @Observable
final class AppModel {
    let settings: AppSettings
    let status = StatusModel()
    let steam: SteamAccount
    let meta: MetaAccount
    let games = GamesModel()
    let build = BuildModel()
    let launch = LaunchModel()
    let sessions = SessionsModel()
    let stream = StreamModel()
    let saves = SavesModel()

    init() {
        let s = AppSettings()
        settings = s
        steam = SteamAccount(settings: s)
        meta = MetaAccount(settings: s)
    }

    func stopEverything() {
        stream.stopForQuit()
        build.cancel()
        launch.stop()
        games.cancel()
        steam.cancel()
        if meta.running { meta.cancelLogin() }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case status, accounts, games, build, launch, streaming, sessions, saves, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return L("Estado", "Status")
        case .accounts: return L("Cuentas", "Accounts")
        case .games: return L("Juegos", "Games")
        case .build: return L("Compilar e instalar", "Build & Install")
        case .launch: return L("Lanzar y probar", "Launch & Test")
        case .streaming: return L("Streaming", "Streaming")
        case .sessions: return L("Sesiones", "Sessions")
        case .saves: return L("Partidas", "Saves")
        case .settings: return L("Ajustes", "Settings")
        }
    }
    var icon: String {
        switch self {
        case .status: return "checklist"
        case .accounts: return "person.crop.circle"
        case .games: return "gamecontroller"
        case .build: return "hammer"
        case .launch: return "play.circle"
        case .streaming: return "dot.radiowaves.left.and.right"
        case .sessions: return "chart.xyaxis.line"
        case .saves: return "externaldrive.badge.timemachine"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var screen: Screen? = .status

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { s in
                Label {
                    HStack {
                        Text(s.title)
                        Spacer()
                        if s == .build && app.build.running || s == .launch && app.launch.running || s == .games && app.games.running != nil
                            || s == .streaming && (app.stream.running || app.stream.building)
                            || s == .saves && app.saves.running {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } icon: { Image(systemName: s.icon) }
                .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch screen ?? .status {
            case .status: StatusView()
            case .accounts: AccountsView()
            case .games: GamesView()
            case .build: BuildView()
            case .launch: LaunchView()
            case .streaming: StreamingView()
            case .sessions: SessionsView()
            case .saves: SavesView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a plain `swift run` executable, the process is not an app bundle: make it a
        // regular foreground app with a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}

@main
struct AVPGameHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AVP Game Hub") {
            RootView()
                .environment(model)
                .onAppear { delegate.onTerminate = { [model] in MainActor.assumeIsolated { model.stopEverything() } } }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
