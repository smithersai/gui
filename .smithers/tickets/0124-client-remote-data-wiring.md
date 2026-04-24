# Client: remote data wiring to shapes, PTY, and writes

## Context

Once `libsmithers-core` exposes the production runtime, the SwiftUI app still has to consume it. Today the view layer is wired around `SmithersClient` and local assumptions. `Smithers.Client.swift:4-140` wraps generic `smithers_client_call` and `smithers_client_stream` entrypoints, and `checkConnection()` still reports `.cli` transport based on a local orchestrator version probe (`1131-1137`). Screens such as `DashboardView.swift`, `RunsView.swift`, `RunInspectView.swift`, `ApprovalsView.swift`, `LiveRunView.swift`, `WorkspacesView.swift`, and `JJHubWorkflowsView.swift` currently bind to that facade rather than to Electric-backed state subscriptions.

The spec says the production client reads synced state from Electric shapes into a bounded SQLite cache, writes via HTTP JSON, keeps PTY over WebSocket, and only uses SSE where the shape model is intentionally not the right fit.

## Problem

Without a dedicated wiring ticket, the new runtime would exist but the app would still render from the wrong data plane. That would block both desktop-remote rollout and iOS parity.

## Goal

Bind the shared SwiftUI views to `libsmithers-core`’s production remote runtime: Electric shape subscriptions for state, WebSocket PTY for terminals, HTTP writes for mutations, and SSE only for the specific append-only traces the spec allows.

## Scope

- **In scope**
  - Replace the remote-mode responsibilities of `SmithersClient` so it becomes a facade over the `0120` runtime session instead of the current generic CLI/local transport wrapper.
  - Introduce the shared observable store layer that consumes runtime callbacks and cached reads for:
    - remote workspace/sandbox summaries,
    - agent sessions, messages, and **message parts** (0118 content bodies),
    - run status and inspect surfaces,
    - pending approvals,
    - any other pinned summary data required for the main shell.
  - Wire the core product surfaces to that store layer:
    - `DashboardView.swift`,
    - `RunsView.swift`,
    - `RunInspectView.swift`,
    - `LiveRunView.swift`,
    - `ApprovalsView.swift`,
    - `WorkspacesView.swift`,
    - any shared shell/workspace list views needed by `0122` and `0126`.
  - Use the production shape slices from tickets `0114`-`0118` as the state source. Specifically: `0114` (agent_sessions envelopes), `0115` (agent_messages headers), `0118` (agent_parts content bodies — required for actual transcript rendering), `0116` (workspaces), `0117` (workspace_sessions). Remote-mode UI should stop polling or treating local SQLite/CLI output as the authoritative state for those entities.
  - Use HTTP writes for create/send/approve/cancel/run actions and wait for the shape echo before considering the UI state committed, per the spec’s pessimistic-write rule.
  - Keep SSE only where the spec explicitly allows it, such as per-run event/log traces that are not modeled as shapes.
  - Integrate auth/session lifecycle with `0106` and `0109`:
    - token injection into runtime sessions,
    - auth-expired handling,
    - sign-out wiping remote cache,
    - reconnect rendering from last-known cache while subscriptions resume.
  - Feed PTY attachment and detach state into the terminal work from `0123` without letting terminal code own the remote transport directly.
- **Out of scope**
  - Build-target setup in `0121`.
  - The terminal renderer portability work itself in `0123`.
  - TestFlight/code-signing release automation in `0125`.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `.smithers/tickets/0110-plue-approvals-implementation.md`
- `.smithers/tickets/0111-plue-run-shape-route-reconciliation.md`
- Tickets `0114`-`0118` (production shape slices, authored in parallel)
- `macos/Sources/Smithers/Smithers.Client.swift:4-140`
- `macos/Sources/Smithers/Smithers.Client.swift:1131-1237`
- `DashboardView.swift`
- `RunsView.swift`
- `RunInspectView.swift`
- `LiveRunView.swift`
- `ApprovalsView.swift`
- `WorkspacesView.swift`

## Acceptance criteria

- Remote-mode state for runs, approvals, sessions/messages, and workspace summaries comes from `libsmithers-core` subscriptions and cached reads rather than CLI/local fallbacks.
- Mutations use runtime-backed HTTP writes and are reflected back into the UI by shape echo.
- SSE is only used where the spec allows it, not as the general state plane.
- Reconnect behavior matches the spec: the app renders last-known cache while subscriptions resume.
- Sign-out wipes remote cache and drops the user back to the sign-in flow from `0109`.
- The shared SwiftUI views named in scope render against the new store layer without requiring per-platform forks.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies that the remote path does not silently fall back to `connectionTransport = .cli`, the main remote views still update when the network is interrupted and resumed, and approval/run/message writes only appear after server echo rather than optimistic local insertion.

## Risks / unknowns

- The shape boundaries from `0114`-`0118` are being defined in parallel, so the shared store API should stay entity-oriented rather than hard-coding table names everywhere in Swift.
- Some existing views likely assume request/response timing or local polling. Those assumptions will surface as subtle UI regressions during the migration.
- If this ticket reaches into macOS-only product behavior, it will overlap with `0126`; keep the boundary at shared data/store wiring.
