import Foundation

public enum SteamDepotError: Error, CustomStringConvertible, Sendable {
    case protocolError(String)
    case connectionFailed(String)
    case timeout(String)
    case steamResult(String, Int32)
    case authFailed(String)
    case logonFailed(Int32)
    case notOwned(String)
    case cdn(String)
    case corrupt(String)
    case cancelled
    case insufficientSpace(needed: UInt64, available: UInt64)

    public var description: String {
        switch self {
        case .protocolError(let s): return "protocol error: \(s)"
        case .connectionFailed(let s): return "connection failed: \(s)"
        case .timeout(let s): return "timed out: \(s)"
        case .steamResult(let s, let r): return "\(s) failed: EResult \(r) (\(EResult.name(r)))"
        case .authFailed(let s): return "authentication failed: \(s)"
        case .logonFailed(let r): return "logon failed: EResult \(r) (\(EResult.name(r)))"
        case .notOwned(let s): return "not owned / no access: \(s)"
        case .cdn(let s): return "CDN error: \(s)"
        case .corrupt(let s): return "corrupt data: \(s)"
        case .cancelled: return "cancelled"
        case .insufficientSpace(let n, let a):
            return String(format: "not enough free space: need %.1f GB, %.1f GB available", Double(n) / 1e9, Double(a) / 1e9)
        }
    }
}

/// Subset of Steam's EResult values we care about for diagnostics.
public enum EResult {
    public static let ok: Int32 = 1
    public static let fail: Int32 = 2
    public static let fileNotFound: Int32 = 9
    public static let invalidPassword: Int32 = 5
    public static let accessDenied: Int32 = 15
    public static let expired: Int32 = 27
    public static let invalidSignature: Int32 = 63
    public static let revoked: Int32 = 26
    public static let tryAnotherCM: Int32 = 48
    public static let serviceUnavailable: Int32 = 20

    static func name(_ r: Int32) -> String {
        switch r {
        case 1: return "OK"
        case 2: return "Fail"
        case 3: return "NoConnection"
        case 5: return "InvalidPassword"
        case 8: return "InvalidParam"
        case 9: return "FileNotFound"
        case 10: return "Busy"
        case 15: return "AccessDenied"
        case 16: return "Timeout"
        case 20: return "ServiceUnavailable"
        case 26: return "Revoked"
        case 27: return "Expired"
        case 29: return "DuplicateRequest"
        case 48: return "TryAnotherCM"
        case 63: return "InvalidSignature"
        case 84: return "RateLimitExceeded"
        case 88: return "TwoFactorCodeMismatch"
        default: return "?"
        }
    }
}

/// Steam message ids (EMsg) used by this package. Values from SteamKit2 SteamLanguage.cs.
enum EMsg {
    static let multi: UInt32 = 1
    static let serviceMethod: UInt32 = 146
    static let serviceMethodResponse: UInt32 = 147
    static let serviceMethodCallFromClient: UInt32 = 151
    static let clientHeartBeat: UInt32 = 703
    static let clientLogOff: UInt32 = 706
    static let clientChangeStatus: UInt32 = 716
    static let clientLogOnResponse: UInt32 = 751
    static let clientLoggedOff: UInt32 = 757
    static let clientAccountInfo: UInt32 = 768
    static let clientLicenseList: UInt32 = 780
    static let clientGetUserStats: UInt32 = 818
    static let clientGetUserStatsResponse: UInt32 = 819
    static let clientStoreUserStatsResponse: UInt32 = 821
    static let clientGamesPlayedWithDataBlob: UInt32 = 5410
    static let clientGetDepotDecryptionKey: UInt32 = 5438
    static let clientGetDepotDecryptionKeyResponse: UInt32 = 5439
    static let clientStoreUserStats2: UInt32 = 5466
    static let clientStatsUpdated: UInt32 = 5467
    static let clientLogon: UInt32 = 5514
    static let clientPICSChangesSinceRequest: UInt32 = 8901
    static let clientPICSChangesSinceResponse: UInt32 = 8902
    static let clientPICSProductInfoRequest: UInt32 = 8903
    static let clientPICSProductInfoResponse: UInt32 = 8904
    static let clientPICSAccessTokenRequest: UInt32 = 8905
    static let clientPICSAccessTokenResponse: UInt32 = 8906
    static let serviceMethodCallFromClientNonAuthed: UInt32 = 9804
    static let clientPlayingSessionState: UInt32 = 9600
    static let clientHello: UInt32 = 9805
}

let steamProtocolVersion: UInt32 = 65581
