// AuthViewModel.swift — SwiftUI view model driving the sign-in shell.
//
// Ticket 0109. Platform-neutral — the view itself picks between
// `NavigationStack` (iOS) and `WindowGroup` (macOS) presentation.

import Foundation
import SwiftUI

@MainActor
public final class AuthViewModel: ObservableObject {
    public enum Phase: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case whitelistDenied(String)
        case error(String)
    }

    @Published public private(set) var phase: Phase = .signedOut

    public let client: OAuth2Client
    public let tokens: TokenManager
    public let driver: AuthorizeSessionDriver
    public let callbackScheme: String

    public init(
        client: OAuth2Client,
        tokens: TokenManager,
        driver: AuthorizeSessionDriver,
        callbackScheme: String
    ) {
        self.client = client
        self.tokens = tokens
        self.driver = driver
        self.callbackScheme = callbackScheme
        // Restore from Keychain on init.
        if tokens.hasSession {
            self.phase = .signedIn
        }
    }

    public func signIn() async {
        switch phase {
        case .signedOut, .error:
            // Proceed. `.error` retries are allowed (transient network,
            // etc.). `.whitelistDenied` is intentionally terminal.
            break
        case .signingIn, .signedIn, .whitelistDenied:
            return
        }
        phase = .signingIn

        do {
            let pkce = try PKCE.generate()
            let state = try Self.randomState()
            let url = client.authorizeURL(pkce: pkce, state: state)
            let cb = try await driver.start(
                authorizeURL: url,
                callbackScheme: callbackScheme,
                expectedState: state
            )
            let newTokens = try await client.exchange(code: cb.code, verifier: pkce.verifier)
            try tokens.install(tokens: newTokens)
            phase = .signedIn
        } catch let err as OAuth2Error {
            switch err {
            case .whitelistDenied(let msg):
                // Per ticket: static page. Do not auto-retry.
                phase = .whitelistDenied(msg)
            default:
                phase = .error(Self.describe(err))
            }
        } catch let err as AuthorizeSessionError {
            if case .userCancelled = err {
                phase = .signedOut
            } else {
                phase = .error(Self.describe(err))
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func signOut() async {
        await tokens.signOut()
        phase = .signedOut
    }

    // MARK: - helpers

    static func randomState() throws -> String {
        let bytes = try PKCE.secureRandomBytes(16)
        return Base64URL.encode(bytes)
    }

    static func describe(_ err: Error) -> String {
        switch err {
        case let e as OAuth2Error:
            switch e {
            case .unauthorized: return "Authentication failed. Please try again."
            case .invalidGrant(let m): return "Sign-in rejected: \(m)"
            case .whitelistDenied(let m): return m
            case .badStatus(let code, _): return "Server returned status \(code)."
            case .invalidResponse: return "Server returned an unexpected response."
            case .transport(let m): return "Network error: \(m)"
            }
        case let e as AuthorizeSessionError:
            switch e {
            case .userCancelled: return "Sign-in cancelled."
            case .missingCode: return "Browser did not return an authorization code."
            case .stateMismatch: return "Browser response failed the CSRF check."
            case .presenterUnavailable: return "No window available to present sign-in."
            case .underlying(let m): return m
            }
        default:
            return err.localizedDescription
        }
    }
}
