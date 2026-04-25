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
        case restoringSession
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
    private let startupSessionValidator: (() async -> AccessTokenValidationResult)?
    private var didAttemptStartupSessionValidation = false

    /// Active in-flight `signIn` task. Cancelled by `signOut` so a still-
    /// suspended sign-in cannot resurrect the session by installing tokens
    /// after the user has explicitly signed out. (Security: an attacker who
    /// times a `signOut` against an in-flight `signIn` should not be able to
    /// leave the user signed in.)
    private var activeSignInTask: Task<Void, Never>?
    /// Monotonic id for the currently-installed `activeSignInTask`. Used
    /// because `Task` is a value type and not identity-comparable, so we
    /// match generations to know whether a finishing task is still the
    /// "current" one or has already been displaced by a fresher signIn.
    private var activeSignInGeneration: UInt64 = 0

    public init(
        client: OAuth2Client,
        tokens: TokenManager,
        driver: AuthorizeSessionDriver,
        callbackScheme: String,
        startupSessionValidator: (() async -> AccessTokenValidationResult)? = nil
    ) {
        self.client = client
        self.tokens = tokens
        self.driver = driver
        self.callbackScheme = callbackScheme
        self.startupSessionValidator = startupSessionValidator
        // Restore from storage on init. Some callers provide an async
        // validator so we don't trust a restored access token until plue
        // confirms it still authenticates.
        if tokens.hasSession {
            self.phase = startupSessionValidator == nil ? .signedIn : .restoringSession
        }
    }

    /// Runs once for restored-session flows that want to revalidate the
    /// cached access token before exposing signed-in UI.
    public func resolveRestoredSessionIfNeeded() async {
        guard phase == .restoringSession else { return }
        guard !didAttemptStartupSessionValidation else { return }
        didAttemptStartupSessionValidation = true

        guard let startupSessionValidator else {
            phase = .signedIn
            return
        }

        switch await startupSessionValidator() {
        case .valid, .indeterminate:
            phase = .signedIn
        case .invalid:
            await tokens.localSignOut()
            phase = .signedOut
        }
    }

    public func signIn() async {
        switch phase {
        case .signedOut, .error:
            // Proceed. `.error` retries are allowed (transient network,
            // etc.). `.whitelistDenied` is intentionally terminal.
            break
        case .restoringSession, .signingIn, .signedIn, .whitelistDenied:
            return
        }
        phase = .signingIn

        // Kick off the sign-in body in a child task so `signOut` can cancel
        // it. The public API stays `async` — callers still await completion
        // via `task.value` so the perceived behavior is unchanged when no
        // cancellation occurs. If `signOut` cancels mid-flight, the post-
        // suspension `Task.isCancelled` checks short-circuit before any
        // tokens are installed or `.signedIn` is published.
        activeSignInGeneration &+= 1
        let myGeneration = activeSignInGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSignIn()
        }
        self.activeSignInTask = task
        await task.value
        // Only clear if this is still the same task — a later signIn tap
        // could have replaced it.
        if self.activeSignInGeneration == myGeneration {
            self.activeSignInTask = nil
        }
    }

    /// Body of the in-flight sign-in. Each `await` is followed by a
    /// `Task.isCancelled` checkpoint so a `signOut`-driven cancellation
    /// never lets a still-suspended sign-in resurrect the session by
    /// installing tokens or publishing `.signedIn`.
    private func runSignIn() async {
        do {
            let pkce = try PKCE.generate()
            let state = try Self.randomState()
            let url = client.authorizeURL(pkce: pkce, state: state)
            let cb = try await driver.start(
                authorizeURL: url,
                callbackScheme: callbackScheme,
                expectedState: state
            )
            if Task.isCancelled { return }
            let newTokens = try await client.exchange(code: cb.code, verifier: pkce.verifier)
            if Task.isCancelled { return }
            try tokens.install(tokens: newTokens)
            if Task.isCancelled {
                // Tokens slipped through the gate — undo immediately so a
                // racing signOut isn't defeated.
                await tokens.localSignOut()
                return
            }
            phase = .signedIn
        } catch is CancellationError {
            // Cancelled mid-await. `signOut` already drove the phase to
            // `.signedOut`; do not republish or surface a user-visible
            // error.
            return
        } catch let err as OAuth2Error {
            if Task.isCancelled { return }
            switch err {
            case .whitelistDenied(let msg):
                // Per ticket: static page. Do not auto-retry.
                phase = .whitelistDenied(msg)
            default:
                phase = .error(Self.describe(err))
            }
        } catch let err as AuthorizeSessionError {
            if Task.isCancelled { return }
            if case .userCancelled = err {
                phase = .signedOut
            } else {
                phase = .error(Self.describe(err))
            }
        } catch {
            if Task.isCancelled { return }
            phase = .error(error.localizedDescription)
        }
    }

    public func signOut() async {
        // Cancel any in-flight sign-in BEFORE wiping tokens so a still-
        // suspended sign-in cannot install fresh tokens after we clear
        // them. See `runSignIn`'s `Task.isCancelled` checkpoints.
        //
        // NOTE: `AuthorizeSessionDriver` does not expose a synchronous
        // cancel hook (`ASWebAuthenticationSession` would need to be torn
        // down explicitly). `Task.cancel()` propagates to the underlying
        // `await` and the post-await `Task.isCancelled` gates short-
        // circuit token install. The browser sheet may remain open
        // briefly until the user dismisses it; the resulting code is
        // discarded. Documented gap; see ticket follow-up to wire a
        // driver-level cancel.
        activeSignInTask?.cancel()
        activeSignInTask = nil
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
