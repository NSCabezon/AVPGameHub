// In-game quick settings and the performance overlay.
//
// Two head-locked panels drawn by KleptonHUD in the immersive view, the same
// textured-quad mechanism as the toasts and the controller card:
//
//   * THE PERFORMANCE OVERLAY. A small panel, lower left: guest fps and frame
//     ms (avg / worst of the last half second), the guest's GPU ms per frame
//     (kl_gpu_time, whose Metal timing is switched on live while the overlay
//     is up), how many compositor frames reused an old picture, the process
//     footprint, thermal state and display Hz. Per-game setting "Performance
//     overlay" (default off) or KL_HUD=1; Siri turns it on/off mid-game.
//     COST: a 2 Hz timer on a utility queue reads KLSessionStats' counters
//     (one lock round trip), task_info and kl_gpu_time's totals, rasters ~6
//     lines with CoreText into a fresh 512x256 texture and hands it over; the
//     render thread only draws one more quad. Nothing per frame on the render
//     thread but a lock-free pointer read.
//
//   * THE QUICK SETTINGS MENU. Opened by Siri ("Abre ajustes del juego en Hub"),
//     closed by Siri, ○ or its last row. Five rows: the overlay, Alyx's
//     antialiasing 2×/4× (live: `vr_fidelity_level 0|1` through kl_openvr_console — Source 2
//     changes MSAA when the fidelity level changes, as its own Auto-Fidelity
//     does mid-game), foveated rendering (live through the foveating MoltenVK's
//     klMVKFoveationSetEnabled when the game BOOTED foveating, else "next
//     launch") and render scale 80/90/100 % (next launch: the eye targets are
//     sized at boot), then "Cerrar"/"Close", which closes it like ○ (trigger,
//     ✕ or right pinch on it). Every change is saved to the game's settings
//     (KLGameSettingsStore) so the next launch keeps it.
//     INPUT. While the menu is open the PSVR2 Sense input never reaches the
//     game (KleptonControllers pushes a released controller instead; poses go
//     through): stick up/down moves, trigger or ✕/□ (A) changes, ○/△ (B)
//     closes. Hands only (pinch): LEFT pinch moves down (wrapping), RIGHT pinch
//     changes. After it closes, each hand stays swallowed until everything on
//     it is released, so the closing press never reaches the game.
//     KL_QS_PAUSE=1 also sends Alyx `setpause` / `unpause` on open / close
//     (off by default: not verified that it pauses cleanly mid-level).
//
// Thread model: state behind one NSLock. Siri (any thread), the render thread
// (input, panel pick-up) and the raster queue all go through it; nothing
// slow runs under it.
import Foundation
import Metal
import CoreText
import CoreGraphics
import simd

final class KLQuickSettings: @unchecked Sendable {
    static let shared = KLQuickSettings()

    enum Item: Int, CaseIterable { case overlay, antialiasing, foveation, renderScale, close }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "klepton.quick-settings", qos: .utility)
    private var device: MTLDevice?

    // --- state (under lock) ---
    private var hudOn: Bool
    private var menuOpen = false
    private var cursor = 0
    private var running = false
    private var status = ""
    private var swallow = [false, false]
    private var perfTex: MTLTexture?
    private var menuTex: MTLTexture?
    private var menuVersion = 0
    private var rasteredMenu = -1
    // Live values this run (what the game is rendering with now).
    private var msaaNow = 2
    private var foveateNow = false
    private var renderScaleBoot: Float = 1
    // Input edge state, render thread only.
    private var raw: [KleptonHandState] = [KleptonHandState(), KleptonHandState()]
    private var prevButtons: [UInt32] = [0, 0]
    private var prevTrigger: [Bool] = [false, false]
    private var stickArmed = [true, true]
    // Overlay sampler, queue only.
    private var timer: DispatchSourceTimer?
    private var lastLive: KLSessionStats.Live?
    private var lastNs: UInt64 = 0
    private var lastGpu: (Double, UInt64) = (0, 0)

    private static let pauseOnOpen = klEnvOn("KL_QS_PAUSE", default: false)

    private init() { hudOn = klEnvOn("KL_HUD", default: false) }

    private var target: String { klTargetName() }
    private var isAlyx: Bool { KLGameSettingsStore.hasPerformance(target) }
    private static var es: Bool { klL("en", "es") == "es" }

    // MARK: - Lifecycle (compositor)

    /// The render loop started: the overlay may sample, the menu may open.
    func gameStarted(device: MTLDevice) {
        // What the game booted with: the hub put the game's settings into the
        // environment at Play (KLGameSettingsStore.applyBeforeBoot).
        let env = ProcessInfo.processInfo.environment
        lock.lock()
        self.device = device
        running = true
        hudOn = hudOn || klEnvOn("KL_HUD", default: false)
        msaaNow = Int(env["KL_ALYX_MSAA"] ?? "") == 4 ? 4 : 2
        foveateNow = klEnvOn("KL_FOVEATE", default: false)
        renderScaleBoot = Float(env["KL_OPENVR_RT_SCALE"] ?? "") ?? KLGameSettingsStore.defaultRenderScale
        let on = hudOn
        lock.unlock()
        NSLog("[qs] game running (\(target)); performance overlay \(on ? "ON" : "off") (KL_HUD / setting)")
        if on { startSampler() }
    }

    func gameEnded() {
        lock.lock(); running = false; menuOpen = false; lock.unlock()
        stopSampler()
    }

    var gameRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var overlayOn: Bool { lock.lock(); defer { lock.unlock() }; return hudOn }
    var isMenuOpen: Bool { lock.lock(); defer { lock.unlock() }; return menuOpen }

    // MARK: - Actions (Siri, the menu). Each returns what to say.

    enum Outcome { case applied, nextLaunch, notRunning, notSupported }

    struct Reply { let outcome: Outcome; let text: String }

    func notRunning() -> Reply {
        Reply(outcome: .notRunning, text: klL("No game is running in AVP Game Hub right now.",
                                              "Ahora mismo no hay ningún juego en marcha en AVP Game Hub."))
    }

    /// The performance overlay on/off (nil: toggle). Saved to the game's settings.
    @discardableResult
    func setOverlay(_ want: Bool?) -> Reply {
        lock.lock()
        guard running else { lock.unlock(); return notRunning() }
        let on = want ?? !hudOn
        let changed = on != hudOn
        hudOn = on
        menuVersion += 1
        lock.unlock()
        let t = target
        queue.async { KLGameSettingsStore.update(t) { $0.perfOverlay = on } }
        NSLog("[qs] performance overlay \(on ? "ON" : "off")\(changed ? "" : " (already)")")
        if on { startSampler() } else { stopSampler() }
        requestMenuRaster()
        return Reply(outcome: .applied, text: on ? klL("Performance overlay on.", "Visor de rendimiento activado.")
                                                 : klL("Performance overlay off.", "Visor de rendimiento desactivado."))
    }

    /// Alyx's antialiasing, 2× or 4×, live through the console.
    @discardableResult
    func setAntialiasing(_ msaa: Int) -> Reply {
        guard gameRunning else { return notRunning() }
        guard isAlyx else {
            return Reply(outcome: .notSupported, text: klL("Antialiasing can only be changed in Half-Life: Alyx.",
                                                          "El antialiasing solo se puede cambiar en Half-Life: Alyx."))
        }
        let m = msaa >= 4 ? 4 : 2
        let t = target
        queue.async { KLGameSettingsStore.update(t) { s in
            var p = s.performance ?? KLPerformance(); p.msaa = m; s.performance = p } }
        let ok = kl_openvr_console("vr_fidelity_level \(m == 4 ? 1 : 0)") == 0
        NSLog("[qs] antialiasing \(m)x: \(ok ? "applied live (vr_fidelity_level \(m == 4 ? 1 : 0))" : "saved for the next launch (console not reachable)")")
        lock.lock(); if ok { msaaNow = m }; menuVersion += 1; lock.unlock()
        requestMenuRaster()
        if ok {
            return Reply(outcome: .applied, text: klL("Antialiasing set to \(m)×.", "Antialiasing a \(m)×."))
        }
        return Reply(outcome: .nextLaunch, text: klL("Antialiasing \(m)× saved; it applies the next time the game starts.",
                                                     "Antialiasing \(m)× guardado; se aplicará la próxima vez que arranque el juego."))
    }

    /// Foveated rendering on/off: live when the game booted foveating.
    @discardableResult
    func setFoveation(_ on: Bool) -> Reply {
        guard gameRunning else { return notRunning() }
        guard isAlyx else {
            return Reply(outcome: .notSupported, text: klL("Foveated rendering is only available in Half-Life: Alyx.",
                                                          "El renderizado foveado solo está disponible en Half-Life: Alyx."))
        }
        let t = target
        queue.async { KLGameSettingsStore.update(t) { s in
            var p = s.performance ?? KLPerformance(); p.foveate = on; s.performance = p } }
        let live = kl_vulkan_foveate_live(on ? 1 : 0) == 1
        NSLog("[qs] foveation \(on ? "ON" : "off"): \(live ? "applied live" : "saved for the next launch")")
        lock.lock(); if live { foveateNow = on }; menuVersion += 1; lock.unlock()
        requestMenuRaster()
        if live {
            return Reply(outcome: .applied, text: on ? klL("Foveated rendering on.", "Renderizado foveado activado.")
                                                     : klL("Foveated rendering off.", "Renderizado foveado desactivado."))
        }
        return Reply(outcome: .nextLaunch,
                     text: on ? klL("Foveated rendering saved as on; it starts the next time the game starts.",
                                    "Renderizado foveado guardado como activado; empezará la próxima vez que arranque el juego.")
                              : klL("Foveated rendering saved as off; it applies the next time the game starts.",
                                    "Renderizado foveado guardado como desactivado; se aplicará la próxima vez que arranque el juego."))
    }

    /// Render scale (Alyx): saved for the next launch.
    @discardableResult
    func setRenderScale(_ v: Float) -> Reply {
        guard gameRunning else { return notRunning() }
        guard isAlyx else { return Reply(outcome: .notSupported, text: "") }
        let t = target
        queue.async { KLGameSettingsStore.update(t) { s in
            var p = s.performance ?? KLPerformance(); p.renderScale = v; s.performance = p } }
        NSLog("[qs] render scale \(Int((v * 100).rounded())) %: saved for the next launch")
        lock.lock(); menuVersion += 1; lock.unlock()
        requestMenuRaster()
        return Reply(outcome: .nextLaunch, text: klL("Render scale \(Int((v * 100).rounded())) % applies the next time the game starts.",
                                                     "Escala de render \(Int((v * 100).rounded())) %: se aplicará la próxima vez que arranque el juego."))
    }

    @discardableResult
    func openMenu() -> Reply {
        lock.lock()
        guard running else { lock.unlock(); return notRunning() }
        let was = menuOpen
        menuOpen = true
        if !was { cursor = 0; status = "" }
        menuVersion += 1
        lock.unlock()
        NSLog("[qs] menu opened\(was ? " (already open)" : "")")
        if !was && Self.pauseOnOpen && isAlyx { _ = kl_openvr_console("setpause") }
        requestMenuRaster()
        return Reply(outcome: .applied, text: klL("Settings open. Move with the stick, change with the trigger, close with circle.",
                                                  "Ajustes abiertos. Muévete con el stick, cambia con el gatillo y cierra con círculo."))
    }

    @discardableResult
    func closeMenu() -> Reply {
        lock.lock()
        let was = menuOpen
        menuOpen = false
        swallow = [true, true]
        menuVersion += 1
        lock.unlock()
        if was {
            NSLog("[qs] menu closed")
            if Self.pauseOnOpen && isAlyx { _ = kl_openvr_console("unpause") }
        }
        return Reply(outcome: .applied, text: was ? klL("Settings closed.", "Ajustes cerrados.")
                                                  : klL("The settings were not open.", "Los ajustes no estaban abiertos."))
    }

    // MARK: - Input (render thread, from KleptonControllers.update)

    /// Whether this hand's input is for the menu, not the game. Records it.
    func capture(hand: Int, _ st: KleptonHandState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if menuOpen { raw[hand] = st; return true }
        if swallow[hand] {
            let idle = st.buttons == 0 && st.indexTrigger < 0.1 && st.handTrigger < 0.1 && simd_length(st.stick) < 0.3
            if idle { swallow[hand] = false } else { return true }
        }
        return false
    }

    /// Once per frame after both hands were captured: edges into actions.
    func processInput() {
        lock.lock()
        guard menuOpen else {
            prevButtons = [0, 0]; prevTrigger = [false, false]; stickArmed = [true, true]
            lock.unlock(); return
        }
        let hands = raw
        lock.unlock()
        var move = 0, select = false, close = false
        for h in 0...1 {
            let st = hands[h]
            let b = st.buttons
            let pressed = b & ~prevButtons[h]
            prevButtons[h] = b
            let trig = st.indexTrigger > (prevTrigger[h] ? 0.4 : 0.6)
            let trigEdge = trig && !prevTrigger[h]
            prevTrigger[h] = trig
            if st.fromController {
                let y = st.stick.y
                if stickArmed[h] {
                    if y > 0.6 { move = -1; stickArmed[h] = false }
                    else if y < -0.6 { move = 1; stickArmed[h] = false }
                } else if abs(y) < 0.3 { stickArmed[h] = true }
                let selBit = h == 0 ? OVRPRawButton.x : OVRPRawButton.a
                let closeBit = h == 0 ? OVRPRawButton.y : OVRPRawButton.b
                if trigEdge || pressed & selBit != 0 { select = true }
                if pressed & closeBit != 0 { close = true }
            } else if trigEdge {
                // Hands only: left pinch moves, right pinch changes.
                if h == 0 { move = 1 } else { select = true }
            }
        }
        if close { closeMenu(); return }
        if move != 0 {
            lock.lock()
            let n = Item.allCases.count
            cursor = ((cursor + move) % n + n) % n
            menuVersion += 1
            lock.unlock()
            requestMenuRaster()
        }
        if select {
            lock.lock(); let item = Item(rawValue: cursor) ?? .overlay; lock.unlock()
            // The "Close" row closes right here, as ○ does (the swallow starts this frame).
            if item == .close { closeMenu(); return }
            // Off the render thread: the console queue, UserDefaults, the log.
            queue.async { self.activate(item) }
        }
    }

    private func activate(_ item: Item) {
        let r: Reply
        switch item {
        case .overlay: r = setOverlay(nil)
        case .antialiasing:
            lock.lock(); let m = msaaNow; lock.unlock()
            let saved = KLGameSettingsStore.load(target).performance?.msaa ?? m
            r = setAntialiasing((saved == 4) ? 2 : 4)
        case .foveation:
            let saved = KLGameSettingsStore.load(target).performance?.foveate
            lock.lock(); let now = foveateNow; lock.unlock()
            r = setFoveation(!(saved ?? now))
        case .renderScale:
            let cur = KLGameSettingsStore.load(target).performance?.renderScale ?? renderScaleBoot
            let steps: [Float] = [0.8, 0.9, 1.0]
            let i = steps.firstIndex(where: { abs($0 - cur) < 0.025 }) ?? 2
            r = setRenderScale(steps[(i + 1) % steps.count])
        case .close:
            _ = closeMenu(); return
        }
        lock.lock(); status = r.text; menuVersion += 1; lock.unlock()
        requestMenuRaster()
    }

    // MARK: - Panels (render thread pick-up)

    /// The textures to draw this frame (nil: hide that panel).
    func panels() -> (perf: MTLTexture?, menu: MTLTexture?) {
        lock.lock(); defer { lock.unlock() }
        return (hudOn && running ? perfTex : nil, menuOpen ? menuTex : nil)
    }

    // MARK: - Menu raster (queue)

    private func requestMenuRaster() {
        queue.async { self.rasterMenu() }
    }

    private func rasterMenu() {
        lock.lock()
        let v = menuVersion
        guard v != rasteredMenu, let device else { lock.unlock(); return }
        rasteredMenu = v
        let open = menuOpen, cur = cursor, st = status, on = hudOn
        let msaa = msaaNow, fov = foveateNow
        lock.unlock()
        guard open else { return }
        let es = Self.es
        let saved = KLGameSettingsStore.load(target)
        let alyx = isAlyx
        let next = es ? "siguiente arranque" : "next launch"
        let savedMsaa = saved.performance?.msaa ?? msaa
        let savedFov = saved.performance?.foveate ?? fov
        let scale = saved.performance?.renderScale ?? renderScaleBoot
        let yes = es ? "Sí" : "On", no = es ? "No" : "Off"
        let na = es ? "no disponible" : "n/a"
        var rows: [(String, String, String)] = []   // label, value, note
        rows.append((es ? "Visor de rendimiento" : "Performance overlay", on ? yes : no, ""))
        rows.append(("Antialiasing", alyx ? "\(savedMsaa)×" : "—",
                     !alyx ? na : savedMsaa != msaa ? next : ""))
        rows.append((es ? "Renderizado foveado" : "Foveated rendering", alyx ? (savedFov ? yes : no) : "—",
                     !alyx ? na : savedFov != fov ? next : ""))
        rows.append((es ? "Escala de render" : "Render scale", alyx ? "\(Int((scale * 100).rounded())) %" : "—",
                     !alyx ? na : abs(scale - renderScaleBoot) > 0.01 ? next : ""))
        rows.append((es ? "Cerrar" : "Close", "", ""))
        let tex = KLPanelRaster.menu(title: es ? "Ajustes rápidos" : "Quick settings",
                                     subtitle: KLPanelRaster.gameName(target),
                                     rows: rows, cursor: cur, status: st,
                                     hint: es ? "Stick: mover · Gatillo / ✕: cambiar · ○: cerrar"
                                              : "Stick: move · Trigger / ✕: change · ○: close",
                                     device: device)
        // A newer version may have arrived while rastering: show this one
        // anyway (it is closer than the last) and go again.
        lock.lock(); menuTex = tex; let again = menuVersion != rasteredMenu; lock.unlock()
        if again { rasterMenu() }
    }

    // MARK: - Overlay sampler (queue)

    private func startSampler() {
        kl_gpu_time_set_live(1)
        queue.async {
            guard self.timer == nil else { return }
            self.lastLive = nil
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.sample() }
            self.timer = t
            t.resume()
        }
    }

    private func stopSampler() {
        kl_gpu_time_set_live(0)
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.lock.lock(); self.perfTex = nil; self.lock.unlock()
        }
    }

    private func sample() {
        lock.lock(); let dev = device; let on = hudOn && running; lock.unlock()
        guard on, let dev else { return }
        let now = KLSessionStats.nowNsPublic
        let l = KLSessionStats.shared.live()
        var gs = 0.0, gn: UInt64 = 0
        kl_gpu_time_totals(&gs, &gn)
        defer { lastLive = l; lastNs = now; lastGpu = (gs, gn) }
        guard let p = lastLive, now > lastNs else { return }
        let dt = Double(now - lastNs) / 1e9
        let frames = l.guestFrames &- p.guestFrames
        let playNs = l.playNs &- p.playNs
        let comp = l.compFrames &- p.compFrames
        // Reused pictures: the counted ones plus those since the last new frame.
        let reused = (l.reprojected &+ l.pendingReused) &- (p.reprojected &+ p.pendingReused)
        let ci = l.compIntervals &- p.compIntervals, cin = l.compIntervalNs &- p.compIntervalNs
        let gpuN = gn &- lastGpu.1
        let gpuMs = gpuN > 0 ? (gs - lastGpu.0) / Double(gpuN) : nil
        let loading = l.lastNewNs == 0 || now &- l.lastNewNs > 1_000_000_000
        let fps = Double(frames) / dt
        let frameMs = frames > 0 ? Double(playNs) / Double(frames) / 1e6 : nil
        let maxMs = KLSessionStats.shared.takeMaxIntervalMs()
        let hz = ci > 0 ? Double(ci) * 1e9 / Double(cin) : nil
        let reproj = comp > 0 ? 100 * Double(min(reused, comp)) / Double(comp) : nil
        let mem = KLSessionStats.footprint()?.now ?? 0
        let es = Self.es
        let thermal: (String, SIMD3<Double>) = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return (es ? "normal" : "nominal", SIMD3(0.55, 0.9, 0.6))
            case .fair: return (es ? "templado" : "fair", SIMD3(0.95, 0.85, 0.4))
            case .serious: return (es ? "alto" : "serious", SIMD3(1.0, 0.6, 0.25))
            case .critical: return (es ? "crítico" : "critical", SIMD3(1.0, 0.35, 0.3))
            @unknown default: return ("?", SIMD3(0.8, 0.8, 0.8))
            }
        }()
        func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
        let fpsColor: SIMD3<Double> = loading ? SIMD3(0.7, 0.72, 0.76)
            : fps >= 44 ? SIMD3(0.55, 0.9, 0.6) : fps >= 30 ? SIMD3(0.95, 0.85, 0.4) : SIMD3(1.0, 0.45, 0.35)
        let lines: [KLPanelRaster.Line] = [
            .init(text: loading ? (es ? "cargando…" : "loading…") : String(format: "%.0f fps", fps),
                  size: 52, bold: true, color: fpsColor),
            .init(text: (es ? "imagen " : "frame ") + "\(f1(frameMs)) ms · " + (es ? "máx " : "max ") + f1(maxMs),
                  size: 30, bold: false, color: SIMD3(0.92, 0.93, 0.95)),
            .init(text: "GPU \(f1(gpuMs)) ms", size: 30, bold: false, color: SIMD3(0.92, 0.93, 0.95)),
            .init(text: (es ? "reproyectado " : "reprojected ") + (reproj.map { String(format: "%.0f %%", $0) } ?? "—")
                  + " · \(hz.map { String(format: "%.0f Hz", $0) } ?? "—")",
                  size: 30, bold: false, color: SIMD3(0.92, 0.93, 0.95)),
            .init(text: (es ? "memoria " : "memory ") + String(format: "%.2f GB", Double(mem) / 1_073_741_824),
                  size: 30, bold: false, color: SIMD3(0.92, 0.93, 0.95)),
            .init(text: (es ? "temperatura " : "thermal ") + thermal.0, size: 30, bold: false, color: thermal.1),
        ]
        let tex = KLPanelRaster.overlay(lines, device: dev)
        lock.lock(); if hudOn { perfTex = tex }; lock.unlock()
    }
}

// MARK: - Raster

/// CoreText panels for the overlay and the menu: premultiplied RGBA8 sRGB,
/// row 0 at the top, the same format KLToastRaster makes.
enum KLPanelRaster {
    struct Line { let text: String; let size: Double; let bold: Bool; let color: SIMD3<Double> }

    static let overlaySize = (w: 512, h: 288)
    static let menuSize = (w: 1024, h: 720)   // five 84-pt rows above status + hint

    static func gameName(_ target: String) -> String {
        #if KL_HUB
        if let r = klHubGameRows.first(where: { $0.target == target }) { return r.display }
        #endif
        return target
    }

    private static func font(_ size: Double, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    private static func draw(_ c: CGContext, _ text: String, x: Double, y: Double, size: Double,
                             bold: Bool, color: SIMD3<Double>, alpha: Double = 1, rightAlignedAt: Double? = nil,
                             maxWidth: Double = 960) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: alpha)]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let ell = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        let line = CTLineCreateTruncatedLine(full, maxWidth, .end, ell) ?? full
        var px = x
        if let r = rightAlignedAt { px = r - CTLineGetTypographicBounds(line, nil, nil, nil) }
        c.textPosition = CGPoint(x: px, y: y)
        CTLineDraw(line, c)
    }

    private static func context(_ W: Int, _ H: Int) -> CGContext? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    private static func card(_ c: CGContext, _ W: Int, _ H: Int, radius: Double, accent: SIMD3<Double>) {
        let card = CGPath(roundedRect: CGRect(x: 4, y: 4, width: W - 8, height: H - 8),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        c.addPath(card)
        c.setFillColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 0.88)
        c.fillPath()
        c.addPath(card)
        c.setStrokeColor(red: accent.x, green: accent.y, blue: accent.z, alpha: 0.5)
        c.setLineWidth(3)
        c.strokePath()
    }

    private static func texture(_ c: CGContext, _ W: Int, _ H: Int, device: MTLDevice) -> MTLTexture? {
        guard let data = c.data else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: W, height: H,
                                                          mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: data, bytesPerRow: W * 4)
        return tex
    }

    static func overlay(_ lines: [Line], device: MTLDevice) -> MTLTexture? {
        let (W, H) = overlaySize
        guard let c = context(W, H) else { return nil }
        card(c, W, H, radius: 28, accent: SIMD3(0.5, 0.75, 1.0))
        var y = Double(H) - 26
        for l in lines {
            y -= l.size * 1.12
            draw(c, l.text, x: 28, y: y, size: l.size, bold: l.bold, color: l.color)
            y -= 4
        }
        return texture(c, W, H, device: device)
    }

    static func menu(title: String, subtitle: String, rows: [(String, String, String)], cursor: Int,
                     status: String, hint: String, device: MTLDevice) -> MTLTexture? {
        let (W, H) = menuSize
        guard let c = context(W, H) else { return nil }
        card(c, W, H, radius: 40, accent: SIMD3(0.5, 0.75, 1.0))
        let white = SIMD3<Double>(1, 1, 1), grey = SIMD3<Double>(0.72, 0.74, 0.78)
        let blue = SIMD3<Double>(0.5, 0.75, 1.0), amber = SIMD3<Double>(1.0, 0.75, 0.35)
        draw(c, title, x: 48, y: Double(H) - 82, size: 48, bold: true, color: white)
        draw(c, subtitle, x: 48, y: Double(H) - 82, size: 30, bold: false, color: grey, rightAlignedAt: Double(W) - 48)
        let rowH = 84.0
        var top = Double(H) - 120
        for (i, r) in rows.enumerated() {
            let sel = i == cursor
            if sel {
                let rect = CGRect(x: 28, y: top - rowH + 6, width: Double(W) - 56, height: rowH - 8)
                c.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
                c.setFillColor(red: 0.5, green: 0.75, blue: 1.0, alpha: 0.22)
                c.fillPath()
            }
            let base = top - rowH / 2 - 12
            draw(c, (sel ? "▸ " : "   ") + r.0, x: 48, y: base, size: 36, bold: sel, color: sel ? white : grey)
            draw(c, r.1, x: 0, y: base, size: 36, bold: true, color: sel ? blue : white,
                 rightAlignedAt: Double(W) - 60)
            if !r.2.isEmpty {
                draw(c, r.2, x: 0, y: base - 4, size: 22, bold: false, color: amber, rightAlignedAt: Double(W) - 200)
            }
            top -= rowH
        }
        if !status.isEmpty {
            draw(c, status, x: 48, y: 92, size: 24, bold: false, color: amber, maxWidth: Double(W) - 96)
        }
        draw(c, hint, x: 48, y: 40, size: 26, bold: false, color: grey)
        return texture(c, W, H, device: device)
    }
}
