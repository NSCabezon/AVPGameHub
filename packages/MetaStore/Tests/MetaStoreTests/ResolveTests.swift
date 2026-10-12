import Foundation
import XCTest
@testable import MetaStore

/// `resolveDownload`: Meta's redirect to a signed CDN address is captured (never followed), and
/// only an address that carries no credential of ours is handed on.
final class ResolveTests: XCTestCase {
    let base = URL(string: "https://securecdn.oculus.com/binaries/download/?id=123")!

    final class Redirecting: MetaTransport, @unchecked Sendable {
        let status: Int, location: String?
        private(set) var requests: [URLRequest] = []
        init(_ status: Int, _ location: String?) { self.status = status; self.location = location }
        func data(for request: URLRequest) async throws -> (Data, Int) { XCTFail("no data request"); return (Data(), 0) }
        func download(_ request: URLRequest, into sink: DownloadSink) async throws { XCTFail("no download") }
        func firstResponse(for request: URLRequest) async throws -> (status: Int, location: String?) {
            requests.append(request)
            return (status, location)
        }
    }

    func testRedirectToCDNIsSigned() async throws {
        let t = Redirecting(302, "https://scontent.oculuscdn.com/v/t64/file.apk?_nc_cat=1&oh=abc&oe=6700AAAA")
        let r = try await MetaClient(token: "OCAtesttokentesttokentest", transport: t).resolveDownload(id: "123")
        guard case .signed(let url) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(url.host, "scontent.oculuscdn.com")
        XCTAssertEqual(t.requests.count, 1)
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.url?.host, "securecdn.oculus.com")
        XCTAssertNil(req.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(req.url?.query?.range(of: "access_token"), "the token is a header, never in the address")
    }

    func testNoRedirectMeansInProcess() throws {
        XCTAssertEqual(try MetaClient.location(status: 200, header: nil, requestURL: base), .direct)
        XCTAssertEqual(try MetaClient.location(status: 206, header: nil, requestURL: base), .direct)
    }

    func testUnsafeRedirectsStayInProcess() throws {
        // A credential in the address, plain http, back to Meta's own hosts, or a relative path.
        XCTAssertEqual(try MetaClient.location(status: 302, header: "https://cdn.example.net/f?access_token=OCAxyz", requestURL: base), .direct)
        XCTAssertEqual(try MetaClient.location(status: 302, header: "http://cdn.example.net/f", requestURL: base), .direct)
        XCTAssertEqual(try MetaClient.location(status: 307, header: "https://securecdn.oculus.com/other", requestURL: base), .direct)
        XCTAssertEqual(try MetaClient.location(status: 302, header: "/binaries/x", requestURL: base), .direct)
        XCTAssertEqual(try MetaClient.location(status: 302, header: nil, requestURL: base), .direct)
    }

    func testDeniedAndUnexpected() {
        XCTAssertThrowsError(try MetaClient.location(status: 404, header: nil, requestURL: base)) {
            XCTAssertEqual($0 as? MetaError, .denied(status: 404))
        }
        XCTAssertThrowsError(try MetaClient.location(status: 500, header: nil, requestURL: base)) {
            XCTAssertEqual($0 as? MetaError, .unexpected(status: 500))
        }
    }

    func testTransportsWithoutRedirectSupportThrow() async {
        // The scripted transport of the other tests has no firstResponse: resolving fails cleanly
        // (callers fall back to the in-process download).
        let t = MockTransport { _ in .init(status: 200, body: Data()) }
        do {
            _ = try await MetaClient(token: "OCAtesttokentesttokentest", transport: t).resolveDownload(id: "1")
            XCTFail("expected a throw")
        } catch {
            guard case MetaError.transport = error else { return XCTFail("\(error)") }
        }
    }
}
