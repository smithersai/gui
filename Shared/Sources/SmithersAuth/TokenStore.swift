// TokenStore.swift — Keychain wrapper for OAuth2 access + refresh tokens.
//
// SECURITY (ticket 0109):
//   - Storage class is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
//     Justification: the app needs to perform background refresh (and
//     network calls in response to user taps shortly after launch) without
//     re-authenticating, so `WhenUnlocked` is too strict. Binding to THIS
//     DEVICE ONLY prevents the Keychain item from migrating to a new
//     device via iCloud Keychain backup and expanding the blast radius of
//     a device compromise.
//   - Tokens are never logged. `String(describing:)` on any value here
//     returns a redacted placeholder for diagnostics.
//   - Refresh-token rotation atomicity is enforced by the `saveTokens`
//     contract: callers must write the new tokens BEFORE retrying the
//     authenticated request. If the write fails, the sign-in session is
//     discarded rather than kept alive with the old refresh token — the
//     old refresh token was invalidated server-side the moment plue
//     issued a new one.
//
// The API surface is small intentionally — this is a credential boundary.

import Foundation
#if canImport(Security)
import Security
#endif

/// Tokens materialized in memory. Do not `Codable`-ify this struct to JSON
/// on disk — Keychain is the only persistent store.
public struct OAuth2Tokens: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date?
    public let scope: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

extension OAuth2Tokens: CustomStringConvertible {
    /// Redacted diagnostic. We never want `po tokens` to leak in a debug
    /// session or a crash log.
    public var description: String {
        "OAuth2Tokens(access: <redacted \(accessToken.count)B>, refresh: <redacted \(refreshToken.count)B>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))"
    }
}

public enum TokenStoreError: Error, Equatable {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed
    case notFound
}

/// Abstract persistence layer so tests can plug in an in-memory fake.
/// Production binding is `KeychainTokenStore`.
public protocol TokenStore: AnyObject {
    func load() throws -> OAuth2Tokens?
    /// Write-then-return: returns ONLY after the Keychain (or backing
    /// store) has accepted the new tokens. Callers MUST use the returned
    /// tokens for any subsequent retry.
    @discardableResult
    func save(_ tokens: OAuth2Tokens) throws -> OAuth2Tokens
    func clear() throws
}

// MARK: - Keychain-backed implementation.

/// Persists tokens as a single Keychain item keyed by `service + account`.
/// We store JSON so future fields (e.g. `id_token`) can be added without a
/// migration. The payload itself is encrypted by the system keychain.
public final class KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "com.smithers.oauth2", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() throws -> OAuth2Tokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw TokenStoreError.keychainReadFailed(status)
        }
        return try TokenJSON.decode(data)
    }

    @discardableResult
    public func save(_ tokens: OAuth2Tokens) throws -> OAuth2Tokens {
        let payload = try TokenJSON.encode(tokens)

        // Try update first — if an item exists, keep its attributes.
        let update: [String: Any] = [kSecValueData as String: payload]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return tokens
        case errSecItemNotFound:
            // Fall through to add.
            break
        default:
            throw TokenStoreError.keychainWriteFailed(updateStatus)
        }

        var add = baseQuery()
        add[kSecValueData as String] = payload
        // SECURITY: access class + this-device-only + no iCloud sync.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.keychainWriteFailed(addStatus)
        }
        return tokens
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw TokenStoreError.keychainDeleteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: "" as String, // intentionally empty — no sharing group
            kSecAttrAccount as String: account,
        ].filter { key, value in
            // Strip the empty access group; some simulators reject it.
            if key == (kSecAttrAccessGroup as String), let s = value as? String, s.isEmpty {
                return false
            }
            return true
        }
    }
}

// MARK: - In-memory fake for unit tests.

public final class InMemoryTokenStore: TokenStore {
    public enum FailureMode {
        case none
        case onSave(TokenStoreError)
        case onLoad(TokenStoreError)
        case onClear(TokenStoreError)
    }

    private let lock = NSLock()
    private var current: OAuth2Tokens?
    public var failureMode: FailureMode = .none
    public private(set) var saveCount: Int = 0
    public private(set) var clearCount: Int = 0

    public init(initial: OAuth2Tokens? = nil) {
        self.current = initial
    }

    public func load() throws -> OAuth2Tokens? {
        lock.lock(); defer { lock.unlock() }
        if case let .onLoad(err) = failureMode { throw err }
        return current
    }

    @discardableResult
    public func save(_ tokens: OAuth2Tokens) throws -> OAuth2Tokens {
        lock.lock(); defer { lock.unlock() }
        if case let .onSave(err) = failureMode { throw err }
        current = tokens
        saveCount += 1
        return tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if case let .onClear(err) = failureMode { throw err }
        current = nil
        clearCount += 1
    }
}

// MARK: - Private JSON codec.

private enum TokenJSON {
    private struct Payload: Codable {
        let access_token: String
        let refresh_token: String
        let expires_at: Double?
        let scope: String?
    }

    static func encode(_ tokens: OAuth2Tokens) throws -> Data {
        let p = Payload(
            access_token: tokens.accessToken,
            refresh_token: tokens.refreshToken,
            expires_at: tokens.expiresAt?.timeIntervalSince1970,
            scope: tokens.scope
        )
        do {
            return try JSONEncoder().encode(p)
        } catch {
            throw TokenStoreError.encodingFailed
        }
    }

    static func decode(_ data: Data) throws -> OAuth2Tokens {
        do {
            let p = try JSONDecoder().decode(Payload.self, from: data)
            return OAuth2Tokens(
                accessToken: p.access_token,
                refreshToken: p.refresh_token,
                expiresAt: p.expires_at.map { Date(timeIntervalSince1970: $0) },
                scope: p.scope
            )
        } catch {
            throw TokenStoreError.decodingFailed
        }
    }
}
