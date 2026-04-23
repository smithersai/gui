// E2EEnvironment.swift — strictly env-var-gated hooks for the iOS
// XCUITest harness.
//
// Ticket: ios-e2e-harness. This module exists so the real iOS app can be
// driven end-to-end by XCUITest WITHOUT a human clicking through the
// ASWebAuthenticationSession browser flow and WITHOUT a mocked HTTP
// transport inside the test bundle. Tests set three launch-environment
// variables on `XCUIApplication.launchEnvironment`:
//
//   PLUE_E2E_MODE=1          — opt-in kill-switch. When unset, EVERY
//                              helper in this file returns nil/false and
//                              the production code path runs untouched.
//                              This is the single guard the rest of the
//                              app checks.
//   SMITHERS_E2E_BEARER=...  — the bearer token to install as the signed-
//                              in session. Typically `jjhub_e2e_<hex>`
//                              issued by `ios/scripts/seed-e2e-data.sh`.
//   PLUE_BASE_URL=...        — overrides the production Plue base URL so
//                              the runtime + workspace fetcher talk to
//                              `http://localhost:4000` during tests.
//
// SECURITY note: production app binaries never see these env vars — iOS
// does not let a shipped app read arbitrary environment from the host.
// The only way they take effect is inside an XCUITest runner (which
// sets them via `launchEnvironment`). This makes the gate tight: even
// if a shipped build somehow includes this module, a user can't flip
// `PLUE_E2E_MODE` from outside and escape production auth.

import Foundation
#if SWIFT_PACKAGE
// Depend on Auth for OAuth2Tokens + TokenStore protocol. No cycle — the
// direction is Auth ← E2ESupport.
import SmithersAuth
#endif

/// Read-only accessor over `ProcessInfo.processInfo.environment` so tests
/// in this module can inject a fake environment without messing with the
/// real process env (which is append-only in Swift).
public protocol E2EEnvironmentSource {
    func value(forKey key: String) -> String?
}

/// Thin wrapper around `ProcessInfo`.
public struct ProcessInfoEnvironmentSource: E2EEnvironmentSource {
    public init() {}
    public func value(forKey key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}

/// In-memory source for unit tests.
public struct DictionaryEnvironmentSource: E2EEnvironmentSource {
    public let values: [String: String]
    public init(_ values: [String: String]) { self.values = values }
    public func value(forKey key: String) -> String? { values[key] }
}

/// The E2E env-var keys, exposed so tests and the harness script use the
/// same canonical spellings.
public enum E2EEnvironmentKey {
    public static let mode = "PLUE_E2E_MODE"
    public static let bearer = "SMITHERS_E2E_BEARER"
    public static let baseURL = "PLUE_BASE_URL"
    /// Optional — when set, the E2E mode also installs a synthetic refresh
    /// token so `refresh()` code paths can be exercised deterministically.
    /// Not required for the basic sign-in bypass.
    public static let refreshToken = "SMITHERS_E2E_REFRESH"
}

/// The parsed "is E2E mode on, with what config?" structure. A nil value
/// here means the process is running normally and the rest of the app
/// should take the production branch.
public struct E2EConfig: Equatable {
    public let bearer: String
    public let baseURL: URL
    public let refreshToken: String?

    public init(bearer: String, baseURL: URL, refreshToken: String? = nil) {
        self.bearer = bearer
        self.baseURL = baseURL
        self.refreshToken = refreshToken
    }
}

public enum E2EEnvironment {
    /// Parse the process environment. Returns nil unless `PLUE_E2E_MODE=1`.
    /// If `PLUE_E2E_MODE=1` is set but `SMITHERS_E2E_BEARER` is missing
    /// or `PLUE_BASE_URL` is not a valid URL, returns nil and (by design)
    /// the app falls back to the production path. The xcuitest harness
    /// treats that as a test failure because the sign-in shell will
    /// appear instead of the workspace switcher.
    public static func parse(_ source: E2EEnvironmentSource = ProcessInfoEnvironmentSource()) -> E2EConfig? {
        guard let mode = source.value(forKey: E2EEnvironmentKey.mode), mode == "1" else {
            return nil
        }
        guard let bearer = source.value(forKey: E2EEnvironmentKey.bearer), !bearer.isEmpty else {
            return nil
        }
        guard let baseString = source.value(forKey: E2EEnvironmentKey.baseURL),
              let baseURL = URL(string: baseString) else {
            return nil
        }
        let refresh = source.value(forKey: E2EEnvironmentKey.refreshToken)
        return E2EConfig(bearer: bearer, baseURL: baseURL, refreshToken: refresh)
    }

    /// Convenience: build an `OAuth2Tokens` that can be `install()`-ed
    /// into a `TokenManager` to flip the app to a signed-in phase without
    /// any `ASWebAuthenticationSession` round trip.
    public static func syntheticTokens(from config: E2EConfig) -> OAuth2Tokens {
        OAuth2Tokens(
            accessToken: config.bearer,
            // `refresh` is not exercised by any test today; a placeholder
            // keeps the `TokenManager.hasSession` invariant happy.
            refreshToken: config.refreshToken ?? "e2e-refresh-placeholder",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scope: "read:workspace,write:workspace"
        )
    }
}
