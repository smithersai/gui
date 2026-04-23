// SessionLifecycle.swift — wiring for 0109 (auth) + 0124 (store) lifecycle.
//
// Responsibilities:
//   - Build a `SmithersRuntime` + `RuntimeSession` from config.
//   - Inject the 0109 `TokenManager` as the runtime's credentials provider.
//   - Implement `SessionWipeHandler` so `TokenManager.signOut()` wipes the
//     Electric cache and tears down the store's subscriptions.
//
// This is intentionally kept as a thin glue layer so the macOS and iOS
// apps can share one lifecycle and only differ in UI hosting.

import Foundation
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

/// Dependency-inject abstractions for the SmithersAuth types — kept as
/// protocols here so `SmithersStore` target doesn't import SmithersAuth
/// directly (that module lives in a sibling package directory).
public protocol StoreTokenSource: AnyObject {
    func currentAccessTokenOrNil() -> String?
    func expiresAt() -> Date?
}

/// Bridge object returned to the app. Keep it alive as long as the user is
/// signed in.
public final class SmithersSessionLifecycle {
    public let runtime: SmithersRuntime
    public let session: RuntimeSession
    public let store: SmithersStore

    public init(runtime: SmithersRuntime, session: RuntimeSession, store: SmithersStore) {
        self.runtime = runtime
        self.session = session
        self.store = store
    }

    /// Construct a lifecycle using a token source for credentials injection.
    ///
    /// FAKE-TRANSPORT CAVEAT: 0120's runtime currently does not actually
    /// reach plue. This factory will still succeed locally; behaviour
    /// against a real stack is verified behind `POC_ELECTRIC_STACK=1`
    /// (see Shared/Tests/SmithersStoreTests).
    public static func bootstrap(
        tokenSource: StoreTokenSource,
        engineConfig: EngineConfig
    ) throws -> SmithersSessionLifecycle {
        let provider: CredentialsProvider = { [weak tokenSource] in
            guard let token = tokenSource?.currentAccessTokenOrNil(), !token.isEmpty else {
                return nil // emits AUTH_EXPIRED downstream
            }
            return SmithersCredentials(
                bearer: token,
                expiresAt: tokenSource?.expiresAt(),
                refreshToken: nil
            )
        }
        let runtime = try SmithersRuntime(credentials: provider)
        let session = try runtime.connect(engineConfig)
        let store = SmithersStore(session: session)
        return SmithersSessionLifecycle(runtime: runtime, session: session, store: store)
    }

    /// Call from `TokenManager.signOut()` via a `SessionWipeHandler` shim.
    public func wipeForSignOut() {
        store.wipeForSignOut()
    }
}
