import Foundation

/// HTTP access to Steam content servers with server rotation, CDN auth tokens and retries.
final class CDNClient: @unchecked Sendable {
    private let servers: [CDNServer]
    private let depot: UInt32
    private let app: UInt32
    private let session: SteamSession
    private let http: URLSession
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var tokens: [String: String] = [:]   // host -> token query string
    private var penalty: [Int] = []

    init(servers: [CDNServer], depot: UInt32, app: UInt32, session: SteamSession, maxConnections: Int,
         log: @escaping @Sendable (String) -> Void) {
        self.servers = servers
        self.depot = depot
        self.app = app
        self.session = session
        self.log = log
        self.penalty = [Int](repeating: 0, count: servers.count)
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = max(4, maxConnections)
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "Valve/Steam HTTP Client 1.0"]
        self.http = URLSession(configuration: config)
    }

    /// Pick a server for this worker: spread workers over the best few servers, skipping penalised ones.
    private func server(for worker: Int, attempt: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let pool = min(servers.count, 3)
        let ranked = (0..<servers.count).sorted { (penalty[$0], $0) < (penalty[$1], $1) }
        return ranked[(worker + attempt) % max(1, min(pool, ranked.count))]
    }

    private func penalise(_ i: Int) { lock.lock(); penalty[i] += 1; lock.unlock() }

    private func setToken(_ t: String, for host: String) { lock.lock(); tokens[host] = t; lock.unlock() }
    private func token(for host: String) -> String? { lock.lock(); defer { lock.unlock() }; return tokens[host] }

    func get(_ path: String, worker: Int) async throws -> Data {
        var lastError: Error = SteamDepotError.cdn("no attempt")
        for attempt in 0..<6 {
            let si = server(for: worker, attempt: attempt)
            let s = servers[si]
            var urlString = "\(s.baseURL)/\(path)"
            if let t = token(for: s.host) { urlString += t.hasPrefix("?") ? t : "?" + t }
            guard let url = URL(string: urlString) else { throw SteamDepotError.cdn("bad url \(urlString)") }
            do {
                let (data, resp) = try await http.data(from: url)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return data }
                if (code == 401 || code == 403) && token(for: s.host) == nil {
                    if let t = try? await session.cdnAuthToken(app: app, depot: depot, host: s.host), !t.isEmpty {
                        setToken(t, for: s.host)
                        log("got CDN auth token for \(s.host)")
                        continue
                    }
                }
                lastError = SteamDepotError.cdn("HTTP \(code) from \(s.host) for \(path)")
                if code == 404 && path.contains("/manifest/") { throw lastError }
            } catch let e as SteamDepotError {
                throw e
            } catch {
                if Task.isCancelled { throw SteamDepotError.cancelled }
                lastError = SteamDepotError.cdn("\(s.host): \(error.localizedDescription)")
            }
            penalise(si)
            log("retry \(attempt + 1) for \(path): \(lastError)")
            try await Task.sleep(nanoseconds: UInt64(200_000_000 * (attempt + 1)))
        }
        throw lastError
    }

    /// Download + decrypt + decompress + verify one chunk. Returns (data, network bytes, format).
    func fetchChunk(_ chunk: DepotManifest.Chunk, key: Data, worker: Int) async throws -> (Data, Int, DepotChunk.Format) {
        var lastError: Error = SteamDepotError.cdn("no attempt")
        for _ in 0..<3 {
            let raw = try await get("depot/\(depot)/chunk/\(chunk.id)", worker: worker)
            do {
                let (data, fmt) = try DepotChunk.process(raw, chunk: chunk, key: key)
                return (data, raw.count, fmt)
            } catch {
                lastError = error
                log("chunk \(chunk.id) failed to process (\(error)); retrying")
            }
        }
        throw lastError
    }
}
