import Foundation

/// One hub session, as the headset writes it to Library/Application Support/sessions/<target>.jsonl
/// (KLSessionRecord in Klepton's visionos/Sources/KleptonSessionStats.swift). Every field but the
/// identity is optional here so an older or newer line still decodes.
public struct SessionRecord: Codable, Identifiable, Hashable, Sendable {
    public var v: Int?
    public var id: String
    public var target: String
    public var build: String?
    public var start: Date
    public var end: Date?
    public var final: Bool?
    public var endReason: String?
    public var durationS: Double?
    public var playS: Double?
    public var loadingS: Double?
    public var guestFrames: UInt64?
    public var fpsAvg: Double?
    public var fps1Low: Double?
    public var fps5Low: Double?
    public var fpsMin5s: Double?
    public var fpsMax5s: Double?
    public var frameMsP50: Double?
    public var displayHz: Double?
    public var compositorFrames: UInt64?
    public var reprojectedFrames: UInt64?
    public var peakFootprintMB: Int?

    /// Share of compositor frames that reused an old guest frame, 0…1.
    public var reprojectedShare: Double? {
        guard let c = compositorFrames, c > 0, let r = reprojectedFrames else { return nil }
        return Double(r) / Double(c)
    }

    /// A session whose last line is not final ended without a clean exit (kill, crash).
    public var endedCleanly: Bool { final ?? false }
}

public enum SessionDecoding {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = iso.date(from: s) ?? isoFractional.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(s)")
        }
        return d
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Every session in a .jsonl text. Lines that do not decode (torn write, future format) are
    /// skipped; a session written more than once (checkpoints) keeps its LAST line.
    public static func decode(jsonl text: String) -> [SessionRecord] {
        let dec = decoder()
        var order: [String] = []
        var byID: [String: SessionRecord] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let r = try? dec.decode(SessionRecord.self, from: Data(line.utf8)) else { continue }
            if byID[r.id] == nil { order.append(r.id) }
            byID[r.id] = r
        }
        return order.compactMap { byID[$0] }
    }

    /// Every .jsonl in a directory, oldest session first.
    public static func load(directory: URL) -> [SessionRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [SessionRecord] = []
        for f in files where f.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: f) else { continue }
            out += decode(jsonl: String(decoding: data, as: UTF8.self))
        }
        var seen = Set<String>()
        return out.sorted { $0.start < $1.start }.filter { seen.insert($0.id).inserted }
    }
}

public enum DeviceFileListing {
    /// The .jsonl file names in a `devicectl device info files --json-output` result. The JSON
    /// layout is devicectl's and not documented, so any string value that names a .jsonl file is
    /// taken (its last path component).
    public static func jsonlNames(in data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [String] = []
        func walk(_ v: Any) {
            if let s = v as? String {
                let name = (s as NSString).lastPathComponent
                if name.hasSuffix(".jsonl"), !name.hasPrefix("."), !out.contains(name) { out.append(name) }
            } else if let a = v as? [Any] {
                a.forEach(walk)
            } else if let d = v as? [String: Any] {
                for k in d.keys.sorted() { walk(d[k]!) }
            }
        }
        walk(obj)
        return out
    }
}
