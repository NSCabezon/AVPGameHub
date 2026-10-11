import Foundation

/// Small regex helper (NSRegularExpression; first capture groups as strings).
struct Pattern: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String) { re = try! NSRegularExpression(pattern: pattern) }

    func groups(in s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    func double(in s: String) -> Double? { groups(in: s)?.first.flatMap { $0 }.flatMap(Double.init) }
}

// MARK: - Build progress (visionos/run.sh "[n/5] …" lines)

public struct BuildStep: Equatable, Sendable {
    public var index: Int
    public var total: Int
    public var title: String
    public init(index: Int, total: Int, title: String) { self.index = index; self.total = total; self.title = title }
}

public enum BuildLog {
    private static let step = Pattern(#"^\s*\[(\d+)/(\d+)\]\s*(.*)$"#)

    /// `[3/5] building for device …` → (3, 5, "building for device …").
    public static func step(in line: String) -> BuildStep? {
        guard let g = step.groups(in: line), let i = g[0].flatMap(Int.init), let t = g[1].flatMap(Int.init),
              t > 0, i >= 1, i <= t else { return nil }
        return BuildStep(index: i, total: t, title: (g[2] ?? "").trimmingCharacters(in: .whitespaces))
    }

    /// Lines the build script and xcodebuild use to say something went wrong.
    public static func isError(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("!!") || t.contains("error:") || t.contains("** BUILD FAILED **")
            || t.contains("FAULT") || t.localizedCaseInsensitiveContains("fatal")
    }
}

// MARK: - Runtime log events

public enum LogEvent: Equatable, Sendable {
    /// `[perf] gpu time over N frames: X ms avg / Y ms worst per frame` (KL_GPU_TIME)
    case gpuTime(frames: Int, avgMs: Double, worstMs: Double?)
    /// `[vk] pipeline stall: <kind> batch of N took X ms (stalls so far: K, T ms total)`
    case pipelineStall(ms: Double, count: Int?, totalMs: Double?)
    /// `[session] … guest X fps avg, 1% low Y, 5% low Z, … median frame M ms; … peak footprint P MB`
    case session(SessionLine)
    /// `[mvk-fov] A/B so far: foveated X GPU ms/frame … | full rate Y … | ±Z% GPU time` (KL_FOVEATE_AB)
    case foveateAB(foveatedMs: Double?, fullMs: Double?, deltaPercent: Double?)
}

public struct SessionLine: Equatable, Sendable {
    public var target: String?
    public var fpsAvg: Double?
    public var fps1Low: Double?
    public var fps5Low: Double?
    public var frameMsP50: Double?
    public var displayHz: Double?
    public var peakFootprintMB: Int?
    public var final: Bool
}

public enum LogParser {
    private static let gpu = Pattern(#"\[perf\] gpu time over (\d+) frames: ([\d.]+) ms avg(?: / ([\d.]+) ms worst)?"#)
    private static let stall = Pattern(#"\[vk\] pipeline stall:.*?took ([\d.]+) ms(?: \(stalls so far: (\d+), ([\d.]+) ms total\))?"#)
    private static let sessionTarget = Pattern(#"\[session\] (\S+) \d+m\d+s"#)
    private static let fpsAvg = Pattern(#"guest ([\d.]+) fps avg"#)
    private static let low1 = Pattern(#"1% low ([\d.]+)"#)
    private static let low5 = Pattern(#"5% low ([\d.]+)"#)
    private static let median = Pattern(#"median frame ([\d.]+) ms"#)
    private static let display = Pattern(#"display ([\d.]+) Hz"#)
    private static let peak = Pattern(#"peak footprint (\d+) MB"#)
    private static let abFov = Pattern(#"foveated ([\d.]+) GPU ms"#)
    private static let abFull = Pattern(#"full rate ([\d.]+) GPU ms"#)
    private static let abDelta = Pattern(#"([+\-−±]?[\d.]+)% GPU time"#)

    public static func parse(_ line: String) -> LogEvent? {
        if line.contains("[perf] gpu time"), let g = gpu.groups(in: line),
           let n = g[0].flatMap(Int.init), let avg = g[1].flatMap(Double.init) {
            return .gpuTime(frames: n, avgMs: avg, worstMs: g[2].flatMap(Double.init))
        }
        if line.contains("pipeline stall"), let g = stall.groups(in: line), let ms = g[0].flatMap(Double.init) {
            return .pipelineStall(ms: ms, count: g[1].flatMap(Int.init), totalMs: g[2].flatMap(Double.init))
        }
        if line.contains("[session]"), line.contains("fps avg") {
            return .session(SessionLine(
                target: sessionTarget.groups(in: line)?.first ?? nil,
                fpsAvg: fpsAvg.double(in: line), fps1Low: low1.double(in: line), fps5Low: low5.double(in: line),
                frameMsP50: median.double(in: line), displayHz: display.double(in: line),
                peakFootprintMB: peak.groups(in: line)?.first.flatMap { $0 }.flatMap(Int.init),
                final: line.contains(" FINAL ")))
        }
        if line.contains("A/B so far") {
            let delta = abDelta.groups(in: line)?.first.flatMap { $0 }.map {
                $0.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "±", with: "")
            }.flatMap(Double.init)
            return .foveateAB(foveatedMs: abFov.double(in: line), fullMs: abFull.double(in: line), deltaPercent: delta)
        }
        return nil
    }
}

/// Live mini-stats accumulated from a running log.
public struct LiveStats: Equatable, Sendable {
    public var lines = 0
    public var errors = 0
    public var gpuLastMs: Double?
    public var gpuWorstMs: Double?
    /// Recent GPU averages (oldest first), capped at `historyLimit`.
    public var gpuHistory: [Double] = []
    public var stalls = 0
    public var stallMsTotal: Double = 0
    public var session: SessionLine?
    public var abFoveatedMs: Double?
    public var abFullMs: Double?
    public var abDeltaPercent: Double?
    public static let historyLimit = 120

    public init() {}

    public var gpuAvgMs: Double? {
        gpuHistory.isEmpty ? nil : gpuHistory.reduce(0, +) / Double(gpuHistory.count)
    }

    public mutating func ingest(_ line: String) {
        lines += 1
        if BuildLog.isError(line) { errors += 1 }
        guard let e = LogParser.parse(line) else { return }
        switch e {
        case .gpuTime(_, let avg, let worst):
            gpuLastMs = avg
            gpuWorstMs = worst
            gpuHistory.append(avg)
            if gpuHistory.count > Self.historyLimit { gpuHistory.removeFirst(gpuHistory.count - Self.historyLimit) }
        case .pipelineStall(let ms, let count, let total):
            // The line carries the running totals; trust them when present.
            if let count { stalls = count } else { stalls += 1 }
            if let total { stallMsTotal = total } else { stallMsTotal += ms }
        case .session(let s):
            session = s
        case .foveateAB(let f, let full, let d):
            abFoveatedMs = f ?? abFoveatedMs
            abFullMs = full ?? abFullMs
            abDeltaPercent = d ?? abDeltaPercent
        }
    }
}

// MARK: - Filters

public enum LogCategory: String, CaseIterable, Identifiable, Sendable {
    case all, perf, vulkan, session, errors
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return L("Todo", "All")
        case .perf: return "[perf]"
        case .vulkan: return "[vk]"
        case .session: return "[session]"
        case .errors: return L("Errores", "Errors")
        }
    }

    public func matches(_ line: String) -> Bool {
        switch self {
        case .all: return true
        case .perf: return line.contains("[perf]") || line.contains("[mvk-fov]")
        case .vulkan: return line.contains("[vk]") || line.contains("[mvk")
        case .session: return line.contains("[session]")
        case .errors: return BuildLog.isError(line)
        }
    }
}

public enum LogFilter {
    public static func matches(_ line: String, category: LogCategory, search: String) -> Bool {
        guard category.matches(line) else { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || line.localizedCaseInsensitiveContains(q)
    }
}

public enum ANSI {
    private static let escape = Pattern(#"\u001B\[[0-9;?]*[ -/]*[@-~]|\u001B[()][A-Za-z0-9]"#)

    /// Text without terminal colour/cursor escapes (tools print them on a pty).
    public static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        let ns = s as NSString
        return escape.re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
}
