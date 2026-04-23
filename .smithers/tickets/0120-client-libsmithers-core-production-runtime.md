# Client: libsmithers-core production runtime

## Context

Section 4 of `.smithers/specs/ios-and-remote-sandboxes.md` says the client runtime is a session-per-engine-connection core that owns Electric shapes, WebSocket PTY, HTTP writes, SSE fallback, and a bounded SQLite cache. The current codebase is not shaped that way. `libsmithers/include/smithers.h:66-388` still centers the ABI on a process-lifetime `smithers_app_t`, separate `smithers_session_t`, a `smithers_client_t` described as “daemon/CLI transport,” and global persistence handles. `libsmithers/src/App.zig:21-146` owns workspaces, recents, and persisted session restore. `libsmithers/src/session/session.zig:43-225` still synthesizes local chat/run events. `libsmithers/src/client/client.zig:18-255` still multiplexes devtools helpers, local fallbacks, and CLI shell-outs. `libsmithers/src/persistence/sqlite.zig:73-260` still persists `workspace_sessions`, `workspace_chat_sessions`, and `recent_workspaces`.

The Swift shell mirrors that model. `macos/Sources/Smithers/Smithers.App.swift:41-154`, `Smithers.Session.swift:5-96`, and `Smithers.Client.swift:4-140` each wrap separate app/session/client handles. That is fundamentally different from the spec’s “one session object per engine connection” contract.

## Problem

There is no ticket owning the production implementation of `libsmithers-core`, even though it is the architectural prerequisite for desktop-remote and iOS. Leaving the current `App.zig`-centered model in place would force every client feature ticket to build on the wrong abstraction and duplicate transport/cache logic in Swift.

## Goal

Replace the current `libsmithers/src/App.zig`-centered architecture with the production `libsmithers-core` runtime described in the spec: one runtime session per engine connection, owning Electric subscriptions, WebSocket PTY, HTTP writes, SSE fallback, bounded per-connection SQLite cache, libghostty renderer integration points, and platform-injected OAuth2 token handoff.

## Scope

- **In scope**
  - Redesign the C FFI in `libsmithers/include/smithers.h` so the center of gravity is a connection-scoped runtime session, not the current `app + client + session + workspace` split. The new surface must be sufficient for downstream Swift code to:
    - create/destroy one core session per local or remote engine connection,
    - inject credentials and connection metadata owned by the platform,
    - subscribe/unsubscribe/pin/unpin shape-backed data,
    - query cached rows out of the bounded SQLite store,
    - issue HTTP JSON writes,
    - attach/detach/resize/write PTY streams,
    - observe auth-expired, reconnect, and state-change events.
  - Replace the current responsibilities of `libsmithers/src/client/client.zig` with the production transport coordinator from the spec: Electric over HTTP, WebSocket PTY, HTTP JSON writes, SSE fallback, and the event-loop thread that owns those clients.
  - Replace the current responsibilities of `libsmithers/src/session/session.zig` so it no longer fabricates local chat state as the source of truth. Session state must instead reflect one engine connection and its subscriptions/PTY attachments.
  - Repurpose `libsmithers/src/persistence/sqlite.zig` from local workspace/session persistence to the bounded per-connection cache the spec describes. The old `workspace_sessions`, `workspace_chat_sessions`, and `recent_workspaces` tables stop being the production source of truth for remote mode.
  - Wire the Stage 0 outputs into production code:
    - `0092` libghostty iOS/macOS renderer path,
    - `0093` Zig Electric client,
    - `0094` Zig WebSocket PTY client,
    - `0095` Zig↔Swift observable FFI pattern,
    - `0103` Zig + SQLite on iOS,
    - `0106` + `0109` OAuth2 token handoff from platform secure storage.
  - Update the Swift wrappers in `macos/Sources/Smithers/Smithers.App.swift`, `Smithers.Client.swift`, and `Smithers.Session.swift` so they become thin adapters over the new runtime session, not parallel state machines with their own transport assumptions.
  - Remove remote-mode reliance on the current CLI/local fallback behavior in `libsmithers/src/client/client.zig:50-255`. Remote mode must not shell out to `smithers` CLI or treat local SQLite/devtools files as the source of truth.
  - Keep the migration strategy from `0100` intact: anything required for the separate desktop-local track may stay temporarily behind compatibility shims, but the production remote path must run through the new runtime.
- **Out of scope**
  - SwiftUI view refactors and product behavior changes in `ContentView.swift` and related views.
  - Creating the iOS target and CI wiring in `0121`.
  - Terminal SwiftUI portability work in `0123`.
  - Desktop-local engine-binary design from the sibling desktop-local spec.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/specs/ios-and-remote-sandboxes-execution.md`
- `.smithers/tickets/0100-design-migration-strategy.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- Tickets `0114`-`0117` (production shape slices, authored in parallel)
- `libsmithers/include/smithers.h:66-388`
- `libsmithers/src/App.zig:21-146`
- `libsmithers/src/client/client.zig:18-255`
- `libsmithers/src/session/session.zig:43-225`
- `libsmithers/src/persistence/sqlite.zig:73-260`
- `macos/Sources/Smithers/Smithers.App.swift:41-154`
- `macos/Sources/Smithers/Smithers.Client.swift:4-140`
- `macos/Sources/Smithers/Smithers.Session.swift:5-96`

## Acceptance criteria

- The production remote runtime is session-per-engine-connection, not `smithers_app_t`-centered.
- The FFI exposes connection/session construction, shape subscription management, cached reads, PTY attach/resize/write, HTTP writes, and auth lifecycle hooks required by downstream Swift tickets.
- `libsmithers/src/client/client.zig` no longer uses CLI shell-outs or local fallback paths for production remote behavior.
- `libsmithers/src/persistence/sqlite.zig` stores the bounded cache model from the spec, including pinned-vs-evictable subscription state and sign-out wipe support.
- The Swift wrapper layer compiles against the new FFI and can bootstrap a remote runtime session with platform-supplied OAuth tokens.
- Automated validation covers:
  - shape subscribe + delta application,
  - HTTP write followed by shape echo,
  - PTY attach + resize + stdin/stdout flow,
  - token refresh handoff and auth-expired signaling,
  - cache wipe on sign-out.
- A reviewer can point at the resulting code and see the Stage 0 PoCs embedded in production paths rather than copied into Swift.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the remote path never shells out to `smithers` CLI, the SQLite schema is no longer the old workspace/session persistence schema, and the smoke test talks to a real plue/Electric/WebSocket stack rather than a fake-only harness.

## Risks / unknowns

- This is the biggest ABI churn in the client slice; downstream tickets should not start coding against unstable names.
- The mirrored schema contract lives in plue, so generated types and cache schema changes will move with tickets `0114`-`0117`.
- A sloppy compatibility layer could leave both the old `App.zig` model and the new connection-session model live at once. The migration needs an explicit cut line.
