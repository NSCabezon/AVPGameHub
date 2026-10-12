// Klepton's own things in the immersive layer, drawn after the game's frame:
//
//   * GHOST CONTROLLERS. In full VR the real PSVR2 Sense controllers are
//     invisible. When one is NOT in a hand (resting on a table, on the floor),
//     a plain light-grey ring + grip is drawn at its real tracked pose so it can
//     be found; the moment it is picked up it fades out and only the game's own
//     hands remain. Per game: "Show controllers when not held" (KLGameSettings,
//     default on), env KL_GHOST_CTRL=0/1.
//
//   * THE ACHIEVEMENT TOAST. kl_steam.c calls the unlock handler registered
//     here for every achievement a StoreStats confirmed (the bridge's
//     `unlocked` list), and this shows "🏆 Logro desbloqueado" / name /
//     description with the icon on a small panel ~1.2 m ahead, a little below
//     eye level, following the head lazily, ~5 s each, queued. KL_TOAST_TEST=1
//     fires a fake one 5 s after the compositor starts.
//
//   * THE COMPOSITOR FADE. OpenVR's FadeToColor / FadeGrid (kl_openvr.c),
//     filed in kl_ovrp and read here every frame (kl_ovrp_fade_color): a
//     head-locked colour over the whole view, both eyes, drawn FIRST so the
//     ghosts and panels stay readable over it. KL_OPENVR_FADE=0 files nothing.
//
//   * THE CONTROLLER CARD. A PSVR2 Sense controller that is not connected
//     while a game runs — asleep at start, or dropped mid-game — leaves that
//     hand on ARKit hand tracking, which reads as "buttons broken / hand
//     jittery". So a head-locked card says "Mando izquierdo desconectado /
//     Pulsa el botón PS para despertarlo" (system language, es/en) until it
//     comes back, then "Mando izquierdo conectado" for ~2 s. See
//     KleptonHUD.updateControllerPresence for the policy and the knobs
//     (KL_CTRL_WARN, KL_CTRL_WARN_FORCE).
//
//   * THE PERFORMANCE OVERLAY and THE QUICK SETTINGS MENU
//     (KleptonQuickSettings.swift): textures rastered off the render thread
//     and picked up here each frame; the overlay lower left, 1 m ahead, the
//     menu straight ahead at 0.9 m. Both follow the head like the prompt.
//
//   * THE GATE PROMPT. Alyx's "Pulsa Trigger para empezar" after every load
//     (mailbox show_message -> kl_ovrp_set_prompt): a panel "Pulsa el gatillo
//     para empezar" held in front of the eyes until the level starts
//     (end_loading). KL_GATE_TOAST=1 turns it on (default off).
//
// Both are drawn by KleptonCompositor at the END of each composite encoder —
// after the eye, the guest's layers and the loading skybox — with the same
// per-view projection and amplification as the eye pass, so they are solid in
// stereo. Neither is depth-tested against the game: the game's picture is a
// quad at KL_REPROJECT_DEPTH (500 m) and anything here is within 2 m, so the
// ghost only needs depth for itself (ring in front of grip) and the toast
// ignores depth entirely. Both WRITE their real depth, because visionOS
// reprojects the submitted frame with its depth buffer and a near object
// stamped with the backdrop's depth would swim when the head moves.
//
// The panel's pixels are rasterised once per toast with CoreText/CoreGraphics
// (no SwiftUI inside the CompositorLayer); the macOS viewer has the same layout
// in kl_view_mtl.m (klvm_toast_raster) for host verification.
import Foundation
import Metal
import ARKit
import CoreText
import CoreGraphics
import ImageIO
import QuartzCore
import simd

// MARK: - Toast queue

struct KLToast {
    let api: String
    let name: String
    let desc: String
    let icon: String          // a file path; "" a gold placeholder; "-" no icon at all
    var header: String? = nil // nil: the achievement header
    var accent: SIMD3<Double>? = nil // edge + header colour; nil: the achievement gold
}

/// A persistent status card, drawn in the toast's place for as long as it is
/// set (and over the toast queue, which resumes when it clears). The Mac
/// stream's "Conectando a <Mac>…" / "Sin señal del Mac" (KleptonStreamClient.swift).
/// Set from any thread; read once a frame on the render thread.
struct KLHUDStatus: Equatable {
    let header: String
    let name: String
    let desc: String

    nonisolated(unsafe) private static var value: KLHUDStatus?
    private static let lock = NSLock()
    static func set(_ s: KLHUDStatus?) { lock.lock(); value = s; lock.unlock() }
    static func current() -> KLHUDStatus? { lock.lock(); defer { lock.unlock() }; return value }
}

/// The unlocks waiting to be shown. Filled from kl_steam.c's store worker
/// thread through the C handler, drained on the render thread.
final class KleptonToasts: @unchecked Sendable {
    static let shared = KleptonToasts()
    private let lock = NSLock()
    private var queue: [KLToast] = []

    func push(_ t: KLToast) {
        lock.lock()
        if queue.count < 16 { queue.append(t) }
        lock.unlock()
    }

    func pop() -> KLToast? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// kl_steam_unlock_fn. The strings live only for the call, so they are
    /// copied before it returns.
    static let handler: kl_steam_unlock_fn = { api, name, desc, icon in
        func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        let t = KLToast(api: s(api), name: s(name), desc: s(desc), icon: s(icon))
        NSLog("[toast] unlock received: \(t.api) \"\(t.name)\" icon=\(t.icon.isEmpty ? "none" : t.icon)")
        KleptonToasts.shared.push(t)
    }

    static func register() { kl_steam_set_unlock_handler(handler) }

    /// The header follows the GAME's language (KL_STEAM_LANG, the hub's
    /// per-game language), not the headset's: Spanish for "spanish"/"latam",
    /// English for everything else.
    static var spanish: Bool {
        guard let p = kl_steam_game_language() else { return false }
        let l = String(cString: p)
        return l.hasPrefix("spanish") || l.hasPrefix("latam")
    }
    static var header: String { spanish ? "🏆 Logro desbloqueado" : "🏆 Achievement unlocked" }
}

/// The panel's pixels: 1024x288 premultiplied RGBA8 (sRGB), row 0 at the top.
/// Number for number the layout of klvm_toast_raster in kl_view_mtl.m.
enum KLToastRaster {
    static let width = 1024, height = 288

    private static func line(_ text: String, _ font: CTFont, _ color: CGColor,
                             _ maxW: Double) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let ell = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        return CTLineCreateTruncatedLine(l, maxW, .end, ell) ?? l
    }

    static func texture(_ t: KLToast, device: MTLDevice) -> MTLTexture? {
        let W = width, H = height
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: W * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        c.clear(CGRect(x: 0, y: 0, width: W, height: H))
        // Card: dark, slightly translucent, hairline gold edge.
        let card = CGPath(roundedRect: CGRect(x: 4, y: 4, width: W - 8, height: H - 8),
                          cornerWidth: 56, cornerHeight: 56, transform: nil)
        c.addPath(card)
        c.setFillColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 0.92)
        c.fillPath()
        c.addPath(card)
        let ac = t.accent ?? SIMD3(1.0, 0.80, 0.35)
        c.setStrokeColor(red: ac.x, green: ac.y, blue: ac.z, alpha: 0.55)
        c.setLineWidth(4)
        c.strokePath()
        // Icon, 192 px, rounded, vertically centred; a gold square without one.
        let noIcon = t.icon == "-"
        let ir = CGRect(x: 48, y: Double(H - 192) / 2, width: 192, height: 192)
        var img: CGImage?
        if !t.icon.isEmpty, !noIcon,
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: t.icon) as CFURL, nil) {
            img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if !noIcon {
            c.saveGState()
            c.addPath(CGPath(roundedRect: ir, cornerWidth: 28, cornerHeight: 28, transform: nil))
            c.clip()
            if let img { c.draw(img, in: ir) } else {
                c.setFillColor(red: 0.85, green: 0.66, blue: 0.22, alpha: 1)
                c.fill(ir)
            }
            c.restoreGState()
        }
        // Text column. Baselines from the top: header 78, name 146, desc 198/240.
        let x = noIcon ? 72.0 : 48.0 + 192 + 40, maxW = Double(W) - x - 48
        let fh = CTFontCreateUIFontForLanguage(.emphasizedSystem, 34, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
        let fn = CTFontCreateUIFontForLanguage(.emphasizedSystem, 50, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 50, nil)
        let fd = CTFontCreateUIFontForLanguage(.system, 32, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let gold = CGColor(srgbRed: ac.x, green: ac.y, blue: ac.z, alpha: 1)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let grey = CGColor(srgbRed: 0.78, green: 0.80, blue: 0.84, alpha: 1)
        c.textPosition = CGPoint(x: x, y: Double(H - 78))
        CTLineDraw(line(t.header ?? KleptonToasts.header, fh, gold, maxW), c)
        c.textPosition = CGPoint(x: x, y: Double(H - 146))
        CTLineDraw(line(t.name, fn, white, maxW), c)
        if !t.desc.isEmpty {
            // Two lines at most: break the first with a typesetter, truncate the second.
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): fd,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): grey]
            let ns = t.desc as NSString
            let ts = CTTypesetterCreateWithAttributedString(
                NSAttributedString(string: t.desc, attributes: attrs))
            let n1 = CTTypesetterSuggestLineBreak(ts, 0, maxW)
            c.textPosition = CGPoint(x: x, y: Double(H - 198))
            CTLineDraw(CTTypesetterCreateLine(ts, CFRange(location: 0, length: n1)), c)
            if n1 < ns.length {
                let rest = ns.substring(from: n1)
                c.textPosition = CGPoint(x: x, y: Double(H - 240))
                CTLineDraw(line(rest, fd, grey, maxW), c)
            }
        }
        guard let data = c.data else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                          width: W, height: H, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: W * 4)
        return tex
    }
}

// MARK: - Ghost controllers: is it in a hand?

/// One Sense controller as the ghost logic sees it, sampled per frame by
/// KleptonControllers.ghostSample.
struct KLGhostSample {
    var originFromGrip: simd_float4x4      // ARKit origin, `.grip`, rendered correction
    var positionTracked: Bool              // false: untracked or orientation-only
    var heldByPlatform: Bool               // AccessoryAnchor.heldChirality != nil
    var speed: Float                       // m/s
    var angularSpeed: Float                // rad/s
}

/// The in-hand decision for one controller, with hysteresis.
///
/// HELD (ghost hidden) the moment any of these is true:
///   1. the platform says so (`AccessoryAnchor.heldChirality`, visionOS 26);
///      KL_GHOST_PLATFORM_HELD=0 ignores it if it proves unreliable;
///   2. input from that controller in the last 2 s (any button, capacitive
///      touch, trigger, grip or stick off-centre) — KL_GHOST_INPUT_S;
///   3. the controller MOVED in the last 0.6 s (velocity > 8 cm/s or
///      > 0.9 rad/s, or > 2.5 cm from where it last rested) while a tracked
///      palm is within 9 cm of its grip point (12 cm to leave, so it does not
///      flicker at the edge) — or while hand tracking has no hand at all,
///      which is the normal state when the hands are full of controllers:
///      visionOS stops reporting hands that hold them.
/// A palm near a controller that is NOT moving does not hide it: that is the
/// hand reaching for it, and that is exactly when it has to stay visible.
///
/// RESTING (ghost shown) again only after none of the above for 1 s when a
/// tracked hand is visibly away from it, else for KL_GHOST_SHOW_S (2.5 s) —
/// the fallback "show after N s still" when hand tracking cannot vouch.
/// Not tracked (no anchor, untracked, orientation only): hidden.
struct KLGhostHand {
    var visible = false
    var alpha: Float = 0
    var lastHeldEvidence: TimeInterval = -100
    var lastMotion: TimeInterval = -100
    var restPos: SIMD3<Float>?
    var palmNear = false
    var pose = matrix_identity_float4x4
    var lastReason = ""
    var platformHeld = false

    static let inputWindow = Double(klEnvFloat("KL_GHOST_INPUT_S", 2.0))
    static let showAfter = Double(klEnvFloat("KL_GHOST_SHOW_S", 2.5))
    static let usePlatformHeld = klEnvOn("KL_GHOST_PLATFORM_HELD", default: true)
    static let nearIn: Float = 0.09, nearOut: Float = 0.12

    mutating func update(hand: Int, sample: KLGhostSample?, palms: [SIMD3<Float>],
                         handTrackingSeesHands: Bool, lastInput: TimeInterval,
                         now: TimeInterval, dt: Float) {
        var show = false
        var reason: String
        if let s = sample, s.positionTracked {
            pose = s.originFromGrip
            let p = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            if s.speed > 0.08 || s.angularSpeed > 0.9 { lastMotion = now }
            if let r = restPos {
                if simd_distance(p, r) > 0.025 { lastMotion = now; restPos = p }
            } else { restPos = p }
            let d = palms.map { simd_distance($0, p) }.min() ?? .infinity
            palmNear = d < (palmNear ? Self.nearOut : Self.nearIn)
            let moved = now - lastMotion < 0.6
            let platform = Self.usePlatformHeld && s.heldByPlatform
            let input = now - lastInput < Self.inputWindow
            let grabbed = moved && (palmNear || !handTrackingSeesHands)
            if platform || input || grabbed {
                lastHeldEvidence = now
                reason = platform ? "held (platform)" : input ? "held (input)"
                       : palmNear ? "held (hand near + moving)" : "held (moving, no hands tracked)"
            } else {
                let handAway = handTrackingSeesHands && !palmNear
                let wait = handAway ? 1.0 : Self.showAfter
                show = now - lastHeldEvidence > wait
                reason = show ? (handAway ? "resting (hand away)" : "resting (still \(Self.showAfter) s)")
                              : "settling"
            }
        } else {
            restPos = nil
            palmNear = false
            reason = sample == nil ? "no anchor" : "not position-tracked"
        }
        // Said on every change of visibility, and on every change of the
        // platform's own held flag — the one input this logic cannot check
        // off-device, so the log has to say whether it agrees with reality.
        let side = hand == 0 ? "left" : "right"
        if show != visible {
            NSLog("[ghost] \(side): \(show ? "SHOWN" : "hidden") — \(reason)")
        } else if reason != lastReason && (reason.hasPrefix("no") || reason.hasPrefix("not")) {
            NSLog("[ghost] \(side): \(reason)")
        }
        let ph = sample?.heldByPlatform ?? false
        if ph != platformHeld {
            platformHeld = ph
            NSLog("[ghost] \(side): platform heldChirality \(ph ? "SET" : "cleared")")
        }
        visible = show
        lastReason = reason
        // ~200 ms fades.
        let step = dt / 0.2
        alpha = visible ? min(1, alpha + step) : max(0, alpha - step)
    }
}

// MARK: - The renderer

/// The per-view matrix the HUD shaders index by [[amplification_id]].
struct KLHUDView { var viewProj: simd_float4x4 }

private struct KLHObj {
    var model: simd_float4x4
    var color: SIMD4<Float>
    var params: SIMD4<Float>       // x inflate (m), y alpha, z lit
}

final class KleptonHUD {
    private let device: MTLDevice
    private var solidPipe: MTLRenderPipelineState?
    private var texPipe: MTLRenderPipelineState?
    private var fadePipe: MTLRenderPipelineState?
    private var fadeDepth: MTLDepthStencilState?
    /// The compositor fade this frame (straight alpha), from kl_ovrp_fade_color.
    private var fade = SIMD4<Float>(0, 0, 0, 0)

    /// The gate prompt: kl_ovrp_prompt's serial seen last, and its panel.
    private var promptSerial: UInt32 = 0
    private var promptText = ""
    private var promptTex: MTLTexture?
    private var promptAlpha: Float = 0
    private var promptPos: SIMD3<Float>?
    private var promptModel = matrix_identity_float4x4
    private var ghostDepth: MTLDepthStencilState?
    private var toastDepth: MTLDepthStencilState?
    /// Set by the compositor for each encode: the eye pass under this HUD wrote
    /// the GAME's depth (KL_REPROJECT_DEPTH_MODE=2), not a 500 m plane, so the
    /// ghost's `.greater` would let any nearer piece of the virtual world hide
    /// a real controller. The body is then drawn always-pass (writing its own
    /// depth) and only the rim keeps the test, against the body it outlines.
    var depthOverScene = false
    private var sampler: MTLSamplerState?
    private var mesh: [(vb: MTLBuffer, ib: MTLBuffer, count: Int)] = []
    private var quad: MTLBuffer?

    /// Read live (getenv, cheap) rather than latched: the hub sets KL_GHOST_CTRL
    /// from the game's settings at Play, which can come after this layer exists.
    var ghostsEnabled: Bool {
        guard let v = getenv("KL_GHOST_CTRL") else { return true }
        return !["", "0", "no", "off", "false"].contains(String(cString: v).lowercased())
    }
    private var ghosts = [KLGhostHand(), KLGhostHand()]
    private var lastTick: TimeInterval = 0
    private let ghostFix: simd_float4x4

    private var toast: KLToast?
    private var toastTex: MTLTexture?
    private var toastT0: TimeInterval = 0
    private var toastPos: SIMD3<Float>?
    private var toastModel = matrix_identity_float4x4
    private var toastAlpha: Float = 0
    private var lastPrepare: TimeInterval = 0
    private let toastSecs = Double(klEnvFloat("KL_TOAST_SECS", 5))
    private let started = CACurrentMediaTime()
    private var testFired = !klEnvOn("KL_TOAST_TEST", default: false)
    private var statusShown: KLHUDStatus?

    // The controller card (updateControllerPresence / prepareControllerCard).
    /// A Sense controller was connected at some point in this process — the
    /// "this person plays with controllers" evidence the default policy needs.
    nonisolated(unsafe) static var senseEverSeen = false
    private var ctrlT0: TimeInterval = 0
    private var ctrlMissingSince: [TimeInterval?] = [nil, nil]
    private var ctrlWarned = [false, false]
    private var ctrlConfirmUntil: [TimeInterval] = [0, 0]
    private var ctrlKey = ""
    private var ctrlTex: MTLTexture?
    private var ctrlAlpha: Float = 0
    private var ctrlPos: SIMD3<Float>?
    private var ctrlModel = matrix_identity_float4x4
    // The overlay and the quick settings menu (KLQuickSettings).
    private var perfTex: MTLTexture?, menuTex: MTLTexture?
    private var perfAlpha: Float = 0, menuAlpha: Float = 0
    private var perfPos: SIMD3<Float>?, menuPos: SIMD3<Float>?
    private var perfModel = matrix_identity_float4x4, menuModel = matrix_identity_float4x4
    private static let ctrlGrace = 5.0        // s after the compositor starts
    private static let ctrlDebounce = 1.0     // s a mid-game drop must last
    private static let ctrlConfirmSecs = 2.0
    /// KL_CTRL_WARN_FORCE=left|right|both[:secs] — pretend that controller is
    /// missing (and that one was seen), for checking the card without a
    /// headset's controllers. With `:secs` it "comes back" that long after the
    /// grace period, so the confirmation shows too.
    private static let ctrlForce: (hands: [Bool], secs: Double)? = {
        guard let v = ProcessInfo.processInfo.environment["KL_CTRL_WARN_FORCE"]?.lowercased(),
              !v.isEmpty, v != "0" else { return nil }
        let parts = v.split(separator: ":")
        let w = String(parts[0])
        let hands = [w == "left" || w == "both", w == "right" || w == "both"]
        guard hands.contains(true) else { return nil }
        let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        return (hands, secs)
    }()
    /// KL_CTRL_WARN: 0 off; 1 (default) only once a Sense controller has been
    /// seen in this process; 2 always (a game that cannot be played with hands).
    /// Read live, like KL_GHOST_CTRL, so the hub can set it per game at Play.
    private var ctrlWarnMode: Int {
        guard let p = getenv("KL_CTRL_WARN") else { return 1 }
        let v = String(cString: p).lowercased()
        if ["", "0", "no", "off", "false"].contains(v) { return 0 }
        return v == "2" || v == "always" ? 2 : 1
    }
    /// The card follows the HEADSET's language, not the game's: it is about
    /// the hardware, not the game.
    private static let ctrlSpanish = Locale.preferredLanguages.first?.hasPrefix("es") ?? false

    static let msl = """
    #include <metal_stdlib>
    using namespace metal;
    struct KLHVert { packed_float3 p; packed_float3 n; float2 uv; };
    struct KLHView { float4x4 vp; };
    struct KLHObj  { float4x4 model; float4 color; float4 params; };
    struct KLHOut  { float4 pos [[position]]; float3 n; float2 uv; };
    vertex KLHOut kl_hud_v(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                           const device KLHVert *vb [[buffer(0)]],
                           constant KLHView *views [[buffer(1)]],
                           constant KLHObj &o [[buffer(2)]]) {
        KLHVert v = vb[vid];
        float3 p = float3(v.p) + float3(v.n) * o.params.x;
        KLHOut out;
        out.pos = views[amp].vp * (o.model * float4(p, 1));
        out.n = (o.model * float4(float3(v.n), 0)).xyz;
        out.uv = v.uv;
        return out;
    }
    fragment float4 kl_hud_solid_f(KLHOut in [[stage_in]], constant KLHObj &o [[buffer(0)]]) {
        float3 L = normalize(float3(0.3, 1.0, 0.45));
        float3 n = normalize(in.n);
        float lit = o.params.z > 0.5 ? (0.58 + 0.42 * max(dot(n, L), 0.0)) : 1.0;
        float a = o.color.a * o.params.y;
        return float4(o.color.rgb * lit * a, a);
    }
    fragment float4 kl_hud_tex_f(KLHOut in [[stage_in]], constant KLHObj &o [[buffer(0)]],
                                 texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return t.sample(s, in.uv) * o.params.y;
    }
    // The fade: one clip-space triangle covering the whole view, the same in
    // every amplified view (head-locked by construction), at the far plane.
    struct KLFOut { float4 pos [[position]]; };
    vertex KLFOut kl_hud_fade_v(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
        KLFOut o; o.pos = float4(p, 0, 1); return o;
    }
    fragment float4 kl_hud_fade_f(KLFOut in [[stage_in]], constant float4 &c [[buffer(0)]]) {
        return float4(c.rgb * c.a, c.a);
    }
    """

    init(device: MTLDevice, colorFormat: MTLPixelFormat, amplification: Int) {
        self.device = device
        // KL_GHOST_ROT=x,y,z degrees (about the grip) and KL_GHOST_POS=x,y,z
        // metres: the model's fit to the real plastic, for a device session.
        var fix = matrix_identity_float4x4
        let env = ProcessInfo.processInfo.environment
        func triple(_ k: String) -> SIMD3<Float>? {
            guard let s = env[k] else { return nil }
            let f = s.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            return f.count == 3 ? SIMD3(f[0], f[1], f[2]) : nil
        }
        if let r = triple("KL_GHOST_ROT") {
            let d = r * .pi / 180
            let q = simd_quatf(angle: d.z, axis: [0, 0, 1]) * simd_quatf(angle: d.y, axis: [0, 1, 0])
                  * simd_quatf(angle: d.x, axis: [1, 0, 0])
            fix = simd_float4x4(q)
        }
        if let p = triple("KL_GHOST_POS") { fix.columns.3 = SIMD4(p.x, p.y, p.z, 1) }
        ghostFix = fix

        do {
            let lib = try device.makeLibrary(source: Self.msl, options: nil)
            func pipe(_ frag: String, vertex: String = "kl_hud_v") throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: vertex)
                d.fragmentFunction = lib.makeFunction(name: frag)
                d.colorAttachments[0].pixelFormat = colorFormat
                d.depthAttachmentPixelFormat = .depth32Float
                d.maxVertexAmplificationCount = amplification
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true          // premultiplied
                c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            solidPipe = try pipe("kl_hud_solid_f")
            texPipe = try pipe("kl_hud_tex_f")
            fadePipe = try pipe("kl_hud_fade_f", vertex: "kl_hud_fade_v")
        } catch {
            NSLog("[hud] pipelines failed: \(error) — no ghost controllers, toasts only logged")
        }
        // Reverse-Z: .greater is "nearer". Only the ghost's own surfaces
        // compete — the game's picture is 500 m away.
        let g = MTLDepthStencilDescriptor()
        g.depthCompareFunction = .greater
        g.isDepthWriteEnabled = true
        ghostDepth = device.makeDepthStencilState(descriptor: g)
        let t = MTLDepthStencilDescriptor()
        t.depthCompareFunction = .always
        t.isDepthWriteEnabled = true
        toastDepth = device.makeDepthStencilState(descriptor: t)
        // The fade leaves the scene's depth alone: it is a colour over the
        // view, and visionOS should keep reprojecting what is under it.
        let fd = MTLDepthStencilDescriptor()
        fd.depthCompareFunction = .always
        fd.isDepthWriteEnabled = false
        fadeDepth = device.makeDepthStencilState(descriptor: fd)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        for hand in 0...1 { if let m = Self.controllerMesh(device, right: hand == 1) { mesh.append(m) } }
        // Unit quad, -0.5...0.5, facing +Z, uv (0,0) at the top left. Strip order.
        let q: [Float] = [-0.5,  0.5, 0,  0, 0, 1,  0, 0,
                           0.5,  0.5, 0,  0, 0, 1,  1, 0,
                          -0.5, -0.5, 0,  0, 0, 1,  0, 1,
                           0.5, -0.5, 0,  0, 0, 1,  1, 1]
        quad = device.makeBuffer(bytes: q, length: q.count * 4, options: .storageModeShared)

        KleptonToasts.register()
        if let f = Self.ctrlForce {
            NSLog("[hud] KL_CTRL_WARN_FORCE: left \(f.hands[0]) right \(f.hands[1])"
                  + (f.secs > 0 ? ", back after \(f.secs) s" : ""))
        }
        NSLog("[hud] ghost controllers \(ghostsEnabled ? "ON" : "off") (KL_GHOST_CTRL, now), toasts on"
              + (testFired ? "" : ", KL_TOAST_TEST in 5 s"))
    }

    // MARK: Per frame

    /// Once per frame, from updatePoses: the in-hand state machines.
    func updateGhosts(samples: [KLGhostSample?], lastInput: [TimeInterval],
                      left: HandAnchor?, right: HandAnchor?, handTrackingRunning: Bool) {
        let now = CACurrentMediaTime()
        let dt = lastTick > 0 ? Float(min(now - lastTick, 0.1)) : 0
        lastTick = now
        guard ghostsEnabled else { return }
        var palms: [SIMD3<Float>] = []
        for a in [left, right] { if let a, let p = Self.palm(a) { palms.append(p) } }
        for h in 0...1 {
            ghosts[h].update(hand: h, sample: samples[h], palms: palms,
                             handTrackingSeesHands: handTrackingRunning && !palms.isEmpty,
                             lastInput: lastInput[h], now: now, dt: dt)
        }
    }

    /// Once per frame, from updatePoses: which hands have a Sense controller
    /// connected (KleptonControllers.presentHands). Decides the card.
    ///
    /// Policy (KL_CTRL_WARN=1, the default): warn only once a Sense controller
    /// has been seen connected in this process. Someone who plays with hands
    /// never sees it; someone who plays with controllers is told when one is
    /// asleep at start (after a 5 s grace for the pair to wake and connect) or
    /// drops mid-game (after 1 s, so a reconnect blip does not flash it). If
    /// both sleep from the very start nothing has been seen and nothing shows —
    /// KL_CTRL_WARN=2 warns regardless, for a game that needs controllers.
    func updateControllerPresence(_ raw: [Bool]) {
        let now = CACurrentMediaTime()
        if ctrlT0 == 0 { ctrlT0 = now }
        var present = raw
        if let f = Self.ctrlForce {
            Self.senseEverSeen = true
            let active = f.secs <= 0 || now - ctrlT0 < Self.ctrlGrace + f.secs
            for h in 0...1 where f.hands[h] && active { present[h] = false }
        }
        if present.contains(true) && !Self.senseEverSeen {
            Self.senseEverSeen = true
            NSLog("[hud] controller warning: armed (a Sense controller was seen)")
        }
        let mode = ctrlWarnMode
        let armed = mode != 0 && (mode == 2 || Self.senseEverSeen) && now - ctrlT0 >= Self.ctrlGrace
        for h in 0...1 {
            if present[h] { ctrlMissingSince[h] = nil }
            else if ctrlMissingSince[h] == nil { ctrlMissingSince[h] = now }
            let missingFor = ctrlMissingSince[h].map { now - $0 } ?? 0
            let warn = armed && !present[h] && missingFor >= Self.ctrlDebounce
            guard warn != ctrlWarned[h] else { continue }
            ctrlWarned[h] = warn
            let side = h == 0 ? "left" : "right"
            if warn {
                ctrlConfirmUntil[h] = 0
                NSLog("[hud] controller warning: \(side) missing")
            } else if present[h] {
                ctrlConfirmUntil[h] = now + Self.ctrlConfirmSecs
                NSLog("[hud] controller warning: \(side) back")
            } else {
                NSLog("[hud] controller warning: \(side) cleared (KL_CTRL_WARN off)")
            }
        }
    }

    /// The card's text for this frame: warnings first, then confirmations.
    private func controllerCard(now: TimeInterval) -> KLToast? {
        let es = Self.ctrlSpanish
        let header = "PlayStation VR2 Sense"
        let amber = SIMD3<Double>(1.0, 0.62, 0.22), green = SIMD3<Double>(0.45, 0.88, 0.55)
        let side = { (h: Int) in es ? (h == 0 ? "izquierdo" : "derecho") : (h == 0 ? "Left" : "Right") }
        if ctrlWarned[0] && ctrlWarned[1] {
            return KLToast(api: "ctrl", name: es ? "Mandos desconectados" : "Both controllers disconnected",
                           desc: es ? "Pulsa el botón PS de cada mando para despertarlos"
                                    : "Press the PS button on each to wake them up",
                           icon: "-", header: header, accent: amber)
        }
        if let h = ctrlWarned.firstIndex(of: true) {
            return KLToast(api: "ctrl", name: es ? "Mando \(side(h)) desconectado" : "\(side(h)) controller disconnected",
                           desc: es ? "Pulsa el botón PS para despertarlo" : "Press the PS button to wake it up",
                           icon: "-", header: header, accent: amber)
        }
        let back = (0...1).filter { now < ctrlConfirmUntil[$0] }
        if back.count == 2 {
            return KLToast(api: "ctrl", name: es ? "Mandos conectados" : "Both controllers connected",
                           desc: "", icon: "-", header: header, accent: green)
        }
        if let h = back.first {
            return KLToast(api: "ctrl", name: es ? "Mando \(side(h)) conectado" : "\(side(h)) controller connected",
                           desc: "", icon: "-", header: header, accent: green)
        }
        return nil
    }

    /// Re-raster when the text changes, fade 0.25 s, and hold the card 1 m
    /// ahead, 25 cm below the eyes — under the gate prompt (5 cm below) and
    /// the achievement toast (1.2 m / 15 cm below), so the three never overlap
    /// — following the head closely like the prompt.
    private func prepareControllerCard(originFromHead: simd_float4x4, dt: Float) {
        let card = controllerCard(now: CACurrentMediaTime())
        let key = card.map { $0.name + "|" + $0.desc } ?? ""
        if !key.isEmpty && key != ctrlKey {
            ctrlTex = KLToastRaster.texture(card!, device: device)
            if ctrlTex == nil { NSLog("[hud] controller card raster FAILED") }
        }
        if !key.isEmpty { ctrlKey = key }
        let step = dt / 0.25
        ctrlAlpha = card == nil ? max(0, ctrlAlpha - step) : min(1, ctrlAlpha + step)
        if ctrlAlpha <= 0 { ctrlPos = nil; ctrlTex = nil; ctrlKey = ""; return }
        ctrlModel = Self.panelModel(originFromHead: originFromHead, dist: 1.0, drop: 0.25,
                                    tau: 0.12, dt: dt, pos: &ctrlPos)
    }

    /// The middle of the palm: halfway between the middle finger's metacarpal
    /// base and its knuckle, where a fist closes around a grip.
    private static func palm(_ a: HandAnchor) -> SIMD3<Float>? {
        let o = a.originFromAnchorTransform
        guard let sk = a.handSkeleton else {
            return SIMD3(o.columns.3.x, o.columns.3.y, o.columns.3.z)
        }
        let b = (o * sk.joint(.middleFingerMetacarpal).anchorFromJointTransform).columns.3
        let k = (o * sk.joint(.middleFingerKnuckle).anchorFromJointTransform).columns.3
        return SIMD3((b.x + k.x) / 2, (b.y + k.y) / 2, (b.z + k.z) / 2)
    }

    /// Once per frame, before the drawables are encoded: the toast queue and
    /// its lazy follow. `originFromHead` is the composite's own head pose
    /// (recentred), so the panel lives in the same space it is drawn in.
    func prepare(originFromHead: simd_float4x4) {
        let now = CACurrentMediaTime()
        let dt = lastPrepare > 0 ? Float(min(now - lastPrepare, 0.1)) : 0
        lastPrepare = now
        preparePrompt(originFromHead: originFromHead, dt: dt)
        prepareControllerCard(originFromHead: originFromHead, dt: dt)
        prepareQuickSettings(originFromHead: originFromHead, dt: dt)
        var c: [Float] = [0, 0, 0, 0]
        let on = c.withUnsafeMutableBufferPointer { kl_ovrp_fade_color($0.baseAddress) } != 0
        let newFade = on ? SIMD4<Float>(c[0], c[1], c[2], c[3]) : SIMD4<Float>(0, 0, 0, 0)
        if (newFade.w > 0) != (fade.w > 0) {
            NSLog("[hud] compositor fade \(newFade.w > 0 ? "drawing" : "clear")"
                  + String(format: " (%.2f %.2f %.2f a %.2f)", newFade.x, newFade.y, newFade.z, newFade.w))
        }
        fade = newFade
        if !testFired && now - started >= 5 {
            testFired = true
            let es = KleptonToasts.spanish
            KleptonToasts.shared.push(KLToast(
                api: "KL_TOAST_TEST",
                name: es ? "Prueba de logro" : "Test achievement",
                desc: es ? "KL_TOAST_TEST: un aviso falso para comprobar el panel."
                         : "KL_TOAST_TEST: a fake toast to check the panel.",
                icon: ""))
            NSLog("[toast] KL_TOAST_TEST: fake toast queued")
        }
        // The status card first: while one is set it IS the toast, without
        // the expiry, and the queue waits behind it.
        let status = KLHUDStatus.current()
        if status != statusShown {
            statusShown = status
            if let status {
                let t = KLToast(api: "status", name: status.name, desc: status.desc,
                                icon: "", header: status.header)
                toast = t
                toastT0 = now
                toastTex = KLToastRaster.texture(t, device: device)
                NSLog("[toast] status card: \(status.header) — \(status.name)")
            } else {
                toast = nil; toastTex = nil
            }
        }
        if statusShown == nil {
            if toast != nil && now - toastT0 > toastSecs {
                toast = nil; toastTex = nil
            }
            if toast == nil, let next = KleptonToasts.shared.pop() {
                toast = next
                toastT0 = now
                toastTex = KLToastRaster.texture(next, device: device)
                NSLog("[toast] showing \"\(next.name)\" (\(KleptonToasts.header))"
                      + (toastTex == nil ? " — raster FAILED" : ""))
            }
        }
        guard toast != nil else { toastAlpha = 0; toastPos = nil; return }
        let e = now - toastT0
        toastAlpha = statusShown != nil
            ? Float(max(0, min(1, e / 0.3)))
            : Float(max(0, min(1, min(e / 0.3, (toastSecs - e) / 0.3))))

        // Lazy follow: the target is 1.2 m ahead along the head's YAW, 15 cm
        // below the eyes; the panel eases toward it (time constant 0.35 s), so
        // it stays in view without being nailed to the face.
        toastModel = Self.panelModel(originFromHead: originFromHead, dist: 1.2, drop: 0.15,
                                     tau: 0.35, dt: dt, pos: &toastPos)
    }

    /// The gate prompt: rebuilt when kl_ovrp_prompt's serial moves, faded
    /// 0.25 s in and out, held ~1 m ahead at eye level and following the head
    /// closely (0.12 s) — it is the thing to read right now, not a notice.
    private func preparePrompt(originFromHead: simd_float4x4, dt: Float) {
        var buf = [CChar](repeating: 0, count: 256)
        let serial = buf.withUnsafeMutableBufferPointer { kl_ovrp_prompt($0.baseAddress, 256) }
        if serial != promptSerial {
            promptSerial = serial
            promptText = String(cString: buf)
            if !promptText.isEmpty {
                let es = KleptonToasts.spanish
                let t = KLToast(api: "gate",
                                name: es ? "Pulsa el gatillo para empezar" : "Pull the trigger to start",
                                desc: promptText == "-" ? "" : promptText, icon: "-",
                                header: es ? "Nivel cargado" : "Level loaded")
                promptTex = KLToastRaster.texture(t, device: device)
                NSLog("[hud] gate prompt shown (\(promptText))" + (promptTex == nil ? " — raster FAILED" : ""))
            } else if promptTex != nil {
                NSLog("[hud] gate prompt cleared")
            }
        }
        let step = dt / 0.25
        promptAlpha = promptText.isEmpty ? max(0, promptAlpha - step) : min(1, promptAlpha + step)
        if promptAlpha <= 0 { promptPos = nil; if promptText.isEmpty { promptTex = nil }; return }
        promptModel = Self.panelModel(originFromHead: originFromHead, dist: 1.0, drop: 0.05,
                                      tau: 0.12, dt: dt, pos: &promptPos)
    }

    /// The overlay (lower left: 1 m ahead, 32 cm left, 18 cm below the eyes,
    /// 20 cm wide) and the menu (0.9 m ahead, at eye level, 46 cm wide). A
    /// texture that goes away fades out with the last one it showed.
    private func prepareQuickSettings(originFromHead: simd_float4x4, dt: Float) {
        let (p, m) = KLQuickSettings.shared.panels()
        let step = dt / 0.2
        if let p { perfTex = p }
        perfAlpha = p == nil ? max(0, perfAlpha - step) : min(1, perfAlpha + step)
        if perfAlpha <= 0 { perfTex = nil; perfPos = nil } else {
            let o = KLPanelRaster.overlaySize
            perfModel = Self.panelModel(originFromHead: originFromHead, dist: 1.0, drop: 0.18,
                                        tau: 0.15, dt: dt, pos: &perfPos, side: -0.32,
                                        width: 0.20, aspect: Float(o.h) / Float(o.w))
        }
        if let m { menuTex = m }
        menuAlpha = m == nil ? max(0, menuAlpha - step) : min(1, menuAlpha + step)
        if menuAlpha <= 0 { menuTex = nil; menuPos = nil } else {
            let o = KLPanelRaster.menuSize
            menuModel = Self.panelModel(originFromHead: originFromHead, dist: 0.9, drop: 0.02,
                                        tau: 0.25, dt: dt, pos: &menuPos, side: 0,
                                        width: 0.46, aspect: Float(o.h) / Float(o.w))
        }
    }

    /// A panel ahead of the head along its yaw, `drop` metres below the eyes,
    /// easing toward that spot with time constant `tau`, upright and facing
    /// the eyes. The toast's placement, shared with the prompt.
    private static func panelModel(originFromHead: simd_float4x4, dist: Float, drop: Float,
                                   tau: Float, dt: Float, pos: inout SIMD3<Float>?,
                                   side: Float = 0, width: Float = 0.40,
                                   aspect: Float? = nil) -> simd_float4x4 {
        let h = SIMD3<Float>(originFromHead.columns.3.x, originFromHead.columns.3.y,
                             originFromHead.columns.3.z)
        var f = -SIMD3<Float>(originFromHead.columns.2.x, 0, originFromHead.columns.2.z)
        f = simd_length(f) > 1e-3 ? simd_normalize(f) : SIMD3(0, 0, -1)
        let right = SIMD3<Float>(-f.z, 0, f.x)
        let target = h + f * dist + right * side + SIMD3(0, -drop, 0)
        if let p = pos, dt > 0 {
            pos = p + (target - p) * (1 - exp(-dt / tau))
        } else {
            pos = target
        }
        let p = pos!
        var z = h - p
        z = simd_length(z) > 1e-3 ? simd_normalize(z) : SIMD3(0, 0, 1)
        var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
        x = simd_length(x) > 1e-3 ? simd_normalize(x) : SIMD3(1, 0, 0)
        let y = simd_cross(z, x)
        let w = width, ht = w * (aspect ?? Float(KLToastRaster.height) / Float(KLToastRaster.width))
        return simd_float4x4(SIMD4(x * w, 0), SIMD4(y * ht, 0), SIMD4(z, 0), SIMD4(p, 1))
    }

    var hasContent: Bool {
        (toastTex != nil && toastAlpha > 0) || ghosts.contains { $0.alpha > 0 }
            || fade.w > 0 || (promptTex != nil && promptAlpha > 0)
            || (ctrlTex != nil && ctrlAlpha > 0)
            || (perfTex != nil && perfAlpha > 0) || (menuTex != nil && menuAlpha > 0)
    }

    // MARK: Encode

    /// Draw into the encoder the composite already has open: viewports and
    /// amplification mappings are the caller's (they are the eye pass's).
    func encode(_ enc: MTLRenderCommandEncoder, views: [KLHUDView], recenter: simd_float4x4) {
        guard hasContent, let solidPipe, let texPipe, !views.isEmpty else { return }
        enc.setFrontFacing(.counterClockwise)

        // The fade first: over the game, under Klepton's own things.
        if fade.w > 0, let fadePipe {
            enc.setRenderPipelineState(fadePipe)
            if let fadeDepth { enc.setDepthStencilState(fadeDepth) }
            enc.setCullMode(.none)
            var c = fade
            enc.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        views.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }

        if ghostsEnabled, mesh.count == 2 {
            enc.setRenderPipelineState(solidPipe)
            if let ghostDepth { enc.setDepthStencilState(ghostDepth) }
            for h in 0...1 where ghosts[h].alpha > 0 {
                if depthOverScene, let toastDepth { enc.setDepthStencilState(toastDepth) }
                let m = mesh[h]
                let model = recenter * ghosts[h].pose * ghostFix
                // Body (light grey, lit), then the soft outline: the same mesh
                // pushed out 2.5 mm along its normals with its FRONT faces
                // culled, so only the rim around the silhouette survives.
                var body = KLHObj(model: model, color: SIMD4(0.80, 0.81, 0.84, 1),
                                  params: SIMD4(0, ghosts[h].alpha, 1, 0))
                var rim = KLHObj(model: model, color: SIMD4(0.10, 0.11, 0.13, 0.85),
                                 params: SIMD4(0.0025, ghosts[h].alpha, 0, 0))
                enc.setVertexBuffer(m.vb, offset: 0, index: 0)
                enc.setCullMode(.back)
                enc.setVertexBytes(&body, length: MemoryLayout<KLHObj>.stride, index: 2)
                enc.setFragmentBytes(&body, length: MemoryLayout<KLHObj>.stride, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint16,
                                          indexBuffer: m.ib, indexBufferOffset: 0)
                enc.setCullMode(.front)
                if depthOverScene, let ghostDepth { enc.setDepthStencilState(ghostDepth) }
                enc.setVertexBytes(&rim, length: MemoryLayout<KLHObj>.stride, index: 2)
                enc.setFragmentBytes(&rim, length: MemoryLayout<KLHObj>.stride, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint16,
                                          indexBuffer: m.ib, indexBufferOffset: 0)
            }
            enc.setCullMode(.none)
        }

        if let tex = toastTex, toastAlpha > 0, let quad, let sampler {
            enc.setRenderPipelineState(texPipe)
            if let toastDepth { enc.setDepthStencilState(toastDepth) }
            enc.setCullMode(.none)
            var o = KLHObj(model: toastModel, color: SIMD4(1, 1, 1, 1),
                           params: SIMD4(0, toastAlpha, 0, 0))
            enc.setVertexBuffer(quad, offset: 0, index: 0)
            enc.setVertexBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 2)
            enc.setFragmentBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let tex = promptTex, promptAlpha > 0, let quad, let sampler {
            enc.setRenderPipelineState(texPipe)
            if let toastDepth { enc.setDepthStencilState(toastDepth) }
            enc.setCullMode(.none)
            var o = KLHObj(model: promptModel, color: SIMD4(1, 1, 1, 1),
                           params: SIMD4(0, promptAlpha, 0, 0))
            enc.setVertexBuffer(quad, offset: 0, index: 0)
            enc.setVertexBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 2)
            enc.setFragmentBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let tex = ctrlTex, ctrlAlpha > 0, let quad, let sampler {
            enc.setRenderPipelineState(texPipe)
            if let toastDepth { enc.setDepthStencilState(toastDepth) }
            enc.setCullMode(.none)
            var o = KLHObj(model: ctrlModel, color: SIMD4(1, 1, 1, 1),
                           params: SIMD4(0, ctrlAlpha, 0, 0))
            enc.setVertexBuffer(quad, offset: 0, index: 0)
            enc.setVertexBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 2)
            enc.setFragmentBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // The overlay, then the menu over everything.
        func panel(_ tex: MTLTexture?, _ alpha: Float, _ model: simd_float4x4) {
            guard let tex, alpha > 0, let quad, let sampler else { return }
            enc.setRenderPipelineState(texPipe)
            if let toastDepth { enc.setDepthStencilState(toastDepth) }
            enc.setCullMode(.none)
            var o = KLHObj(model: model, color: SIMD4(1, 1, 1, 1), params: SIMD4(0, alpha, 0, 0))
            enc.setVertexBuffer(quad, offset: 0, index: 0)
            enc.setVertexBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 2)
            enc.setFragmentBytes(&o, length: MemoryLayout<KLHObj>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        panel(perfTex, perfAlpha, perfModel)
        panel(menuTex, menuAlpha, menuModel)
    }

    // MARK: The controller model

    /// A PSVR2 Sense, roughly: a capsule grip along the grip frame's Z axis
    /// (OpenXR / visionOS `.grip`: Z runs through the fist) and a flattened
    /// band that loops round the BACK of the hand from the grip's top to its
    /// bottom — the Sense's tracking ring. Built for the right hand (back of
    /// the hand toward +X) and mirrored for the left. ~1.4k triangles.
    private static func controllerMesh(_ device: MTLDevice, right: Bool)
        -> (vb: MTLBuffer, ib: MTLBuffer, count: Int)? {
        var v: [Float] = []
        var idx: [UInt16] = []
        let sx: Float = right ? 1 : -1

        /// A (nu+1)x(nv+1) grid surface. `f(u, v)` returns position and outward
        /// normal; each triangle's winding is checked against the normal so the
        /// mirror (and any parametrisation slip) cannot turn a mesh inside out.
        func surface(_ nu: Int, _ nv: Int,
                     _ f: (Float, Float) -> (SIMD3<Float>, SIMD3<Float>)) {
            let base = v.count / 8
            var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = []
            for i in 0...nu {
                for j in 0...nv {
                    var (p, n) = f(Float(i) / Float(nu), Float(j) / Float(nv))
                    p.x *= sx; n.x *= sx
                    n = simd_normalize(n)
                    pos.append(p); nrm.append(n)
                    v += [p.x, p.y, p.z, n.x, n.y, n.z, Float(i) / Float(nu), Float(j) / Float(nv)]
                }
            }
            func at(_ i: Int, _ j: Int) -> Int { i * (nv + 1) + j }
            func tri(_ a: Int, _ b: Int, _ c: Int) {
                let fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
                let n = nrm[a] + nrm[b] + nrm[c]
                if simd_length(fn) < 1e-12 { return }           // degenerate (a pole)
                if simd_dot(fn, n) >= 0 { idx += [UInt16(base + a), UInt16(base + b), UInt16(base + c)] }
                else { idx += [UInt16(base + a), UInt16(base + c), UInt16(base + b)] }
            }
            for i in 0..<nu {
                for j in 0..<nv {
                    tri(at(i, j), at(i + 1, j), at(i + 1, j + 1))
                    tri(at(i, j), at(i + 1, j + 1), at(i, j + 1))
                }
            }
        }

        // Grip: capsule, radius 1.9 cm, from z = +5.5 cm (bottom) to -4.5 cm (top).
        let r: Float = 0.019, zBot: Float = 0.055 - r, zTop: Float = -0.045 + r
        surface(24, 24) { u, w in
            let th = u * .pi, ph = w * 2 * .pi
            let n = SIMD3<Float>(sin(th) * cos(ph), sin(th) * sin(ph), cos(th))
            let zc = n.z >= 0 ? zBot : zTop
            return (SIMD3(n.x * r, n.y * r, zc + n.z * r), n)
        }
        // Ring: a flattened band (6 mm in its plane, 14 mm tall) on a circle of
        // radius 5.5 cm in the XZ plane, centred 3 cm toward the back of the
        // hand — the part of the circle beyond the grip, i.e. about ±123°.
        let c = SIMD3<Float>(0.030, 0, 0.005), R: Float = 0.055
        let a0 = acos(-c.x / R)
        let r1: Float = 0.006, r2: Float = 0.014
        surface(48, 16) { u, w in
            let al = -a0 + u * 2 * a0, be = w * 2 * .pi
            let e1 = SIMD3<Float>(cos(al), 0, sin(al)), e2 = SIMD3<Float>(0, 1, 0)
            let p = c + R * e1 + r1 * cos(be) * e1 + r2 * sin(be) * e2
            let n = (cos(be) / r1) * e1 + (sin(be) / r2) * e2
            return (p, n)
        }
        // Top face: a small disc where the stick and buttons sit, so the top
        // end reads as the top.
        surface(1, 24) { u, w in
            let ph = w * 2 * .pi, rr = u * r * 0.85
            return (SIMD3(rr * cos(ph), rr * sin(ph), zTop - r - 0.002), SIMD3(0, 0, -1))
        }

        guard v.count / 8 < 65535,
              let vb = device.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared)
        else { return nil }
        return (vb, ib, idx.count)
    }
}
