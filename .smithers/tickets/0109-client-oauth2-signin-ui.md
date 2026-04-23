# Client: OAuth2 sign-in UI for iOS + macOS

## Context

Sibling of ticket 0106 (plue-side browser-native authorize flow). This ticket owns the gui/client side: iOS and macOS SwiftUI sign-in views, PKCE verifier generation, Keychain storage, refresh and revoke wiring. Cannot complete until 0106's authorize flow exists, but development of the client UI and unit-testable parts (PKCE code, Keychain wrapper) can proceed in parallel against a mocked server.

## Problem

Without a working sign-in shell on iOS and macOS, none of the other client work (FFI sessions, Electric shape subscriptions, WebSocket PTY) has a valid bearer token to attach. This is a hard prerequisite for every downstream client ticket, second only to 0106 itself.

## Goal

A SwiftUI sign-in view on both iOS and macOS that opens an `ASWebAuthenticationSession`, completes plue's OAuth2 PKCE authorize flow, stores access + refresh tokens in Keychain, handles silent refresh on 401, and revokes on sign-out — proven end-to-end against a running plue dev instance (once 0106 is live) and against a mocked server for unit tests that can run without 0106.

## Scope

- **In scope**
  - SwiftUI view + view-model at `poc/client-signin/` (or equivalent in the gui app structure) for both iOS and macOS targets.
  - **PKCE code generation:** cryptographically-random verifier, SHA-256 → base64url challenge, persist verifier across the auth session.
  - **`ASWebAuthenticationSession` integration:** open the flow pointing at plue's `/api/oauth2/authorize` with the right parameters; handle the callback URL.
  - **Custom URL scheme** for iOS; `127.0.0.1` loopback on macOS for desktop-remote mode. Match what 0106 registers.
  - **Keychain wrapper** — platform-owned secure-store with atomic update (refresh-token rotation is already enabled on plue's side; failure to atomically persist the new refresh token locks the user out).
  - **Token lifecycle:**
    - On sign-in: POST code + verifier to `/api/oauth2/token`, store tokens.
    - On 401 from any authenticated call: attempt refresh once via `/api/oauth2/token` with `grant_type=refresh_token`; atomically update Keychain; retry original request. Failure escalates to sign-out (per main spec Auth section).
    - On sign-out: POST to `/api/oauth2/revoke`, wipe Keychain + SQLite cache + session state (per main spec).
  - **Whitelist display:** if the server returns the "access not yet granted" structured error during code exchange, render a static message. No retry loop.
  - **Tests:**
    - Unit: PKCE verifier/challenge derivation against RFC 7636 test vectors.
    - Unit: Keychain wrapper roundtrip on simulator.
    - Integration (requires 0106): full sign-in → authenticated call → simulated 401 → refresh → retry → sign-out → revoked.
    - Integration (mocked): XCTest harness that mocks `ASWebAuthenticationSession` + a fake token endpoint, asserts request shape and Keychain writes. Runs without 0106.
- **Out of scope**
  - Plue-side authorize flow (0106).
  - Biometric unlock on token use (follow-up).
  - Multi-account support.
  - Android sign-in UI — Android canary (0104) has no user flow in v1.
  - Linux/GTK sign-in — not in this pass.

## References

- Ticket 0106 — the plue-side prerequisite.
- Apple `ASWebAuthenticationSession` docs.
- RFC 7636 (PKCE), RFC 8252 (Native App OAuth).
- Existing gui repo structure: `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.App.swift` (app entry), `/Users/williamcory/gui/ContentView.swift` (existing shell).

## Acceptance criteria

- iOS + macOS SwiftUI sign-in views compile and run.
- Unit tests for PKCE derivation pass (RFC 7636 vectors).
- Unit tests for Keychain wrapper pass on simulator.
- Mocked integration test (no 0106 dependency) confirms end-to-end request shape and Keychain atomicity.
- Real integration test (requires 0106 live): full sign-in + refresh + sign-out cycle succeeds against a running plue dev instance.
- README covers: custom URL scheme / loopback setup, how to reset Keychain for testing, what happens on whitelist rejection.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the PKCE verifier is actually random per session (not constant), the refresh path persists the new refresh token BEFORE retrying the original request (atomicity), and the sign-out path wipes SQLite cache too (not just Keychain).

## Risks / unknowns

- `ASWebAuthenticationSession`'s cookie isolation means upstream IdP session reuse may or may not work; document behavior on iOS + macOS.
- Refresh token rotation atomicity: if the app crashes between "got new refresh token" and "persisted new refresh token," the user is locked out. Mitigation: write-then-return, not return-then-write. Covered by an explicit test.
- Custom URL scheme collisions on iOS (another app registering the same scheme) — document uniqueness.
