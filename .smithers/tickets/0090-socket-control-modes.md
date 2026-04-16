# Socket Control Modes for Agent/Automation Safety

## Problem

Exposing the app's control socket (tickets 0085 and 0089) opens a new attack
surface. By default it is fine to allow only descendants of the Smithers app
process, but users have good reasons to widen this (external automation,
shared machines, VMs) and equally good reasons to lock it down (shared
untrusted hosts, CI). Without explicit modes, we either pick an unsafe default
or block legitimate use cases.

cmux formalizes this with five modes in
`vendor/cmux/Sources/SocketControlSettings.swift`. Port the model.

## Modes

| Mode | Behavior |
|------|----------|
| `off` | Socket not created. No CLI access at all. |
| `smithersOnly` (default) | Only processes whose PID ancestry descends from the Smithers app (or a PTY it launched) can send commands. |
| `automation` | Any local process owned by the same macOS user may connect. No ancestry check. |
| `password` | Any local process may connect but must complete an HMAC-SHA256 challenge-response using a password stored in a protected file. |
| `allowAll` | Anyone on the local machine may connect. Unsafe. Requires double-confirmation in Settings. |

Socket file permissions:

- `off`: N/A.
- `smithersOnly`, `automation`, `password`: `0o600`.
- `allowAll`: `0o666`.

## Ancestry Check (smithersOnly)

1. On accept, read the peer PID via `SO_PEERCRED` / `LOCAL_PEERPID`.
2. Walk the process tree via `proc_pidinfo`.
3. If any ancestor PID equals the Smithers app PID, accept. Otherwise reject
   with a structured error `auth_ancestry_denied`.

## Password Mode

- Password stored at `~/.config/smithers/socket-control-password` with mode
  `0o600`, directory mode `0o700`.
- Alternative: environment variable `SMITHERS_SOCKET_PASSWORD` for ephemeral
  automation.
- Handshake:
  1. Client connects, server sends a random 32-byte nonce.
  2. Client returns HMAC-SHA256(password, nonce).
  3. Server verifies constant-time. On success, the connection enters the
     normal command loop; on failure, it is closed with
     `auth_password_failed`.
- Support rotating the password in Settings; listeners see the new password
  immediately via a notification; existing authenticated connections remain
  alive.

## Automation Mode

- No ancestry check. Local socket permission (`0o600`) already gates to the
  current user; that is the only enforcement.
- Surface a visible status chip in the app to remind the user they are in
  automation mode.

## allowAll Mode

- Two-step toggle with explicit warning dialog.
- Socket permissions flip to `0o666`.
- Sticky banner in the app while enabled.

## Settings Surface

- Settings → Security → Socket Control:
  - Mode picker with per-mode description (localized).
  - Password field (password mode only).
  - Show/Reset password actions.
  - Link to documentation.

## Implementation Notes

- Introduce `SocketControlMode` enum matching the table above.
- Add `SocketAuthenticator` that wraps every accept() call.
- Add `SocketControlPasswordStore` with file-based storage and optional
  keychain fallback for legacy compatibility if we ever migrate from another
  store.
- Every command handler runs *after* auth succeeds; unauthenticated connections
  cannot reach handlers.
- Audit log (bounded in-memory ring) of recent accept decisions, visible in
  Developer Debug view.

## Non-Goals for First Pass

- Per-command ACLs (some commands readonly, others gated behind higher
  privilege).
- TLS / remote socket support.
- Per-client rate limiting.
- Exporting/importing password across machines.

## Files Likely to Change

- New `Sources/SocketControlSettings.swift`
- New `Sources/SocketAuthenticator.swift`
- New `Sources/SocketControlPasswordStore.swift`
- `Sources/SocketServer.swift` (wire auth)
- Settings view
- Developer debug view (audit log)
- Tests under `Tests/SmithersGUITests`

## Test Plan

- `off`: socket file is absent; CLI connect fails fast.
- `smithersOnly`: PTY child connects; `nc` from a shell started outside the
  app is rejected.
- `automation`: any local user process connects.
- `password`: correct HMAC is accepted; wrong HMAC is rejected; missing
  response times out and is closed.
- `allowAll`: a second user on the machine (test via file permission mode
  check) can connect.
- Mode switch at runtime disconnects existing connections for now-disallowed
  modes and keeps allowed ones.
- Password rotation reflects immediately for new connects; does not break
  already-authenticated connections.
- Constant-time HMAC comparison (microbenchmark sanity test).
- `SO_PEERCRED` / `LOCAL_PEERPID` usage works on macOS in the supported
  versions.

## Acceptance Criteria

- Default mode is `smithersOnly`. Installing the CLI and running
  `smithers identify` from an in-app terminal works without configuration.
- Running `smithers identify` from an external terminal in the default mode
  fails with `auth_ancestry_denied`.
- Users can switch to automation/password/allowAll via Settings, with clear
  warnings for the last.
- Password mode enforces HMAC handshake with constant-time compare.
- Mode changes take effect without restarting the app.
- Audit log records accept decisions and is viewable in Developer Debug.
