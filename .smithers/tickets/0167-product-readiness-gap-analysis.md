# 0167 Product Readiness Gap Analysis

Date: 2026-04-24

Scope reviewed:
- `.smithers/tickets/0145` through `0165`
- `ios/Sources/SmithersiOS`
- `Shared/Sources`
- Supporting client runtime files where the iOS source delegates behavior (`libsmithers/src/core/transport.zig`, `WorkspaceSwitcherView.swift`, `SharedNavigation.swift`, `ios/SmithersiOS.entitlements`, `ios/RELEASE.md`)

Summary: not ready for external iOS testing. The main gaps are not visual polish; they are auth completion, token lifecycle, terminal attachability, sign-out/data isolation, and backend authz/security holes that can leak repo or workspace data.

Gap counts:
- Show-stoppers: 8
- Pre-beta blockers: 10
- Pre-GA polish: 7
- Nice-to-have: 5

## Show-stoppers

### 1. Native OAuth sign-in cannot complete against production plue

Evidence:
- iOS opens `ASWebAuthenticationSession` and waits for a `smithers://auth/callback` URL in `Shared/Sources/SmithersAuth/AuthViewModel.swift:82`, `Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:91`, and `Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:109`.
- Ticket 0165 says plue `/api/oauth2/authorize` still returns JSON instead of redirecting to `redirect_uri` (`.smithers/tickets/0165-auth-token-lifecycle-audit.md:11`).

Impact: a fresh external tester cannot sign in through the happy path.

Fix:
- Make `/api/oauth2/authorize` a browser-native redirect flow.
- Keep exact redirect URI validation and add e2e coverage using the real `ASWebAuthenticationSession` callback, not the mock driver.

### 2. Token refresh is implemented but most production requests do not use it

Evidence:
- `TokenManager.performWithRetry` exists in `Shared/Sources/SmithersAuth/TokenManager.swift:159`, but fetchers pull the current bearer and treat `401/403` as expired: `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:214`, `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:234`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:340`, `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:356`, `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:503`, `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:526`.
- Ticket 0165 calls this out directly (`.smithers/tickets/0165-auth-token-lifecycle-audit.md:27`).

Impact: after access-token expiry, core surfaces fail or force re-auth instead of rotating the refresh token.

Fix:
- Centralize authenticated HTTP through a refresh-aware client.
- On first `401`, call serialized refresh once, persist before retry, then replay the request.

### 3. Sign-out is not a hard local barrier

Evidence:
- `TokenManager.signOut()` awaits server revocation before local wipe in `Shared/Sources/SmithersAuth/TokenManager.swift:177`.
- Refresh tasks save/cache new tokens after network return in `Shared/Sources/SmithersAuth/TokenManager.swift:123`, `Shared/Sources/SmithersAuth/TokenManager.swift:141`, and `Shared/Sources/SmithersAuth/TokenManager.swift:146`.
- Ticket 0165 documents the resurrection race (`.smithers/tickets/0165-auth-token-lifecycle-audit.md:19`).

Impact: a user can tap sign out and later be silently signed back in by an in-flight refresh.

Fix:
- Set a signing-out generation before network revocation.
- Clear local token state immediately, cancel/poison `inFlightRefresh`, and make refresh tasks verify the generation before saving.

### 4. Sign-out does not wipe the iOS runtime/cache path

Evidence:
- `TokenManager.localSignOut()` only calls `wipeHandler?.wipeAfterSignOut()` in `Shared/Sources/SmithersAuth/TokenManager.swift:196`.
- iOS constructs `TokenManager(client:store:)` without a wipe handler in `ios/Sources/SmithersiOS/SmithersApp.swift:82`.
- `SmithersStore.wipeForSignOut()` exists in `Shared/Sources/SmithersStore/SmithersStore.swift:244`, but the iOS shell uses a separate `IOSRuntimeSessionHost` and creates a persistent cache directory in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:326`.

Impact: cached runtime data and live subscriptions can survive account transitions.

Fix:
- Own one signed-in session lifecycle on iOS, wire it as `SessionWipeHandler`, stop runtime transports on sign-out, and wipe the runtime cache.

### 5. External users cannot mount a production workspace terminal

Evidence:
- Workspace detail only considers terminal mounting when `PLUE_E2E_WORKSPACE_SESSION_ID` is present: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:409`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift:469`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift:752`.
- The runtime config points at `baseURL/pty` in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:298`, while `libsmithers` builds `/api/workspace/sessions/{id}/terminal` in `libsmithers/src/core/transport.zig:706`; ticket 0164 says plue only registers the repo-scoped terminal route (`.smithers/tickets/0164-ssh-wspty-production-audit.md:39`).

Impact: the remote-sandbox core loop cannot open a shell for a real tester.

Fix:
- Remove E2E-env gating from terminal discovery.
- Carry repo owner/name into PTY attach or have the backend return the exact terminal URL.
- Add an iOS e2e test that opens a workspace from `/api/user/workspaces` and attaches to its terminal without seeded environment variables.

### 6. Terminal SSH host-key verification is disabled server-side

Evidence:
- Ticket 0164 reports `InsecureIgnoreHostKey()` in the plue terminal route and no host-key material in SSH connection info (`.smithers/tickets/0164-ssh-wspty-production-audit.md:22`).

Impact: a MITM or misrouted SSH gateway can capture live workspace credentials before PTY allocation.

Fix:
- Return gateway host-key material from the workspace SSH API and fail closed on mismatch.
- Test correct-key success and mismatched-key rejection before `RequestPty`.

### 7. Electric shapes can leak cross-repo and cross-user data

Evidence:
- Ticket 0163 reports raw SQL `where` clauses can broaden predicates after an authorized repo ID (`.smithers/tickets/0163-plue-electric-shape-authz-audit.md:11`).
- User-private workspace shapes do not bind `user_id` to the authenticated bearer (`.smithers/tickets/0163-plue-electric-shape-authz-audit.md:20`).

Impact: external users with repo access can receive data outside their authorized repo/user slice.

Fix:
- Replace regex authz with a real allowlist parser.
- Require `user_id == authenticated user` for user-private shapes and enforce token scopes for Electric subscriptions.

### 8. Remaining backend authz leaks expose workflow logs/devtools payloads

Evidence:
- Workflow log/event SSE aliases lack repo-read permission checks (`.smithers/tickets/0159-plue-security-review-wave3-4.md:10`).
- Devtools snapshot writes are not bound to the route repo or actor (`.smithers/tickets/0159-plue-security-review-wave3-4.md:17`).

Impact: workflow logs can contain secrets, and devtools snapshots can be forged or moved across repos.

Fix:
- Apply repo-read middleware to SSE aliases.
- Resolve `session_id` before devtools writes and enforce session repo/user ownership.

## Pre-beta Blockers

### 1. No first-run onboarding beyond sign-in

Evidence:
- Signed-out app goes straight to `SignInView` in `ios/Sources/SmithersiOS/SmithersApp.swift:149`.
- The sign-in screen only explains browser auth in `Shared/Sources/SmithersAuth/SignInView.swift:22`.

Fix: add a first-run flow that explains remote sandboxes, required account access, expected workspace lifecycle, and support/recovery paths before auth.

### 2. No privacy/terms acceptance

Evidence:
- `SignInView` has a single CTA and no terms/privacy links or acceptance state (`Shared/Sources/SmithersAuth/SignInView.swift:33`).
- No `Privacy`, `Terms`, or acceptance persistence appears under `ios/Sources` or `Shared/Sources`.

Fix: add terms/privacy links and an acceptance record before external testing; make server-side account acceptance authoritative if required.

### 3. Settings/account management is effectively absent

Evidence:
- The iOS account section only exposes Sign out (`ios/Sources/SmithersiOS/ContentShell.iOS.swift:255`).
- `.settings` is listed as a route in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:215`, but unimplemented routes fall through to the generic navigation list in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:220`.

Fix: add a real Settings surface with signed-in account identity, sign out, delete account, password/security handoff, support/contact, legal, build/version, and diagnostics export.

### 4. Feature-flag/backend-down state is indistinguishable from "not enabled"

Evidence:
- `IOSRemoteAccessGateModel.refreshNow` catches failures and keeps current/cached state in `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:70`.
- The disabled view always says "Remote sandboxes aren't enabled for your account" in `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:159`.

Fix: split disabled, unauthorized, backend unavailable, offline, and unknown states; provide retry and sign-out paths for each.

### 5. No global offline mode or foreground refresh owner

Evidence:
- The switcher presenter comment says foreground refresh is the caller's responsibility (`ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:14`).
- URLSession fetchers convert network failures into screen-local strings, e.g. `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:222` and `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:242`.
- No `scenePhase` or `NWPathMonitor` usage was found in `ios/Sources` or `Shared/Sources`.

Fix: add an app-level connectivity/lifecycle coordinator that refreshes on foreground, pauses/presents offline state, and lets screens render last-known data consistently.

### 6. Rate-limit recovery is inconsistent

Evidence:
- Workspace actions parse `429` and `Retry-After` in `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:147`.
- Approvals and workflow runs treat non-auth non-success responses as generic backend errors in `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:356` and `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:526`.
- Agent chat surfaces raw HTTP failures in `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:523`.

Fix: define one API error model for `429`, quota, offline, auth-expired, and retryable backend failures; use it across all clients.

### 7. Workflow runs are unusable without E2E seeded repo context

Evidence:
- `WorkflowRunsRepoRef.seeded()` reads `PLUE_E2E_REPO_OWNER` and `PLUE_E2E_REPO_NAME` in `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:811`.
- Missing repo context renders "No seeded repository context is available" in `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:341`.

Fix: add repo selection/global run discovery, or route runs from a selected workspace/repo context.

### 8. Workspace detail has no production way to create/select sessions

Evidence:
- Agent chat mounts a seeded session if present, otherwise picks the first discovered session in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:844` and `ios/Sources/SmithersiOS/ContentShell.iOS.swift:851`.
- Terminal mount is seeded-only as noted above.

Fix: add explicit start/resume session actions, session picker, and empty-state CTAs for "Create agent session" and "Open terminal".

### 9. No push notification path for long-running remote work

Evidence:
- iOS entitlements only include keychain access groups (`ios/SmithersiOS.entitlements:36`).
- The iOS release runbook explicitly leaves push notifications out of scope (`ios/RELEASE.md:312`).

Fix: decide whether approvals, completed runs, terminal disconnects, or quota events need APNs before TestFlight; if yes, add entitlement, registration, backend device-token storage, and notification settings.

### 10. Long-lived refresh token storage policy is not beta-ready

Evidence:
- Tokens use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in `Shared/Sources/SmithersAuth/TokenStore.swift:119`.
- Ticket 0165 flags the lack of biometric/current-unlock access control (`.smithers/tickets/0165-auth-token-lifecycle-audit.md:35`).

Fix: decide the product policy. Use `WhenUnlockedThisDeviceOnly` or `SecAccessControl` for refresh tokens unless background behavior explicitly requires the current weaker class.

## Pre-GA Polish

### 1. iOS terminal fidelity is still a fallback text view

Evidence:
- `TerminalIOSRendererBridge` mounts `TerminalIOSTextView` in `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:71`.
- That view decodes the latest byte buffer as plain UTF-8 in `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:178`.
- Ticket 0146 says this was supposed to be replaced by the Ghostty cell renderer (`.smithers/tickets/0146-client-ghostty-vt-ios-cell-renderer.md:1`).

Fix: select the Ghostty renderer in production, keep the text view as fallback only, and verify SGR/cursor/hardware-keyboard fixtures.

### 2. Performance risks are visible in polling and rendering paths

Evidence:
- Agent chat polls every two seconds after send in `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:246`.
- Terminal text rendering replaces the whole text buffer and scrolls every update in `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:178`.
- iOS runtime cache is configured at 512 MB in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:304`.

Fix: move chat to shape/SSE updates or exponential backoff, render terminal deltas through Ghostty cells, and add cache pressure/LRU telemetry.

### 3. Accessibility issues remain from the Wave 4 review

Evidence:
- Ticket 0160 reports 17 a11y/UI findings, including Dynamic Type gaps, inaccessible context-menu-only delete, and missing labels (`.smithers/tickets/0160-ios-a11y-ui-review-wave4.md:23`).

Fix: address all High/Medium findings before GA and add a small UI test pass with large Dynamic Type and VoiceOver labels.

### 4. Localization scaffolding is missing

Evidence:
- `Info.plist` declares development region `en` only (`ios/Sources/SmithersiOS/Info.plist:19`).
- UI strings are hard-coded throughout, e.g. `Shared/Sources/SmithersAuth/SignInView.swift:22` and `ios/Sources/SmithersiOS/ContentShell.iOS.swift:255`.
- No `Localizable.strings` files were found.

Fix: introduce string catalogs or `String(localized:)`, define localization keys for all iOS/shared UI, and add pseudo-localization checks.

### 5. Analytics and crash reporting are not wired for iOS product learning

Evidence:
- No analytics/crash SDK references were found under `ios/Sources` or `Shared/Sources`.
- Current error handling is mostly local banners or `NSLog`, e.g. `ios/Sources/SmithersiOS/ContentShell.iOS.swift:372`.

Fix: add opt-in/consented crash reporting and privacy-preserving product analytics for sign-in, workspace open, terminal attach, approvals decisions, and failures.

### 6. Empty states are functional but not launch-quality

Evidence:
- Empty/error states mostly use SF Symbols and short text, e.g. workspace switcher in `WorkspaceSwitcherView.swift:72`, approvals in `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:97`, and chat in `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:46`.

Fix: add product-specific illustrations or richer hints where they unblock the next action.

### 7. Deep-link and universal-link support is incomplete

Evidence:
- OAuth custom scheme is registered in `ios/Sources/SmithersiOS/Info.plist:58`.
- Associated domains are intentionally omitted in `ios/SmithersiOS.entitlements:20`.
- No route-level `.onOpenURL` handling was found in `ios/Sources`.

Fix: support links to workspace, approval, run, and repo contexts; add universal links once the plue origin serves `apple-app-site-association`.

## Nice-to-have

### 1. Snapshot management UI

Evidence:
- Snapshot create/delete action kinds exist in `Shared/Sources/SmithersStore/ActionKind.swift:9`.
- Ticket 0145 explicitly left snapshot UI out of scope (`.smithers/tickets/0145-plue-workspace-snapshots-shape.md:38`).

Fix: add snapshot list, create, delete, and fork-from-snapshot flows after the core workspace/terminal paths are stable.

### 2. Workflow inspector v2 / live logs

Evidence:
- iOS run detail currently shows metadata and cancel only in `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:270`.

Fix: add logs/events streaming, node timeline, retries/resume, and deep links to related workspace/session.

### 3. Multi-client PTY attach with shared scrollback

Evidence:
- Ticket 0164 says duplicate attaches create independent shells, not shared PTY views (`.smithers/tickets/0164-ssh-wspty-production-audit.md:105`).

Fix: introduce a session-ID keyed PTY owner with fanout, per-client cursors, replay, and write policy.

### 4. Advanced devtools inspector

Evidence:
- iOS devtools panel only fetches latest snapshots for one session in `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:162`.

Fix: add snapshot history, diffing, filters, screenshot zoom, network timeline, and export/share.

### 5. Repo/workspace command palette

Evidence:
- iOS navigation is a basic list in `ios/Sources/SmithersiOS/ContentShell.iOS.swift:227`; repo-scoped surfaces each invent their own discovery.

Fix: add a global command/search surface for repositories, workspaces, runs, approvals, and sessions.
