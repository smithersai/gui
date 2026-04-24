// SignInView.swift — SwiftUI sign-in shell, shared between iOS + macOS.
//
// Ticket 0109. No `#if os(iOS)` branching that hides stubs — both
// platforms render the same view. Tiny platform shim lives in the
// AuthorizeSessionPresenter (window-anchor difference).

import SwiftUI

public struct SignInView: View {
    @ObservedObject public var model: AuthViewModel

    public init(model: AuthViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Sign in to Smithers")
                .font(.title2.weight(.semibold))
            Text("You will be redirected to complete authentication in your browser.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Group {
                switch model.phase {
                case .signedOut:
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        Text("Continue with browser")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("auth.signin.primary-cta")

                case .signingIn:
                    ProgressView("Opening browser…")
                        .progressViewStyle(.circular)

                case .signedIn:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Signed in.")
                    }
                    Button("Sign out") {
                        Task { await model.signOut() }
                    }
                    .buttonStyle(.bordered)

                case .whitelistDenied(let msg):
                    WhitelistDeniedView(message: msg)

                case .error(let msg):
                    VStack(spacing: 8) {
                        Text("Sign-in failed")
                            .font(.headline)
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Try again") {
                            Task { await model.signIn() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .animation(.default, value: phaseKey(model.phase))
        }
        .padding(32)
        .frame(maxWidth: 480)
        .accessibilityIdentifier("auth.signin.root")
    }

    private func phaseKey(_ phase: AuthViewModel.Phase) -> String {
        switch phase {
        case .signedOut: return "signedOut"
        case .signingIn: return "signingIn"
        case .signedIn: return "signedIn"
        case .whitelistDenied: return "whitelistDenied"
        case .error: return "error"
        }
    }
}

/// Static terminal state — NO retry button. Matches ticket acceptance
/// criteria: "structured error → static 'access not yet granted' screen
/// with no retry loop."
public struct WhitelistDeniedView: View {
    public let message: String
    public init(message: String) { self.message = message }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Access not yet granted")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Contact your Smithers administrator to request access.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 8)
    }
}
