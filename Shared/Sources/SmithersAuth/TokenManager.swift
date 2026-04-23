// TokenManager.swift — the single point for "give me a valid access token"
// and "retry this request once if it 401s."
//
// Ticket 0109. The refresh path here is the most security-sensitive part of
// the whole feature: if we break atomicity, the user gets locked out.
//
// The contract:
//   1. Caller asks for a fresh access token via `currentAccessToken()`.
//   2. Caller fires its request.
//   3. On 401, caller invokes `refreshAndRetry { token in ... }`. We refresh
//      with the stored refresh token, **persist the new token pair to the
//      store BEFORE returning to the retry closure**, and only then invoke
//      the closure with the new access token.
//   4. If the Keychain write fails for any reason, the user is signed out
//      rather than retained with a stale refresh token. Rationale: plue
//      has already invalidated the old refresh token by issuing a new
//      one. Keeping it in Keychain is worse than wiping.
//
// `TokenManager` is intentionally platform-neutral. It never touches
// `ASWebAuthenticationSession`. Sign-in sources (the SwiftUI view model)
// call `install(tokens:)` after a successful code exchange; sign-out
// sources call `signOut()` to wipe + revoke.

import Foundation

public enum TokenManagerError: Error, Equatable {
    case notSignedIn
    case refreshFailed(OAuth2Error)
    case persistenceFailed(TokenStoreError)
    case whitelistDenied(String)
}

/// Delegate used to wipe downstream state (SQLite cache etc.) when the user
/// signs out or gets locked out by a refresh failure. Per 0133 the sign-out
/// wipe MUST include the local cache, not just Keychain.
public protocol SessionWipeHandler: AnyObject {
    /// Called after Keychain is cleared. Implementations should drop any
    /// per-user SQLite caches, invalidate in-memory session state, and
    /// cancel any Electric shape subscriptions. Synchronous to keep the
    /// wipe ordering deterministic.
    func wipeAfterSignOut()
}

public final class TokenManager {
    public let client: OAuth2Client
    public let store: TokenStore
    public weak var wipeHandler: SessionWipeHandler?

    private let lock = NSLock()
    private var cached: OAuth2Tokens?
    private var inFlightRefresh: Task<OAuth2Tokens, Error>?

    public init(client: OAuth2Client, store: TokenStore, wipeHandler: SessionWipeHandler? = nil) {
        self.client = client
        self.store = store
        self.wipeHandler = wipeHandler
        // Best-effort load on init.
        self.cached = try? store.load()
    }

    /// `true` if we have a refresh token on disk right now. Accessible from
    /// SwiftUI via `AuthViewModel.isSignedIn`.
    public var hasSession: Bool {
        lock.lock(); defer { lock.unlock() }
        return cached != nil
    }

    public func currentAccessToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let t = cached else { throw TokenManagerError.notSignedIn }
        return t.accessToken
    }

    /// Install freshly-exchanged tokens (from the sign-in view model). Writes
    /// to the store and caches in memory.
    public func install(tokens: OAuth2Tokens) throws {
        do {
            try store.save(tokens)
        } catch let e as TokenStoreError {
            throw TokenManagerError.persistenceFailed(e)
        }
        lock.lock(); cached = tokens; lock.unlock()
    }

    /// Refresh the session once. Shared by the 401-retry helper below and
    /// by proactive refresh at app launch. Write-before-return: the new
    /// tokens hit the Keychain before this function resolves.
    @discardableResult
    public func refresh() async throws -> OAuth2Tokens {
        // De-duplicate concurrent refreshes — two parallel 401s must not
        // both redeem the same refresh token.
        let (existingTask, current): (Task<OAuth2Tokens, Error>?, OAuth2Tokens?) = {
            lock.lock(); defer { lock.unlock() }
            return (inFlightRefresh, cached)
        }()
        if let existing = existingTask {
            return try await existing.value
        }
        guard let current = current else {
            throw TokenManagerError.notSignedIn
        }
        let task = Task { [client, store] () throws -> OAuth2Tokens in
            let newTokens: OAuth2Tokens
            do {
                newTokens = try await client.refresh(refreshToken: current.refreshToken)
            } catch let err as OAuth2Error {
                if case .whitelistDenied(let msg) = err {
                    throw TokenManagerError.whitelistDenied(msg)
                }
                throw TokenManagerError.refreshFailed(err)
            }
            // WRITE-BEFORE-RETURN. If this throws, the caller treats the
            // user as signed out — see `refreshAndRetry` wiring.
            do {
                try store.save(newTokens)
            } catch let e as TokenStoreError {
                throw TokenManagerError.persistenceFailed(e)
            }
            return newTokens
        }
        setInflight(task)

        do {
            let newTokens = try await task.value
            self.setCached(newTokens)
            self.clearInflight()
            return newTokens
        } catch {
            self.clearInflight()
            // A refresh failure (expired/rotated/revoked refresh token OR
            // a store write failure) locks the user out. Wipe silently.
            await self.localSignOut()
            throw error
        }
    }

    private func setCached(_ t: OAuth2Tokens) {
        lock.lock(); cached = t; lock.unlock()
    }

    private func clearInflight() {
        lock.lock(); inFlightRefresh = nil; lock.unlock()
    }

    private func setInflight(_ t: Task<OAuth2Tokens, Error>) {
        lock.lock(); inFlightRefresh = t; lock.unlock()
    }

    /// 401-retry helper. `perform` receives a bearer access token; return
    /// `nil` to indicate a 401 that needs one refresh attempt.
    public func performWithRetry<T>(
        _ perform: (String) async throws -> T?
    ) async throws -> T {
        let token = try currentAccessToken()
        if let first = try await perform(token) {
            return first
        }
        let refreshed = try await refresh()
        guard let second = try await perform(refreshed.accessToken) else {
            throw TokenManagerError.refreshFailed(.unauthorized)
        }
        return second
    }

    /// Full sign-out: revoke on the server (best effort), wipe Keychain,
    /// wipe downstream caches via the wipe handler. Idempotent.
    public func signOut() async {
        let snapshot = snapshotCached()
        if let t = snapshot {
            await client.revoke(refreshToken: t.refreshToken)
        }
        await localSignOut()
    }

    private func snapshotCached() -> OAuth2Tokens? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Wipe everything local. Used by `signOut` and by refresh-failure
    /// lock-outs. Never hits the network.
    public func localSignOut() async {
        try? store.clear()
        clearCached()
        wipeHandler?.wipeAfterSignOut()
    }

    private func clearCached() {
        lock.lock(); cached = nil; lock.unlock()
    }
}
