import Foundation
import Security

/// Persists Steam refresh-token credentials. Nothing else (no password) is ever stored.
public protocol CredentialStore: Sendable {
    func load() throws -> SteamCredentials?
    func save(_ creds: SteamCredentials) throws
    func clear() throws
}

/// Keychain-backed store (generic password item), for the visionOS/macOS app.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String

    public init(service: String = "SteamDepot.refreshToken", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> SteamCredentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw SteamDepotError.authFailed("keychain read failed (\(status))")
        }
        return try JSONDecoder().decode(SteamCredentials.self, from: data)
    }

    public func save(_ creds: SteamCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = baseQuery
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let s = SecItemAdd(q as CFDictionary, nil)
            guard s == errSecSuccess else { throw SteamDepotError.authFailed("keychain add failed (\(s))") }
        } else if status != errSecSuccess {
            throw SteamDepotError.authFailed("keychain update failed (\(status))")
        }
    }

    public func clear() throws {
        let s = SecItemDelete(baseQuery as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw SteamDepotError.authFailed("keychain delete failed (\(s))") }
    }
}

/// JSON file store (mode 0600), used by the CLI's --token-file.
public struct FileCredentialStore: CredentialStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> SteamCredentials? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SteamCredentials.self, from: Data(contentsOf: url))
    }

    public func save(_ creds: SteamCredentials) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(creds)
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
