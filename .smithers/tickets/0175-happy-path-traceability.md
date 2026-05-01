# Ticket 0175 - Happy Path Traceability Review

Date: 2026-04-24

Scope reviewed:
- GUI: `/Users/williamcory/gui`
- Plue: `/Users/williamcory/plue`

## Executive Summary

First break if the iOS app is launched right now: **Step 2 - OAuth2 PKCE flow completes**.

The iOS app defaults to `https://app.smithers.sh` (`ios/Sources/SmithersiOS/SmithersApp.swift:49-67`), but curl probes to that host returned Vercel `DEPLOYMENT_NOT_FOUND` for `/api/oauth2/authorize`, `/api/user`, and `/api/user/workspaces`. Even against local Plue, the hardcoded client id `smithers-ios` has no discovered seed or static registration in the repo, and `POST /api/oauth2/token` returned `401 {"message":"invalid client_id"}`.

There are later missing pieces too: production sign-in does not fetch `/api/user`, created workspaces do not expose a normal session id for terminal mounting, chat posts a text-only payload that Plue treats as an assistant message, the libsmithers PTY client builds the wrong terminal WS path, and there is no production caller that creates approval rows when an agent requests approval.

## Curl Probes

Production default host:
- `GET https://app.smithers.sh/api/oauth2/authorize?...` -> `404 DEPLOYMENT_NOT_FOUND`.
- `GET https://app.smithers.sh/api/user` -> `404 DEPLOYMENT_NOT_FOUND`.
- `GET https://app.smithers.sh/api/user/workspaces` -> `404 DEPLOYMENT_NOT_FOUND`.

Local Plue on `localhost:4000`:
- `GET /api/oauth2/authorize?...client_id=smithers-ios...` -> `401 {"message":"authentication required"}`. Route exists but requires an authenticated web/API session before issuing a code.
- `POST /api/oauth2/token` with `client_id=smithers-ios` -> `401 {"message":"invalid client_id"}`.
- `GET /api/user` -> `401 {"message":"authentication required"}`. Route exists and is auth-protected.
- `GET /api/user/workspaces` -> `401 {"message":"authentication required"}`. Route exists and is auth-protected.
- `GET /api/feature-flags` -> `200`, with `remote_sandbox_enabled:false`, `electric_client_enabled:true`, `approvals_flow_enabled:true`.
- `GET /api/repos/acme/widgets/approvals?state=pending` -> `404 {"message":"repository not found"}`. Approval route stack is reachable, but this unauthenticated probe used a non-existent repo.

## Step Trace

### 1. User taps "Sign in" in iOS app

Status: **PASS**

Trace:
- `ios/Sources/SmithersiOS/SmithersApp.swift:127-155` shows signed-out users get `SignInView`.
- `Shared/Sources/SmithersAuth/SignInView.swift:30-41` wires the primary CTA to `Task { await model.signIn() }`.
- The visible label is `Continue with browser`, not literal `Sign in`, but the intended sign-in action is wired.

No chain break here.

### 2. OAuth2 PKCE flow completes, bearer stored in keychain

Status: **FAIL**

Trace:
- `ios/Sources/SmithersiOS/SmithersApp.swift:49-67` selects `https://app.smithers.sh` by default and hardcodes `clientID: "smithers-ios"` plus `redirectURI: "smithers://auth/callback"`.
- `Shared/Sources/SmithersAuth/AuthViewModel.swift:81-92` generates PKCE/state, starts browser auth, exchanges the code, installs tokens, then marks the app signed in.
- `Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:85-121` uses `ASWebAuthenticationSession` and waits for the `smithers` callback scheme.
- `Shared/Sources/SmithersAuth/OAuth2Client.swift:109-138` builds `/api/oauth2/authorize` and posts `/api/oauth2/token`.
- `ios/Sources/SmithersiOS/SmithersApp.swift:70-80`, `Shared/Sources/SmithersAuth/TokenManager.swift:77-83`, and `Shared/Sources/SmithersAuth/TokenStore.swift:95-126` show the production token store is keychain-backed and would persist tokens if exchange succeeded.
- Plue registers public token exchange at `cmd/server/main.go:930-934` and authenticated authorize at `cmd/server/main.go:1284-1291`.
- Plue authorize requires a current user at `internal/routes/oauth2.go:167-172`, validates the OAuth app/client in `internal/services/oauth2.go:237-244`, and redirects to the registered callback at `internal/routes/oauth2.go:211-225`.

Breaks:
- Production base URL is dead for this API surface: curl to `https://app.smithers.sh/api/oauth2/authorize` returned `DEPLOYMENT_NOT_FOUND`.
- Local authorize cannot complete without an existing authenticated browser/session cookie because `GetAuthorize` immediately rejects missing users (`internal/routes/oauth2.go:167-172`).
- The native client id is hardcoded in GUI, but no repo seed or static registration for `smithers-ios` was found in Plue. Local `POST /api/oauth2/token` with `client_id=smithers-ios` returned `invalid_client_id`; Plue validates client ids through `GetOAuth2ApplicationByClientID` (`internal/services/oauth2.go:237-244`, `internal/services/oauth2.go:326-331`).

### 3. App fetches `/api/user` and returns user

Status: **FAIL**

Trace:
- Client support exists in `Shared/Sources/SmithersAuth/OAuth2Client.swift:153-175`, where `validateAccessToken` sends `GET /api/user` with a bearer token.
- Plue registers `/api/user` at `cmd/server/main.go:1026-1030`.
- Plue handler returns the authenticated profile at `internal/routes/user.go:205-218`.

Breaks:
- Production sign-in does not fetch `/api/user` after token exchange. `AuthViewModel.signIn()` installs tokens and immediately sets `.signedIn` at `Shared/Sources/SmithersAuth/AuthViewModel.swift:90-92`.
- Startup validation is disabled for normal production launches. `startupSessionValidator` is only assigned in E2E mode and is `nil` otherwise (`ios/Sources/SmithersiOS/SmithersApp.swift:82-93`).
- Production curl to `https://app.smithers.sh/api/user` returned `DEPLOYMENT_NOT_FOUND`.

### 4. App fetches `/api/user/workspaces` and renders switcher

Status: **PARTIAL**

Trace:
- Signed-in app first passes through the remote access feature gate. `FeatureFlagGate.iOS.swift:70-77` turns the shell on only when `remote_sandbox_enabled` is true; `FeatureFlagGate.iOS.swift:139-156` renders `RemoteAccessDisabledView` otherwise.
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:66-76` creates `URLSessionRemoteWorkspaceFetcher` and `WorkspaceSwitcherViewModel`.
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:97` refreshes on presentation.
- `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:214-244` sends bearer `GET /api/user/workspaces`.
- Plue registers the route at `cmd/server/main.go:1251-1254`.
- `internal/routes/user_workspaces.go:43-97` returns a `workspaces` envelope with repo owner/name, title/name, state/status, and timestamps.

Breaks/limits:
- Blocked by Steps 2 and 3 in a real launch.
- Local feature flags currently return `remote_sandbox_enabled:false`, so the shell/switcher is disabled before this fetch in the local default environment.
- Production curl to `https://app.smithers.sh/api/user/workspaces` returned `DEPLOYMENT_NOT_FOUND`.

### 5. User creates a new workspace

Status: **PARTIAL**

Trace:
- Switcher plus button starts create flow at `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:79-84`.
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:154-174` posts create, closes the sheet, and refreshes the list on success.
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:305-343` sends bearer `POST /api/repos/{owner}/{repo}/workspaces` with JSON `{"name": title}`.
- Plue handles create at `internal/routes/workspace.go:67-100`.
- `internal/services/workspace_provisioning.go:117-145` creates/resumes the workspace and ensures it is running.

Breaks/limits:
- Blocked by auth, feature gate, and switcher fetch failures above.
- The create response is a `WorkspaceResponse` with no session id (`internal/services/workspace.go:43-60`). Session IDs are represented separately as `WorkspaceSessionResponse` (`internal/services/workspace.go:62-75`), but the iOS create path does not create or select one for the detail screen.

### 6. Workspace detail mounts chat + terminal

Status: **FAIL**

Trace:
- The detail placeholder renders chat and terminal gates at `ios/Sources/SmithersiOS/ContentShell.iOS.swift:599-645`.
- Chat mounts only when `surfaceGate.showsAgentChatSurface` is true and an agent session id can be resolved (`ios/Sources/SmithersiOS/ContentShell.iOS.swift:704-713`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift:862-895`).
- Terminal mount requires a workspace session id and seeded repo/session context. `refreshTerminalMountState()` exits with "Workspace session lookup is not configured" when seeded repo owner/name are absent (`ios/Sources/SmithersiOS/ContentShell.iOS.swift:784-797`).

Breaks:
- A newly created workspace does not provide a workspace session id to the iOS detail path. The only normal terminal mount path depends on seeded E2E/session context, not the workspace returned by Step 5.
- Chat only discovers an existing first agent session; no code in this detail path creates an agent session for a new workspace if none exists.

### 7. User types a chat message, `POST /messages` succeeds, assistant part streams back

Status: **FAIL**

Trace:
- UI send creates an optimistic user message, calls `client.sendMessage`, refreshes, then starts polling every two seconds (`ios/Sources/SmithersiOS/Chat/AgentChatView.swift:210-255`).
- Client first posts a text-only JSON body: `{"text": text}` (`ios/Sources/SmithersiOS/Chat/AgentChatView.swift:448-455`).
- Structured `{role:"user", parts:[...]}` fallback only runs on HTTP 400/404/422 (`ios/Sources/SmithersiOS/Chat/AgentChatView.swift:456-470`).
- Plue message route appends messages at `internal/routes/agent_sessions.go:223-290`.
- Plue dispatches an agent run only if the normalized role is `user` (`internal/routes/agent_sessions.go:275-283`).
- Plue normalizes text-only payloads with missing role to `assistant` (`internal/routes/agent_sessions.go:365-372`).
- Plue has an SSE stream endpoint at `internal/routes/agent_session_stream.go:36-102`.

Breaks:
- The iOS first POST is accepted as an assistant message, so it does not trigger `DispatchAgentRun`. Because it succeeds, the fallback user-role payload never runs.
- The iOS chat client polls `GET /messages`; it does not connect to the server SSE stream. The requested "assistant part streams back" path is not implemented in the iOS chat surface.

### 8. User opens terminal, WS PTY connects, bytes flow both ways

Status: **FAIL**

Trace:
- Backend route is registered at `cmd/server/main.go:1012-1018` as `/api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal`.
- `internal/routes/workspace_terminal.go:83-144` validates origin, user, repo context, session ownership, SSH info, then accepts the `terminal` WebSocket.
- `internal/routes/workspace_terminal.go:208-230` wires SSH stdout/stderr to WebSocket and WebSocket to SSH stdin.
- iOS terminal model attaches a `TerminalPTYTransport` and appends incoming bytes (`TerminalSurface.swift:148-165`); runtime-backed transport writes outbound bytes through `RuntimePTY.write` (`TerminalSurface.swift:336-343`).
- Swift runtime config passes `ws_pty_url` into libsmithers (`Shared/Sources/SmithersRuntime/SmithersRuntime.swift:113-138`).

Breaks:
- Same detail-screen session id problem as Step 6: a normal newly created workspace does not hand the iOS terminal a workspace session id.
- The libsmithers PTY transport builds `/api/workspace/sessions/{id}/terminal` (`libsmithers/src/core/transport.zig:706-710`), but Plue serves `/api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal` (`cmd/server/main.go:1012-1018`). That path mismatch prevents the WS attach from reaching the registered server handler.

### 9. Agent requests approval, approval arrives in inbox

Status: **FAIL**

Trace:
- iOS exposes an Approvals sheet from the shell toolbar (`ios/Sources/SmithersiOS/ContentShell.iOS.swift:174-177`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift:205-210`).
- The inbox loads on presentation and manual refresh (`ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:67-69`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:92-94`).
- `URLSessionApprovalsInboxClient` discovers repos via `/api/user/workspaces`, then lists pending approvals per repo (`ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:315-333`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:370-407`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:409-446`).
- Plue registers list/detail/decide approval routes at `cmd/server/main.go:1095-1101`.
- `internal/routes/approvals.go:29-51` lists approvals for the route repo context.
- `internal/services/approvals.go:67-88` reads approval rows by repo.
- Electric shape definitions include repo-scoped approvals (`internal/electric/shapes.go:45-48`), and `SmithersStore` pins the approvals shape (`Shared/Sources/SmithersStore/SmithersStore.swift:97-102`), but this iOS inbox is using HTTP discovery/listing, not a live inbox projection.

Breaks:
- No production agent-to-approval creation path was found. The SQL/generated DB primitive exists (`internal/db/approvals.sql.go:46-73`), but the production approvals service interface only exposes get, decide, and list (`internal/services/approvals.go:22-26`), and repository-wide search found `CreateApproval` callers only in tests/test harnesses such as `internal/routes/integration_harness_integration_test.go:394-408`.
- The inbox does not receive live arrivals. It loads on sheet open and refresh; an approval row inserted elsewhere can appear after fetch, but the "agent requests approval -> arrives in inbox" chain is missing at the emission and live-delivery points.

### 10. User taps Approve, decision posts, approval transitions

Status: **PASS**

Trace:
- Row Approve button calls `viewModel.decide(row, decision: .approved)` (`ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:73-87`).
- View model posts the decision and removes the row locally on success (`ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:258-270`).
- Client sends bearer `POST /api/repos/{owner}/{repo}/approvals/{id}/decide` with JSON `{"decision":"approved"}` (`ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:335-355`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:520-524`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:527-529`).
- Plue route validates auth/repo/id/body and calls the service (`internal/routes/approvals.go:87-125`).
- Service normalizes `approved`, verifies pending state, and updates via `DecideApproval` (`internal/services/approvals.go:125-197`, `internal/services/approvals.go:199-207`).
- SQL transition is guarded to `state = 'pending'` and writes `decided_at`/`decided_by` (`oss/db/queries/approvals.sql:25-41`).
- Integration coverage proves list/detail/approve/deny/conflict behavior with authenticated requests (`internal/routes/approvals_integration_test.go:69-108`).

Limit:
- This step works only if an approval row already exists and the user can reach the inbox. In the full happy path, it is blocked by the missing Step 9 emission and earlier auth/environment failures.

## First Break

**Step 2 is the first user-visible break.** Step 1 reaches the sign-in handler, but the OAuth2 PKCE flow cannot complete against the app's default production base URL, and local Plue also lacks a working `smithers-ios` client registration for token exchange.
