// Adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/AVPPlayCore/MetaClient.swift.
// Changes: the network sits behind `MetaTransport` (unit tests use a mock, no network), English only.
import Foundation

public enum MetaError: Error, CustomStringConvertible, Equatable {
    /// Meta does not accept the token (expired, incomplete, revoked).
    case tokenRejected(String)
    case api(status: Int, message: String)
    /// The download address does not deliver the file (not owned or not visible).
    case denied(status: Int)
    case unexpected(status: Int)
    case transport(String)
    case missingAppId
    case notOwned(String)

    public var description: String {
        switch self {
        case .tokenRejected(let m): return "Meta rejected the token (\(m)). Sign in again (metastore login + push-token)."
        case .api(let s, let m): return "Meta responded with an error (HTTP \(s)): \(m)"
        case .denied(let s): return "Meta won't deliver this file (HTTP \(s))."
        case .unexpected(let s): return "Unexpected response from Meta (HTTP \(s))."
        case .transport(let m): return "Connection error: \(m)"
        case .missingAppId: return "The recipe has no store app ID; ownership can't be checked."
        case .notOwned(let t): return "\(t) is not owned by this Meta account."
        }
    }
}

// MARK: - Transport

/// Receives a download's response and body. `begin` decides whether the response is the
/// file (throws otherwise: nothing is written and the transfer is cancelled).
public protocol DownloadSink: AnyObject {
    func begin(status: Int, contentRange: String?, expectedLength: Int64?) throws
    func write(_ data: Data) throws
    func finish()
}

/// The network, abstracted so the client can be tested without it.
public protocol MetaTransport: Sendable {
    /// One request, whole body. Returns (body, HTTP status).
    func data(for request: URLRequest) async throws -> (Data, Int)
    /// A streamed download into `sink`.
    func download(_ request: URLRequest, into sink: DownloadSink) async throws
    /// The first response to `request` WITHOUT following a redirect: its HTTP status and
    /// `Location` header. The body is not read.
    func firstResponse(for request: URLRequest) async throws -> (status: Int, location: String?)
}

public extension MetaTransport {
    /// Transports that cannot stop at a redirect say so; callers then download in-process.
    func firstResponse(for request: URLRequest) async throws -> (status: Int, location: String?) {
        throw MetaError.transport("this transport cannot stop at a redirect")
    }
}

// MARK: - Client

/// Every request to Meta. The token goes ONLY as an Authorization header, ONLY to
/// `graph.oculus.com` and `securecdn.oculus.com` — never in a URL, never to another host,
/// never into a log.
public struct MetaClient: Sendable {
    public static let graphHost = "graph.oculus.com"
    public static let downloadHost = "securecdn.oculus.com"

    private let token: String
    private let transport: MetaTransport

    public init(token: String, transport: MetaTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    // MARK: Account, ownership, purchases (graph.oculus.com)

    /// Checks the token and returns the user id. Call before anything else.
    public func me() async throws -> String {
        struct Me: Decodable { let id: String }
        return try decode(Me.self, from: try await graph(path: "/me", query: [URLQueryItem(name: "fields", value: "id")])).id
    }

    /// Does the account own this app? (documented `verify_entitlement`)
    public func ownsApp(appId: String, userId: String) async throws -> Bool {
        guard MetaClient.isNumericID(appId), MetaClient.isNumericID(userId) else {
            throw MetaError.api(status: 0, message: "app and user ids must be numeric")
        }
        struct Answer: Decodable { let success: Bool }
        let data = try await graph(path: "/\(appId)/verify_entitlement", form: ["user_id": userId])
        return try decode(Answer.self, from: data).success
    }

    /// The store-confirmed purchases (SKUs) inside an app. Expired purchases don't count.
    public func purchases(appId: String, now: Date = Date()) async throws -> [String] {
        guard MetaClient.isNumericID(appId) else { throw MetaError.api(status: 0, message: "app id must be numeric") }
        struct Page: Decodable {
            struct Row: Decodable {
                struct Item: Decodable { let sku: String? }
                let expiration_time: Int?
                let item: Item?
            }
            struct Paging: Decodable { let next: String? }
            let data: [Row]
            let paging: Paging?
        }
        var skus: [String] = []
        var next: URL? = MetaClient.graphURL(path: "/\(appId)/viewer_purchases", query: [
            URLQueryItem(name: "fields", value: "expiration_time,item{sku}"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        var pages = 0
        while let url = next, pages < 25 {
            pages += 1
            let page = try decode(Page.self, from: try await send(MetaClient.request(url, token: token)))
            for row in page.data {
                guard let sku = row.item?.sku, MetaClient.isPlainSKU(sku) else { continue }
                if let exp = row.expiration_time, exp > 0, Double(exp) < now.timeIntervalSince1970 { continue }
                skus.append(sku)
            }
            next = page.paging?.next.flatMap(MetaClient.sanitizedNextPage)
        }
        return Array(Set(skus)).sorted()
    }

    /// Meta appends the token to the next-page URL. It does not belong in a URL: it is removed,
    /// and the page is only followed on the same host.
    static func sanitizedNextPage(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw), parts.scheme == "https", parts.host == graphHost else { return nil }
        parts.queryItems = parts.queryItems?.filter { $0.name.lowercased() != "access_token" }
        return parts.url
    }

    static func isPlainSKU(_ s: String) -> Bool {
        !s.isEmpty && s.count < 96 && s.allSatisfy { $0.isASCII && !$0.isWhitespace && !$0.isNewline && $0 != "\0" }
    }

    public static func isNumericID(_ s: String) -> Bool { (1...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }

    // MARK: Download (securecdn.oculus.com)

    public struct DownloadOutcome: Sendable, Equatable {
        public let bytesReceived: Int64
        public let totalSize: Int64?
        public let resumed: Bool
    }

    /// Downloads one file by its store id. With `resumeFrom`, continues a partial file
    /// (HTTP Range). Anything other than 200/206 writes nothing.
    public func download(id: String, to destination: URL, resumeFrom offset: Int64 = 0,
                         progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> DownloadOutcome {
        guard MetaClient.isNumericID(id) else { throw MetaError.api(status: 0, message: "file id must be numeric") }
        var request = MetaClient.request(MetaClient.downloadURL(id: id), token: token)
        request.timeoutInterval = 120
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let sink = try FileSink(destination: destination, offset: offset, progress: progress)
        do {
            try await transport.download(request, into: sink)
        } catch let e as MetaError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let f = sink.failure { throw f }
            throw MetaError.transport(Redaction.redact("\(error)"))
        }
        if let f = sink.failure { throw f }
        return DownloadOutcome(bytesReceived: sink.received, totalSize: sink.total, resumed: sink.resumed)
    }

    /// Where a file's bytes can be fetched from.
    public enum DownloadLocation: Sendable, Equatable {
        /// Meta answered with a redirect to a CDN address on another host. That address carries
        /// no credential of ours (the token only ever went as a header to Meta's own host), so it
        /// can be handed to a system background download. It expires; ask again then.
        case signed(URL)
        /// Meta serves the file itself (no redirect), or the redirect is not one that can be
        /// handed on safely: download it in-process with the token, as `download(id:)` does.
        case direct
    }

    /// One request to securecdn for the file (counts like any other request: callers put it
    /// through the RequestGate). The redirect is NOT followed and the body is not read.
    /// 401/403/404 throw `.denied` (an add-on Meta does not deliver to this account), exactly as
    /// `download(id:)` would.
    public func resolveDownload(id: String) async throws -> DownloadLocation {
        let a = try await downloadAnswer(id: id)
        return try MetaClient.location(status: a.status, header: a.location, requestURL: MetaClient.downloadURL(id: id))
    }

    /// The raw first answer to a file request (status and Location header), redirect not followed.
    /// For diagnostics (`metastore resolve`); the Location is a credential while it lasts, so
    /// callers never print or log it whole.
    public func downloadAnswer(id: String) async throws -> (status: Int, location: String?) {
        guard MetaClient.isNumericID(id) else { throw MetaError.api(status: 0, message: "file id must be numeric") }
        var request = MetaClient.request(MetaClient.downloadURL(id: id), token: token)
        request.timeoutInterval = 60
        // No Range: the request is exactly what a download sends; if Meta serves the file itself,
        // the transport stops at the response headers.
        do {
            return try await transport.firstResponse(for: request)
        } catch let e as MetaError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MetaError.transport(Redaction.redact("\(error.localizedDescription)"))
        }
    }

    /// The decision behind `resolveDownload`, testable without a network.
    public static func location(status: Int, header: String?, requestURL: URL) throws -> DownloadLocation {
        switch status {
        case 301, 302, 303, 307, 308:
            guard let header, let target = URL(string: header, relativeTo: requestURL)?.absoluteURL,
                  target.scheme == "https", let host = target.host?.lowercased(), !host.isEmpty,
                  host != graphHost, host != downloadHost else { return .direct }
            // A credential in the address itself is never handed on (nor logged).
            let names = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
            if names.contains("access_token") { return .direct }
            return .signed(target)
        case 200, 206:
            return .direct
        case 401, 403, 404:
            throw MetaError.denied(status: status)
        default:
            throw MetaError.unexpected(status: status)
        }
    }

    // MARK: Helpers

    static func downloadURL(id: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = downloadHost
        parts.path = "/binaries/download/"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        return parts.url!
    }

    static func graphURL(path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = graphHost
        parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        precondition(url.scheme == "https" && (url.host == graphHost || url.host == downloadHost),
                     "The token is only ever sent to Meta's own hosts")
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func graph(path: String, query: [URLQueryItem] = [], form: [String: String]? = nil) async throws -> Data {
        var request = MetaClient.request(MetaClient.graphURL(path: path, query: query), token: token)
        if let form {
            request.httpMethod = "POST"
            var body = URLComponents()
            body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MetaError.transport(Redaction.redact("\(error.localizedDescription)"))
        }
        guard status == 200 else {
            struct Failure: Decodable {
                struct Body: Decodable { let message: String?; let code: Int? }
                let error: Body
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let message = Redaction.redact(failure?.error.message ?? "no details given")
            if status == 401 || failure?.error.code == 190 { throw MetaError.tokenRejected(message) }
            throw MetaError.api(status: status, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw MetaError.api(status: 200, message: "the response doesn't have the expected form")
        }
    }
}

/// Writes a download's body to a file, only if it really is the file.
final class FileSink: DownloadSink, @unchecked Sendable {
    private let destination: URL
    private let offset: Int64
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    private var handle: FileHandle?
    private(set) var received: Int64 = 0
    private(set) var total: Int64?
    private(set) var resumed = false
    private(set) var failure: MetaError?
    private var lastReport: Int64 = 0

    init(destination: URL, offset: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?) throws {
        self.destination = destination
        self.offset = offset
        self.progress = progress
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// `Content-Range: bytes 0-4095/43406683` -> 43406683
    static func totalSize(contentRange: String?) -> Int64? {
        guard let value = contentRange, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    func begin(status: Int, contentRange: String?, expectedLength: Int64?) throws {
        switch status {
        case 200:
            // The whole file (even when a resume was asked for): write from the start.
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            handle = try FileHandle(forWritingTo: destination)
            total = (expectedLength ?? 0) > 0 ? expectedLength : nil
        case 206 where offset > 0:
            handle = try FileHandle(forWritingTo: destination)
            try handle?.truncate(atOffset: UInt64(offset))
            try handle?.seekToEnd()
            resumed = true
            received = offset
            total = FileSink.totalSize(contentRange: contentRange)
        case 401, 403, 404:
            failure = .denied(status: status)
            throw failure!
        default:
            failure = .unexpected(status: status)
            throw failure!
        }
    }

    func write(_ data: Data) throws {
        guard let handle else { throw MetaError.unexpected(status: 0) }
        try handle.write(contentsOf: data)
        received += Int64(data.count)
        if received - lastReport >= 1 << 20 || received == total {
            lastReport = received
            progress?(received, total)
        }
    }

    func finish() {
        try? handle?.close()
        handle = nil
        progress?(received, total)
    }
}
