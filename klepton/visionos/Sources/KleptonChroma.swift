// Chroma keying and hand matting — the two things that decide how much of the
// ROOM shows through the guest's picture, made adjustable while wearing the
// headset and remembered across launches.
//
// **Ported from VisionOSALVRClient with its maths and its defaults intact.**
// The two distance dials are numbers a person finds by looking at a matte, not
// values that can be derived, so keeping them identical means a setting found
// in that client still means the same thing here. `kl_reproject.c` carries the
// shader half and the same argument.
//
// Unlike the controller tuning beside it, these are PERSISTED: a key colour is
// a property of the room the person is sitting in, not of a debugging session,
// and re-finding it every launch is the thing that would stop it being used.
import SwiftUI
import simd

/// Everything the two panels below own. `Codable` because it is written to
/// UserDefaults as JSON — a struct rather than seven separate defaults keys so
/// a settings file can never be half-migrated, and so adding a dial later is a
/// field with a default rather than a new key nothing writes.
struct KLChromaSettings: Codable, Equatable {
    var enabled = false
    var color   = SIMD3<Float>(16.0 / 255.0, 124.0 / 255.0, 16.0 / 255.0)
    var distMin: Float = 0.35
    var distMax: Float = 0.7
    // Hand matting USED to live here, app-wide. It is per game now
    // (KLGameSettings below): whether the system draws your real hands over the
    // picture depends on whether the GAME draws its own. A blob written by an
    // older build still carries a `handMatting` key; the decoder below simply
    // never reads it (and the next save drops it), which is the migration.
    // Ignored rather than carried over because it was rarely a choice about a
    // game: any save of the chroma dials wrote the default along with them, and
    // in the hub that default was computed for the target "hub" (matting ON)
    // before any game was picked — which is how SUPERHOT showed real hands.

    /// SIMD3 is not Codable, so the colour rides as three keyed floats. Spelled
    /// out rather than reached for a wrapper: this is the file format, and a
    /// format that is legible in the JSON is one a person can fix by hand.
    private enum CodingKeys: String, CodingKey {
        case enabled, distMin, distMax
        case colorR, colorG, colorB
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // decodeIfPresent throughout, so a settings blob written by an older
        // build is READ rather than rejected: a missing field keeps this
        // struct's default instead of failing the whole decode and silently
        // resetting every other dial with it.
        enabled     = try c.decodeIfPresent(Bool.self,  forKey: .enabled)     ?? enabled
        distMin     = try c.decodeIfPresent(Float.self, forKey: .distMin)     ?? distMin
        distMax     = try c.decodeIfPresent(Float.self, forKey: .distMax)     ?? distMax
        color = SIMD3<Float>(try c.decodeIfPresent(Float.self, forKey: .colorR) ?? color.x,
                             try c.decodeIfPresent(Float.self, forKey: .colorG) ?? color.y,
                             try c.decodeIfPresent(Float.self, forKey: .colorB) ?? color.z)
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(enabled,     forKey: .enabled)
        try c.encode(distMin,     forKey: .distMin)
        try c.encode(distMax,     forKey: .distMax)
        try c.encode(color.x, forKey: .colorR)
        try c.encode(color.y, forKey: .colorG)
        try c.encode(color.z, forKey: .colorB)
    }
}

final class KleptonChroma: ObservableObject {
    static let shared = KleptonChroma()

    private static let defaultsKey = "klepton.chroma"

    @Published var settings = KLChromaSettings() { didSet { publish(); save() } }

    /// The game these per-game values belong to (klTargetName() at init; the
    /// hub re-points it at the picked game in HubLaunch.select).
    private(set) var gameTarget = ""
    private var loadingGame = false

    /// Whether the system mattes the user's own hands and arms OVER the guest's
    /// picture — PER GAME (KLGameSettings). Off is what a guest that draws its
    /// own hands wants, because two pairs of hands in one place is worse than
    /// either alone; see KLGameSettingsStore.defaultMatting for the defaults.
    /// Toggling it in the Matting panel saves it for this game only.
    @Published var handMatting = false {
        didSet {
            guard !loadingGame, !gameTarget.isEmpty else { return }
            KLGameSettingsStore.update(gameTarget) { $0.handMatting = handMatting }
        }
    }

    private init() {
        // **The environment wins where it is explicitly set, then the saved
        // settings, then the defaults**, and that order is the one that stays
        // predictable. Saved-wins would make a `KL_CHROMA=1` on a launch line
        // do nothing as soon as anything had ever been saved, which reads as
        // the knob being broken; environment-always-wins would make the panel
        // unable to turn off something a script had turned on.
        var s = KLChromaSettings()
        if let d = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(KLChromaSettings.self, from: d) {
            s = saved
            NSLog("[chroma] restored: \(Self.describe(s))")
        }
        let env = ProcessInfo.processInfo.environment
        if let v = env["KL_CHROMA"]       { s.enabled = v != "0" }
        if let v = env["KL_CHROMA_COLOR"] {
            let f = v.split(separator: ",").compactMap { Float($0) }
            if f.count == 3 { s.color = SIMD3<Float>(f[0], f[1], f[2]) }
        }
        if let v = env["KL_CHROMA_RANGE"] {
            let f = v.split(separator: ",").compactMap { Float($0) }
            if f.count == 2 { s.distMin = f[0]; s.distMax = f[1] }
        }
        settings = s          // didSet publishes it to the shader and re-saves
        loadGame(klTargetName())
    }

    /// Re-read the per-game values for `target`. Called at init (a single-game
    /// build's target) and by the hub when Play picks a game, BEFORE the boot
    /// window exists — so the immersive scene is already .full / hands-hidden
    /// by the time anything could open it.
    func loadGame(_ target: String) {
        loadingGame = true
        defer { loadingGame = false }
        gameTarget = target
        handMatting = KLGameSettingsStore.handMatting(for: target)
        #if KL_HUB
        // The hub's default does not depend on the guest kind, so it is
        // knowable now rather than only after kl_app_configure.
        immersionFull = KLGameSettingsStore.fullImmersion(for: target)
        #endif
        NSLog("[chroma] \(target): handMatting=\(handMatting) immersionFull=\(immersionFull) "
              + "(\(KLGameSettingsStore.describe(target)))")
    }

    /// What the App reads to decide whether the system draws the user's hands
    /// over the guest. Published, so toggling it re-evaluates the scene rather
    /// than waiting for a relaunch.
    var upperLimbVisibility: Visibility { handMatting ? .automatic : .hidden }

    /// Whether the immersive space opens FULLY immersive (no passthrough). This
    /// lives here — on the object the scene already observes — rather than in a
    /// static read at scene-build time, because for a single-game build that
    /// default depends on the guest kind (kl_app_target_wants_full), which is
    /// only known AFTER kl_app_configure runs, well after SwiftUI first
    /// evaluates the scene. Boot sets it once configure has resolved the target
    /// (the hub sets it earlier still, in loadGame); publishing it re-evaluates
    /// the scene so .full takes hold before the space opens.
    @Published var immersionFull = false

    private func publish() {
        var rgb = [settings.color.x, settings.color.y, settings.color.z]
        kl_reproject_set_chroma(settings.enabled ? 1 : 0, &rgb,
                                settings.distMin, settings.distMax)
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(d, forKey: Self.defaultsKey)
    }

    /// The environment lines that would reproduce this set, for the same reason
    /// the controller panel has one: a value found by dragging and not written
    /// down is a value found twice — and this one also has to survive being
    /// quoted into a `build_run_vpro.sh` invocation.
    static func describe(_ s: KLChromaSettings, handMatting: Bool? = nil) -> String {
        String(format: "KL_CHROMA=%d KL_CHROMA_COLOR=\"%.4f,%.4f,%.4f\" "
               + "KL_CHROMA_RANGE=\"%.3f,%.3f\"",
               s.enabled ? 1 : 0, s.color.x, s.color.y, s.color.z,
               s.distMin, s.distMax)
            + (handMatting.map { " KL_HAND_MATTING=\($0 ? 1 : 0)" } ?? "")
    }
}

// MARK: - Per-game settings

/// What each game remembers for itself: how it is presented and in which
/// language it boots. One JSON blob per target under `klepton.game.<target>`.
/// Every field is optional and nil means "the default for this game"
/// (KLGameSettingsStore), so a default can change in a later build without a
/// migration, and only what the person actually chose is pinned.
struct KLGameSettings: Codable, Equatable {
    /// .full (no passthrough) vs .mixed.
    var fullImmersion: Bool?
    /// The system draws the user's real hands over the game.
    var handMatting: Bool?
    /// Draw a virtual PSVR2 controller where a real one rests while it is not
    /// in a hand (KleptonHUD ghost controllers). nil = on.
    var ghostControllers: Bool?
    /// KLGameLanguage raw value; nil or "system" = the headset's language.
    var language: String?
    /// Controller calibration — the Sense (PSVR2) grip correction and the
    /// OpenXR grip tune, the SAME values the boot window's Controller alignment
    /// panel edits (KleptonTuning). Only fields that differ from the baseline.
    var calibration: KLCalibration?
    /// Render performance (Alyx's OpenVR path only, for now).
    var performance: KLPerformance?
    /// "Precompile graphics": replay the game's pipeline list (klfz/<target>.foz)
    /// before it boots, so the Metal compiler is warm (KL_FOZ_PREWARM). nil = off.
    var precompileGraphics: Bool?
    /// "Performance overlay": the in-game fps/GPU/memory panel
    /// (KleptonQuickSettings.swift), KL_HUD. nil = off. Siri and the in-game
    /// quick settings write it too.
    var perfOverlay: Bool?
}

/// See KLGameSettings.calibration and KleptonTuning. Degrees and metres, in the
/// grip's own frame; nil = the baseline (environment, else built-in default).
struct KLCalibration: Codable, Equatable {
    var senseOffset: [Float]?        // KL_SENSE_POS  x,y,z
    var sensePitch: Float?           // KL_SENSE_PITCH
    var senseYaw: Float?             // KL_SENSE_YAW
    var senseRoll: Float?            // KL_SENSE_ROLL
    var sensePivot: [Float]?         // KL_SENSE_PIVOT
    var gripPitch: Float?            // KL_XR_GRIP_PITCH (OpenXR guests)
    var aimPitch: Float?             // KL_XR_AIM_PITCH
    var gripPivot: [Float]?          // KL_XR_GRIP_PIVOT
    var gripPos: [Float]?            // KL_XR_GRIP_POS
}

/// Alyx's OpenVR render knobs; nil = the runtime's default (kl_openvr.c).
struct KLPerformance: Codable, Equatable {
    var renderScale: Float?          // KL_OPENVR_RT_SCALE, 0.6–1.2 (default 1.0)
    var overscan: Float?             // KL_OPENVR_OVERSCAN, 0–0.2 (default 0.12 for alyx)
    var overscanRT: Bool?            // KL_OPENVR_OVERSCAN_RT (default on)
    var msaa: Int?                   // KL_ALYX_MSAA, 2 or 4 (default 4; kl_app.c picks the fidelity level)
    var foveate: Bool?               // KL_FOVEATE (default on; kl_app.c)
}

/// The languages a game can be told to boot in, and what each one means on the
/// two channels a guest reads: the Android locale (java.util.Locale,
/// AConfiguration, SDL, persist.sys.locale — all from KL_LOCALE, see
/// kl_jni_locale_parts) and Steam's language API name
/// (GetCurrentGameLanguage / GetSteamUILanguage — KL_STEAM_LANG).
enum KLGameLanguage: String, CaseIterable, Identifiable {
    case system
    case en, es, fr, de, it
    case ptBR = "pt-BR"
    case ja, ko
    case zhHans = "zh-Hans"
    case ru
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return klL("System", "Sistema")
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .ptBR: return "Português (Brasil)"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .zhHans: return "简体中文"
        case .ru: return "Русский"
        }
    }

    /// Android/POSIX locale (KL_LOCALE, LANG). nil = leave the system's.
    var locale: String? {
        switch self {
        case .system: return nil
        case .en: return "en_US"
        case .es: return "es_ES"
        case .fr: return "fr_FR"
        case .de: return "de_DE"
        case .it: return "it_IT"
        case .ptBR: return "pt_BR"
        case .ja: return "ja_JP"
        case .ko: return "ko_KR"
        case .zhHans: return "zh_CN"
        case .ru: return "ru_RU"
        }
    }

    /// Steam's language API name (KL_STEAM_LANG). nil = leave the system's.
    var steam: String? {
        switch self {
        case .system: return nil
        case .en: return "english"
        case .es: return "spanish"
        case .fr: return "french"
        case .de: return "german"
        case .it: return "italian"
        case .ptBR: return "brazilian"
        case .ja: return "japanese"
        case .ko: return "koreana"
        case .zhHans: return "schinese"
        case .ru: return "russian"
        }
    }
}

enum KLGameSettingsStore {
    static func key(_ target: String) -> String { "klepton.game.\(target)" }

    static func load(_ target: String) -> KLGameSettings {
        guard let d = UserDefaults.standard.data(forKey: key(target)),
              let s = try? JSONDecoder().decode(KLGameSettings.self, from: d) else { return KLGameSettings() }
        return s
    }

    static func save(_ s: KLGameSettings, for target: String) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(d, forKey: key(target))
    }

    static func update(_ target: String, _ change: (inout KLGameSettings) -> Void) {
        var s = load(target)
        change(&s)
        save(s, for: target)
    }

    /// The languages offered for `target`. Every game the hub carries today
    /// (Half-Life: Alyx, SUPERHOT VR) ships text for all of these; a game that
    /// does not gets its own list here.
    static func languages(for target: String) -> [KLGameLanguage] {
        KLGameLanguage.allCases
    }

    /// Whether the Performance section applies (the OpenVR render knobs).
    static func hasPerformance(_ target: String) -> Bool { target == "alyx" }
    static let defaultRenderScale: Float = 1.0
    static let defaultOverscan: Float = 0.12
    static let defaultOverscanRT = true
    // What kl_app.c sets for Alyx when neither the launch environment nor the
    // hub says otherwise (4x MSAA + foveation: -36% GPU against 4x full rate on
    // M2, 2026-10-11). The pickers show these when the setting is nil.
    static let defaultMSAA = 4
    static let defaultFoveate = true

    /// Whether "Precompile graphics" applies (a Vulkan game with a pipeline list).
    static func hasPrecompile(_ target: String) -> Bool { target == "alyx" || target == "metro" }
    /// ...and whether it is on when the player has not chosen. Metro (UE5) compiles
    /// its pipelines on first use, ~300 ms each on M2, and has no list of its own:
    /// on by default, the first session records what it compiles (klfz/recorded/)
    /// and every later launch compiles that before the game starts.
    static func defaultPrecompile(_ target: String) -> Bool { target == "metro" }
    /// The game's pipeline list, and the record of how it makes its Vulkan device
    /// (written by the runtime at the game's vkCreateDevice), in the game's
    /// container: Documents/games/<target>/klfz/ in the hub. Generated on the Mac
    /// (tools/alyx_pipelines.py) and copied there (BUILDING.md, Fossilize).
    static func fozDir(_ target: String) -> URL {
        Paths.containerURL(for: target).appendingPathComponent("klfz", isDirectory: true)
    }
    static func fozURL(_ target: String) -> URL {
        fozDir(target).appendingPathComponent("\(target).foz")
    }
    static func precompileGraphics(for target: String) -> Bool {
        hasPrecompile(target) && (load(target).precompileGraphics ?? defaultPrecompile(target))
    }
    /// Pipelines recorded on earlier sessions (KL_FOZ_AUTORECORD), which the
    /// prewarm replays along with the list.
    static func hasRecordedPipelines(_ target: String) -> Bool {
        let rec = fozDir(target).appendingPathComponent("recorded", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rec.path)) ?? []
        return names.contains { $0.hasSuffix(".foz") }
    }
    /// The setting is on and there is something to compile: the boot window shows
    /// "Preparing graphics… n/N" before the game starts.
    static func willPrecompile(_ target: String) -> Bool {
        precompileGraphics(for: target)
            && (FileManager.default.fileExists(atPath: fozURL(target).path) || hasRecordedPipelines(target))
    }

    // Defaults. The hub's are "a VR game, fully": every hub game draws its own
    // world and its own hands, so it opens .full with the real hands hidden.
    // A single-game build keeps its development defaults: .mixed unless the
    // guest kind wants .full (kl_app_target_wants_full, valid only after
    // kl_app_configure), and hand matting on except for alyx.
    static func defaultFull(_ target: String) -> Bool {
        #if KL_HUB
        return true
        #else
        return kl_app_target_wants_full() != 0
        #endif
    }
    static func defaultMatting(_ target: String) -> Bool {
        #if KL_HUB
        return false
        #else
        return target != "alyx" && targetHandMatting
        #endif
    }
    /// A single-game build's own default (targets.py "hand_matting", baked into
    /// Info.plist as KLHandMattingDefault). Anything but "0" is on, so every row
    /// that does not state it keeps the old default; avp-play's rows whose games
    /// draw their own hands say False. Adapted from avp-play (MIT,
    /// github.com/myMartek/avp-play) visionos/Sources/KleptonChroma.swift.
    static let targetHandMatting: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "KLHandMattingDefault") as? String) != "0"

    /// Environment (KL_FULL, for debugging) > saved > default.
    static func fullImmersion(for target: String) -> Bool {
        klEnvOn("KL_FULL", default: load(target).fullImmersion ?? defaultFull(target))
    }
    /// Environment (KL_HAND_MATTING) > saved > default.
    static func handMatting(for target: String) -> Bool {
        if let v = ProcessInfo.processInfo.environment["KL_HAND_MATTING"] { return v != "0" }
        return load(target).handMatting ?? defaultMatting(target)
    }
    static func language(for target: String) -> KLGameLanguage {
        KLGameLanguage(rawValue: load(target).language ?? "system") ?? .system
    }
    static let defaultGhostControllers = true
    /// Environment (KL_GHOST_CTRL) > saved > default (on).
    static func ghostControllers(for target: String) -> Bool {
        klEnvOn("KL_GHOST_CTRL", default: load(target).ghostControllers ?? defaultGhostControllers)
    }

    /// Put the game's language into the environment the runtime reads, BEFORE
    /// kl_app_configure/boot: KL_LOCALE (Android Locale / AConfiguration / SDL /
    /// persist.sys.locale), KL_STEAM_LANG (Steamworks' game and UI language —
    /// what Alyx and SUPERHOT read) and LANG (what a glibc guest's getenv sees).
    /// Never overwrites: a value already in the launch environment is a
    /// debugging override and wins. "System" sets nothing.
    /// Everything the runtime reads from the environment, before boot: the
    /// language below and Alyx's render knobs. Never overwrites a value already
    /// in the launch environment (a debugging override wins).
    static func applyBeforeBoot(for target: String) {
        applyLanguage(for: target)
        // The compositor reads KL_GHOST_CTRL (KleptonHUD); a value already in
        // the launch environment wins.
        if let g = load(target).ghostControllers { setenv("KL_GHOST_CTRL", g ? "1" : "0", 0) }
        // The performance overlay (KleptonQuickSettings reads KL_HUD once, at
        // its first use, which is after this).
        if load(target).perfOverlay == true { setenv("KL_HUD", "1", 0) }
        applyPrecompile(for: target)
        guard hasPerformance(target), let p = load(target).performance else { return }
        if let v = p.renderScale { setenv("KL_OPENVR_RT_SCALE", String(format: "%.3f", v), 0) }
        if let v = p.overscan    { setenv("KL_OPENVR_OVERSCAN", String(format: "%.3f", v), 0) }
        if let v = p.overscanRT  { setenv("KL_OPENVR_OVERSCAN_RT", v ? "1" : "0", 0) }
        if let v = p.msaa        { setenv("KL_ALYX_MSAA", String(v), 0) }
        if let v = p.foveate     { setenv("KL_FOVEATE", v ? "1" : "0", 0) }
        let env = ProcessInfo.processInfo.environment
        NSLog("[perf] \(target): KL_OPENVR_RT_SCALE=\(env["KL_OPENVR_RT_SCALE"] ?? "default") "
              + "KL_OPENVR_OVERSCAN=\(env["KL_OPENVR_OVERSCAN"] ?? "default") "
              + "KL_OPENVR_OVERSCAN_RT=\(env["KL_OPENVR_OVERSCAN_RT"] ?? "default") "
              + "KL_ALYX_MSAA=\(env["KL_ALYX_MSAA"] ?? "default") "
              + "KL_FOVEATE=\(env["KL_FOVEATE"] ?? "default")")
    }

    /// "Precompile graphics": KL_VK_DEVICE_INFO so the runtime records how the game
    /// makes its device (the prewarm rebuilds that device on the next launch), and
    /// KL_FOZ_PREWARM when the pipeline list is there. Never overwrites.
    static func applyPrecompile(for target: String) {
        guard precompileGraphics(for: target) else { return }
        let dir = fozDir(target)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("KL_VK_DEVICE_INFO", dir.appendingPathComponent("device-info.json").path, 0)
        let foz = fozURL(target)
        if FileManager.default.fileExists(atPath: foz.path) {
            setenv("KL_FOZ_PREWARM", foz.path, 0)
        }
        // Each session records the pipelines the list did not have into klfz/recorded/,
        // and the next prewarm replays those too (kl_fossilize.cpp, KL_FOZ_AUTORECORD:
        // only new pipelines are written; old sessions are merged, the folder is capped).
        // KL_FOZ_AUTORECORD=0 in the launch environment turns it off.
        let rec = dir.appendingPathComponent("recorded")
        try? FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        setenv("KL_FOZ_AUTORECORD", rec.path, 0)
        let env = ProcessInfo.processInfo.environment
        NSLog("[foz] \(target): KL_FOZ_PREWARM=\(env["KL_FOZ_PREWARM"] ?? "unset (no \(foz.path))") "
              + "KL_FOZ_AUTORECORD=\(env["KL_FOZ_AUTORECORD"] ?? "") "
              + "KL_VK_DEVICE_INFO=\(env["KL_VK_DEVICE_INFO"] ?? "")")
    }

    static func applyLanguage(for target: String) {
        let lang = language(for: target)
        guard let loc = lang.locale, let steam = lang.steam else {
            NSLog("[lang] \(target): system language")
            return
        }
        setenv("KL_LOCALE", loc, 0)
        setenv("KL_STEAM_LANG", steam, 0)
        setenv("LANG", loc + ".UTF-8", 0)
        let env = ProcessInfo.processInfo.environment
        NSLog("[lang] \(target): \(lang.rawValue) -> KL_LOCALE=\(env["KL_LOCALE"] ?? "") "
              + "KL_STEAM_LANG=\(env["KL_STEAM_LANG"] ?? "") LANG=\(env["LANG"] ?? "")")
    }

    static func describe(_ target: String) -> String {
        let s = load(target)
        func opt(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "default" }
        return "saved full=\(opt(s.fullImmersion)) matting=\(opt(s.handMatting)) "
            + "language=\(s.language ?? "system")"
    }
}

/// The panel, a sibling of TuningView in the boot window — which stays open
/// beside the immersive space, so the guest keeps rendering while these move.
struct ChromaView: View {
    @ObservedObject private var chroma = KleptonChroma.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Matting").font(.headline)
            Text("What of the room shows through. The key colour is matched in "
                 + "HSV with hue weighted heaviest, so a green screen under "
                 + "uneven light still keys as one colour.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Chroma key", isOn: $chroma.settings.enabled)
            ColorPicker("Key colour", selection: Binding(
                get: { Color(.sRGB,
                             red:   Double(chroma.settings.color.x),
                             green: Double(chroma.settings.color.y),
                             blue:  Double(chroma.settings.color.z)) },
                set: { c in
                    // resolve() gives the components in the picker's own space,
                    // which is what the shader compares against — see
                    // kl_reproject.c on which space the key test runs in.
                    let r = c.resolve(in: EnvironmentValues())
                    chroma.settings.color = SIMD3<Float>(r.red, r.green, r.blue)
                }))
            .disabled(!chroma.settings.enabled)

            // The fade band. `min` is where a pixel is fully keyed out and
            // `max` where it is fully kept, so min above max would invert the
            // ramp — the setters clamp rather than letting the sliders cross.
            dist("Key out below", $chroma.settings.distMin)
            dist("Keep above",    $chroma.settings.distMax)

            Divider()
            Toggle("Hand matting (system draws your hands over the guest)",
                   isOn: $chroma.handMatting)
            Text("Saved for this game only. Turn off for a guest that draws its "
                 + "own hands — two pairs in one place is worse than either alone.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            HStack {
                Button("Log as environment") {
                    NSLog("[chroma] \(KleptonChroma.describe(chroma.settings, handMatting: chroma.handMatting))")
                }
                Button("Reset") { chroma.settings = KLChromaSettings() }
            }
            Text(KleptonChroma.describe(chroma.settings, handMatting: chroma.handMatting))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func dist(_ label: String, _ value: Binding<Float>) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { v in
                    value.wrappedValue = v
                    // Hold min <= max from whichever side moved, so the band
                    // can be dragged shut but never through itself.
                    if chroma.settings.distMin > chroma.settings.distMax {
                        if label.hasPrefix("Key out") {
                            chroma.settings.distMax = chroma.settings.distMin
                        } else {
                            chroma.settings.distMin = chroma.settings.distMax
                        }
                    }
                }), in: 0 ... 2, step: 0.01)
            Text(String(format: "%5.2f", value.wrappedValue))
                .font(.system(.body, design: .monospaced)).frame(width: 60)
        }
        .disabled(!chroma.settings.enabled)
    }
}
