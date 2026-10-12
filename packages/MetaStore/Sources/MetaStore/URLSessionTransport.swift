// Adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/AVPPlayCore/MetaClient.swift
// (MetaClient.configuration and DownloadDelegate).
import Foundation

/// The real network: ephemeral sessions (no cookies, no cache), and an Authorization
/// header that never follows a redirect to another host.
public struct URLSessionTransport: MetaTransport {
    public init() {}

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        return c
    }

    public func data(for request: URLRequest) async throws -> (Data, Int) {
        let session = URLSession(configuration: URLSessionTransport.configuration())
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard(authorizedHost: request.url?.host))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func download(_ request: URLRequest, into sink: DownloadSink) async throws {
        let delegate = StreamDelegate(sink: sink, authorizedHost: request.url?.host)
        let session = URLSession(configuration: URLSessionTransport.configuration(), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

extension URLSessionTransport {
    /// Stops at the first response: a redirect is reported, not followed (so the token never
    /// leaves Meta's host), and the body is never read.
    public func firstResponse(for request: URLRequest) async throws -> (status: Int, location: String?) {
        let delegate = FirstResponseDelegate()
        let session = URLSession(configuration: URLSessionTransport.configuration(), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(status: Int, location: String?), Error>) in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

final class FirstResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _continuation: CheckedContinuation<(status: Int, location: String?), Error>?
    var continuation: CheckedContinuation<(status: Int, location: String?), Error>? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }

    private func finish(_ result: Result<(status: Int, location: String?), Error>) {
        let c: CheckedContinuation<(status: Int, location: String?), Error>? = lock.withLock {
            let c = _continuation
            _continuation = nil
            return c
        }
        c?.resume(with: result)
    }

    private static func answer(_ response: URLResponse?) -> (status: Int, location: String?) {
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Location"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)          // not followed: the redirect response itself is the answer
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        finish(.success(Self.answer(response)))
        completionHandler(.cancel)      // the body is not wanted
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response {
            finish(.success(Self.answer(response)))
        } else if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(MetaError.transport(Redaction.redact(error.localizedDescription)))) }
        } else {
            finish(.failure(MetaError.unexpected(status: 0)))
        }
    }
}

/// If Meta redirects, the token does not travel to another host.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let authorizedHost: String?
    init(authorizedHost: String?) { self.authorizedHost = authorizedHost }

    static func strip(_ request: URLRequest, authorizedHost: String?) -> URLRequest {
        var next = request
        if authorizedHost == nil || next.url?.host != authorizedHost || next.url?.scheme != "https" {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectGuard.strip(request, authorizedHost: authorizedHost))
    }
}

final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sink: DownloadSink
    private let authorizedHost: String?
    private var failure: Error?
    var continuation: CheckedContinuation<Void, Error>?

    init(sink: DownloadSink, authorizedHost: String?) {
        self.sink = sink
        self.authorizedHost = authorizedHost
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        do {
            try sink.begin(status: http?.statusCode ?? 0, contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                           expectedLength: response.expectedContentLength > 0 ? response.expectedContentLength : nil)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try sink.write(data) } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sink.finish()
        let c = continuation
        continuation = nil
        if let failure {
            c?.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled { c?.resume(throwing: CancellationError()) }
            else { c?.resume(throwing: MetaError.transport(Redaction.redact(error.localizedDescription))) }
        } else {
            c?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectGuard.strip(request, authorizedHost: authorizedHost))
    }
}
