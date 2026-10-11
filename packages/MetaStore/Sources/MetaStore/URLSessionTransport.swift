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
