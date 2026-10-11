// Token storage and ownership cache.
// OwnershipRecord / needsCheck adapted from avp-play (MIT, github.com/myMartek/avp-play)
// core/Sources/AVPPlayCore/Ownership.swift; token plausibility from TokenStore.swift.
import Foundation
import Security

public enum MetaToken {
    /// A token is one line of letters and digits, at least 32 long. Anything else is never sent.
    public static func isPlausible(_ token: String) -> Bool {
        token.count >= 32 && token.count <= 4096 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

public enum TokenStoreError: Error, CustomStringConvertible, Equatable {
    case malformed
    case keychain(Int32)
    public var description: String {
        switch self {
        case .malformed: return "The Meta token has an unexpected form."
        case .keychain(let s): return "The Keychain didn't accept the entry (OSStatus \(s))."
        }
    }
}

/// Where the token lives.
public protocol MetaTokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

/// Keychain generic-password item (the hub on visionOS). Only the token, never a password.
public struct KeychainTokenStore: MetaTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "MetaStore.token", account: String = "meta") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw TokenStoreError.keychain(status) }
        let token = String(decoding: data, as: UTF8.self)
        guard MetaToken.isPlausible(token) else { throw TokenStoreError.malformed }
        return token
    }

    public func save(_ token: String) throws {
        guard MetaToken.isPlausible(token) else { throw TokenStoreError.malformed }
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = baseQuery
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let s = SecItemAdd(q as CFDictionary, nil)
            guard s == errSecSuccess else { throw TokenStoreError.keychain(s) }
        } else if status != errSecSuccess {
            throw TokenStoreError.keychain(status)
        }
    }

    public func clear() throws {
        let s = SecItemDelete(baseQuery as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw TokenStoreError.keychain(s) }
    }
}

/// In-memory store (tests).
public final class MemoryTokenStore: MetaTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(_ token: String? = nil) { self.token = token }
    public func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ t: String) throws {
        guard MetaToken.isPlausible(t) else { throw TokenStoreError.malformed }
        lock.lock(); token = t; lock.unlock()
    }
    public func clear() throws { lock.lock(); token = nil; lock.unlock() }
}

/// The one-time hand-off from the Mac: `metastore push-token` copies this JSON into the hub's
/// Documents/; the hub moves the token into its Keychain and deletes the file.
public enum TokenHandoff {
    public static let fileName = "metastore-token.json"

    struct Payload: Codable { var token: String; var created: Date }

    public static func encode(token: String, now: Date = Date()) throws -> Data {
        guard MetaToken.isPlausible(token) else { throw TokenStoreError.malformed }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(Payload(token: token, created: now))
    }

    public static func decode(_ data: Data) -> String? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let p = try? d.decode(Payload.self, from: data), MetaToken.isPlausible(p.token) else { return nil }
        return p.token
    }

    /// If `directory` holds a hand-off file: store its token, delete the file (even when it is
    /// malformed — a credential file is never left lying around). Returns true when a token was imported.
    @discardableResult
    public static func importIfPresent(in directory: URL, into store: MetaTokenStore) -> Bool {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let token = decode(data) else { return false }
        do { try store.save(token); return true } catch { return false }
    }
}

/// What Meta last said about whether the account owns an app.
public struct OwnershipRecord: Codable, Sendable, Equatable {
    public var owned: Bool
    public var checked: Date
    public init(owned: Bool, checked: Date) {
        self.owned = owned
        self.checked = checked
    }
}

/// The answers per store app id, for one Meta user. Lets the UI know what is owned without a
/// new request; a fresh answer replaces the old one, a failed request changes nothing.
public struct OwnershipCache: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    struct File: Codable { var userId: String; var apps: [String: OwnershipRecord] }

    public func load(userId: String) -> [String: OwnershipRecord] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let f = try? d.decode(File.self, from: data), f.userId == userId else { return [:] }
        return f.apps
    }

    /// The cached answers whatever the user (for offline display); nil user = none cached.
    public func loadAny() -> (userId: String, apps: [String: OwnershipRecord])? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let f = try? d.decode(File.self, from: data) else { return nil }
        return (f.userId, f.apps)
    }

    public func save(userId: String, _ apps: [String: OwnershipRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        try e.encode(File(userId: userId, apps: apps)).write(to: url, options: .atomic)
    }

    /// On sign-out: the answers belong to one account.
    public func clear() { try? FileManager.default.removeItem(at: url) }

    /// Is a new check due? Yes without an answer, or one older than `maxAge` (or from the future).
    public static func needsCheck(_ record: OwnershipRecord?, now: Date = Date(), maxAge: TimeInterval = 24 * 3600) -> Bool {
        guard let record else { return true }
        return now.timeIntervalSince(record.checked) > maxAge || record.checked > now
    }
}

/// Ownership checks for several apps: one `me` plus one `verify_entitlement` per app whose
/// cached answer is stale, all through the gate; stops at the first error (the cache keeps
/// whatever was answered before it).
public enum OwnershipCheck {
    public static func refresh(client: MetaClient, appIds: [String], cache: OwnershipCache, gate: RequestGate,
                               force: Bool = false, now: @Sendable () -> Date = { Date() }) async throws -> (userId: String, apps: [String: OwnershipRecord]) {
        let userId = try await gate.run { try await client.me() }
        var apps = cache.load(userId: userId)
        for app in Array(Set(appIds)).sorted() where force || OwnershipCache.needsCheck(apps[app], now: now()) {
            let owned = try await gate.run { try await client.ownsApp(appId: app, userId: userId) }
            apps[app] = OwnershipRecord(owned: owned, checked: now())
            try cache.save(userId: userId, apps)
        }
        try cache.save(userId: userId, apps)
        return (userId, apps)
    }
}
