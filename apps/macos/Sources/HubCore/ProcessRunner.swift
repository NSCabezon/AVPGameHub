import Foundation

/// Splits a byte stream into lines. `\n`, `\r\n` and a bare `\r` (progress redraws) all end a
/// line; an incomplete tail is kept until more data (or `flush`) arrives.
public final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    public init() {}

    public func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        var i = pending.startIndex
        while i < pending.endIndex {
            let b = pending[i]
            if b == 0x0A || b == 0x0D {
                lines.append(String(decoding: pending[start..<i], as: UTF8.self))
                // \r\n counts once
                if b == 0x0D, pending.index(after: i) < pending.endIndex, pending[pending.index(after: i)] == 0x0A {
                    i = pending.index(after: i)
                }
                start = pending.index(after: i)
            }
            i = pending.index(after: i)
        }
        pending = Data(pending[start...])
        return lines
    }

    public func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let s = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return [s]
    }
}

/// A command to run: executable + arguments, extra environment on top of this process's, and a
/// working directory.
public struct ShellCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String] = [:],
                currentDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// `/bin/bash -c script` (login-less; PATH is fixed up by `resolvedEnvironment`).
    public static func bash(_ script: String, environment: [String: String] = [:], currentDirectory: String? = nil) -> ShellCommand {
        ShellCommand("/bin/bash", ["-c", script], environment: environment, currentDirectory: currentDirectory)
    }

    /// `xcrun devicectl ...`
    public static func devicectl(_ arguments: [String]) -> ShellCommand {
        ShellCommand("/usr/bin/xcrun", ["devicectl"] + arguments)
    }

    /// How it reads in a log header.
    public var display: String {
        ([executable] + arguments).map { $0.contains(" ") || $0.isEmpty ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// The environment the child gets. A Finder-launched app has a minimal PATH, so Homebrew's
    /// and /usr/local's bins are appended (python3, apktool, git…).
    public func resolvedEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in extra where !path.contains(p) { path.append(p) }
        env["PATH"] = path.joined(separator: ":")
        for (k, v) in environment { env[k] = v }
        return env
    }
}

/// Runs one process at a time, streaming merged stdout+stderr line by line. Cancel terminates
/// the whole process tree (build scripts spawn xcodebuild, devicectl…), then kills it.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    public init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public var pid: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    /// `onExit` is called once with the exit status (negative = killed by that signal). Output
    /// from background children that outlive the process may still arrive afterwards.
    public func start(_ command: ShellCommand,
                      onLine: @escaping @Sendable (String) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command.executable)
        p.arguments = command.arguments
        p.environment = command.resolvedEnvironment()
        if let dir = command.currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                for l in buffer.flush() { onLine(l) }
                return
            }
            for l in buffer.append(data) { onLine(l) }
        }
        p.terminationHandler = { proc in
            let status = proc.terminationReason == .uncaughtSignal ? -proc.terminationStatus : proc.terminationStatus
            // Let the reader drain what the process wrote just before it ended.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { onExit(status) }
        }
        lock.lock()
        process = p
        lock.unlock()
        try p.run()
    }

    /// SIGTERM to the process and every descendant; SIGKILL to whatever is left after 3 s.
    public func cancel() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        let tree = ProcessTree.descendants(of: p.processIdentifier) + [p.processIdentifier]
        for pid in tree { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Run to completion and return status + all output. For short probes (status checks).
    public static func capture(_ command: ShellCommand, timeout: TimeInterval = 60) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let runner = ProcessRunner()
            let out = OutputCollector()
            let once = Once()
            do {
                try runner.start(command, onLine: { out.add($0) }, onExit: { status in
                    once.run { cont.resume(returning: (status, out.text)) }
                })
            } catch {
                once.run { cont.resume(returning: (-1, "\(error)")) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if runner.isRunning {
                    runner.cancel()
                    once.run { cont.resume(returning: (-2, out.text + "\n(timed out after \(Int(timeout)) s)")) }
                }
            }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

public enum ProcessTree {
    /// Every descendant pid, deepest first (via `pgrep -P`).
    public static func descendants(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        for child in children(of: pid) {
            out += descendants(of: child)
            out.append(child)
        }
        return out
    }

    static func children(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }
}
