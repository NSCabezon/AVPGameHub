// Siri / Shortcuts control of the running game (hub builds only).
//
// Every intent flips the same runtime state the in-game quick settings use
// (KLQuickSettings, KleptonQuickSettings.swift) and saves the choice to the
// game's settings, so the next launch keeps it. They run in the app's own
// process (there is no extension) and in the BACKGROUND (`supportedModes`):
// the hub's window is never brought forward over the immersive game. A game
// is one process here, so "no game running" means the intent woke the library
// (or nothing has been launched): it says so and changes nothing.
//
// Phrases: English in the source; Spanish in AppShortcuts.xcstrings (the
// per-locale phrase catalog). Each phrase carries \(.applicationName), which is
// the hub's CFBundleDisplayName, "AVP Game Hub" (visionos/targets.py, hub row) —
// "Activa el visor de FPS en AVP Game Hub" — or one of its INAlternativeAppNames,
// "Hub" / "Game Hub" (gen_xcodeproj.py): "Abre ajustes del juego en Hub". Phrases, intent type names and the
// AppEnum raw values are a public contract once shipped: add, do not rename.
//
// perform() is not main-actor isolated; KLQuickSettings is lock-protected and
// safe to call from here. Nothing irreversible happens before a value request
// (there are none), so a restarted perform() is harmless.
import AppIntents

private func klReply(_ r: KLQuickSettings.Reply) -> IntentDialog {
    // The text is chosen at runtime in the headset's language (klL), the same
    // way the rest of the hub speaks Spanish; it is not a catalog key.
    IntentDialog("\(r.text)")
}

// The two settings-menu intents carry plain titles ("Open Game Settings" / "Abrir
// ajustes del juego", Localizable.xcstrings) so a user can drop one into a personal
// Shortcut named "Abre ajustes del juego": Siri runs a personal shortcut by its name
// alone, with no app name in the sentence.
struct KLOpenQuickSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Game Settings"
    static let description = IntentDescription("Opens the quick settings panel inside the running game.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.openMenu()))
    }
}

struct KLCloseQuickSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Game Settings"
    static let description = IntentDescription("Closes the quick settings panel inside the running game.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard KLQuickSettings.shared.gameRunning else {
            return .result(dialog: klReply(KLQuickSettings.shared.notRunning()))
        }
        return .result(dialog: klReply(KLQuickSettings.shared.closeMenu()))
    }
}

struct KLShowPerformanceOverlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Performance Overlay"
    static let description = IntentDescription("Shows the fps / GPU / memory panel in the running game.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.setOverlay(true)))
    }
}

struct KLHidePerformanceOverlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide Performance Overlay"
    static let description = IntentDescription("Hides the fps / GPU / memory panel in the running game.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.setOverlay(false)))
    }
}

struct KLTogglePerformanceOverlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Performance Overlay"
    static let description = IntentDescription("Shows or hides the fps / GPU / memory panel in the running game.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.setOverlay(nil)))
    }
}

/// Raw values are persisted by saved shortcuts: never rename.
enum KLAntialiasingLevel: String, AppEnum {
    case x2 = "2x"
    case x4 = "4x"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Antialiasing"
    static let caseDisplayRepresentations: [KLAntialiasingLevel: DisplayRepresentation] = [
        .x2: DisplayRepresentation(title: "2x", synonyms: ["2×", "two x", "dos x", "dos equis", "dos"]),
        .x4: DisplayRepresentation(title: "4x", synonyms: ["4×", "four x", "cuatro x", "cuatro equis", "cuatro"]),
    ]
}

struct KLSetAntialiasingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Antialiasing"
    static let description = IntentDescription("Half-Life: Alyx: changes antialiasing between 2× and 4× while playing.")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Level") var level: KLAntialiasingLevel
    static var parameterSummary: some ParameterSummary { Summary("Set antialiasing to \(\.$level)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.setAntialiasing(level == .x4 ? 4 : 2)))
    }
}

struct KLEnableFoveationIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Foveated Rendering"
    static let description = IntentDescription("Half-Life: Alyx: turns foveated rendering on.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.setFoveation(true)))
    }
}

struct KLDisableFoveationIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Foveated Rendering"
    static let description = IntentDescription("Half-Life: Alyx: turns foveated rendering off.")
    static var supportedModes: IntentModes { .background }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: klReply(KLQuickSettings.shared.setFoveation(false)))
    }
}

/// Eight App Shortcuts (the cap is ten).
struct KLAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: KLOpenQuickSettingsIntent(),
                    phrases: ["Open game settings in \(.applicationName)"],
                    shortTitle: "Open Game Settings", systemImageName: "slider.horizontal.3")
        AppShortcut(intent: KLCloseQuickSettingsIntent(),
                    phrases: ["Close game settings in \(.applicationName)"],
                    shortTitle: "Close Game Settings", systemImageName: "xmark.circle")
        AppShortcut(intent: KLShowPerformanceOverlayIntent(),
                    phrases: ["Turn on the FPS overlay in \(.applicationName)",
                              "Show the FPS counter in \(.applicationName)"],
                    shortTitle: "Show FPS Overlay", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: KLHidePerformanceOverlayIntent(),
                    phrases: ["Turn off the FPS overlay in \(.applicationName)",
                              "Hide the FPS counter in \(.applicationName)"],
                    shortTitle: "Hide FPS Overlay", systemImageName: "gauge.with.dots.needle.0percent")
        AppShortcut(intent: KLTogglePerformanceOverlayIntent(),
                    phrases: ["Toggle the FPS overlay in \(.applicationName)"],
                    shortTitle: "Toggle FPS Overlay", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: KLSetAntialiasingIntent(),
                    phrases: ["Set antialiasing to \(\.$level) in \(.applicationName)"],
                    shortTitle: "Set Antialiasing", systemImageName: "square.grid.3x3")
        AppShortcut(intent: KLEnableFoveationIntent(),
                    phrases: ["Turn on foveated rendering in \(.applicationName)",
                              "Turn on foveation in \(.applicationName)"],
                    shortTitle: "Foveation On", systemImageName: "eye")
        AppShortcut(intent: KLDisableFoveationIntent(),
                    phrases: ["Turn off foveated rendering in \(.applicationName)",
                              "Turn off foveation in \(.applicationName)"],
                    shortTitle: "Foveation Off", systemImageName: "eye.slash")
    }
}
