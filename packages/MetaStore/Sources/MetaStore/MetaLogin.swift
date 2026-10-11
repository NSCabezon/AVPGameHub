// Adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/AVPPlayCore/MetaLogin.swift,
// Pty.swift and TokenStore.swift (the /usr/bin/security route). macOS only: the hub never logs in
// itself — it receives the token from `metastore push-token`.
#if os(macOS)
import Darwin
import Foundation

public enum LoginError: Error, CustomStringConvertible, Equatable {
    case toolMissing(String)
    case wrongSigner(String)
    case couldNotStart(tool: String, why: String)
    case needsRosetta(tool: String)
    case toolFailed(Int32)
    case noToken
    case notExecutable(String)

    public static let rosettaCommand = "softwareupdate --install-rosetta --agree-to-license"

    public var description: String {
        switch self {
        case .toolMissing(let p):
            return "Meta's tool ovr-platform-util wasn't found at \(p). Download it from Meta "
                + "(developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility) and put it there, or pass --tool."
        case .wrongSigner(let who): return "The file isn't signed by Meta (\(who)). It will not be run."
        case .couldNotStart(let tool, let why): return "\(tool) couldn't be started: \(why)"
        case .needsRosetta(let tool):
            return "\(tool) is built for Intel processors and needs Rosetta: run “\(LoginError.rosettaCommand)” once, then try again."
        case .toolFailed(let status): return "Sign-in wasn't completed (ovr-platform-util exited with status \(status))."
        case .noToken: return "ovr-platform-util didn't output a token."
        case .notExecutable(let p): return "\(p) is Meta's tool but not executable yet: chmod +x it."
        }
    }
}

/// Meta's own command-line tool. Not shipped here; the user downloads it from Meta.
public struct MetaTool: Sendable {
    /// Team id of “Facebook Technologies, LLC” in the tool's signature.
    public static let expectedTeam = "HXH6UQBHD4"
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ovr-platform-util")
    }

    /// Only an executable file with a valid signature from Meta is ever started.
    public func verify() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoginError.toolMissing(url.path) }
        try verifySignature()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw LoginError.notExecutable(url.path) }
    }

    public func verifySignature() throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw LoginError.toolMissing(url.path) }
        guard MetaTool.status(["/usr/bin/codesign", "--verify", "--strict", url.path]) == 0 else {
            throw LoginError.wrongSigner("signature invalid or missing")
        }
        let info = MetaTool.captureBoth(["/usr/bin/codesign", "-dv", "--verbose=2", url.path])
        let team = MetaTool.teamIdentifier(in: info)
        guard team == MetaTool.expectedTeam else { throw LoginError.wrongSigner("team \(team ?? "unknown")") }
    }

    static func teamIdentifier(in codesignOutput: String) -> String? {
        codesignOutput.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    static func status(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func captureBoth(_ argv: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Passes the tool's output through but holds back the token: it must appear neither on screen
/// nor in a log. A token is a long run of letters and digits. Every such run is held until it
/// ends — unless it arrives character by character, which is the echo of what the user types
/// and must show at once. The tool writes its token in one piece.
public struct TokenSieve: Sendable {
    public static let placeholder = "[Token received – not shown]"
    static let tokenFrom = 64, typingChunk = 4
    private var run: [UInt8] = []
    private var held = false
    public private(set) var token: String?
    public init() {}

    private static func isTokenByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    }

    /// `chunk` is what one read returned.
    public mutating func feed(_ chunk: some Collection<UInt8>) -> [UInt8] {
        let typing = chunk.count <= TokenSieve.typingChunk
        var out: [UInt8] = []
        for b in chunk {
            if TokenSieve.isTokenByte(b) {
                if run.isEmpty { held = !typing }
                run.append(b)
                if !held { out.append(b) }
            } else {
                out.append(contentsOf: endRun())
                out.append(b)
            }
        }
        return out
    }

    public mutating func finish() -> [UInt8] { endRun() }

    private mutating func endRun() -> [UInt8] {
        defer { run.removeAll(keepingCapacity: true); held = false }
        guard held else { return [] }
        guard run.count >= TokenSieve.tokenFrom else { return run }
        token = String(decoding: run, as: UTF8.self)
        return Array(TokenSieve.placeholder.utf8)
    }
}

/// Sign-in through `ovr-platform-util get-access-token`. E-mail, password and 2FA code go from
/// the user straight to Meta's tool on its own pseudo-terminal; keystrokes are relayed unchanged
/// and stored nowhere. Only the token is taken from the output.
public enum MetaLogin {
    public static func run(tool: URL, arguments: [String] = ["get-access-token"],
                           input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                           onSpawn: (pid_t) -> Void = { _ in }) throws -> String {
        var sieve = TokenSieve()
        let code = try Pty.run(tool: tool, arguments: arguments, environment: ProcessInfo.processInfo.environment,
                               input: input, output: output, onSpawn: onSpawn,
                               transform: { sieve.feed($0) }, finish: { sieve.finish() })
        guard code == 0 else { throw LoginError.toolFailed(code) }
        guard let token = sieve.token, MetaToken.isPlausible(token) else { throw LoginError.noToken }
        return token
    }
}

/// Runs a foreign command-line tool on its own pseudo-terminal, relaying what the user types and
/// what the tool writes; the tool can ask for password and code without this program keeping them.
enum Pty {
    static func run(tool: URL, arguments: [String], environment: [String: String],
                    input: Int32, output: Int32, onSpawn: (pid_t) -> Void = { _ in },
                    transform: (ArraySlice<UInt8>) -> [UInt8], finish: () -> [UInt8] = { [] }) throws -> Int32 {
        let name = tool.lastPathComponent
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize()
        let haveSize = ioctl(input, TIOCGWINSZ, &size) == 0
        guard (haveSize ? openpty(&master, &slave, nil, nil, &size) : openpty(&master, &slave, nil, nil, nil)) == 0 else {
            throw LoginError.couldNotStart(tool: name, why: String(cString: strerror(errno)))
        }
        defer { close(master) }
        guard let slaveName = ttyname(slave).map({ String(cString: $0) }) else {
            close(slave); throw LoginError.couldNotStart(tool: name, why: "no name for the pseudo-terminal")
        }

        // Own session; the child opens the terminal itself so it becomes its controlling
        // terminal (Ctrl-C reaches the tool). Every other descriptor stays closed.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([tool.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool.path, &actions, &attr, argv, envp)
        close(slave)
        guard rc != EBADARCH else { throw LoginError.needsRosetta(tool: name) }
        guard rc == 0 else { throw LoginError.couldNotStart(tool: name, why: String(cString: strerror(rc))) }
        onSpawn(pid)

        var saved = termios()
        let isTerminal = isatty(input) == 1 && tcgetattr(input, &saved) == 0
        if isTerminal {
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(input, TCSANOW, &raw)
        }
        defer { if isTerminal { tcsetattr(input, TCSANOW, &saved) } }

        var inputOpen = true
        var buffer = [UInt8](repeating: 0, count: 4096)
        func emit(_ bytes: [UInt8]) {
            var rest = bytes[...]
            while !rest.isEmpty {
                let n = rest.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                rest = rest.dropFirst(n)
            }
        }
        relay: while true {
            var fds = [pollfd(fd: master, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: inputOpen ? input : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(input, &buffer, buffer.count)
                if n > 0 { _ = buffer.withUnsafeBytes { write(master, $0.baseAddress, n) } } else { inputOpen = false }
            }
            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = read(master, &buffer, buffer.count)
                if n <= 0 { break relay }
                emit(transform(buffer[..<n]))
            }
        }
        emit(finish())

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let exited = (status & 0x7f) == 0
        return exited ? (status >> 8) & 0xff : -(status & 0x7f)
    }
}

/// The Mac CLI's token store: the login Keychain through /usr/bin/security, so a rebuilt (re-signed)
/// development binary does not trigger a Keychain prompt on every run. The token goes in over
/// stdin (`security -i`), never in a process argument, and comes back over a pipe.
public struct SecurityCLITokenStore: MetaTokenStore {
    public let service: String
    public let account: String
    public init(service: String = "metastore-meta", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard MetaToken.isPlausible(token) else { throw TokenStoreError.malformed }
        return token
    }

    public func save(_ token: String) throws {
        guard MetaToken.isPlausible(token) else { throw TokenStoreError.malformed }
        let safe: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        guard safe(service), safe(account) else { throw TokenStoreError.malformed }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        input.fileHandleForWriting.write(Data("add-generic-password -U -s \(service) -a \(account) -w \(token)\n".utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0, (try? load()) == token else { throw TokenStoreError.keychain(p.terminationStatus) }
    }

    public func clear() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", account]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
    }
}
#endif
