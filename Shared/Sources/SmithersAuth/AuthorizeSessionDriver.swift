// AuthorizeSessionDriver.swift — opens `ASWebAuthenticationSession` and
// returns the callback URL. Cross-platform (iOS + macOS).
//
// Ticket 0109. The driver is protocolised so the unit-test suite can
// replace it with an `InProcessMockAuthDriver` that simulates a redirect
// without touching AuthenticationServices.

import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

public enum AuthorizeSessionError: Error, Equatable {
    case userCancelled
    case missingCode
    case stateMismatch
    case presenterUnavailable
    case underlying(String)
}

/// Result is the parsed query items from the callback URL. The view model
/// verifies `state` and extracts `code`.
public struct AuthorizeCallback: Equatable, Sendable {
    public let code: String
    public let state: String

    public init(code: String, state: String) {
        self.code = code
        self.state = state
    }
}

public protocol AuthorizeSessionDriver: AnyObject {
    /// Opens `authorizeURL`, waits for the user to complete upstream IdP,
    /// returns the parsed callback. `callbackScheme` matches 0106's
    /// registered redirect URI scheme (iOS: `smithers`; macOS loopback
    /// just uses `http` on `127.0.0.1:<port>`).
    func start(
        authorizeURL: URL,
        callbackScheme: String,
        expectedState: String
    ) async throws -> AuthorizeCallback
}

/// Parses `?code=...&state=...` off a callback URL. Shared by the real
/// driver and the mock. Exposed so integration tests can fuzz inputs.
public func parseCallback(
    url: URL,
    expectedState: String
) throws -> AuthorizeCallback {
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let items = comps?.queryItems ?? []
    let code = items.first { $0.name == "code" }?.value
    let state = items.first { $0.name == "state" }?.value
    guard let c = code, !c.isEmpty else { throw AuthorizeSessionError.missingCode }
    guard let s = state, s == expectedState else { throw AuthorizeSessionError.stateMismatch }
    return AuthorizeCallback(code: c, state: s)
}

// MARK: - Real implementation

#if canImport(AuthenticationServices)

/// `ASWebAuthenticationSession` presenter. Needs a
/// `PresentationContextProviding` anchor — the app injects one via
/// `AuthorizeSessionPresenter`.
public protocol AuthorizeSessionPresenter: AnyObject {
    /// Returns the anchor window for `ASWebAuthenticationSession`.
    /// iOS: active `UIWindow`. macOS: key `NSWindow`.
    func presentationAnchor() -> ASPresentationAnchor?
}

public final class WebAuthSessionDriver: NSObject, AuthorizeSessionDriver, ASWebAuthenticationPresentationContextProviding {
    public weak var presenter: AuthorizeSessionPresenter?
    /// When `true`, the session uses an ephemeral (private) web context so
    /// an existing Auth0/WorkOS SSO cookie is NOT reused. Default `false`
    /// to match user expectations that "sign in with browser" respects
    /// their existing session.
    public var prefersEphemeralSession: Bool = false

    public init(presenter: AuthorizeSessionPresenter?) {
        self.presenter = presenter
    }

    public func start(
        authorizeURL: URL,
        callbackScheme: String,
        expectedState: String
    ) async throws -> AuthorizeCallback {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AuthorizeCallback, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { url, err in
                if let err = err as NSError? {
                    if err.domain == ASWebAuthenticationSessionError.errorDomain,
                       err.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: AuthorizeSessionError.userCancelled)
                        return
                    }
                    cont.resume(throwing: AuthorizeSessionError.underlying(err.localizedDescription))
                    return
                }
                guard let url = url else {
                    cont.resume(throwing: AuthorizeSessionError.missingCode)
                    return
                }
                do {
                    let cb = try parseCallback(url: url, expectedState: expectedState)
                    cont.resume(returning: cb)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
            if !session.start() {
                cont.resume(throwing: AuthorizeSessionError.presenterUnavailable)
            }
        }
    }

    // ASWebAuthenticationPresentationContextProviding
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor = presenter?.presentationAnchor() {
            return anchor
        }
        // Fallback: an empty anchor. On iOS this is treated as "present
        // on the key window" by the system.
        return ASPresentationAnchor()
    }
}

#endif

// MARK: - Mock driver for unit + mocked-integration tests

public final class MockAuthorizeSessionDriver: AuthorizeSessionDriver {
    public enum Behavior {
        case success(code: String)
        case cancel
        case stateMismatch
        case error(AuthorizeSessionError)
    }

    public var behavior: Behavior = .success(code: "MOCK_CODE_FIXTURE")
    public private(set) var lastAuthorizeURL: URL?
    public private(set) var lastCallbackScheme: String?

    public init() {}

    public func start(
        authorizeURL: URL,
        callbackScheme: String,
        expectedState: String
    ) async throws -> AuthorizeCallback {
        lastAuthorizeURL = authorizeURL
        lastCallbackScheme = callbackScheme
        switch behavior {
        case .success(let code):
            return AuthorizeCallback(code: code, state: expectedState)
        case .cancel:
            throw AuthorizeSessionError.userCancelled
        case .stateMismatch:
            throw AuthorizeSessionError.stateMismatch
        case .error(let e):
            throw e
        }
    }
}
