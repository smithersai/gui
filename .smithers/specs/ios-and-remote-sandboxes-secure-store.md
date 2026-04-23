# iOS And Remote Sandboxes — Secure-Store Threat Model & Session Recovery

Companion to [`ios-and-remote-sandboxes.md`](ios-and-remote-sandboxes.md) (Auth → Token lifecycle / Sign-out, lines 215–231) and the `ticket-implement`-ready work in [0106](../tickets/0106-plue-oauth2-pkce-for-mobile.md) (plue) and [0109](../tickets/0109-client-oauth2-signin-ui.md) (client). Produced by [ticket 0133](../tickets/0133-design-secure-store-threat-model-and-session-recovery.md). Consumed by reviewers of 0106/0109 and by anyone asking "what happens when the user loses their phone?"

## 1. Summary

This doc decides how gui clients defend the OAuth2 access + refresh tokens held in the platform secure store, and what the user's recovery path looks like when something breaks. **v1 scope is (b): app-wide revoke of all Smithers sessions for the signed-in user.** Plue already exposes `DeleteOAuth2AccessTokensByAppAndUser` and `DeleteOAuth2RefreshTokensByAppAndUser` on the service layer (`plue/internal/services/oauth2.go:45, 51`); 0109 calls these on explicit sign-out, and on the "lost device" recovery path. Per-device labeling (option (c)) is a deliberate non-goal for v1 and is tracked as a follow-up only if telemetry shows it is needed.

**Required recovery paths.**

- **"Lost phone, have laptop."** User signs in on the laptop (desktop-remote build, 0109), taps **Sign out of all devices** in the account menu, which calls the plue admin endpoint described in §7 (or, for v1, reuses `/api/oauth2/revoke` per-token plus a server helper invocation — see §5). Every refresh token for this user + this OAuth2 app is deleted; the lost device's next request 401s, core raises `auth_revoked`, the device wipes local cache on next app launch.
- **"App crashed mid refresh-rotation."** The old refresh token was consumed server-side but the new pair never reached disk. On next launch, the client presents the stale refresh token, plue rejects it (`invalid_grant`), core raises `auth_expired`, the app returns to the sign-in screen with cache wiped. This is *by design*; the fix is not "try to recover the lost token," it is "make sign-in cheap enough that a lockout recovery is a single tap."

Everything below justifies those two sentences.

## 2. Assets

Enumerated for clarity. Anything not on this list is explicitly out of scope.

| Asset | Where it lives | Lifetime | Sensitivity |
| --- | --- | --- | --- |
| **Access token** (`jjhub_...`) | Platform secure store (Keychain / Android Keystore / libsecret), injected into `libsmithers-core` at session construction. | 1 hour (`oauth2.go:26`). | High — bearer for every plue request. |
| **Refresh token** | Same secure store slot, separate key. | 90 days (`oauth2.go:27`), rotated on every use. | Highest — can mint access tokens. |
| **PKCE code verifier** | In-memory in the sign-in view model, per authorize attempt; destroyed on callback or cancel. | Seconds. | Medium — only useful during an active authorize round-trip. |
| **Local SQLite cache** | App sandbox container (`~/Library/Application Support/Smithers/…` on iOS/macOS, libsmithers-core-owned). Not encrypted separately — protected by OS file-level encryption. | Until sign-out or app uninstall. | Medium — contains last-known shape state; no tokens. |
| **Callback URL** (custom scheme on iOS, `127.0.0.1` loopback on desktop-remote) | App bundle registration (Info.plist) / runtime listener. | App install lifetime. | Low — URL itself is not secret; the PKCE verifier is. |
| **Device attestation** (DeviceCheck / Play Integrity / Apple App Attest) | — | — | **Out of scope for v1.** See §8. |

Not in scope: biometric-gated secrets, passkeys, FIDO2 assertions.

## 3. Trust boundaries

- **Platform secure store.** Trusted as long as the device is unlocked. On iOS, Keychain items are written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (set in 0109's Keychain wrapper); on macOS, the default login keychain; on Linux, libsecret under the user session. **Not trusted** against an attacker who has an unlocked device in hand — that is threat scenario 4.2 below.
- **App process.** Trusted only while running. Tokens held in Zig-side memory in `libsmithers-core` are zeroed on session teardown; the Swift/Kotlin/GTK shells never see the raw token (see main spec line 218).
- **`ASWebAuthenticationSession` (iOS/macOS).** OS-mediated. The app does not observe the upstream IdP cookies or credentials; only the final redirect URL + code arrives back in-process. Trust is OS-enforced.
- **Plue OAuth2 endpoints** (`/api/oauth2/authorize`, `/token`, `/revoke`). TLS-trusted. Certificate pinning is **not** in scope for v1 — the cost-benefit versus App Store certificate agility is unfavorable at this stage.
- **Upstream IdP (Auth0 / WorkOS).** Trusted transitively through plue. The client never talks to the IdP directly.

## 4. Threat scenarios + mitigations

| # | Scenario | Impact | Mitigation | Owner |
| --- | --- | --- | --- | --- |
| 4.1 | **Lost device, still signed in, nobody has the passcode.** | None, unless the passcode is eventually guessed / biometrics compromised. Tokens remain usable until the user acts. | User signs in from another device, hits **Sign out of all devices**, which triggers app-wide revoke via plue's `DeleteOAuth2RefreshTokensByAppAndUser` + `DeleteOAuth2AccessTokensByAppAndUser`. Lost device's next request gets 401 → refresh fails → `auth_revoked` → local wipe on launch. Refresh tokens have a hard 90-day cap regardless (`oauth2.go:27`). | **0109** owns the UI + client call. Server helpers already exist — no plue ticket needed. |
| 4.2 | **Stolen unlocked device.** | Attacker can use the app as the user for the current access-token TTL (up to 1h) and beyond if they stay in the app long enough to trigger refresh. | Out-of-band mitigation: user follows scenario 4.1 from another device. No in-app defense — we do not biometric-gate each token use (explicit non-goal, §8). Document this limitation in the 0109 README. | **0109** (docs only). Defense-in-depth (app-level biometric lock on foreground) is a named follow-up, not v1. |
| 4.3 | **Custom URL-scheme collision on iOS.** Another installed app registers the same scheme and intercepts the authorize redirect. | Attacker's app receives the authorization code. Without the PKCE verifier (which never leaves the legit app's memory), the code cannot be exchanged for a token. Worst case: authorize flow fails closed for the legit user. | PKCE is the mitigation; this is RFC 8252's stated reason for mandating it for native apps. Use a sufficiently unique scheme (`com.smithers.app.oauth`, not `smithers`); document scheme uniqueness in 0109 README. Consider universal links as a follow-up once plue can host `apple-app-site-association`. | **0109** picks + documents the scheme. Universal-link follow-up is named §7. |
| 4.4 | **App crash during refresh-token rotation.** Server consumed the old refresh token and issued a new pair; client crashed before persisting the new pair. | User is locked out of the current install. No token leakage. | **Write-then-return:** the refresh HTTP call's caller does not proceed until the new refresh token is atomically written to the secure store. 0109 already mandates this (acceptance criterion + independent validation). Recovery is: sign in again. This is accepted, not prevented — see §5. | **0109** enforces atomicity. No prevention beyond "make sign-in fast"; fully preventing requires a second-chance refresh window server-side, explicitly not planned. |
| 4.5 | **Local SQLite cache surviving auth loss.** Sign-out or forced revoke wipes Keychain but leaves shape state on disk; a later sign-in as a different user (or a forensic pull) sees old data. | Data leakage across principals or to a forensic attacker. | Sign-out is **atomic and total**: wipes Keychain entries, bounded SQLite, session-scoped `UserDefaults`, in-memory connection state (main spec line 224). On `auth_revoked` / `auth_expired` → forced sign-out → same wipe. Android/Linux follow the same contract. | **0109** enforces the wipe on sign-out and on forced-sign-out triggered by `auth_revoked`. |
| 4.6 | **iCloud / backup restore carrying stale tokens to a new device.** | A recycled or re-imaged device could attempt to use a long-dead refresh token. Mostly a nuisance, not a breach. | Keychain items written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — excluded from iCloud Keychain sync and from device-transfer restore. Android Keystore items are not exported by Google backup by default; rely on this (and assert in 0109 tests). Linux libsecret — no cross-device sync. Any token that *does* survive a restore and is stale will 401 on first use → normal `auth_expired` path. | **0109** sets Keychain attributes + adds a test that a Keychain dump does not appear in an iCloud backup manifest. |

## 5. Recovery UX decisions

Three recovery triggers. Each maps to one of the error codes already in the observability doc's §4 table — **no new error class is introduced by this decision** (reusing `auth_expired` and `auth_revoked`).

| Trigger | Server signal | Client behavior | Error code | Owner |
| --- | --- | --- | --- | --- |
| Refresh token rejected or missing | `400 invalid_grant` from `/api/oauth2/token` | Single retry, then forced sign-out → sign-in screen. No modal; inline message on sign-in screen: "Your session expired. Please sign in again." | `auth_expired` (reuse) | **0109** |
| User removed from whitelist | Structured error on code-exchange or on whitelisted-route 403 | Forced sign-out, static message: "Your access was revoked. Contact support if this is unexpected." Do **not** offer re-sign-in; whitelist check will re-fail. | `auth_revoked` (reuse) | **0106** surfaces the structured error; **0109** renders the static message. |
| Remote session revoked from another device | Any authenticated request 401s; refresh 400s because token was deleted by the app-wide revoke call. | Same as "refresh token rejected" — forced sign-out + local wipe. Identical UX to 5.1. | `auth_expired` (reuse; plue cannot distinguish "user explicitly revoked" from "refresh token expired" for the victim device, and v1 chooses not to) | **0109** |

The v1 decision to *not* distinguish "remotely revoked" from "simply expired" on the victim device is deliberate. Distinguishing them requires either (a) per-device session tracking (option (c), rejected for v1) or (b) a revocation-reason column on refresh tokens, which plue does not have today. The current UX — "sign in again if you want to keep using the app" — is correct and ships now.

## 6. v1 scope decision

**Chosen: (b) app-wide revoke for all Smithers sessions of this user.**

Rationale:

- **Existing server capability.** `DeleteOAuth2RefreshTokensByAppAndUser` and `DeleteOAuth2AccessTokensByAppAndUser` are already on the service interface (`plue/internal/services/oauth2.go:45, 51`). Exposing them via a client-callable route is trivial; doing it without a route by calling them server-side on a higher-level "sign out of all devices" endpoint is the path 0109 takes.
- **Covers the lost-phone case cleanly.** The user's mental model is "nuke all my sessions"; app-wide revoke matches it exactly.
- **Smallest surface area.** No new database columns, no device-id plumbing, no per-session UI — the latter would demand a full session-management screen, which is an explicit non-goal (§8).

Alternatives considered:

- **(a) local-device sign-out only.** Rejected: leaves the lost-phone case with no remote remediation. Unacceptable.
- **(c) per-device session revocation.** Rejected for v1. Requires: (i) plue to persist a device-id / user-agent hash on each refresh token, (ii) a "your signed-in devices" list UI on iOS + macOS, (iii) a new error code (`session_revoked_remote`) to distinguish targeted revocation from bulk. Worth doing iff v1 telemetry on the `auth_revoked` event rate suggests users are regularly wanting to revoke one device at a time without touching the others. Follow-up only.

## 7. Follow-up tickets

Work explicitly created or named by this doc.

- **None required for v1 shipping.** The v1 decision (b) closes on existing plue primitives.
- **Named (not filed) follow-ups, gated on telemetry or evidence:**
  - *Per-device session labeling + revocation UI.* Requires plue schema change + client UI. File only if (c) becomes necessary.
  - *Universal-link-based OAuth redirect for iOS* (hardening against scenario 4.3). Requires plue to host an `apple-app-site-association` document. Nice-to-have; PKCE already prevents code exchange by a rogue app.
  - *App-level biometric foreground lock* (hardening against scenario 4.2). UI ticket against 0109 once v1 ships.
  - *Device attestation* (DeviceCheck / App Attest / Play Integrity binding on token issuance). Large-surface, intentionally deferred.

Named drive-by inside 0109's existing scope (not a new ticket):

- 0109 "sign out" acceptance criterion now reads: on sign-out, **call a plue endpoint that invokes `RevokeAllByAppAndUser`** (or, if that endpoint is not yet exposed, iterate `/api/oauth2/revoke` for both the access and refresh token this client currently holds and add a TODO referencing this doc). Either implementation path is acceptable; the eventual target is a single server-side "revoke all" call.

## 8. Non-goals

- **Biometric gate on every token use.** Once unlocked, the app is trusted. Repeated biometric prompts would destroy the mobile UX and are out of scope for v1.
- **Multi-account.** Main spec line 213 — one user per device. Recovery flows assume a single principal.
- **Full session-management UI** ("here are your 3 signed-in devices, revoke this one"). Requires option (c); not v1.
- **Certificate pinning** on OAuth2 endpoints. App Store agility > pinning benefit at this scale.
- **Encrypted local SQLite** (SQLCipher). Relying on OS file-level encryption is sufficient for v1; revisit if telemetry surfaces a threat.
- **Device attestation / binding.** Out of scope; named follow-up only.

---

Cross-references for reviewers:

- Main spec Auth section: [`ios-and-remote-sandboxes.md`](ios-and-remote-sandboxes.md) lines 205–231.
- Execution plan: this doc is adjacent to D-series design tickets — see [`ios-and-remote-sandboxes-execution.md`](ios-and-remote-sandboxes-execution.md) D2/D3 wording.
- Observability taxonomy: [`ios-and-remote-sandboxes-observability.md`](ios-and-remote-sandboxes-observability.md) §4 — `auth_expired` and `auth_revoked` are reused unchanged.
- Validation universal checks: [`ios-and-remote-sandboxes-validation.md`](ios-and-remote-sandboxes-validation.md) §1.
