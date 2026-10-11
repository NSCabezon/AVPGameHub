// Adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/AVPPlayCore/Redaction.swift,
// Hashing.swift and RequestGate.swift.
import CryptoKit
import Foundation

/// Removes credentials from text before it is shown or logged.
public enum Redaction {
    private static let patterns: [NSRegularExpression] = [
        // Meta tokens (prefix OC/OCA/FRL, then long and alphanumeric)
        try! NSRegularExpression(pattern: #"(OCA|OC|FRL)[A-Za-z0-9_|.\-]{16,}"#),
        try! NSRegularExpression(pattern: #"(?i)(access_token=)[^&"\s]+"#),
        try! NSRegularExpression(pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#),
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for (i, re) in patterns.enumerated() {
            let template = i == 0 ? "<REDACTED>" : "$1<REDACTED>"
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}

public enum Hashing {
    /// SHA-256 of a file as lowercase hex, read in blocks (fine for multi-GB files).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif

/// Brake for requests to Meta: at least `minInterval` between the end of one request and
/// the start of the next. avp-play's note: a run with ~140 requests in ten minutes locked an
/// account out of one access path. The brake does not replace the second rule — never probe:
/// stop at the first unexpected answer (Fetcher).
public actor RequestGate {
    public let minInterval: Duration
    private var lastFinished: ContinuousClock.Instant?

    public init(minInterval: Duration = .seconds(5)) { self.minInterval = minInterval }

    /// How long to wait before the next request.
    public static func delay(lastFinished: ContinuousClock.Instant?, now: ContinuousClock.Instant,
                             minInterval: Duration) -> Duration {
        guard let lastFinished else { return .zero }
        let elapsed = now - lastFinished
        return elapsed >= minInterval ? .zero : minInterval - elapsed
    }

    public func waitForTurn() async throws {
        let wait = RequestGate.delay(lastFinished: lastFinished, now: .now, minInterval: minInterval)
        if wait > .zero { try await Task.sleep(for: wait) }
    }

    public func requestFinished() { lastFinished = .now }

    /// waitForTurn + body + requestFinished (also on error).
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await waitForTurn()
        defer { lastFinished = .now }
        return try await body()
    }
}
