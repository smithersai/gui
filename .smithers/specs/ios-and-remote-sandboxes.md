# iOS App And Remote Sandboxes

Status: in progress (designing).

## Summary

Smithers splits into an **engine** (owns PTYs, workspaces, subprocess lifecycle, and the control-protocol server) and a **client** (`libsmithers-core`: models, control-protocol client, devtools state machines, libghostty as a pipes-backed renderer). The engine is **JJHub itself** (`/Users/williamcory/plue/`, Go) for remote mode — specifically the existing `cmd/guest-agent/` + `internal/sandbox/` + workspace/terminal/agent-session route infrastructure. For desktop-local mode, we ship a standalone Go binary that reuses plue's packages as a library. The client ships as a Zig framework linked into both the macOS and iOS apps. SwiftUI on both platforms binds to the same Zig client via FFI. iOS connects only to JJHub sandboxes; desktop connects to either local or a JJHub sandbox. JJHub is the identity provider and owns sandbox lifecycle.

A JJHub sandbox *is* a workspace. Workspaces are either local (desktop only) or remote (a sandbox). They are never both; there is no sync layer between them.

## Goals

- One SwiftUI codebase, two targets (macOS, iOS); identical feature set when both point at a JJHub sandbox, including terminal rendering via libghostty.
- One control-protocol schema as the sole contract between client and engine.
- iOS has full authoring capability: create chats, drive runs, approve, inspect.
- JJHub is the identity provider; no separate account system.
- Reuse libghostty's pipes backend on iOS (reference: `ghostty-org/ghostty` iOS target, `vivy-company/vvterm`).
- `libsmithers-core` avoids spawning processes and walking arbitrary filesystems. It *does* own platform-appropriate terminal rendering (libghostty pipes backend) and a bounded local SQLite cache for Electric-synced state. It compiles for macOS, iOS, Linux, and Android. A pure-wasm build is not in scope — a future web client would swap the renderer and storage backends, not reuse them.

## Non-goals

- Peer-to-peer iOS ↔ desktop connections.
- Running the engine outside "local desktop" or "JJHub sandbox" in this pass (no self-hosted, no generic SSH, no shared multi-tenant hosts).
- Offline mode on iOS beyond a graceful empty state.
- Multi-user sharing of a single sandbox. Multi-device same-user is partially in scope: both devices may be signed in and see synced state (chats, runs, approvals) via Electric, but **shared PTY attachment** on a single terminal session from two devices at once is NOT in scope for v1. Today plue's `workspace_terminal.go:124` calls `GetSSHConnectionInfo` which goes through `buildWorkspaceSSHConnectionInfo` (`internal/services/workspace_ssh.go:93, 105`) — each WebSocket connect mints fresh SSH credentials and opens an **independent shell**. So a second device does not "kick the first off," it just opens its own parallel terminal. That's not shared attach; it's isolated shells per device. Designing real multi-client PTY multiplexing is tracked as its own PoC (ticket 0102). Other state (chat, runs, approvals) stays in sync across devices via Electric.
- Sync layer for local workspaces (they stay in libsmithers' own SQLite on desktop; only remote workspaces use Electric).
- Syncing or unifying a local workspace with a remote workspace of the same repo.
- A web client in this pass — but `libsmithers-core` should not foreclose one.
- A polished Android app in this pass, and no Android user-facing release. An Android WIP build exists purely as a **continuous build canary** in CI: `libsmithers-core` must compile for `aarch64-linux-android` and link into a minimal Kotlin test app on every PR. If that build breaks, the PR is blocked — that's the only load-bearing role Android plays in this spec. "Ships alongside iOS" would overclaim; the canary exists so that architectural decisions don't foreclose a future Android release, not to serve Android users now.

## Key Decisions So Far

### Three-piece architecture, not two

- `libsmithers-engine` — owns system: process spawning, PTY, filesystem walks, SQLite persistence of engine state, ghostty process hosting. Runs on desktop-local or inside a JJHub sandbox.
- `libsmithers-core` — client runtime. Includes models, control-protocol client, devtools/chat state machines, libghostty rendering (pipes backend), and a bounded local SQLite cache that stores Electric-synced state. Avoids spawning processes or walking arbitrary filesystems, but does use SQLite as its persistence primitive. Target platforms: macOS, iOS, Linux, Android. Wasm/web is not a target in this pass (see Goals).
- Platform UI — SwiftUI on macOS/iOS, GTK on Linux. Binds to `libsmithers-core` via FFI. Never talks to the engine directly; always goes through core.

### Settings stay in Swift, engine state is synced via Electric to bounded client SQLite

- User-facing settings (vim mode, dev tools toggle, browser engine, layout fractions, etc.) live in `UserDefaults` via `@AppStorage`. Device-local. libsmithers has no opinion.
- Engine operational state (sessions, chats, workspaces, pending approvals, etc.) lives in plue's Postgres, synced to every connected client via ElectricSQL shape subscriptions. Each client keeps a bounded local SQLite cache, managed by `libsmithers-core`. See Section 4 for the full client architecture.
- On iOS (always remote), the bounded SQLite cache means the app always has a last-known snapshot to render while shapes reconnect; no "blank screen on reconnect" UX.

### Workspace identity: local XOR remote

- A workspace is tagged `{ local, path }` or `{ remote, sandbox_id }`. Never both.
- The UI workspace list is a union of local workspaces (from libsmithers SQLite, desktop only) and remote sandboxes (from the JJHub API). iOS sees only the remote half.
- The same repo appearing locally and in a sandbox = two independent workspaces. No deduplication, no sync.

### iOS feature parity

- iOS in JJHub mode gets the full authoring surface: create chats, drive runs, inspect, approve, terminal output.
- The only iOS exclusions are features that are intrinsically local-mode-only (process embedding, local ghostty windows, OS-level PTY access) — and these are desktop-local-only even on desktop, not iOS-specific.

### Transport

- WebSocket (bytes) + SSE (events) + JSON (control). Matches JJHub's incumbent transport and the mobile Claude Code prior art. gRPC/protobuf was considered and rejected; see Component Boundaries → Transport.

## Component Boundaries

### Language per piece

- **Engine** — **Go.** We do *not* build a new engine. The engine **is JJHub** (`/Users/williamcory/plue/`). For remote mode: `cmd/guest-agent/` runs inside the sandbox and brokers PTY/workspace/session capabilities; `internal/sandbox/` handles lifecycle; `internal/routes/workspace_terminal.go`, `agent_sessions.go`, `agent_session_stream.go`, and SSE handlers in `workspace.go` (`StreamWorkspace`, `StreamSession` at `workspace.go:642–723`) handle client-facing endpoints. For desktop-local mode: a standalone Go binary (new build target in plue) reuses the same internal packages without the JJHub server shell around them.
- `libsmithers-core` — **Zig.** Portable client logic: models, control-protocol client, devtools/chat state machines, libghostty renderer glue, bounded SQLite cache. Target platforms: macOS, iOS, Linux, Android. Wasm/web is explicitly not a target in this pass (see Goals). Stack policy tier 1.
- Platform UI — **native per platform.** SwiftUI on macOS/iOS, GTK on Linux, Jetpack Compose on Android (experimental). Links `libsmithers-core` via FFI. Stack policy tier 4.

Engine and core meet only over the network protocol. Platform UI talks only to core.

### The invariant

**Platform UI → core → (local or remote) engine.** The platform never sees the engine. On desktop-local, core connects to the standalone engine binary over a localhost WebSocket/HTTP listener; on iOS/desktop-remote, core connects to JJHub's user-facing endpoints (which proxy to the sandbox's guest-agent over SSH). The platform cannot tell the difference.

### Engine: reuse plue, don't rebuild

Rejected alternatives:

- **Build a separate engine service (Go or otherwise) parallel to JJHub.** Rejected: JJHub already owns sandbox lifecycle, auth, guest-agent, PTY-over-SSH proxying, and SSE fan-out via Postgres `LISTEN/NOTIFY`. Rebuilding is pure duplication.
- **Extend JJHub with a new gRPC transport.** Rejected: JJHub's existing client surface is HTTP with WebSocket (terminal) + SSE (event streams) + JSON payloads, and `github.com/coder/websocket` is already the incumbent. Adding a second transport is cost with no customer-visible win. See the transport subsection below.
- **All-Zig engine.** Rejected even before JJHub was on the table: Zig has no working gRPC and std lacks HTTP/2; building either from scratch is 2–4 engineer-months on infrastructure that isn't the product.

### Transport

Three wire protocols, chosen to match plue's incumbent patterns:

- **ElectricSQL shapes over HTTP** for synced structured data (sessions, chats, workspace state, approvals, runs). Plue already has the auth proxy in `internal/electric/` + `cmd/electric-proxy/`; we become the first Go-side consumer. Shapes are filtered-query subscriptions with initial snapshot + live deltas; client stores rows in a bounded local SQLite cache. See Section 4.
- **WebSocket** for byte streams (PTY terminal). Binary frames for bytes, text frames for control (resize). Matches `workspace_terminal.go`.
- **Plain HTTP + JSON** for writes. Some writes use existing plue routes (create session, append message, cancel run — all live today); others are net-new routes landing in their own tickets (`decide approval` in 0110; canonical run paths in 0111). "Dispatch run" is **implicit** via posting a `user`-role message (`agent_sessions.go:280`) — canonical client contract, no separate dispatch route; see [`ios-and-remote-sandboxes-dispatch-run.md`](ios-and-remote-sandboxes-dispatch-run.md) (ticket 0108). Results arrive back at the client via the shapes they're already subscribed to.
- **SSE fallback** for append-only event feeds that don't model as "rows in a table" — today plue exposes workflow-run log streams via `WorkflowRunLogsStream` (`internal/routes/workflow_runs.go:36`) with `log`/`status`/`done` payloads, and agent-session events via `agent_session_stream.go`. Uses `Last-Event-ID` resume. If v1 needs a richer per-run tool-call timeline beyond what `WorkflowRunLogsStream` currently emits, that's a plue addition, not something we can assume is already there.

**Schema contract:** Go types in plue are the source of truth. Shapes are defined in plue alongside the Postgres tables they filter. Shape definitions and write-DTO types mirror to Zig (`libsmithers-core`) and TypeScript. No protoc; shared types are Go-authored with generators.

### Cut against the current `libsmithers/src/` tree

- **Deleted or folded into plue:** anything engine-shaped that has a plue equivalent.
  - `session/pty.zig` → plue already has this via `workspace_terminal.go` + guest-agent PTY.
  - `workspace/cwd.zig` → plue workspaces.
  - `persistence/sqlite.zig` → **repurposed, not deleted.** The engine-state tables (`workspace_sessions`, `workspace_chat_sessions`, `recent_workspaces`) move to plue Postgres, but the SQLite wrapper stays and becomes the backing store for `libsmithers-core`'s bounded Electric cache. Schema is replaced; code is reused.
  - `apprt/embedded.zig` — engine-side portions deprecated.
- **Stays Zig, becomes `libsmithers-core`:**
  - `devtools/ChatStream.zig`, `ChatOutput.zig`, `Stream.zig`, `Snapshot.zig`, `DevToolsClient.zig` — state machines over byte streams.
  - `models/app.zig` and sibling model files — pure data.
  - `commands/palette.zig` — pure command resolution.
  - **New:** control-protocol client (WebSocket/SSE/HTTP + JSON).
  - **New:** libghostty renderer glue (pipes backend).
- **`ffi.zig`** — engine-backed calls are removed; FFI surface becomes core-only.

### Protocol schema location

Authoritative JSON schemas live **in plue** alongside the handlers (likely `plue/pkg/wireschema/` or similar). Generated/mirrored type bindings are consumed by Zig (`libsmithers-core`) and any TypeScript clients. The gui repo does not own the schema.

## Changes Needed In Plue

What plue already covers, and what we'd need to add. Gaps were catalogued by reading the plue tree at `/Users/williamcory/plue/`.

### Already covered — no plue changes needed

- **Sandbox lifecycle.** `POST/GET/DELETE /api/repos/{owner}/{repo}/workspaces[/{id}]`, plus `/suspend` and `/resume`. Auth-gated. `workspace.go:68–251`.
- **Authentication primitives.** Bearer-token verification (`Authorization: Bearer jjhub_xxx` via `middleware/auth.go:56`), Auth0 + WorkOS browser flows (`cmd/server/main.go:901`, `internal/routes/auth.go:25`) that today terminate in a **session cookie** for browser users or a **one-off CLI token** for `callback_port` flows (`internal/routes/auth.go:245, 416`), session cookies, and a separate **OAuth2 application + PKCE flow** (`cmd/server/main.go:917, 1244`, `internal/routes/oauth2.go:165`) that does mint refreshable bearer+refresh tokens. **Gap for this spec:** no public OAuth2 client is registered for the gui/iOS apps today, and the Auth0/WorkOS browser flow alone doesn't hand the mobile app a refreshable token pair. Closing that gap is a named prerequisite (ticket 0106).
- **Agent sessions (chat).** Create, list, get, delete, append message. `POST /api/repos/{owner}/{repo}/agent/sessions[/{id}/messages]`. `agent_sessions.go`. **Note:** there is no explicit dispatch route on the public repo-scoped API; **run dispatch happens implicitly when a `user`-role message is posted** (`agent_sessions.go:280`). This is the canonical client contract — see [`ios-and-remote-sandboxes-dispatch-run.md`](ios-and-remote-sandboxes-dispatch-run.md) for the decision (ticket 0108).
- **Event streams (SSE).** Workspace status, session status, agent session events — all with Postgres `LISTEN/NOTIFY` fan-out and Last-Event-ID resume. `workspace.go:642–723` (StreamWorkspace, StreamSession), `agent_session_stream.go`, `internal/sse/`.
- **Terminal over WebSocket.** Binary frames for stdin/stdout, text JSON `{type:"resize",cols,rows}` for control. Proxies to SSH into the sandbox. `workspace_terminal.go:83–268`.
- **Guest agent baseline.** Vsock daemon inside the Firecracker VM (port 10777) handling Exec, WriteFile, ReadFile, systemd units, snapshot hooks, idle-timeout signalling. `cmd/guest-agent/`, `internal/sandbox/guest/`.

### Additions — net-new to plue, no breaking changes

1. **Wire up Electric on the Go side.** Infrastructure (`internal/electric/` proxy + `cmd/electric-proxy/`) is staged but has no Go-side consumers and no Go-side tests. We need to:
   - Stand up an upstream `electric` service for local development. In the PoC phase (ticket 0096) this lives in a PoC-local compose fragment; a follow-up promotes it to plue's canonical `docker-compose.yml` only after the shape set is stable.
   - Define the shape set the client subscribes to (one per synced-data table: `agent_sessions`, `agent_messages`, `workspace_sessions`, `runs`, `approvals`, etc.).
   - Port the lessons from `oss/packages/sdk/src/services/sync.ts` (write queue, conflict handling, shape lifecycle) into our Zig client design rather than into plue — the Go server stays thin, all the sync smarts live in `libsmithers-core`.
   - Add Go tests for `internal/electric/` (it has zero today).
2. **Run lifecycle — mostly reuse existing routes.** An earlier draft of this spec claimed plue had no run cancel/inspect/events routes. That was wrong. Plue already exposes:
   - `GET /api/repos/{owner}/{repo}/actions/runs/{id}` — inspect (`internal/routes/workflow_runs.go:36`).
   - `POST /api/repos/{owner}/{repo}/actions/runs/{id}/cancel` — cancel (registered in `cmd/server/main.go:1149–1152`).
   - `GET /api/repos/{owner}/{repo}/runs/{id}/logs` and `.../workflows/runs/{id}/events` — SSE log/event stream (`cmd/server/main.go:785,789,1340`; `internal/routes/workflows.go:257`).
   
   The only delta needed is to **expose run status as an Electric shape** so clients sync passively without polling, and to reconcile whatever route-path naming we want the new client to consistently use (existing paths are `/actions/runs/...` and `/workflows/runs/...`; picking one canonical form for the spec avoids client confusion).
3. **Approval flow.** No human-in-the-loop approval concept exists in plue today (only `protected_bookmarks.required_approvals`, which is branch protection). We need:
   - A first-class `approvals` table (pending/approved/rejected/expired, tied to an agent session or run).
   - Shape subscription so every connected client sees pending approvals live.
   - `POST /api/repos/{owner}/{repo}/approvals/{id}/decide` for the action.
4. **Generic devtools snapshot endpoint.** Plue has `diffview/` but it's VCS-tied (jj change diffs). We need a generic devtools surface — snapshot of whatever the agent is looking at (screen, file tree, command output). Shape: SSE feed of typed snapshot events from the guest-agent.
5. **Multi-client PTY attach — out of scope for v1.** `workspace_terminal.go` today creates one SSH session per WebSocket and tears it down on close (`workspace_terminal.go:117, 124, 203, 251, 324`). Each connecting client mints fresh SSH credentials and opens an **independent shell** — two devices do not share a view and neither kicks the other off. Proper multi-client *shared-view* attach requires either session multiplexing in the handler or a new "attach existing PTY" mode in guest-agent — this is a PoC (ticket 0102) that de-risks the design, but the spec does not assume multi-client shared-PTY for v1.

### Guest-agent extensions

- **PTY spawn/read/write methods.** Today PTY lifecycle lives in `workspace_terminal.go` via SSH. Moving it into guest-agent (`MethodSpawnPTY`, `MethodPTYWrite`, `MethodPTYRead`) would let the JJHub server delegate cleanly and would make the engine/guest split cleaner for desktop-local mode reuse. Optional but probably worth it.
- **Approval-event emission.** Whichever subsystem in the guest decides an action needs approval raises a structured event the guest-agent forwards. Depends on where approvals actually get authored (agent runtime vs. jjhub server).

### Desktop-local mode — tracked in a separate spec

Desktop-local is structurally different enough from the iOS-and-remote-sandboxes work that it gets its own spec (TBD: `ios-and-remote-sandboxes-desktop-local.md`). High-level intent — one client binary that speaks the same protocol whether local or remote — remains part of this spec's goals, but the concrete work (new plue `cmd/` entry, listener choice, Postgres-vs-SQLite on the engine side, degenerate sandbox lifecycle, auth bypass via socket permissions) lives there. The migration plan (ticket 0100) must not block on desktop-local landing.

### Summary: changes-needed bill of materials

| Area | Plue today | Delta |
|---|---|---|
| Sandbox CRUD | ✅ | — |
| Auth | ✅ | — |
| Agent sessions (chat) | ✅ | — |
| Workspace/session SSE | ✅ | — |
| Terminal WS (single-client) | ✅ | — |
| Multi-client PTY attach | ❌ | out of scope v1; tracked in PoC-B4 |
| Run control | ✅ (dispatch, inspect, cancel, SSE log/event streams all present) | expose run status as Electric shape; pick canonical route naming |
| Approvals | ❌ | full flow |
| Generic devtools snapshot | ❌ (VCS-only) | new surface |
| ElectricSQL | staged (proxy + cmd exist, zero consumers, zero Go tests) | first Go consumer, define shapes, add upstream service to docker-compose, add Go tests |
| Sandbox quota enforcement | not enforced | hard cap at 100 per user in `POST .../workspaces` |
| Desktop-local mode | ❌ | tracked in separate spec |

## Client Architecture

`libsmithers-core` (Zig) is the client runtime. It owns three network surfaces and one local store, and it exposes a single FFI for platform UIs.

> Failure modes across all four surfaces (auth expiry, shape ACL deny, WebSocket origin reject, network transient, schema mismatch) map to the error taxonomy in [`ios-and-remote-sandboxes-observability.md` §4](ios-and-remote-sandboxes-observability.md#4-error-taxonomy). The client metrics called out below (shape count, WS reconnect, SQLite bytes, etc.) are defined in [observability §2.1](ios-and-remote-sandboxes-observability.md#21-client-side-libsmithers-core).

### Network surfaces

1. **Electric shape client.** HTTP client for plue's `/v1/shape` auth-proxied endpoint. Implements the ElectricSQL shape protocol (initial snapshot + long-poll for deltas, offset/shape-handle tokens for resume). DIY Zig, ~500–800 LOC, referenced against `@electric-sql/client` and the TS sync code in `oss/packages/sdk/src/services/sync.ts`. Handles its own reconnection — no platform-visible "offline" state beyond what the UI chooses to show.
2. **WebSocket PTY client.** Uses a Zig WebSocket lib; connects to `workspace_terminal.go`, binary frames to/from libghostty's pipes-backend renderer. Resize messages as text JSON.
3. **HTTP JSON writes.** Plain HTTP + JSON against plue's existing REST routes for user actions (send message, decide approval, dispatch run, cancel run, etc.). Writes are **pessimistic** in v1: the UI awaits the shape echo before showing the new state, so we don't need optimistic-rollback machinery. Revisit if it feels sluggish.
4. **SSE client** (fallback, for run event traces that don't fit the shape model). `Last-Event-ID` resume.

### Local store

- **One bounded SQLite per engine connection.** On Apple platforms and Android, uses system SQLite (no vendoring). On Linux, same.
- **Schema is plue's Postgres schema, subset to the shapes we subscribe to.** Generated from the Go types in plue.
- **LRU eviction is at the shape-subscription level, not row-level.** Each shape is one active subscription; closing a chat tab unsubscribes its shape after a configurable TTL; the shape's rows then age out of the local SQLite on the next compaction. Some shapes are **pinned** (current workspace summary, pending approvals list) and never evicted.
- **Max concurrent shapes** is a `libsmithers-core` config knob. Default proposal: 50 on desktop, 25 on iOS (memory-constrained).
- Platform UI never sees SQLite. It gets typed, observable state via FFI callbacks.

### FFI boundary

- One session object per engine connection. Session owns the SQLite, owns the three network clients.
- Platform calls on the session: `subscribeToShape(name, params) -> handle`, `unsubscribe(handle)`, `pin(handle)`, `unpin(handle)`, `write(action, payload) -> future`, `attachPTY(sessionId) -> handle`, and queries like `getMessages(sessionId, limit, offset)` which read straight from SQLite.
- Event delivery to platform: callback pointers registered at subscription time. Core owns an event-loop thread; callbacks are invoked on that thread; the FFI glue marshals to the platform's main thread (dispatch_main on Apple, GDK main context on GTK, main Looper on Android).
- **Settings and connection credentials are platform-owned**, not core-owned. Core gets them injected at session construction. Keychain / libsecret details never leak into core.

### Threading model

- One event-loop thread inside `libsmithers-core`, owned by the session. All Electric / WebSocket / SSE / HTTP I/O and SQLite reads/writes happen here.
- Platform UI never blocks on core work. FFI calls are either synchronous-fast (SQLite reads) or futures that resolve via callback.
- libghostty rendering runs on its own thread, fed by the PTY WebSocket client. The renderer produces frames for the platform compositor to display.

## Auth

### Identity

- **JJHub is the identity provider.** Clients authenticate via plue's **OAuth2 application + PKCE flow** (`cmd/server/main.go:917, 1244`, `internal/routes/oauth2.go:165`), with Auth0 or WorkOS as the upstream IdP behind it. This is the flow that returns refreshable bearer + refresh tokens — exactly what a mobile/desktop-remote client needs. The Auth0/WorkOS browser flows alone (`internal/routes/auth.go:25`) terminate in session cookies or one-off CLI tokens and are not sufficient on their own for mobile.
- **Registration is a prerequisite.** No public OAuth2 client for the gui/iOS apps exists in plue today. Registering that client, wiring PKCE handoff, and implementing the iOS/macOS sign-in shell is ticket 0106 — Stage 0.
- GitHub is *not* a user sign-in option in v1. The existing `internal/auth/github.go` supports repo access only.
- **Access is whitelist-gated.** Being whitelisted is expressed through the ability to obtain a plue-issued bearer token (`jjhub_xxx`). An unwhitelisted user may complete OAuth with the upstream IdP but receives no JJHub token; the client treats this as "access not yet granted" and shows a static message. No self-serve onboarding in this pass.
- **Single account per device.** Multi-account is a non-goal; the client stores exactly one set of credentials.

### Token lifecycle

- **Storage:** access + refresh tokens in the platform secure store — Keychain on iOS/macOS, libsecret on Linux, Android Keystore on Android. Platform-owned, injected into `libsmithers-core` at session construction. Tokens never appear in files or logs.
- **Attachment:** every HTTP request, Electric shape subscription, and WebSocket upgrade attaches `Authorization: Bearer jjhub_xxx` via metadata. Core handles this — platform UI never sees the token.
- **401 handling:** core attempts a refresh once. On refresh success, the original request is retried transparently. On refresh failure (expired refresh token, revoked token, user removed from whitelist), core raises an auth-expired event; the platform drops back to the sign-in screen and wipes state per the sign-out rule below.
- **Proactive refresh:** core refreshes at ~80% of the access token's TTL if a request is in flight or pending. No silent background refresh when the app is fully idle.

### Sign-out

- **Sign-out always destroys local cache.** One mode, not two. Wipes: bounded SQLite, Keychain entries, any session-scoped `UserDefaults`, connection state. Prevents the class of bugs where a stale cache survives a credential change.
- **Sign-out scope is app-wide for v1:** calling sign-out revokes every OAuth2 session for this user on this plue OAuth2 app, not just the local device. Threat-model rationale, "lost device" recovery, and the full set of secure-store decisions live in [`ios-and-remote-sandboxes-secure-store.md`](ios-and-remote-sandboxes-secure-store.md) (ticket 0133).
- After sign-out, the user lands on the sign-in screen in the same state as a fresh install. Device-level settings (theme, font size, non-session prefs) persist.

### Desktop vs. iOS

- **Desktop-local mode:** no auth. The engine listens on a Unix socket (macOS/Linux) or a user-bound named pipe; OS-level permissions are the trust boundary. Core connects by path, no token attached.
- **Desktop-remote mode (sandbox):** identical to iOS — plue-issued bearer token, attached to every request to plue.
- A single user can have both a local workspace and one or more remote sandboxes open in tabs simultaneously. Each tab is its own session with its own auth context (or none, for local). Sign-out of the JJHub account closes all remote tabs and wipes remote cache; local tabs are unaffected.

## Sandbox Lifecycle UX

### Boot and connect

- **Block the workspace UI until connected.** No half-loaded state; the user sees a loading screen from "tapped a sandbox" through "first shape snapshot received."
- Sandboxes boot fast in the common case, so no special warming/cold-start distinction surfaces in the UI by default.
- **Slow-boot escape hatch:** after N seconds (proposed: 8s), show "This is taking longer than expected" with no other action. After 30s, allow the user to cancel and pick a different sandbox. Do not expose underlying states ("booting VM," "restoring snapshot") — they're implementation detail.

### Reconnection

- If the connection drops mid-session, show the idiomatic platform indicator (iOS: spinner in a corner pill; macOS/Linux: toolbar indicator). Do not block the UI — the bounded SQLite cache already has a last-known snapshot to render.
- Reconnection is partly transparent: Electric shapes resume from their last offset seamlessly (bounded cache has a last-known snapshot to render against). For PTY, the current plue handler (`workspace_terminal.go`) creates one SSH session per WebSocket and tears it down on close; on reconnect the client opens a fresh terminal session, not the one that was running (see Non-goals — multi-client / session-survive PTY is out of scope v1). The user is never asked to re-authenticate unless the token has actually expired.

### Quota

- Every authenticated user is allowed **up to 100 active workspaces**. No payment or plan tiers in this pass.
- **What counts as "active":** only workspaces whose state is **not** `deleted` (or whatever plue's equivalent soft-delete state ends up being). Today plue's `DeleteWorkspace` (`internal/services/workspace_lifecycle.go:53`) only stops the VM and leaves the row in place — so for the quota promise to work, ticket 0105 must either (a) transition the row to a `deleted` terminal state that this count excludes, or (b) add a hard-delete path that the client calls. The "delete one to continue" UX copy depends on the choice — pick it in 0105.
- **Enforcement paths:** plue must count against the cap at every path that can produce a new workspace for a user — at least `POST .../workspaces`, `POST .../workspaces/{id}/fork`, and any other creator. Note that `POST .../workspaces` on the same repo may reuse the primary workspace rather than creating a new one (`internal/services/workspace_provisioning.go:131`); the enforcement logic must match that semantic so reuse doesn't falsely count.
- Over-quota returns a structured error the client renders as "you've reached your workspace limit — delete one to continue." Precise text may evolve based on the hard-delete vs. soft-delete decision in 0105.

### First run (new user)

- iOS: OAuth sign-in through JJHub → lands on an empty "no sandboxes yet" screen → one CTA: "Create your first workspace." Creation flow picks a repo (scoped to repos the user has access to via JJHub) and boots a sandbox.
- Desktop: same flow, plus the option to open a local workspace instead. "Local" and "Remote" are visually separated in the tab/switcher.

### Workspace switcher

- A single list, recent-first by last-accessed. No pagination needed at 100-item cap.
- On iOS: full-screen modal; on desktop: sidebar section or dropdown.
- Delete sandbox is an explicit action with confirmation. No auto-GC in this pass — user owns the lifecycle.

### State ownership summary

| Data | Source of truth | Where the client stores it |
|---|---|---|
| Agent sessions, messages | plue Postgres | bounded SQLite via shape |
| Workspace state | plue Postgres | bounded SQLite via shape |
| Run status | plue Postgres | bounded SQLite via shape |
| Pending approvals | plue Postgres | bounded SQLite via shape (pinned) |
| Run event trace (`log` events only (confirmed by reading `plue/internal/routes/workflow_runs.go:53` and tests at `workflow_runs_test.go:164` — the handler hardcodes the event type to `log`; status/completion is inferred from payload fields, not separate SSE event types) from `WorkflowRunLogsStream`) | ephemeral, plue-emitted | not stored; rendered live from SSE |
| PTY bytes | guest-agent | not stored; rendered live by libghostty |
| UI settings | device | `UserDefaults` / XDG / etc. |
| Connection credentials | device | Keychain / libsecret |

## Related documents

- Execution plan: `ios-and-remote-sandboxes-execution.md`.
- Production Electric shapes: `ios-and-remote-sandboxes-production-shapes.md`.
- Independent validation checklist (consumed by the `ticket-implement` review step): `ios-and-remote-sandboxes-validation.md`.
- Testing strategy (per-component layers, boundary conditions, CI job set): `ios-and-remote-sandboxes-testing.md`.
- Migration strategy (gui-tree only): `ios-and-remote-sandboxes-migration.md`.
- Rollout plan (phases, feature flags, canary cohorts, kill switches, acceptance gates): `ios-and-remote-sandboxes-rollout.md`.

## Open Questions Tracked Elsewhere

- Warm-pool policy for JJHub sandboxes (cold-start UX).
- Whether JJHub offers per-user KV storage we can use for future follow-me preferences.
- Multi-device same-user semantics (fan-out, resume cursors).
- Schema evolution strategy for the control protocol.
