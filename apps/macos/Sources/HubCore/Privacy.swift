import Foundation

/// Account identifiers (Steam account name, persona, SteamID; Meta e-mail / user id) are never
/// shown: the UI says only "signed in", and logs show them masked as first 2 chars + •••.
public enum Privacy {
    public static func mask(_ s: String) -> String { String(s.prefix(2)) + "•••" }

    /// Every occurrence of each secret (case-insensitive, longest first) masked. Secrets shorter
    /// than 3 characters are ignored (too likely to hit ordinary text).
    public static func redact(_ line: String, secrets: [String]) -> String {
        var out = line
        for s in Set(secrets).filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            var result = ""
            var rest = out[...]
            while let r = rest.range(of: s, options: .caseInsensitive) {
                result += rest[..<r.lowerBound] + mask(String(rest[r]))
                rest = rest[r.upperBound...]
            }
            out = result + rest
        }
        return out
    }

    /// Process-wide list fed by the account models; read by the log views.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: Set<String> = []

    public static func register(_ secrets: [String?]) {
        lock.lock(); defer { lock.unlock() }
        for case let s? in secrets where s.count >= 3 { registered.insert(s) }
    }

    public static var secrets: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(registered)
    }

    public static func redact(_ line: String) -> String {
        let s = secrets
        return s.isEmpty ? line : redact(line, secrets: s)
    }
}
