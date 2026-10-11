import Darwin
import Foundation
import MetaStore
import XCTest
@testable import HubCore

/// Prompt reading split across pty reads, as Node's readline (Meta's tool) produces it.
final class ANSIStreamTests: XCTestCase {
    func testEscapeSplitAcrossChunksIsHeldBack() {
        var s = ANSIStream()
        XCTAssertEqual(s.feed("Enter Meta Quest user credentials\r\n"), "Enter Meta Quest user credentials\n")
        XCTAssertEqual(s.feed("\u{1B}[1G\u{1B}["), "")
        let prompt = s.feed("0JEmail: \u{1B}[")
        XCTAssertEqual(prompt, "Email: ")
        XCTAssertEqual(MetaPrompt.detect(in: prompt), .email)
        XCTAssertEqual(s.feed("8GT"), "T")
    }

    func testOldPerChunkStripMissedThePrompt() {
        // What the app did before: strip each chunk on its own; the dangling "\e[" hid the ":".
        XCTAssertNil(MetaPrompt.detect(in: ANSI.strip("\u{1B}[1G\u{1B}[0JEnter two-factor authentication code: \u{1B}[")))
        var s = ANSIStream()
        XCTAssertEqual(MetaPrompt.detect(in: s.feed("\u{1B}[1G\u{1B}[0JEnter two-factor authentication code: \u{1B}[")), .code)
    }

    func testCredentialsNormaliseEmailOnly() {
        let c = MetaCredentials(email: "  A.B@example.com\n", password: " pw with spaces ", code: "123 456")
        XCTAssertEqual(c.email, "A.B@example.com")
        XCTAssertEqual(c.password, " pw with spaces ")
        XCTAssertEqual(c.code, "123456")
        XCTAssertEqual(MetaCredentials(email: "jose\u{301}@example.com", password: "x").email, "jos\u{E9}@example.com")
    }
}

/// End to end against Tests/Fixtures/fake-ovr-platform-util.js: a copy of the real tool's prompt
/// code (Node readline, hidden password). Never contacts Meta. Needs `node`; skipped without it.
final class MetaLoginFakeToolTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/fake-ovr-platform-util.js")

    private func makeTool() throws -> (tool: URL, log: URL) {
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { throw XCTSkip("node not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ovr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("fake-ovr-platform-util")
        try "#!/bin/sh\nexec '\(node)' '\(Self.fixture.path)' \"$@\"\n".write(to: tool, atomically: true, encoding: .utf8)
        chmod(tool.path, 0o755)
        return (tool, dir.appendingPathComponent("received.txt"))
    }

    private func hex(_ s: String) -> String { Data(s.utf8).map { String(format: "%02x", $0) }.joined() }

    private func run(_ creds: MetaCredentials, expect: (email: String, password: String, code: String),
                     tool: URL, log: URL, timeout: TimeInterval = 30) -> (Result<String, Error>?, [MetaPrompt], MetaLoginDriver) {
        setenv("FAKE_OVR_EMAIL", expect.email, 1)
        setenv("FAKE_OVR_PASSWORD", expect.password, 1)
        setenv("FAKE_OVR_CODE", expect.code, 1)
        setenv("FAKE_OVR_LOG", log.path, 1)
        let done = expectation(description: "finished")
        let box = Box()
        let driver = MetaLoginDriver(credentials: creds, typing: .init(delay: 0.1, gap: 0.005)) { event in
            switch event {
            case .answered(let p): box.lock.withLock { box.answered.append(p) }
            case .finished(let r, _): box.lock.withLock { box.result = r }; done.fulfill()
            default: break
            }
        }
        driver.start { input, output, onSpawn in
            try MetaLogin.run(tool: tool, input: input, output: output, onSpawn: onSpawn)
        }
        wait(for: [done], timeout: timeout)
        return box.lock.withLock { (box.result, box.answered, driver) }
    }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<String, Error>?
        var answered: [MetaPrompt] = []
    }

    /// Regression: prompts must be recognised and the answers must reach the tool byte for byte
    /// (spaces, quotes, non-ASCII), each prompt answered once, ending with the token.
    func testSignInDeliversExactBytes() throws {
        let (tool, log) = try makeTool()
        let email = "Test.User+x@example.com", password = "p\u{E1}\u{F1}€ß w0rd\"'-!\\", code = "123456"
        let (result, answered, _) = run(MetaCredentials(email: " \(email) ", password: password, code: code),
                                         expect: (email, password, code), tool: tool, log: log)
        let received = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(received, "email=\(hex(email))\npassword=\(hex(password))\ncode=\(hex(code))\n")
        XCTAssertEqual(answered, [.email, .password, .code])
        let token = try XCTUnwrap(try result?.get())
        XCTAssertTrue(token.hasPrefix("FAKETOKEN"))
    }

    func testWrongPasswordFails() throws {
        let (tool, log) = try makeTool()
        let (result, answered, _) = run(MetaCredentials(email: "a@example.com", password: "nope"),
                                         expect: ("a@example.com", "right", "123456"), tool: tool, log: log)
        XCTAssertEqual(answered, [.email, .password])
        XCTAssertThrowsError(try result?.get())
    }

    /// Cancel stops exactly the tool this driver started (by pid).
    func testCancelKillsOwnTool() throws {
        let (tool, log) = try makeTool()
        setenv("FAKE_OVR_LOG", log.path, 1)
        let done = expectation(description: "finished")
        let driver = MetaLoginDriver(credentials: nil) { event in
            if case .finished = event { done.fulfill() }
        }
        driver.start { input, output, onSpawn in
            try MetaLogin.run(tool: tool, input: input, output: output, onSpawn: onSpawn)
        }
        var pid: pid_t = 0
        for _ in 0..<100 where pid == 0 { pid = driver.toolPID; usleep(20_000) }
        XCTAssertGreaterThan(pid, 0)
        XCTAssertEqual(kill(pid, 0), 0)
        driver.cancel()
        wait(for: [done], timeout: 10)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }
}
