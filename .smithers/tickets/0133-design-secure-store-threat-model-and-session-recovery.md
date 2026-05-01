# Design: secure-store threat model and session recovery for mobile OAuth tokens

## Context

The main spec explicitly allows the same user to be signed in on multiple devices (`/Users/williamcory/gui/.smithers/specs/ios-and-remote-sandboxes.md:25`) and stores long-lived access + refresh tokens in the platform secure store (`ios-and-remote-sandboxes.md:215-223`). Ticket 0109 covers local Keychain storage, refresh-token atomicity, and local sign-out (`/Users/williamcory/gui/.smithers/tickets/0109-client-oauth2-signin-ui.md:22-32, 49-58`), but it does not define what happens when:

- a device is lost or stolen while still signed in.
- the app loses the rotated refresh token during a crash.
- a user needs to revoke other Smithers app sessions without physically accessing that device.

Plue already has relevant primitives: OAuth2 refresh tokens are valid for 90 days (`plue/internal/services/oauth2.go:25-27`), revoke can delete a single presented token (`oauth2.go:432-452`), and the service layer already exposes revoke-all-by-app-and-user helpers (`oauth2.go:45, 51`) that no current client ticket consumes.

## Goal

Write the auth/session-recovery threat model for gui clients so 0109, 0106, and any follow-up server work have an explicit answer for lost-device recovery, refresh-token failure modes, and remote session revocation.

## Scope

- **In scope**
  - Threat-model document covering:
    - assets: access token, refresh token, local SQLite cache, PKCE verifier, callback URLs.
    - trust boundaries: secure store, app process, `ASWebAuthenticationSession`, plue OAuth2 endpoints.
    - attack/failure scenarios: lost device, stolen unlocked device, custom-URL-scheme collision, refresh rotation crash window, local cache surviving auth loss, iCloud/backup restore.
  - Decide which mitigations belong in existing tickets versus new follow-ups:
    - 0109 client-only behavior.
    - 0106 server-side OAuth2 flow.
    - new server/session-management work if remote revoke or “sign out other devices” needs an API surface.
  - Decide whether the gui public OAuth2 client needs per-device session labeling or whether app-wide revoke is enough for v1.
  - Define the recovery UX for:
    - refresh token rejected or missing.
    - user removed from whitelist.
    - remote session revoked on another device.
  - Produce concrete follow-up tickets if the answer requires server work beyond 0106/0109.
- **Out of scope**
  - Implementing the recovery UI or server API.
  - Biometric gating for every token use.
  - Multi-account support.

## References

- `/Users/williamcory/gui/.smithers/specs/ios-and-remote-sandboxes.md:25` — multi-device same-user is in scope.
- `/Users/williamcory/gui/.smithers/specs/ios-and-remote-sandboxes.md:215-223` — secure-store and sign-out rules today.
- `/Users/williamcory/gui/.smithers/tickets/0109-client-oauth2-signin-ui.md:22-32` — current client auth scope.
- `/Users/williamcory/gui/.smithers/tickets/0109-client-oauth2-signin-ui.md:49-58` — current acceptance criteria stop at local sign-in/refresh/sign-out.
- `plue/internal/services/oauth2.go:25-27` — token lifetimes.
- `plue/internal/services/oauth2.go:45, 51` — revoke-all-by-app-and-user helpers exist in the service contract.
- `plue/internal/services/oauth2.go:432-452` — current public revoke path is single-token based.

## Acceptance criteria

- A design doc exists under `.smithers/specs/` describing the threat model, chosen mitigations, and explicit non-goals.
- The doc covers at least these scenarios: lost device, stolen unlocked device, app crash during refresh-token rotation, revoked/expired refresh token, whitelist removal, and remote-session recovery.
- The doc states whether v1 supports:
  - local-device sign-out only.
  - app-wide revoke for all Smithers sessions.
  - per-device session revocation.
- If additional server/client work is required, the doc names concrete follow-up tickets or explicitly expands 0106/0109 scope.
- Reviewer can point to one chosen recovery path for “I lost my phone but still have my laptop” and one for “refresh rotation corrupted the local token set.”

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the doc is not just a generic OAuth checklist, checks that each scenario maps to a concrete product behavior, and confirms the recommendations line up with the real plue primitives already present in `oauth2.go`.

## Risks / unknowns

- The existing service helpers delete tokens by app and user, not by device label. If v1 needs targeted remote revoke, that is a real server feature, not a Keychain tweak.
- iOS custom URL schemes are susceptible to collision by another installed app. The design should explicitly say whether that is acceptable for v1 or whether additional mitigations are required.
- Over-scoping this into a full “session management UI” ticket would be a mistake. The deliverable is the security decision and the follow-on work list.
