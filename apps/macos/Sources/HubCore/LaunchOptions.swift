import Foundation

/// The Launch & Test presets, turned into the environment the hub app is launched with.
/// Every preset can stay at the hub's own default, in which case nothing is sent: the visionOS
/// hub (kl_app.c) sets its per-game defaults with setenv(…, 0), so only an explicit override
/// from here changes them.
public struct LaunchOptions: Codable, Equatable, Sendable {
    public enum MSAA: Int, Codable, CaseIterable, Sendable { case appDefault = 0, x2 = 2, x4 = 4 }

    /// A preset the hub has its own default for: leave it alone, or force it on / off.
    public enum Tri: String, Codable, CaseIterable, Sendable { case hubDefault, on, off }

    /// What the hub does when nothing is sent (kl_app.c, Alyx block: KL_ALYX_MSAA=4, KL_FOVEATE=1,
    /// KL_GUEST_PACE_HZ=45; other games get none of them).
    public struct HubDefaults: Equatable, Sendable {
        public var msaa: Int?
        public var foveated: Bool
        public var pace45: Bool
    }

    public static func hubDefaults(game: String) -> HubDefaults {
        game == "alyx" ? HubDefaults(msaa: 4, foveated: true, pace45: true)
                       : HubDefaults(msaa: nil, foveated: false, pace45: false)
    }

    public var game: String = "alyx"
    /// KL_ALYX_MSAA=2|4
    public var msaa: MSAA = .appDefault
    /// KL_FOVEATE=1|0 (fixed foveated rendering through the MoltenVK FDM fork)
    public var foveation: Tri = .hubDefault
    /// KL_GUEST_PACE_HZ=45|0
    public var pace: Tri = .hubDefault
    /// KL_HUD=1
    public var hud = false
    /// KL_GPU_TIME=1 (logs "[perf] gpu time over N frames")
    public var gpuTime = true
    /// KL_FOVEATE_AB=<s> (in-process foveation A/B, flips every s seconds; needs the fork). 0 = off.
    public var abSeconds = 0
    /// Extra KEY=VALUE lines, one per line (# comments allowed). They win over the presets.
    public var extra = ""

    public init() {}

    /// The A/B runs only when foveation isn't forced off.
    public var abActive: Bool { abSeconds > 0 && foveation != .off }

    public func environment() -> [String: String] {
        var env: [String: String] = [:]
        if !game.isEmpty { env["KL_HUB_GAME"] = game }
        if msaa != .appDefault { env["KL_ALYX_MSAA"] = String(msaa.rawValue) }
        switch foveation {
        case .on: env["KL_FOVEATE"] = "1"
        case .off: env["KL_FOVEATE"] = "0"
        case .hubDefault:
            // The A/B needs the foveated path; only Alyx turns it on by itself.
            if abActive && !Self.hubDefaults(game: game).foveated { env["KL_FOVEATE"] = "1" }
        }
        if abActive { env["KL_FOVEATE_AB"] = String(abSeconds) }
        switch pace {
        case .on: env["KL_GUEST_PACE_HZ"] = "45"
        case .off: env["KL_GUEST_PACE_HZ"] = "0"
        case .hubDefault: break
        }
        if hud { env["KL_HUD"] = "1" }
        if gpuTime { env["KL_GPU_TIME"] = "1" }
        for (k, v) in Self.parseExtra(extra) { env[k] = v }
        return env
    }

    public static func parseExtra(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            return (k, v)
        }
    }

    // Tolerant decoding: options saved by older builds (foveated/pace45/abTest booleans, which
    // always sent an override) load as "hub default" rather than being thrown away.
    private enum CodingKeys: String, CodingKey { case game, msaa, foveation, pace, hud, gpuTime, abSeconds, extra }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LaunchOptions()
        game = try c.decodeIfPresent(String.self, forKey: .game) ?? d.game
        msaa = (try? c.decodeIfPresent(MSAA.self, forKey: .msaa)) ?? d.msaa
        foveation = (try? c.decodeIfPresent(Tri.self, forKey: .foveation)) ?? d.foveation
        pace = (try? c.decodeIfPresent(Tri.self, forKey: .pace)) ?? d.pace
        hud = try c.decodeIfPresent(Bool.self, forKey: .hud) ?? d.hud
        gpuTime = try c.decodeIfPresent(Bool.self, forKey: .gpuTime) ?? d.gpuTime
        // Old builds kept a separate abTest toggle; without it the seconds alone don't mean "on".
        abSeconds = c.contains(.foveation) ? (try c.decodeIfPresent(Int.self, forKey: .abSeconds) ?? 0) : 0
        extra = try c.decodeIfPresent(String.self, forKey: .extra) ?? d.extra
    }
}
