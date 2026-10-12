// "Jugar desde el Mac" — the headset half (runtime/net/kl_stream_proto.h).
//
// In stream mode the hub does NOT start a guest. The immersive space, the
// CompositorLayer, ARKit and the Sense controllers run exactly as in standalone
// mode, so head, hands and buttons keep flowing into kl_ovrp locally; this file
// reads them back once a display frame and sends them to the Mac, and puts
// what the Mac sends back in front of the compositor through the SAME seam a
// local Vulkan guest uses:
//
//   kl_glfb_note_eye_mtl_texture(eye, stage, tex, slice)   the picture
//   kl_ovrp_frame_begin_external/_end_external(stage, pose, tan)
//                                                          what it was rendered with
//
// so KleptonCompositor's composite and reprojection run unchanged: it samples
// kl_ovrp_last_complete_stage() and reprojects from kl_ovrp_stage_render_pose(),
// which here is the head pose the frame was RENDERED with (the ring entry for
// the POSE the host echoes), not the latest one. That is what keeps the world
// still over Wi-Fi latency.
//
// Pieces:
//   KLStreamBrowser       NWBrowser for KL_STREAM_BONJOUR (+ KL_STREAM_HOST_ADDR)
//   KLStreamSession       the C client (kl_stream_client.c), per-frame tick, HUD status
//   KLStreamFramePublisher decoded CVPixelBuffer -> per-stage eye textures
//   StreamPlayView        the window beside the immersive space (status, Disconnect)
import SwiftUI
import Foundation
import Network
import Metal
import CoreVideo
import QuartzCore
import simd

// MARK: - Where to connect

/// One Mac to stream from: a Bonjour service (resolved on connect) or a
/// literal address (KL_STREAM_HOST_ADDR=ip[:port]).
struct KLStreamTarget: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint?
    let host: String?
    let port: Int
    /// The game the Mac is hosting (the host's Bonjour TXT "guest", its
    /// m_boot target). nil = not known (manual address, an older host): offered
    /// for every streamable game, as before.
    var guest: String? = nil
    var id: String { name + (host ?? "") }

    /// Whether this Mac can be offered for `target`'s "Jugar desde el Mac".
    func serves(_ target: String) -> Bool { guest == nil || guest == target }

    /// KL_STREAM_HOST_ADDR=ip[:port] — the manual fallback (testing, a Mac whose
    /// Bonjour does not reach the headset). An IPv6 literal goes in brackets
    /// when it carries a port: [fe80::1%en0]:9944.
    static func fromEnvironment() -> KLStreamTarget? {
        guard let v = ProcessInfo.processInfo.environment["KL_STREAM_HOST_ADDR"], !v.isEmpty
        else { return nil }
        var host = v
        var port = Int(KL_STREAM_PORT_DEFAULT)
        if v.hasPrefix("["), let close = v.firstIndex(of: "]") {
            host = String(v[v.index(after: v.startIndex)..<close])
            let rest = v[v.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
        } else if v.filter({ $0 == ":" }).count == 1, let c = v.firstIndex(of: ":") {
            host = String(v[..<c])
            port = Int(v[v.index(after: c)...]) ?? port
        }
        let name = ProcessInfo.processInfo.environment["KL_STREAM_HOST_NAME"] ?? host
        return KLStreamTarget(name: name, endpoint: nil, host: host, port: port)
    }
}

/// The Macs advertising KL_STREAM_BONJOUR on the local network, live.
@MainActor
final class KLStreamBrowser: ObservableObject {
    @Published private(set) var macs: [KLStreamTarget] = []
    private var browser: NWBrowser?
    private let manual = KLStreamTarget.fromEnvironment()

    func start() {
        guard browser == nil else { return }
        macs = manual.map { [$0] } ?? []
        let type = String(KL_STREAM_BONJOUR)
        // With the TXT record: the host publishes which game it runs ("guest").
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
        b.stateUpdateHandler = { state in
            NSLog("[stream] Bonjour browser (\(type)): \(state)")
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [KLStreamTarget] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var guest: String?
                if case let .bonjour(txt) = r.metadata { guest = txt["guest"] }
                return KLStreamTarget(name: name, endpoint: r.endpoint, host: nil,
                                      port: Int(KL_STREAM_PORT_DEFAULT), guest: guest)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.macs = (self.manual.map { [$0] } ?? []) + found
                NSLog("[stream] Macs: \(self.macs.map { "\($0.name) [\($0.guest ?? "?")]" })")
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// A Bonjour service -> "host", port, through a UDP NWConnection that never
/// sends anything: it reaches .ready once the name is resolved, and the path
/// then says where it went. IPv4 first (no scope id to carry into the C
/// socket), then whatever the system picks.
enum KLStreamResolver {
    static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        if let r = await attempt(endpoint, v4: true) { return r }
        return await attempt(endpoint, v4: false)
    }

    private static func attempt(_ endpoint: NWEndpoint, v4: Bool) async -> (String, Int)? {
        let params = NWParameters.udp
        if v4, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        let result: (String, Int)? = await withCheckedContinuation { cont in
            let once = KLOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        let h: String
                        switch host {
                        // From the bytes: an IPv4Address's description carries the
                        // interface scope ("192.168.1.10%en0"), which the C client's
                        // getaddrinfo refuses (device, 2026-10-08).
                        case .ipv4(let a): h = a.rawValue.map { String($0) }.joined(separator: ".")
                        case .ipv6(let a): h = "\(a)"
                        case .name(let n, _): h = n
                        @unknown default: h = "\(host)"
                        }
                        once.run { cont.resume(returning: (h, Int(port.rawValue))) }
                    } else {
                        once.run { cont.resume(returning: nil) }
                    }
                case .failed, .cancelled:
                    once.run { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                once.run { cont.resume(returning: nil) }
            }
        }
        conn.cancel()
        NSLog("[stream] resolve \(endpoint) (\(v4 ? "IPv4" : "any")) -> "
              + (result.map { "\($0.0):\($0.1)" } ?? "nothing"))
        return result
    }
}

private final class KLOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

// MARK: - The session

final class KLStreamSession: @unchecked Sendable {
    static let shared = KLStreamSession()

    /// The immersive space about to open (or open) is a stream, not a guest.
    /// Read by KleptonCompositor at construction.
    private(set) var active = false
    private(set) var macName = ""
    private(set) var hostDesc = ""
    private var client: OpaquePointer?
    private let lock = NSLock()

    // Render thread only.
    private var publisher: KLStreamFramePublisher?
    private var tangents = [SIMD4<Float>](repeating: .zero, count: 2)
    private var haveTangents = [false, false]
    private var lastHUD: TimeInterval = 0
    private var simYaw: Float = 0
    private var simLast: TimeInterval = 0
    /// The last frame id handed to the compositor (its "guest frame serial").
    private(set) var lastFrameId: UInt32 = 0

    private init() {
        kl_stream_set_log { line in
            if let line { NSLog("%@", String(cString: line)) }
        }
    }

    /// Open the socket and arm the session. The HELLO goes out once the
    /// compositor has measured the display (displayReady).
    func start(name: String, host: String, port: Int) -> Bool {
        stop(reason: "restart")
        // The Mac's sound arrives as AUDIO and plays through kl_audio, which
        // needs the configured AVAudioSession a local guest gets from BootView
        // (idempotent; before the socket, so the first packet finds it ready).
        KleptonAudio.start()
        guard let c = kl_stream_client_create(host, Int32(port)) else { return false }
        lock.lock()
        client = c
        active = true
        macName = name
        hostDesc = "\(host):\(port)"
        lock.unlock()
        lastFrameId = 0
        NSLog("[stream] session started: \(name) at \(host):\(port)")
        KLHUDStatus.set(KLHUDStatus(header: klL("Play from Mac", "Jugar desde el Mac"),
                                    name: klL("Connecting to \(name)…", "Conectando a \(name)…"),
                                    desc: klL("Waiting for the Mac to answer (\(host)).", "Esperando respuesta del Mac (\(host)).")))
        return true
    }

    /// BYE + teardown. Idempotent; safe from any thread.
    func stop(reason: String) {
        lock.lock()
        let c = client
        client = nil
        active = false
        lock.unlock()
        guard let c else { return }
        NSLog("[stream] session stopping (\(reason))")
        kl_stream_client_destroy(c)
        KLHUDStatus.set(nil)
    }

    private var current: OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    func status() -> kl_stream_client_status? {
        guard let c = current else { return nil }
        var s = kl_stream_client_status()
        kl_stream_client_get_status(c, &s)
        return s
    }

    // --- called by KleptonCompositor ---------------------------------------

    /// The RAW per-eye tangents primeDisplay gives kl_ovrp_set_eye_frustum —
    /// what HELLO must describe (kl_ovrp may unify them for its own guest).
    func noteEyeFrustum(_ eye: Int, _ t: SIMD4<Float>) {
        guard eye >= 0, eye < 2 else { return }
        tangents[eye] = t
        haveTangents[eye] = true
    }

    /// After primeDisplay: the display description is complete in kl_ovrp
    /// (frustum, eye offsets/cant, Hz, eye size). Builds and sends HELLO.
    func displayReady() {
        guard let c = current else { return }
        var hello = kl_stream_hello()
        let device = "Apple Vision Pro"
        if haveTangents[0] && haveTangents[1] {
            // float tan[2][4] is imported as a pointer to a 4-tuple.
            let t: [(Float, Float, Float, Float)] = tangents.map { ($0.x, $0.y, $0.z, $0.w) }
            t.withUnsafeBufferPointer { kl_stream_hello_from_ovrp(&hello, $0.baseAddress, device) }
        } else {
            kl_stream_hello_from_ovrp(&hello, nil, device)
        }
        kl_stream_client_set_display(c, &hello)
    }

    /// Simulator only: there is no world tracking, so publish a fixed standing
    /// head (optionally yawing at KL_STREAM_SIM_YAW_DPS) so the stream path has
    /// a pose to send and the host something to render from.
    func simulatorHead(at t: TimeInterval) {
        let dps = klEnvFloat("KL_STREAM_SIM_YAW_DPS", 0)
        if simLast > 0 { simYaw += dps * Float(t - simLast) * .pi / 180 }
        simLast = t
        let q = simd_quatf(angle: simYaw, axis: SIMD3<Float>(0, 1, 0))
        kl_ovrp_set_head_pose_time(t)
        kl_ovrp_set_head_pose(0, 1.6, 0, q.imag.x, q.imag.y, q.imag.z, q.real)
    }

    /// Once per display frame, after updatePoses and before the composite —
    /// exactly where a local guest would be offered its frame. Sends POSE,
    /// takes the newest decoded picture and files it as the compositor's
    /// latest complete stage.
    func tick(presentation t: TimeInterval, device: MTLDevice, queue: MTLCommandQueue?,
              connectedMask: UInt32) {
        guard let c = current else { return }
        kl_stream_client_send_pose_from_ovrp(c, t, connectedMask)

        var info = kl_stream_frame_info()
        if let um = kl_stream_client_pull_frame(c, &info) {
            let pb = um.takeRetainedValue()
            if publisher == nil || publisher!.device !== device {
                publisher = KLStreamFramePublisher(device: device)
            }
            if publisher!.publish(pb, info: info, queue: queue) {
                lastFrameId = info.frame_id
                kl_stream_client_note_displayed(c, t, info.t_pose)
            }
        }

        if t - lastHUD >= 0.1 {
            lastHUD = t
            updateHUD(c)
        }
    }

    private func updateHUD(_ c: OpaquePointer) {
        var s = kl_stream_client_status()
        kl_stream_client_get_status(c, &s)
        let mac = macName
        let card: KLHUDStatus?
        switch Int32(s.state) {
        case Int32(KL_STREAM_CLIENT_CONNECTING):
            card = KLHUDStatus(header: klL("Play from Mac", "Jugar desde el Mac"), name: klL("Connecting to \(mac)…", "Conectando a \(mac)…"),
                               desc: klL("Waiting for the Mac to answer (\(hostDesc)).", "Esperando respuesta del Mac (\(hostDesc))."))
        case Int32(KL_STREAM_CLIENT_WAITING):
            card = KLHUDStatus(header: klL("Play from Mac", "Jugar desde el Mac"), name: klL("Connecting to \(mac)…", "Conectando a \(mac)…"),
                               desc: klL("Connected. Waiting for the first picture.", "Conectado. Esperando la primera imagen."))
        case Int32(KL_STREAM_CLIENT_NO_SIGNAL):
            card = KLHUDStatus(header: klL("Play from Mac", "Jugar desde el Mac"), name: klL("No signal from the Mac", "Sin señal del Mac"),
                               desc: klL("No video from \(mac). Retrying…", "No llega vídeo de \(mac). Reintentando…"))
        case Int32(KL_STREAM_CLIENT_REFUSED):
            card = KLHUDStatus(header: klL("Play from Mac", "Jugar desde el Mac"), name: klL("\(mac) refused the connection", "\(mac) rechazó la conexión"),
                               desc: KLStreamSession.refusal(s.ack_status))
        case Int32(KL_STREAM_CLIENT_ENDED):
            card = KLHUDStatus(header: klL("Play from Mac", "Jugar desde el Mac"), name: klL("\(mac) ended the session", "\(mac) cerró la sesión"),
                               desc: klL("Back to the library.", "Volviendo a la biblioteca."))
        default:
            card = nil
        }
        KLHUDStatus.set(card)
    }

    static func refusal(_ status: UInt32) -> String {
        switch Int32(status) {
        case Int32(KL_STREAM_ERR_VERSION.rawValue): return klL("Protocol version mismatch: update both the Mac and the headset.", "Versión de protocolo distinta: actualiza el Mac y el visor.")
        case Int32(KL_STREAM_ERR_BUSY.rawValue):    return klL("The Mac is already streaming to another headset.", "El Mac ya está transmitiendo a otro visor.")
        case Int32(KL_STREAM_ERR_GUEST.rawValue):   return klL("The game could not start on the Mac.", "El juego no pudo arrancar en el Mac.")
        default: return klL("Code \(status).", "Código \(status).")
        }
    }
}

// MARK: - Decoded picture -> the compositor's eye seam

/// Owns one 2-slice eye texture per swapchain stage (KL_OVRP_STAGES, 3 by
/// default) and copies each decoded side-by-side frame's halves into the next
/// stage: left half -> slice 0 (eye 0), right half -> slice 1 (eye 1).
///
/// The decoder's native biplanar 4:2:0 (420v, or x420 for a 10-bit stream) is
/// the default: one render pass per eye with kl_stream_yuv_msl() — the shader
/// the Mac harness times and checks — converts to RGB while splitting, into a
/// bgra8Unorm view of the stage (the stream's values are already sRGB-encoded).
/// KL_STREAM_DECODE_BGRA=1 decodes to BGRA and blits, as before.
///
/// The blit is committed on the COMPOSITOR's own queue before its composite
/// command buffer, so Metal orders the two and nothing has to wait on the CPU;
/// rotating stages keeps a composite still in flight from sampling a texture
/// being overwritten. The CVMetalTexture and the pixel buffer behind it are
/// held until that blit completes.
final class KLStreamFramePublisher {
    let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private var stages: [MTLTexture] = []
    private var eyeW = 0, eyeH = 0
    private var stageViews: [MTLTexture] = []   // bgra8Unorm views, the YUV pass's targets
    private var next = 0
    private var logged = false
    private var yuvPipe: MTLRenderPipelineState?
    private var yuvFailed = false

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    private func yuvPipeline() -> MTLRenderPipelineState? {
        if let yuvPipe { return yuvPipe }
        if yuvFailed { return nil }
        do {
            let lib = try device.makeLibrary(source: String(cString: kl_stream_yuv_msl()), options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "kl_stream_yuv_v")
            d.fragmentFunction = lib.makeFunction(name: "kl_stream_yuv_f")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.inputPrimitiveTopology = .triangle
            yuvPipe = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            yuvFailed = true
            NSLog("[stream] YUV split shader failed: \(error)")
        }
        return yuvPipe
    }

    private func planeTexture(_ pb: CVPixelBuffer, _ plane: Int, _ fmt: MTLPixelFormat)
        -> (MTLTexture, CVMetalTexture)? {
        guard let cache else { return nil }
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &cv)
                == kCVReturnSuccess, let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
        return (t, cv)
    }

    private func ensureStages(w: Int, h: Int) -> Bool {
        let n = max(1, Int(kl_ovrp_stage_count()))
        if w == eyeW && h == eyeH && stages.count == n { return true }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .bgra8Unorm_srgb
        d.width = w
        d.height = h
        d.arrayLength = 2
        d.usage = [.shaderRead, .renderTarget, .pixelFormatView]
        d.storageMode = .private
        var made: [MTLTexture] = []
        for i in 0..<n {
            guard let t = device.makeTexture(descriptor: d) else {
                NSLog("[stream] could not allocate the \(w)x\(h) eye texture for stage \(i)")
                return false
            }
            t.label = "klepton stream eyes stage \(i)"
            made.append(t)
        }
        stages = made
        stageViews = made.compactMap { $0.makeTextureView(pixelFormat: .bgra8Unorm) }
        eyeW = w; eyeH = h; next = 0
        // Register once per allocation; the table holds the pointer, `stages`
        // holds the reference.
        for (s, t) in stages.enumerated() {
            for eye in 0..<2 {
                kl_glfb_note_eye_mtl_texture(Int32(eye), Int32(s),
                                             Unmanaged.passUnretained(t).toOpaque(),
                                             Int32(eye), Int32(w), Int32(h))
            }
        }
        NSLog("[stream] eye textures: \(n) stage(s) of \(w)x\(h) x2 slices (bgra8 sRGB)")
        return true
    }

    func publish(_ pb: CVPixelBuffer, info: kl_stream_frame_info, queue: MTLCommandQueue?) -> Bool {
        guard let cache, let queue else { return false }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
        let ew = W / 2
        guard ew > 0, H > 0, ensureStages(w: ew, h: H) else { return false }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let stage = next % stages.count
        let dst = stages[stage]
        if fmt == kCVPixelFormatType_32BGRA {
            var cvtex: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm_srgb,
                                                              W, H, 0, &cvtex)
            guard r == kCVReturnSuccess, let cvtex, let src = CVMetalTextureGetTexture(cvtex),
                  let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder()
            else {
                NSLog("[stream] could not wrap the decoded frame for Metal (\(r))")
                return false
            }
            cmd.label = "klepton stream frame \(info.frame_id)"
            for eye in 0..<2 {
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: eye * ew, y: 0, z: 0),
                          sourceSize: MTLSize(width: ew, height: H, depth: 1),
                          to: dst, destinationSlice: eye, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
            cmd.addCompletedHandler { _ in withExtendedLifetime((cvtex, pb)) {} }
            cmd.commit()
        } else {
            let ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            guard stage < stageViews.count, let pipe = yuvPipeline(),
                  let (ty, cy) = planeTexture(pb, 0, ten ? .r16Unorm : .r8Unorm),
                  let (tc, cc) = planeTexture(pb, 1, ten ? .rg16Unorm : .rg8Unorm),
                  let cmd = queue.makeCommandBuffer()
            else {
                NSLog("[stream] could not wrap the decoded YUV frame for Metal (format \(fmt))")
                return false
            }
            cmd.label = "klepton stream frame \(info.frame_id) (yuv)"
            var u = kl_stream_yuv_uniforms()
            kl_stream_yuv_params(fmt, &u)
            u.eye_w = UInt32(ew); u.frame_w = UInt32(W); u.frame_h = UInt32(H)
            for eye in 0..<2 {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = stageViews[stage]
                rp.colorAttachments[0].slice = eye
                rp.colorAttachments[0].loadAction = .dontCare
                rp.colorAttachments[0].storeAction = .store
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return false }
                enc.setRenderPipelineState(pipe)
                u.x0 = UInt32(eye * ew)
                enc.setFragmentBytes(&u, length: MemoryLayout<kl_stream_yuv_uniforms>.stride, index: 0)
                enc.setFragmentTexture(ty, index: 0)
                enc.setFragmentTexture(tc, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { _ in withExtendedLifetime((cy, cc, pb)) {} }
            cmd.commit()
        }
        next += 1

        // The frame record: this stage now holds a picture rendered at
        // ring[pose_id] with VIDEO.tan.
        kl_ovrp_frame_begin_external()
        let t = info.tan
        var tan8: [Float] = [t.0.0, t.0.1, t.0.2, t.0.3, t.1.0, t.1.1, t.1.2, t.1.3]
        if info.have_pose != 0 {
            let p = info.pose7
            var pose7: [Float] = [p.0, p.1, p.2, p.3, p.4, p.5, p.6]
            kl_ovrp_frame_end_external(Int32(stage), &pose7, &tan8)
        } else {
            // The POSE fell out of the ring (a host more than 256 poses behind):
            // keep the latched pose rather than invent one. Counted as pose-miss.
            kl_ovrp_frame_end_external(Int32(stage), nil, &tan8)
        }
        if !logged {
            logged = true
            NSLog(String(format: "[stream] first frame %u (%dx%d, key=%d) on stage %d, pose %u %@, "
                         + "tan L(%.3f %.3f %.3f %.3f)", info.frame_id, W, H, info.keyframe,
                         stage, info.pose_id, info.have_pose != 0 ? "from the ring" : "MISSING",
                         t.0.0, t.0.1, t.0.2, t.0.3))
        }
        return true
    }
}

// MARK: - The window beside the immersive space

/// What the hub shows while streaming. Opens the immersive space, shows the
/// connection state and the stats line, and ends the session — by the button,
/// or on its own when the Mac says BYE — dismissing the space and returning
/// to the library (no guest ran, so there is nothing to tear down and the
/// process need not exit).
struct StreamPlayView: View {
    let target: KLStreamTarget
    let onExit: () -> Void
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var phase = klL("Looking for the Mac…", "Buscando el Mac…")
    @State private var stats = ""
    @State private var state: Int32 = -1
    @State private var failed = false
    @State private var exiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(klL("Play from Mac", "Jugar desde el Mac")).font(.largeTitle.bold())
                Text(target.name).font(.title2).foregroundStyle(.secondary)
                Spacer()
            }
            Label(phase, systemImage: icon)
                .font(.title3)
                .foregroundStyle(failed ? .red : .primary)
            if !stats.isEmpty {
                Text(stats)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button(role: .destructive) { Task { await exit("disconnect") } } label: {
                    Label(failed ? klL("Back to library", "Volver a la biblioteca") : klL("Disconnect", "Desconectar"),
                          systemImage: failed ? "chevron.backward" : "xmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(exiting)
                Spacer()
                Text(klL("The game runs on the Mac; the headset shows it and sends your head, controllers and hands.", "Se juega en el Mac; el visor muestra la imagen y envía la cabeza, los mandos y las manos."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .task { await connect() }
        .task { await poll() }
    }

    private var icon: String {
        if failed { return "exclamationmark.triangle" }
        switch state {
        case Int32(KL_STREAM_CLIENT_STREAMING): return "play.circle.fill"
        case Int32(KL_STREAM_CLIENT_NO_SIGNAL): return "wifi.exclamationmark"
        default: return "desktopcomputer"
        }
    }

    private func connect() async {
        var host = target.host
        var port = target.port
        if host == nil, let ep = target.endpoint {
            phase = klL("Looking for \(target.name) on the network…", "Buscando \(target.name) en la red…")
            if let r = await KLStreamResolver.resolve(ep) { host = r.0; port = r.1 }
        }
        guard let host else {
            phase = klL("Can't find \(target.name) on the network.", "No se encuentra \(target.name) en la red.")
            failed = true
            return
        }
        guard KLStreamSession.shared.start(name: target.name, host: host, port: port) else {
            phase = klL("Couldn't open a connection to \(host):\(port).", "No se pudo abrir la conexión con \(host):\(port).")
            failed = true
            return
        }
        phase = klL("Connecting to \(target.name)…", "Conectando a \(target.name)…")
        let r = await openImmersiveSpace(id: Immersive.id)
        NSLog("[stream] openImmersiveSpace -> \(r)")
        if case .opened = r {} else {
            phase = klL("Couldn't open the immersive space.", "No se pudo abrir el espacio inmersivo.")
            failed = true
            KLStreamSession.shared.stop(reason: "no immersive space")
        }
    }

    private func poll() async {
        var endedAt: Date?
        while !Task.isCancelled && !exiting {
            if let s = KLStreamSession.shared.status() {
                state = s.state
                stats = withUnsafeBytes(of: s.line) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                switch Int32(s.state) {
                case Int32(KL_STREAM_CLIENT_CONNECTING): phase = klL("Connecting to \(target.name)…", "Conectando a \(target.name)…")
                case Int32(KL_STREAM_CLIENT_WAITING):    phase = klL("Connected. Waiting for the first picture…", "Conectado. Esperando la primera imagen…")
                case Int32(KL_STREAM_CLIENT_STREAMING):
                    phase = String(format: klL("Playing from %@ — %.0f fps, %.0f ms pose→photon", "Jugando desde %@ — %.0f fps, %.0f ms pose→fotón"),
                                   target.name, s.video_fps, s.p2p_ms)
                case Int32(KL_STREAM_CLIENT_NO_SIGNAL):  phase = klL("No signal from the Mac", "Sin señal del Mac")
                case Int32(KL_STREAM_CLIENT_REFUSED):
                    phase = klL("\(target.name) refused the connection: ", "\(target.name) rechazó la conexión: ") + KLStreamSession.refusal(s.ack_status)
                    failed = true
                case Int32(KL_STREAM_CLIENT_ENDED):
                    phase = klL("\(target.name) ended the session.", "\(target.name) cerró la sesión.")
                    if endedAt == nil { endedAt = Date() }
                default: break
                }
            }
            // The Mac ended it: give the card a moment, then go home.
            if let e = endedAt, Date().timeIntervalSince(e) > 1.5 {
                await exit("host BYE")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func exit(_ why: String) async {
        guard !exiting else { return }
        exiting = true
        KLStreamSession.shared.stop(reason: why)
        await dismissImmersiveSpace()
        // The session's summary (fps of the stream as shown here, its length) is final now;
        // the next stream in this process is a session of its own.
        KLSessionStats.shared.endStream(reason: "stream ended")
        onExit()
    }
}
