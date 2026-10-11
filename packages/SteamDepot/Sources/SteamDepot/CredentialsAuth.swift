import Foundation
import Security

/// Steam Guard confirmation kinds (EAuthSessionGuardType).
public enum SteamGuardType: Int32, Sendable, CustomStringConvertible {
    case unknown = 0, none = 1, emailCode = 2, deviceCode = 3, deviceConfirmation = 4,
         emailConfirmation = 5, machineToken = 6, legacyMachineAuth = 7

    public var description: String {
        switch self {
        case .none: return "none"
        case .emailCode: return "e-mail code"
        case .deviceCode: return "Steam Guard code"
        case .deviceConfirmation: return "approve in the Steam app"
        case .emailConfirmation: return "approve by e-mail"
        case .machineToken: return "machine token"
        default: return "unknown"
        }
    }
}

/// An in-progress username/password authentication (IAuthenticationService), as the
/// Steam client / Steam Deck do it. The password is used once, RSA-encrypted, and dropped.
public struct CredentialsAuthSession: Sendable {
    public let accountName: String
    public var clientID: UInt64
    public let requestID: Data
    public let steamID: UInt64
    public let interval: TimeInterval
    public let allowed: [(type: SteamGuardType, message: String)]

    public var allowedTypes: [SteamGuardType] { allowed.map(\.type) }
    public var needsCode: SteamGuardType? {
        allowedTypes.first { $0 == .deviceCode } ?? allowedTypes.first { $0 == .emailCode }
    }
    public var canApproveOnDevice: Bool { allowedTypes.contains(.deviceConfirmation) }
    public var canApproveByEmail: Bool { allowedTypes.contains(.emailConfirmation) }
    public var needsNothing: Bool { allowedTypes.isEmpty || allowedTypes.contains(.none) }
}

public enum AuthPollResult: Sendable {
    case pending
    case challengeChanged(String)
    case done(SteamCredentials)
}

extension SteamSession {
    /// IAuthenticationService.GetPasswordRSAPublicKey + BeginAuthSessionViaCredentials.
    public func beginCredentialsAuth(accountName: String, password: String, deviceName: String,
                                     guardData: String? = nil, persistent: Bool = true) async throws -> CredentialsAuthSession {
        var kreq = ProtoWriter()
        kreq.string(1, accountName)
        let kresp = try await cm.serviceCall("Authentication.GetPasswordRSAPublicKey#1", body: kreq.data, authed: false)
        guard kresp.eresult == EResult.ok else { throw SteamDepotError.steamResult("GetPasswordRSAPublicKey", kresp.eresult) }
        let km = try ProtoMessage(kresp.body)
        guard let modHex = km.string(1), let expHex = km.string(2), let ts = km.u64(3) else {
            throw SteamDepotError.protocolError("GetPasswordRSAPublicKey: missing fields")
        }
        let encrypted = try Self.rsaEncrypt(Data(password.utf8), modulusHex: modHex, exponentHex: expHex)

        var w = ProtoWriter()
        w.string(1, deviceName)                                  // device_friendly_name
        w.string(2, accountName)
        w.string(3, encrypted.base64EncodedString())             // encrypted_password
        w.uint(4, ts)                                            // encryption_timestamp
        w.bool(5, persistent)                                    // remember_login
        w.uint(6, UInt32(1))                                     // platform_type = SteamClient
        w.uint(7, UInt32(persistent ? 1 : 0))                    // persistence
        w.string(8, "Client")                                    // website_id
        w.message(9) { d in                                      // device_details
            d.string(1, deviceName)
            d.uint(2, UInt32(1))
            d.int(3, 16)
        }
        w.string(10, guardData)
        let resp = try await cm.serviceCall("Authentication.BeginAuthSessionViaCredentials#1", body: w.data, authed: false)
        guard resp.eresult == EResult.ok else {
            let extra = (try? ProtoMessage(resp.body))?.string(8)
            if resp.eresult == EResult.invalidPassword { throw SteamDepotError.authFailed("wrong account name or password") }
            throw SteamDepotError.steamResult("BeginAuthSessionViaCredentials" + (extra.map { " (\($0))" } ?? ""), resp.eresult)
        }
        let m = try ProtoMessage(resp.body)
        guard let clientID = m.u64(1), let requestID = m.bytes(2) else {
            throw SteamDepotError.protocolError("BeginAuthSessionViaCredentials: missing fields")
        }
        let allowed = try m.messages(4).map { a in
            (type: SteamGuardType(rawValue: a.i32(1) ?? 0) ?? .unknown, message: a.string(2) ?? "")
        }
        logger("credentials auth started; allowed confirmations: \(allowed.map { $0.type.description })")
        return CredentialsAuthSession(accountName: accountName, clientID: clientID, requestID: requestID,
                                      steamID: m.u64(5) ?? 0, interval: TimeInterval(m.float(3) ?? 5), allowed: allowed)
    }

    /// IAuthenticationService.UpdateAuthSessionWithSteamGuardCode. Throws `.steamResult` with
    /// EResult 88 (TwoFactorCodeMismatch) / 65 (InvalidLoginAuthCode) on a wrong code — retryable.
    public func submitGuardCode(_ session: CredentialsAuthSession, code: String, type: SteamGuardType) async throws {
        var w = ProtoWriter()
        w.uint(1, session.clientID)
        w.fixed64(2, session.steamID)
        w.string(3, code.trimmingCharacters(in: .whitespacesAndNewlines))
        w.uint(4, UInt32(type.rawValue))
        let resp = try await cm.serviceCall("Authentication.UpdateAuthSessionWithSteamGuardCode#1", body: w.data, authed: false)
        // DuplicateRequest (29) means it was already accepted.
        guard resp.eresult == EResult.ok || resp.eresult == 29 else {
            throw SteamDepotError.steamResult("Steam Guard code", resp.eresult)
        }
    }

    /// One PollAuthSessionStatus call (works for QR and credentials sessions).
    public func pollAuth(clientID: inout UInt64, requestID: Data, currentURL: String? = nil,
                         fallbackAccount: String = "") async throws -> AuthPollResult {
        var w = ProtoWriter()
        w.uint(1, clientID)
        w.bytes(2, requestID)
        let resp = try await cm.serviceCall("Authentication.PollAuthSessionStatus#1", body: w.data, authed: false)
        guard resp.eresult == EResult.ok else { throw SteamDepotError.steamResult("PollAuthSessionStatus", resp.eresult) }
        let m = try ProtoMessage(resp.body)
        if let newClient = m.u64(1), newClient != 0 { clientID = newClient }
        if let token = m.string(3), !token.isEmpty {
            let guardData = m.string(7).flatMap { $0.isEmpty ? nil : $0 }
            return .done(SteamCredentials(accountName: m.string(6).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackAccount,
                                          refreshToken: token, guardData: guardData))
        }
        if let url = m.string(2), !url.isEmpty, url != currentURL { return .challengeChanged(url) }
        return .pending
    }

    /// Poll a credentials session until Steam issues tokens (after phone approval, a submitted
    /// code, or immediately when no confirmation is required). Reconnects if the CM drops us.
    public func waitForCredentialsAuth(_ session: CredentialsAuthSession) async throws -> SteamCredentials {
        var clientID = session.clientID
        while true {
            try Task.checkCancellation()
            let result: AuthPollResult
            do {
                result = try await pollAuth(clientID: &clientID, requestID: session.requestID, fallbackAccount: session.accountName)
            } catch let e as SteamDepotError {
                switch e {
                case .connectionFailed, .timeout:
                    logger("CM connection lost during auth polling (\(e)); reconnecting")
                    await cm.disconnect()
                    try await connect()
                    continue
                default: throw e
                }
            }
            if case .done(var creds) = result {
                if creds.accountName.isEmpty { creds.accountName = session.accountName }
                return creds
            }
            try await Task.sleep(nanoseconds: UInt64(max(1, session.interval) * 1_000_000_000))
        }
    }

    // MARK: RSA

    /// PKCS#1 v1.5 encryption with Steam's per-account RSA key (hex modulus/exponent).
    static func rsaEncrypt(_ plain: Data, modulusHex: String, exponentHex: String) throws -> Data {
        guard var mod = Data(hex: modulusHex), let exp = Data(hex: exponentHex) else {
            throw SteamDepotError.protocolError("bad RSA key")
        }
        let bits = mod.count * 8
        if let first = mod.first, first & 0x80 != 0 { mod.insert(0, at: 0) } // positive INTEGER
        var e = exp
        if let first = e.first, first & 0x80 != 0 { e.insert(0, at: 0) }
        func der(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag])
            let n = body.count
            if n < 0x80 { d.append(UInt8(n)) } else {
                var len = Data(); var v = n
                while v > 0 { len.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
                d.append(0x80 | UInt8(len.count)); d.append(len)
            }
            d.append(body)
            return d
        }
        let pkcs1 = der(0x30, der(0x02, mod) + der(0x02, e))     // RSAPublicKey
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                    kSecAttrKeySizeInBits as String: bits]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err) else {
            throw SteamDepotError.protocolError("RSA key import failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let out = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plain as CFData, &err) else {
            throw SteamDepotError.protocolError("RSA encrypt failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return out as Data
    }
}
