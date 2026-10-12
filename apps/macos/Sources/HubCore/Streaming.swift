import Foundation

// "Jugar desde el Mac": the Mac runs the game and streams it to the headset
// (Klepton runtime/net/kl_stream_host.c, `KL_STREAM_HOST=1 ./build/m_boot <game>`).

/// Options the user can change. nil = leave it to the host (its own default / auto-sizing).
public struct StreamOptions: Codable, Equatable, Sendable {
    /// Bonjour instance name the headset shows (KL_STREAM_NAME). Empty = this Mac's name.
    public var name: String = ""
    /// KL_STREAM_BITRATE_KBPS. nil = the host's default (100000).
    public var bitrateKbps: Int?
    /// KL_STREAM_SCALE. nil = auto-size from what the guest submits. Setting it turns auto-sizing
    /// OFF (a fixed HELLO eye size × scale; at 1.0 that was 6144x2464 and 26 fps).
    public var scale: Double?

    public init(name: String = "", bitrateKbps: Int? = nil, scale: Double? = nil) {
        self.name = name
        self.bitrateKbps = bitrateKbps
        self.scale = scale
    }

    /// The host's KL_STREAM_BITRATE_KBPS default.
    public static let hostDefaultBitrateKbps = 100_000
}

public enum StreamLaunch {
    /// `build/m_boot`, the Makefile target that builds it, relative to Klepton.
    public static let binary = "build/m_boot"
    public static let makeTarget = "build/m_boot"

    /// The m_boot command for one game. `tmpDir` is a private TMPDIR for this run (a second Alyx
    /// in the same TMPDIR exits on its source_engine_*.lock).
    public static func command(klepton: URL, info: StreamHostInfo, contentDir: String?,
                               macName: String, tmpDir: String, options: StreamOptions) -> ShellCommand {
        var env = info.environment
        env["KL_STREAM_HOST"] = "1"
        let name = options.name.trimmingCharacters(in: .whitespaces)
        env["KL_STREAM_NAME"] = name.isEmpty ? macName : name
        env["TMPDIR"] = tmpDir
        if let key = info.contentEnv, let dir = contentDir, !dir.isEmpty { env[key] = dir }
        if let k = options.bitrateKbps, k > 0 { env["KL_STREAM_BITRATE_KBPS"] = String(k) }
        if let s = options.scale, s > 0.1, s <= 2.0 { env["KL_STREAM_SCALE"] = String(format: "%.2f", s) }
        return ShellCommand(klepton.appendingPathComponent(binary).path, [info.bootTarget],
                            environment: env, currentDirectory: klepton.path)
    }

    /// `make build/m_boot` in Klepton.
    public static func buildCommand(klepton: URL) -> ShellCommand {
        ShellCommand("/usr/bin/make", [makeTarget], currentDirectory: klepton.path)
    }

    /// Whether `dir` holds the game's content (every marker present).
    public static func contentPresent(_ dir: String, info: StreamHostInfo, fileManager: FileManager = .default) -> Bool {
        guard !dir.isEmpty else { return false }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return false }
        return info.contentMarkers.allSatisfy { fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }
    }

    /// First place the content is found: the scripts' override variable, then the usual spots
    /// relative to Klepton. nil if none holds it.
    public static func detectContent(klepton: URL?, info: StreamHostInfo,
                                     env: [String: String] = ProcessInfo.processInfo.environment,
                                     fileManager: FileManager = .default) -> String? {
        guard info.needsContent else { return nil }
        var candidates: [String] = []
        if let k = info.contentOverrideEnv, let v = env[k], !v.isEmpty { candidates.append(v) }
        if let klepton {
            candidates += info.contentCandidates.map { klepton.appendingPathComponent($0).standardizedFileURL.path }
        }
        return candidates.first { contentPresent($0, info: info, fileManager: fileManager) }
    }

    /// Klepton paths the game needs that are missing.
    public static func missingKleptonPaths(klepton: URL, info: StreamHostInfo, fileManager: FileManager = .default) -> [String] {
        info.requiredKleptonPaths.filter { !fileManager.fileExists(atPath: klepton.appendingPathComponent($0).path) }
    }

    /// Busy: the 1-minute load average above 75% of the cores (the game wants the whole Mac).
    public static func isBusy(load1: Double, cores: Int) -> Bool {
        cores > 0 && load1 > Double(cores) * 0.75
    }

    public static func loadAverage() -> Double? {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) >= 1 ? l[0] : nil
    }

    /// A log line with this Mac's name and the home directory masked (both turn up in the host log:
    /// the Bonjour line, content paths).
    public static func scrub(_ line: String, macName: String, home: String = NSHomeDirectory()) -> String {
        var out = line
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        return Privacy.redact(out, secrets: [macName])
    }
}

// MARK: - Host log

public struct StreamStats: Equatable, Sendable {
    public var fps: Double
    public var encodeMs: Double
    public var mbps: Double
    public var poseAgeMs: Double
    public var rttMs: Double?
    /// Encoded frames dropped (sender queue full) and guest frames skipped (encoder busy), this run.
    public var droppedTotal: Int = 0
    public var bitrateKbps: Int?
}

public enum StreamPhase: Equatable, Sendable {
    case idle
    /// Process started, socket / Bonjour not up yet.
    case starting
    /// Advertised, waiting for the headset's HELLO.
    case waitingForHeadset
    /// HELLO received, the guest is booting (no frame encoded yet).
    case booting
    /// Frames are going out.
    case streaming
    /// The headset left (BYE / timeout); the game keeps running and it can reconnect.
    case headsetLeft
    /// The guest is exiting / the process ended.
    case ended(status: Int32?, stoppedByUser: Bool)
    case failed(String)
}

/// Everything the Streaming screen shows, built from the host's stderr.
public struct StreamStatus: Equatable, Sendable {
    public var phase: StreamPhase = .idle
    public var bonjourName: String?
    public var port: Int?
    /// The headset's address (ip:port) and its device string from HELLO.
    public var client: String?
    public var device: String?
    public var frame: String?
    public var stats: StreamStats?
    /// The game was booted in this run (so an exit is a finished game, not a failed start).
    public var gameBooted = false

    public init() {}

    private static let listening = Pattern(#"\[stream-host\] listening on UDP :(\d+)"#)
    private static let bonjour = Pattern(#"\[stream-host\] Bonjour: '(.*)' _"#)
    private static let connected = Pattern(#"\[stream-host\] client (\S+) connected: streaming (?:\(until the guest submits\) )?(\d+x\d+) HEVC at (\d+) kbit/s"#)
    private static let display = Pattern(#"\[stream-host\] display from (\S+) \((.*?)\): [\d.]+ Hz"#)
    private static let fpsLine = Pattern(#"\[stream-host\] ([\d.]+) fps encoded, encode ([\d.]+) ms.*?, ([\d.]+) Mbit/s, .*?pose age ([\d.]+) ms, rtt ([\d.]+) ms"#)
    private static let sender = Pattern(#"\[stream-host\]\s+sender: ([\d.]+) Mbit/s.*?queue drops (\d+),.*?bitrate (\d+) kbit/s"#)
    private static let skipped = Pattern(#"\[stream-host\]\s+(\d+) guest frames skipped"#)
    private static let encodeSize = Pattern(#"\[stream-host\] encode size follows the guest: .*?-> encoding (\d+x\d+)"#)

    public mutating func ingest(_ line: String) {
        guard line.contains("[stream-host]") else { return }
        if let g = Self.listening.groups(in: line) {
            port = g[0].flatMap { Int($0) }
            if phase == .idle || phase == .starting { phase = .starting }
        } else if let g = Self.bonjour.groups(in: line) {
            bonjourName = g[0]
        } else if line.contains("waiting for a client's HELLO") {
            phase = .waitingForHeadset
        } else if let g = Self.display.groups(in: line), g[0] != "built-in" {
            client = g[0]
            device = g[1]
        } else if let g = Self.connected.groups(in: line) {
            client = g[0]
            frame = g[1]
            if let k = g[2].flatMap({ Int($0) }) {
                var s = stats ?? StreamStats(fps: 0, encodeMs: 0, mbps: 0, poseAgeMs: 0)
                s.bitrateKbps = k
                stats = s
            }
            phase = gameBooted ? .streaming : .booting
        } else if line.contains("first frame to the encoder") {
            gameBooted = true
            phase = .streaming
        } else if let g = Self.encodeSize.groups(in: line) {
            frame = g[0]
        } else if let g = Self.fpsLine.groups(in: line), let fps = g[0].flatMap(Double.init) {
            var s = stats ?? StreamStats(fps: 0, encodeMs: 0, mbps: 0, poseAgeMs: 0)
            s.fps = fps
            s.encodeMs = g[1].flatMap(Double.init) ?? 0
            s.mbps = g[2].flatMap(Double.init) ?? 0
            s.poseAgeMs = g[3].flatMap(Double.init) ?? 0
            s.rttMs = g[4].flatMap(Double.init)
            stats = s
            if fps > 0 {
                gameBooted = true
                if phase == .booting || phase == .waitingForHeadset { phase = .streaming }
            }
        } else if let g = Self.sender.groups(in: line) {
            var s = stats ?? StreamStats(fps: 0, encodeMs: 0, mbps: 0, poseAgeMs: 0)
            s.droppedTotal += g[1].flatMap { Int($0) } ?? 0
            s.bitrateKbps = g[2].flatMap { Int($0) } ?? s.bitrateKbps
            stats = s
        } else if let g = Self.skipped.groups(in: line) {
            var s = stats ?? StreamStats(fps: 0, encodeMs: 0, mbps: 0, poseAgeMs: 0)
            s.droppedTotal += g[0].flatMap { Int($0) } ?? 0
            stats = s
        } else if line.contains("client said BYE") || line.contains("client timed out") {
            phase = .headsetLeft
            stats?.fps = 0
        } else if line.contains("the game is exiting") {
            phase = .ended(status: nil, stoppedByUser: false)
        } else if let r = line.range(of: "] bind :") {
            phase = .failed(L("No se pudo abrir el puerto", "Could not open the port") + " (" + line[r.upperBound...].trimmingCharacters(in: .whitespaces) + ")")
        }
    }

    /// The process ended.
    public mutating func exited(status: Int32, stoppedByUser: Bool) {
        if case .failed = phase { return }
        if !stoppedByUser, status != 0, !gameBooted {
            phase = .failed(L("El servidor terminó con estado \(status)", "The server exited with status \(status)"))
            return
        }
        phase = .ended(status: status, stoppedByUser: stoppedByUser)
    }

    public var isLive: Bool {
        switch phase {
        case .starting, .waitingForHeadset, .booting, .streaming, .headsetLeft: return true
        default: return false
        }
    }

    /// One line for the screen.
    public var headline: String {
        switch phase {
        case .idle: return L("Detenido", "Stopped")
        case .starting: return L("Iniciando el servidor…", "Starting the server…")
        case .waitingForHeadset: return L("Esperando al visor…", "Waiting for the headset…")
        case .booting: return L("Arrancando el juego…", "Starting the game…")
        case .streaming: return L("Conectado: \(device ?? client ?? "visor")", "Connected: \(device ?? client ?? "headset")")
        case .headsetLeft: return L("El visor se ha desconectado (el juego sigue; vuelve a conectar desde el visor)",
                                    "The headset left (the game keeps running; reconnect from the headset)")
        case .ended(_, let user): return user ? L("Servidor detenido", "Server stopped") : L("Partida terminada", "Game over")
        case .failed(let why): return why
        }
    }
}
