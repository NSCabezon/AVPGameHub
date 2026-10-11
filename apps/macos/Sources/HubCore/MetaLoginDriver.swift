import Darwin
import Foundation

/// Terminal output with colour/cursor escapes removed, chunk by chunk. A pty read can end in the
/// middle of an escape: Node's readline (Meta's ovr-platform-util) prints "Email: \e[8G" and the
/// "8G" often arrives only with the next output. An unfinished escape at the end of a chunk is
/// held back and completed with the next one, so a prompt is seen as "Email: ", not "Email: \e[".
public struct ANSIStream: Sendable {
    private var carry = ""
    public init() {}

    public mutating func feed(_ chunk: String) -> String {
        var s = carry + chunk
        carry = ""
        if let esc = s.lastIndex(of: "\u{1B}") {
            let tail = s[esc...]
            if ANSIStream.isUnfinished(tail) {
                carry = String(tail)
                s = String(s[..<esc])
            }
        }
        return ANSI.strip(s).replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The rest of the output once the tool has ended (a dangling escape is dropped).
    public mutating func finish() -> String { carry = ""; return "" }

    /// `ESC`, `ESC [ params` or `ESC (` without its final byte yet.
    static func isUnfinished(_ tail: Substring) -> Bool {
        let rest = tail.dropFirst()
        if rest.isEmpty { return true }
        if rest.first == "(" || rest.first == ")" { return rest.count < 2 }
        guard rest.first == "[" else { return false }
        return rest.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || $0 == ";" || $0 == "?" || ($0 >= " " && $0 <= "/")) }
    }
}

/// Answers for one sign-in attempt. Kept in memory only, used once each, dropped afterwards.
public struct MetaCredentials: Sendable, Equatable {
    public var email: String
    public var password: String
    public var code: String?

    /// The e-mail as the user meant it: surrounding whitespace/newlines dropped and Unicode in
    /// composed form (what a keyboard in Terminal sends). The password is passed as typed.
    public init(email: String, password: String, code: String? = nil) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        self.password = password
        self.code = code.map(MetaPrompt.normalizedCode)
    }
}

/// Runs one `ovr-platform-util get-access-token` sign-in: reads the tool's output, recognises
/// its prompts and types the matching answer once. Independent of the UI (and of MetaStore: the
/// caller passes the function that starts the tool on a pty) so it can be tested headlessly.
///
/// `run(input, output, onSpawn)` must start the tool reading `input` and writing `output`, call
/// `onSpawn` with the tool's pid, and return the token (or throw) when the tool ends.
public final class MetaLoginDriver: @unchecked Sendable {
    public typealias Runner = (_ input: Int32, _ output: Int32, _ onSpawn: @escaping (pid_t) -> Void) throws -> String

    public enum Event: Sendable {
        /// Tool output, escapes removed and the password masked; not yet redacted for the e-mail.
        case output(String)
        /// The prompt the tool is waiting on now (nil: none recognised).
        case prompt(MetaPrompt?)
        /// An answer was typed for this prompt.
        case answered(MetaPrompt)
        /// The tool ended: the token, or the error plus the last output since the last answer.
        case finished(Result<String, Error>, tail: String)
    }

    /// Typing like a person: a pause after the prompt, then the characters, then Enter (CR).
    public struct Typing: Sendable {
        public var delay: TimeInterval
        public var gap: TimeInterval
        public init(delay: TimeInterval = 0.3, gap: TimeInterval = 0.01) { self.delay = delay; self.gap = gap }
    }

    private let queue = DispatchQueue(label: "MetaLoginDriver")
    private let typingQueue = DispatchQueue(label: "MetaLoginDriver.typing")
    private let typing: Typing
    private let onEvent: @Sendable (Event) -> Void
    private var credentials: MetaCredentials?
    private var answered: Set<MetaPrompt> = []
    private var sinceAnswer = ""
    private var stream = ANSIStream()
    private var input: FileHandle?
    private var pid: pid_t = 0
    private var cancelled = false
    public private(set) var codeSent = false

    /// `credentials` nil: nothing is answered automatically (answers come from `send`).
    public init(credentials: MetaCredentials?, typing: Typing = Typing(), onEvent: @escaping @Sendable (Event) -> Void) {
        self.credentials = credentials
        self.typing = typing
        self.onEvent = onEvent
    }

    /// The pid of the running tool (0 before it started or after it ended).
    public var toolPID: pid_t { queue.sync { pid } }

    public func start(_ run: @escaping Runner) {
        let inPipe = Pipe(), outPipe = Pipe()
        queue.sync { input = inPipe.fileHandleForWriting }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.received(String(decoding: d, as: UTF8.self)) }
        }
        Thread.detachNewThread { [self] in
            let result = Result {
                try run(inPipe.fileHandleForReading.fileDescriptor, outPipe.fileHandleForWriting.fileDescriptor) { pid in
                    self.queue.sync { self.pid = pid }
                    if self.queue.sync(execute: { self.cancelled }) { kill(pid, SIGTERM) }
                }
            }
            try? outPipe.fileHandleForWriting.close()
            // Let output already read be handled first.
            Thread.sleep(forTimeInterval: 0.15)
            self.queue.sync {
                outPipe.fileHandleForReading.readabilityHandler = nil
                let rest = outPipe.fileHandleForReading.availableDataOrEmpty
                if !rest.isEmpty { self.received(String(decoding: rest, as: UTF8.self)) }
                self.pid = 0
                self.credentials = nil
                try? self.input?.close()
                self.input = nil
                self.onEvent(.finished(result, tail: MetaPrompt.errorTail(self.sinceAnswer)))
            }
            // Keep the pipe's read end open until the tool is gone.
            withExtendedLifetime(inPipe) {}
        }
    }

    /// A line typed by the user (console answer or a code), sent to whatever the tool asks now.
    public func send(_ line: String, isCode: Bool = false) {
        queue.async { [self] in
            if isCode { codeSent = true; answered.insert(.code) }
            type(line)
        }
    }

    /// Stops the tool this driver started (only that pid, never by name).
    public func cancel() {
        queue.sync {
            cancelled = true
            credentials = nil
            try? input?.close()
            input = nil
            if pid > 0 { kill(pid, SIGTERM) }
        }
    }

    // MARK: - On `queue`

    private func received(_ raw: String) {
        var text = stream.feed(raw)
        if let p = credentials?.password, !p.isEmpty { text = text.replacingOccurrences(of: p, with: "••••") }
        guard !text.isEmpty else { return }
        onEvent(.output(text))
        sinceAnswer += text
        let prompt = MetaPrompt.detect(in: sinceAnswer)
        onEvent(.prompt(prompt))
        guard let prompt, !answered.contains(prompt), let creds = credentials else { return }
        let value: String?
        switch prompt {
        case .email: value = creds.email
        case .password: value = creds.password
        case .code: value = creds.code
        }
        guard let value, !value.isEmpty else { return }
        answered.insert(prompt)
        if prompt == .code { codeSent = true; credentials?.code = nil }
        type(value)
        onEvent(.answered(prompt))
    }

    private func type(_ value: String) {
        sinceAnswer = ""
        guard let handle = input else { return }
        let t = typing
        typingQueue.async {
            Thread.sleep(forTimeInterval: t.delay)
            for ch in value {
                guard (try? handle.write(contentsOf: Data(String(ch).utf8))) != nil else { return }
                if t.gap > 0 { Thread.sleep(forTimeInterval: t.gap) }
            }
            try? handle.write(contentsOf: Data("\r".utf8))
        }
    }
}

private extension FileHandle {
    /// Whatever is left in a pipe whose write end is closed (non-blocking in practice).
    var availableDataOrEmpty: Data { (try? readToEnd()) ?? Data() }
}
