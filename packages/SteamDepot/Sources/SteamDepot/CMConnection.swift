import Foundation

/// A decoded Steam CM packet (protobuf-flavoured only).
struct CMPacket: Sendable {
    let emsg: UInt32
    let header: Data
    let body: Data

    var headerMessage: ProtoMessage? { try? ProtoMessage(header) }
    /// CMsgProtoBufHeader.jobid_target (11)
    var jobTarget: UInt64 { headerMessage?.u64(11) ?? UInt64.max }
    /// CMsgProtoBufHeader.eresult (13), default 2 (Fail)
    var eresult: Int32 { headerMessage?.i32(13) ?? EResult.fail }
    var errorMessage: String? { headerMessage?.string(14) }
}

/// One WebSocket connection to a Steam Connection Manager.
/// Handles framing, Multi unpacking, job routing, heartbeats.
actor CMConnection {
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private var nextJobID: UInt64 = 1
    private var jobWaiters: [UInt64: JobWaiter] = [:]
    private var emsgWaiters: [UInt32: [(id: UInt64, cont: CheckedContinuation<CMPacket, Error>)]] = [:]
    private(set) var isConnected = false
    private(set) var closeReason: String?

    var steamID: UInt64 = 0
    var sessionID: Int32 = 0

    /// Messages that arrive unsolicited (license list etc.).
    var unsolicitedHandler: (@Sendable (CMPacket) -> Void)?
    var log: (@Sendable (String) -> Void)?

    final class JobWaiter {
        var packets: [CMPacket] = []
        let isDone: (CMPacket) -> Bool
        let continuation: CheckedContinuation<[CMPacket], Error>
        init(isDone: @escaping (CMPacket) -> Bool, continuation: CheckedContinuation<[CMPacket], Error>) {
            self.isDone = isDone
            self.continuation = continuation
        }
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    func setHandlers(log: (@Sendable (String) -> Void)?, unsolicited: (@Sendable (CMPacket) -> Void)?) {
        self.log = log
        self.unsolicitedHandler = unsolicited
    }

    // MARK: connect

    static func fetchCMList() async throws -> [String] {
        let url = URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets")!
        let (data, _) = try await URLSession.shared.data(from: url)
        struct R: Decodable {
            struct Resp: Decodable { let serverlist: [S] }
            struct S: Decodable { let endpoint: String; let type: String; let wtd_load: Double? }
            let response: Resp
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.response.serverlist.filter { $0.type == "websockets" }.map(\.endpoint)
    }

    func connect(endpoint: String) async throws {
        guard let url = URL(string: "wss://\(endpoint)/cmsocket/") else { throw SteamDepotError.connectionFailed("bad endpoint \(endpoint)") }
        let ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws
        ws.resume()
        isConnected = true
        closeReason = nil
        // Make sure the socket is actually open before talking (and fail fast on a dead CM).
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ws.sendPing { error in
                if let error { c.resume(throwing: SteamDepotError.connectionFailed(error.localizedDescription)) } else { c.resume() }
            }
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        // ClientHello is what SteamKit sends right after the socket opens.
        var hello = ProtoWriter()
        hello.uint(1, steamProtocolVersion)
        try await send(emsg: EMsg.clientHello, body: hello.data)
    }

    func disconnect() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        receiveTask?.cancel(); receiveTask = nil
        failAll(SteamDepotError.connectionFailed("disconnected"))
        isConnected = false
    }

    func startHeartbeat(seconds: Int) {
        heartbeatTask?.cancel()
        let interval = UInt64(max(5, seconds)) * 1_000_000_000
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }
                try? await self.send(emsg: EMsg.clientHeartBeat, body: Data())
            }
        }
    }

    // MARK: send

    private func buildHeader(sourceJob: UInt64?, targetJobName: String?, extra: ((inout ProtoWriter) -> Void)?) -> Data {
        var h = ProtoWriter()
        h.fixed64(1, steamID)
        h.int(2, sessionID)
        if let sourceJob { h.fixed64(10, sourceJob) }
        h.string(12, targetJobName)
        extra?(&h)
        return h.data
    }

    func send(emsg: UInt32, body: Data, sourceJob: UInt64? = nil, targetJobName: String? = nil,
              headerExtra: ((inout ProtoWriter) -> Void)? = nil) async throws {
        guard let socket, isConnected else { throw SteamDepotError.connectionFailed(closeReason ?? "not connected") }
        let header = buildHeader(sourceJob: sourceJob, targetJobName: targetJobName, extra: headerExtra)
        var packet = Data(capacity: 8 + header.count + body.count)
        packet.appendLE(emsg | 0x8000_0000)
        packet.appendLE(UInt32(header.count))
        packet.append(header)
        packet.append(body)
        try await socket.send(.data(packet))
    }

    /// Send a message with a fresh source job id and collect responses targeted at it
    /// until `isDone` returns true for one of them.
    func call(emsg: UInt32, body: Data, targetJobName: String? = nil, timeout: TimeInterval = 30,
              headerExtra: ((inout ProtoWriter) -> Void)? = nil,
              isDone: @escaping (CMPacket) -> Bool = { _ in true }) async throws -> [CMPacket] {
        let job = nextJobID
        nextJobID += 1
        let name = targetJobName ?? "emsg \(emsg)"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CMPacket], Error>) in
            jobWaiters[job] = JobWaiter(isDone: isDone, continuation: cont)
            Task {
                do {
                    try await self.send(emsg: emsg, body: body, sourceJob: job, targetJobName: targetJobName, headerExtra: headerExtra)
                } catch {
                    self.failJob(job, error)
                }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.failJob(job, SteamDepotError.timeout(name))
            }
        }
    }

    /// Unified service method call (e.g. "Authentication.BeginAuthSessionViaQR#1").
    func serviceCall(_ method: String, body: Data, authed: Bool, timeout: TimeInterval = 30) async throws -> CMPacket {
        let emsg = authed ? EMsg.serviceMethodCallFromClient : EMsg.serviceMethodCallFromClientNonAuthed
        let packets = try await call(emsg: emsg, body: body, targetJobName: method, timeout: timeout)
        guard let p = packets.first else { throw SteamDepotError.protocolError("no response for \(method)") }
        return p
    }

    /// Send a message and wait for the next message of `responseEmsg` (registered before sending).
    func sendAndWait(emsg: UInt32, body: Data, responseEmsg: UInt32, timeout: TimeInterval = 30) async throws -> CMPacket {
        let id = nextJobID
        nextJobID += 1
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CMPacket, Error>) in
            emsgWaiters[responseEmsg, default: []].append((id, cont))
            Task {
                do { try await self.send(emsg: emsg, body: body) } catch { self.failEmsg(responseEmsg, id: id, error) }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.timeoutEmsg(responseEmsg, id: id)
            }
        }
    }

    private func failEmsg(_ emsg: UInt32, id: UInt64, _ error: Error) {
        guard var list = emsgWaiters[emsg], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let c = list.remove(at: i).cont
        emsgWaiters[emsg] = list.isEmpty ? nil : list
        c.resume(throwing: error)
    }

    /// Wait for the next message of a given EMsg (not job-routed).
    func waitFor(_ emsg: UInt32, timeout: TimeInterval = 30) async throws -> CMPacket {
        let id = nextJobID
        nextJobID += 1
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CMPacket, Error>) in
            emsgWaiters[emsg, default: []].append((id, cont))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.timeoutEmsg(emsg, id: id)
            }
        }
    }

    private func timeoutEmsg(_ emsg: UInt32, id: UInt64) {
        guard var list = emsgWaiters[emsg], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let c = list.remove(at: i).cont
        emsgWaiters[emsg] = list.isEmpty ? nil : list
        c.resume(throwing: SteamDepotError.timeout("waiting for emsg \(emsg)"))
    }

    private func failJob(_ job: UInt64, _ error: Error) {
        guard let w = jobWaiters.removeValue(forKey: job) else { return }
        w.continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        for (_, w) in jobWaiters { w.continuation.resume(throwing: error) }
        jobWaiters.removeAll()
        for (_, list) in emsgWaiters { for w in list { w.cont.resume(throwing: error) } }
        emsgWaiters.removeAll()
    }

    // MARK: receive

    private func receiveLoop() async {
        while let socket, !Task.isCancelled {
            do {
                let msg = try await socket.receive()
                switch msg {
                case .data(let d): handleRaw(d)
                case .string: break
                @unknown default: break
                }
            } catch {
                guard self.socket === socket else { return } // stale loop from a previous connection
                if isConnected {
                    closeReason = "\(error.localizedDescription) (close code \(socket.closeCode.rawValue))"
                    log?("CM socket closed: \(closeReason!)")
                }
                isConnected = false
                heartbeatTask?.cancel()
                failAll(SteamDepotError.connectionFailed(closeReason ?? "socket closed"))
                return
            }
        }
    }

    private func handleRaw(_ data: Data) {
        do {
            var r = ByteReader(data)
            let rawEmsg = try r.u32()
            let emsg = rawEmsg & ~0x8000_0000
            guard rawEmsg & 0x8000_0000 != 0 else {
                log?("ignoring non-protobuf message emsg=\(emsg)")
                return
            }
            let hlen = Int(try r.u32())
            let header = try r.take(hlen)
            let body = data.subdata(in: r.pos..<data.endIndex)
            let packet = CMPacket(emsg: emsg, header: header, body: body)
            if emsg == EMsg.multi {
                try handleMulti(packet)
            } else {
                dispatch(packet)
            }
        } catch {
            log?("bad packet: \(error)")
        }
    }

    private func handleMulti(_ packet: CMPacket) throws {
        let m = try ProtoMessage(packet.body)
        var payload = m.bytes(2) ?? Data()
        if let unzipped = m.u32(1), unzipped > 0 {
            payload = try Inflate.gunzip(payload, expectedSize: Int(unzipped))
        }
        var r = ByteReader(payload)
        while r.remaining >= 4 {
            let len = Int(try r.u32())
            handleRaw(try r.take(len))
        }
    }

    private func dispatch(_ packet: CMPacket) {
        let target = packet.jobTarget
        if target != UInt64.max, let w = jobWaiters[target] {
            w.packets.append(packet)
            if w.isDone(packet) {
                jobWaiters.removeValue(forKey: target)
                w.continuation.resume(returning: w.packets)
            }
            return
        }
        if var list = emsgWaiters[packet.emsg], !list.isEmpty {
            let c = list.removeFirst().cont
            emsgWaiters[packet.emsg] = list.isEmpty ? nil : list
            c.resume(returning: packet)
            return
        }
        unsolicitedHandler?(packet)
    }
}
