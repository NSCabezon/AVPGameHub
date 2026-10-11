import Foundation

/// Long-lived credentials obtained from a QR login. The refresh token is what gets
/// persisted (Keychain / token file); it is sent as `access_token` in ClientLogon.
public struct SteamCredentials: Codable, Sendable {
    public var accountName: String
    public var refreshToken: String
    /// Steam Guard "remember this device" data from a credentials login (not a secret that
    /// signs in on its own; it only spares the e-mail code next time). Never the password.
    public var guardData: String?

    public init(accountName: String, refreshToken: String, guardData: String? = nil) {
        self.accountName = accountName
        self.refreshToken = refreshToken
        self.guardData = guardData
    }
}

/// A CDN content server as returned by GetServersForSteamPipe.
public struct CDNServer: Sendable, CustomStringConvertible {
    public let type: String
    public let host: String
    public let vhost: String
    public let httpsSupport: String
    public let load: Int32
    public let weightedLoad: Float
    public let allowedAppIDs: [UInt32]
    public let cellID: Int32
    public let priorityClass: UInt32

    /// Prefer HTTPS whenever supported (ATS on visionOS blocks plain HTTP by default).
    public var baseURL: String {
        httpsSupport == "none" || httpsSupport.isEmpty ? "http://\(host)" : "https://\(host)"
    }
    public var description: String { "\(type) \(host) (https: \(httpsSupport), load \(load))" }
}

public struct License: Sendable {
    public let packageID: UInt32
    public let accessToken: UInt64
}

/// High-level Steam client: connection, QR authentication, logon, PICS, content-system calls.
public actor SteamSession {
    let cm = CMConnection()
    public private(set) var licenses: [License] = []
    public private(set) var cellID: UInt32 = 0
    public private(set) var steamID: UInt64 = 0
    public private(set) var isLoggedOn = false
    /// From ClientAccountInfo, pushed after logon.
    public private(set) var personaName: String?
    /// From ClientPlayingSessionState: another session of this account is playing a game, so
    /// ClientGamesPlayed from this one is ignored until it stops.
    public private(set) var playingBlocked = false
    public private(set) var playingBlockedApp: UInt32 = 0
    private var licenseWaiters: [CheckedContinuation<Void, Never>] = []
    let logger: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logger = log
    }

    // MARK: connection

    public func connect() async throws { try await connect(skip: 0) }

    /// Connect to a CM; `skip` rotates through the list (used when retrying).
    func connect(skip: Int) async throws {
        let servers = try await CMConnection.fetchCMList()
        guard !servers.isEmpty else { throw SteamDepotError.connectionFailed("empty CM list") }
        await cm.setHandlers(log: logger, unsolicited: { [weak self] p in
            guard let self else { return }
            Task { await self.handleUnsolicited(p) }
        })
        var lastError: Error = SteamDepotError.connectionFailed("no CM tried")
        let rotated = Array(servers.dropFirst(skip % max(1, servers.count))) + Array(servers.prefix(skip % max(1, servers.count)))
        for endpoint in rotated.prefix(5) {
            do {
                logger("connecting to CM \(endpoint)")
                try await cm.connect(endpoint: endpoint)
                return
            } catch {
                lastError = error
                await cm.disconnect()
            }
        }
        throw lastError
    }

    public func disconnect() async {
        if isLoggedOn { try? await cm.send(emsg: EMsg.clientLogOff, body: Data()) }
        await cm.disconnect()
        isLoggedOn = false
    }

    private func handleUnsolicited(_ p: CMPacket) {
        switch p.emsg {
        case EMsg.clientLicenseList:
            guard let m = try? ProtoMessage(p.body), let list = try? m.messages(2) else { return }
            licenses = list.map { License(packageID: $0.u32(1) ?? 0, accessToken: $0.u64(17) ?? 0) }
            logger("received license list: \(licenses.count) licenses")
            let w = licenseWaiters; licenseWaiters = []
            w.forEach { $0.resume() }
        case EMsg.clientAccountInfo:
            if let name = (try? ProtoMessage(p.body))?.string(1), !name.isEmpty { personaName = name }
        case EMsg.clientPlayingSessionState:
            let m = try? ProtoMessage(p.body)
            playingBlocked = m?.bool(2) ?? false
            playingBlockedApp = m?.u32(3) ?? 0
            logger("playing session state: blocked=\(playingBlocked) app=\(playingBlockedApp)")
        case EMsg.clientLoggedOff:
            let r = (try? ProtoMessage(p.body))?.i32(1) ?? 0
            logger("logged off by server: EResult \(r)")
            isLoggedOn = false
        default:
            break
        }
    }

    // MARK: QR authentication

    public struct QRSession: Sendable {
        public var clientID: UInt64
        public let requestID: Data
        public let interval: TimeInterval
        public var challengeURL: String
    }

    /// IAuthenticationService.BeginAuthSessionViaQR
    public func beginQRAuth(deviceName: String) async throws -> QRSession {
        var w = ProtoWriter()
        w.string(1, deviceName)            // device_friendly_name
        w.uint(2, UInt32(1))               // platform_type = k_EAuthTokenPlatformType_SteamClient
        w.message(3) { d in                // device_details
            d.string(1, deviceName)
            d.uint(2, UInt32(1))
            d.int(3, 16)                   // os_type (Windows10; irrelevant for content)
        }
        w.string(4, "Client")              // website_id
        let resp = try await cm.serviceCall("Authentication.BeginAuthSessionViaQR#1", body: w.data, authed: false)
        guard resp.eresult == EResult.ok else { throw SteamDepotError.steamResult("BeginAuthSessionViaQR", resp.eresult) }
        let m = try ProtoMessage(resp.body)
        guard let clientID = m.u64(1), let url = m.string(2), let requestID = m.bytes(3) else {
            throw SteamDepotError.protocolError("BeginAuthSessionViaQR: missing fields")
        }
        return QRSession(clientID: clientID, requestID: requestID, interval: TimeInterval(m.float(4) ?? 5), challengeURL: url)
    }

    public enum QRPollResult: Sendable {
        case pending
        case challengeChanged(String)
        case done(SteamCredentials)
    }

    /// IAuthenticationService.PollAuthSessionStatus
    public func pollQRAuth(_ session: inout QRSession) async throws -> QRPollResult {
        var w = ProtoWriter()
        w.uint(1, session.clientID)
        w.bytes(2, session.requestID)
        let resp = try await cm.serviceCall("Authentication.PollAuthSessionStatus#1", body: w.data, authed: false)
        guard resp.eresult == EResult.ok else { throw SteamDepotError.steamResult("PollAuthSessionStatus", resp.eresult) }
        let m = try ProtoMessage(resp.body)
        if let newClient = m.u64(1), newClient != 0 { session.clientID = newClient }
        if let token = m.string(3), !token.isEmpty {
            return .done(SteamCredentials(accountName: m.string(6) ?? "", refreshToken: token))
        }
        if let url = m.string(2), !url.isEmpty, url != session.challengeURL {
            session.challengeURL = url
            return .challengeChanged(url)
        }
        return .pending
    }

    /// Full QR flow: begin, report challenge URLs, poll until approved.
    public func authenticateWithQR(deviceName: String = "SteamDepot",
                                   onChallenge: @Sendable (String) async -> Void) async throws -> SteamCredentials {
        var session = try await beginQRAuth(deviceName: deviceName)
        await onChallenge(session.challengeURL)
        while true {
            try await Task.sleep(nanoseconds: UInt64(max(1, session.interval) * 1_000_000_000))
            // CMs drop connections that have not logged on after ~60 s; the auth session
            // survives on Steam's side, so reconnect and keep polling the same client_id.
            let result: QRPollResult
            do {
                result = try await pollQRAuth(&session)
            } catch SteamDepotError.connectionFailed(let why) {
                logger("CM connection lost during QR polling (\(why)); reconnecting")
                await cm.disconnect()
                try await connect()
                continue
            } catch SteamDepotError.timeout(let why) {
                logger("QR poll timed out (\(why)); reconnecting")
                await cm.disconnect()
                try await connect()
                continue
            }
            switch result {
            case .pending: continue
            case .challengeChanged(let url): await onChallenge(url)
            case .done(let creds): return creds
            }
        }
    }

    // MARK: logon

    /// ClientLogon with a refresh token (sent as access_token, as SteamKit/DepotDownloader do).
    /// Log on, retrying on another CM if one does not answer (CMs occasionally swallow ClientLogon).
    public func logOn(_ creds: SteamCredentials, machineName: String = "SteamDepot") async throws {
        var attempt = 0
        while true {
            do {
                return try await logOnOnce(creds, machineName: machineName)
            } catch let e as SteamDepotError {
                switch e {
                case .timeout, .connectionFailed:
                    attempt += 1
                    guard attempt < 4 else { throw e }
                    logger("logon attempt \(attempt) failed (\(e)); reconnecting to another CM")
                    await cm.disconnect()
                    try await connect(skip: attempt)
                case .logonFailed(let r) where r == EResult.tryAnotherCM || r == EResult.serviceUnavailable:
                    attempt += 1
                    guard attempt < 4 else { throw e }
                    await cm.disconnect()
                    try await connect(skip: attempt)
                default:
                    throw e
                }
            }
        }
    }

    private func logOnOnce(_ creds: SteamCredentials, machineName: String) async throws {
        // SteamID(account 0, instance 1 (desktop), universe Public, type Individual)
        await cm.setSteamID(0x0110_0001_0000_0000, session: 0)
        var w = ProtoWriter()
        w.uint(1, steamProtocolVersion)
        let loginID = UInt32.random(in: 1...UInt32.max)
        w.uint(2, loginID ^ 0xBAAD_F00D)                 // deprecated_obfustucated_private_ip
        w.uint(3, UInt32(0))                             // cell_id
        w.uint(5, UInt32(1771))                          // client_package_version
        w.string(6, "english")
        w.int(7, 16)                                     // client_os_type
        w.bool(8, true)                                  // should_remember_password
        w.message(11) { ip in ip.fixed32(1, loginID ^ 0xBAAD_F00D) }
        w.string(50, creds.accountName)
        w.string(96, machineName)
        w.bool(102, true)                                // supports_rate_limit_response
        w.string(108, creds.refreshToken)                // access_token
        let resp = try await cm.sendAndWait(emsg: EMsg.clientLogon, body: w.data, responseEmsg: EMsg.clientLogOnResponse, timeout: 15)
        let m = try ProtoMessage(resp.body)
        let result = m.i32(1) ?? EResult.fail
        guard result == EResult.ok else { throw SteamDepotError.logonFailed(result) }
        let h = resp.headerMessage
        steamID = h?.u64(1) ?? 0
        await cm.setSteamID(steamID, session: h?.i32(2) ?? 0)
        cellID = m.u32(7) ?? 0
        let hb = Int(m.i32(3) ?? m.i32(2) ?? 9)
        await cm.startHeartbeat(seconds: hb > 0 ? hb : 9)
        isLoggedOn = true
        logger("logged on as steamid \(steamID), cell \(cellID)")
    }

    /// Wait (briefly) for the license list that Steam pushes after logon.
    public func waitForLicenses(timeout: TimeInterval = 10) async {
        if !licenses.isEmpty { return }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await withCheckedContinuation { c in Task { await self.addLicenseWaiter(c) } } }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await g.next()
            g.cancelAll()
            await self.flushLicenseWaiters()
        }
    }
    private func addLicenseWaiter(_ c: CheckedContinuation<Void, Never>) {
        if !licenses.isEmpty { c.resume() } else { licenseWaiters.append(c) }
    }
    private func flushLicenseWaiters() { let w = licenseWaiters; licenseWaiters = []; w.forEach { $0.resume() } }

    // MARK: PICS

    /// Returns app access token (0 if none/denied).
    public func picsAccessToken(app: UInt32) async throws -> UInt64 {
        var w = ProtoWriter()
        w.uint(2, app)
        let resp = try await cm.call(emsg: EMsg.clientPICSAccessTokenRequest, body: w.data)
        let m = try ProtoMessage(resp[0].body)
        for t in try m.messages(3) where t.u32(1) == app { return t.u64(2) ?? 0 }
        if m.u32s(4).contains(app) { logger("PICS access token denied for app \(app)") }
        return 0
    }

    /// Returns the app's KeyValues ("appinfo" root).
    public func appInfo(app: UInt32) async throws -> KeyValue {
        let token = try await picsAccessToken(app: app)
        var w = ProtoWriter()
        w.message(2) { a in
            a.uint(1, app)
            if token != 0 { a.uint(2, token) }
        }
        w.bool(7, true) // single_response
        let packets = try await cm.call(emsg: EMsg.clientPICSProductInfoRequest, body: w.data, timeout: 60, isDone: { p in
            ((try? ProtoMessage(p.body))?.bool(6) ?? false) == false // until !response_pending
        })
        for p in packets {
            let m = try ProtoMessage(p.body)
            for a in try m.messages(1) where a.u32(1) == app {
                if a.bool(3) == true { logger("PICS: missing_token for app \(app)") }
                guard var buf = a.bytes(5), !buf.isEmpty else {
                    throw SteamDepotError.protocolError("PICS: no inline buffer for app \(app) (http_host=\(m.string(8) ?? "-"))")
                }
                if buf.last == 0 { buf.removeLast() }
                return try KeyValue.parse(text: String(decoding: buf, as: UTF8.self))
            }
            if m.u32s(2).contains(app) { throw SteamDepotError.notOwned("PICS: unknown app \(app)") }
        }
        throw SteamDepotError.protocolError("PICS: app \(app) not in response")
    }

    /// PICS access tokens for many apps at once (apps the server denies or that need none map to 0
    /// or are absent).
    public func picsAccessTokens(apps: [UInt32]) async throws -> [UInt32: UInt64] {
        guard !apps.isEmpty else { return [:] }
        var w = ProtoWriter()
        for app in apps { w.uint(2, app) }
        let resp = try await cm.call(emsg: EMsg.clientPICSAccessTokenRequest, body: w.data)
        let m = try ProtoMessage(resp[0].body)
        var out: [UInt32: UInt64] = [:]
        for t in try m.messages(3) { if let id = t.u32(1) { out[id] = t.u64(2) ?? 0 } }
        return out
    }

    /// One app or package from a PICS product info response.
    public struct PICSItem: Sendable {
        public let changeNumber: UInt32
        /// Parsed KeyValues; nil for a metadata-only request or when no inline buffer came back.
        public let kv: KeyValue?
        public let missingToken: Bool
    }

    /// Batched PICS product info. Packages are parsed from their binary KeyValues buffer,
    /// apps from text VDF. Items Steam does not return are absent rather than failing the batch.
    ///
    /// No `single_response` here (unlike `appInfo(app:)`): with it set, Steam cuts a response
    /// larger than ~256 KB, flags `response_pending` and never sends the rest. Without it the
    /// remainder arrives as further packets on the same job, which is what SteamKit expects.
    public func productInfo(packages: [(id: UInt32, token: UInt64)] = [],
                            apps: [(id: UInt32, token: UInt64)] = [],
                            metaDataOnly: Bool = false,
                            timeout: TimeInterval = 60) async throws
        -> (packages: [UInt32: PICSItem], apps: [UInt32: PICSItem]) {
        var w = ProtoWriter()
        for p in packages {
            w.message(1) { m in m.uint(1, p.id); if p.token != 0 { m.uint(2, p.token) } }
        }
        for a in apps {
            w.message(2) { m in m.uint(1, a.id); if a.token != 0 { m.uint(2, a.token) } }
        }
        if metaDataOnly { w.bool(3, true) }
        let packets = try await cm.call(emsg: EMsg.clientPICSProductInfoRequest, body: w.data, timeout: timeout, isDone: { p in
            ((try? ProtoMessage(p.body))?.bool(6) ?? false) == false // until !response_pending
        })
        var outPackages: [UInt32: PICSItem] = [:]
        var outApps: [UInt32: PICSItem] = [:]
        for p in packets {
            let m = try ProtoMessage(p.body)
            for a in try m.messages(1) {
                guard let id = a.u32(1) else { continue }
                var kv: KeyValue?
                if var buf = a.bytes(5), !buf.isEmpty {
                    if buf.last == 0 { buf.removeLast() }
                    do { kv = try KeyValue.parse(text: String(decoding: buf, as: UTF8.self)) }
                    catch { logger("PICS: could not parse app \(id): \(error)") }
                } else if !metaDataOnly {
                    logger("PICS: no inline buffer for app \(id) (http_host=\(m.string(8) ?? "-"))")
                }
                outApps[id] = PICSItem(changeNumber: a.u32(2) ?? 0, kv: kv, missingToken: a.bool(3) ?? false)
            }
            for pkg in try m.messages(3) {
                guard let id = pkg.u32(1) else { continue }
                var kv: KeyValue?
                // Buffer = uint32 header (steamclient checks it is 1) + binary KeyValues.
                if let buf = pkg.bytes(5), buf.count > 4 {
                    do { kv = try KeyValue.parseBinary(buf.dropFirst(4)) }
                    catch { logger("PICS: could not parse package \(id): \(error)") }
                }
                outPackages[id] = PICSItem(changeNumber: pkg.u32(2) ?? 0, kv: kv, missingToken: pkg.bool(3) ?? false)
            }
        }
        return (outPackages, outApps)
    }

    public struct PICSChanges: Sendable {
        public let currentChangeNumber: UInt32
        /// The server could not list app / package changes since the given number (too old).
        public let fullAppUpdate: Bool
        public let fullPackageUpdate: Bool
        public let apps: [UInt32: UInt32]       // appid -> change number
        public let packages: [UInt32: UInt32]   // packageid -> change number
    }

    /// ClientPICSChangesSinceRequest: every app/package (Steam-wide) changed since a PICS change
    /// number, plus the current one. With `includeLists` false it is just a cheap way to read the
    /// current change number.
    public func picsChanges(since: UInt32, includeLists: Bool = true) async throws -> PICSChanges {
        var w = ProtoWriter()
        w.uint(1, since)
        w.bool(2, includeLists)
        w.bool(3, includeLists)
        let resp = try await cm.call(emsg: EMsg.clientPICSChangesSinceRequest, body: w.data, timeout: 60)
        let m = try ProtoMessage(resp[0].body)
        var apps: [UInt32: UInt32] = [:]
        var packages: [UInt32: UInt32] = [:]
        for c in try m.messages(5) { if let id = c.u32(1) { apps[id] = c.u32(2) ?? 0 } }
        for c in try m.messages(4) { if let id = c.u32(1) { packages[id] = c.u32(2) ?? 0 } }
        let full = m.bool(3) ?? false
        return PICSChanges(currentChangeNumber: m.u32(1) ?? 0,
                           fullAppUpdate: full || (m.bool(6) ?? false),
                           fullPackageUpdate: full || (m.bool(7) ?? false),
                           apps: apps, packages: packages)
    }

    // MARK: content

    /// ClientGetDepotDecryptionKey. Fails with AccessDenied when the account does not own the depot.
    public func depotKey(depot: UInt32, app: UInt32) async throws -> Data {
        var w = ProtoWriter()
        w.uint(1, depot)
        w.uint(2, app)
        let resp = try await cm.call(emsg: EMsg.clientGetDepotDecryptionKey, body: w.data)
        let m = try ProtoMessage(resp[0].body)
        let r = m.i32(1) ?? EResult.fail
        guard r == EResult.ok, let key = m.bytes(3), key.count == 32 else {
            if r == EResult.accessDenied { throw SteamDepotError.notOwned("depot \(depot)") }
            throw SteamDepotError.steamResult("GetDepotDecryptionKey(\(depot))", r)
        }
        return key
    }

    public func manifestRequestCode(app: UInt32, depot: UInt32, manifest: UInt64, branch: String = "public") async throws -> UInt64 {
        var w = ProtoWriter()
        w.uint(1, app)
        w.uint(2, depot)
        w.uint(3, manifest)
        w.string(4, branch)
        let resp = try await cm.serviceCall("ContentServerDirectory.GetManifestRequestCode#1", body: w.data, authed: true)
        guard resp.eresult == EResult.ok else { throw SteamDepotError.steamResult("GetManifestRequestCode", resp.eresult) }
        return try ProtoMessage(resp.body).u64(1) ?? 0
    }

    public func cdnServers(maxServers: UInt32 = 20) async throws -> [CDNServer] {
        var w = ProtoWriter()
        w.uint(1, cellID)
        w.uint(2, maxServers)
        let resp = try await cm.serviceCall("ContentServerDirectory.GetServersForSteamPipe#1", body: w.data, authed: true)
        guard resp.eresult == EResult.ok else { throw SteamDepotError.steamResult("GetServersForSteamPipe", resp.eresult) }
        return try ProtoMessage(resp.body).messages(1).map { s in
            CDNServer(type: s.string(1) ?? "", host: s.string(8) ?? "", vhost: s.string(9) ?? "",
                      httpsSupport: s.string(12) ?? "", load: s.i32(4) ?? 0, weightedLoad: s.float(5) ?? 0,
                      allowedAppIDs: s.u32s(13), cellID: s.i32(3) ?? 0, priorityClass: s.u32(15) ?? 0)
        }
    }

    /// Returns (token, expiration) or nil if the server says none is needed / unavailable.
    public func cdnAuthToken(app: UInt32, depot: UInt32, host: String) async throws -> String? {
        var w = ProtoWriter()
        w.uint(1, depot)
        w.string(2, host)
        w.uint(3, app)
        let resp = try await cm.serviceCall("ContentServerDirectory.GetCDNAuthToken#1", body: w.data, authed: true)
        guard resp.eresult == EResult.ok else { return nil }
        return try ProtoMessage(resp.body).string(1)
    }
}

extension CMConnection {
    func setSteamID(_ id: UInt64, session: Int32) {
        steamID = id
        sessionID = session
    }
}
