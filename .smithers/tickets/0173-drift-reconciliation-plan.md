# 0173 Drift Reconciliation Plan

Audit date: 2026-04-24

Scope:
- `/Users/williamcory/plue`
- `/Users/williamcory/gui`

Rules observed: no commit, push, reset, or `git add`. This is a working-tree reconciliation plan only.

## Executive Summary

`plue` is not a clean "ahead of main" branch. The current checkout is detached at `a5dbc1265`, with local `main` also at `a5dbc1265`. `origin/main` is `44f0a7eb9`, so the local branch has a two-sided divergence: 16 local commits not on `origin/main`, and 25 remote commits not on the local line. The remediation branch exists remotely/tracking at `4308aefb8`; the local branch namespace does not list `refs/heads/remediation/tickets-0151-0158`.

`gui` is on `initiative/ios-remote-sandboxes` at `c5cedb37`, exactly matching `origin/initiative/ios-remote-sandboxes`. The pushed initiative branch is not merged to `origin/main` (`origin/main` is `cfc163fa`). The working tree still contains a large uncommitted iOS/productization wave.

Both repos have uncommitted state that should be batched by topic, not bulk-committed. `plue` also changed during this audit: Electric parser property-test files appeared after the first status snapshot, so treat them as concurrent agent output.

## Branch Truth

### `/Users/williamcory/plue`

- Current worktree: detached HEAD, `a5dbc1265`.
- Local `main`: `a5dbc1265`.
- `origin/main`: `44f0a7eb971bc12f13c50776480096bcd13d4fa5`.
- `origin/remediation/tickets-0151-0158`: `4308aefb8a17629895ff7c703c0a0c8f24ec3aa5`.
- Merge base with `origin/main`: `c1f0baec8ab584b542fc9d41bb8628a2967bd725`.
- Merge base with remediation: `4308aefb8`.

Local-only relative to `origin/main` includes the `263c9f15b` OAuth revoke-all commit, `07e5d001e`, `4308aefb8`, and 13 later local commits ending at `a5dbc1265` (`fold oss`, docs/marketing/UI/backend/deps work). `origin/remediation/tickets-0151-0158` contains `4308aefb8` and its ancestors, but does not contain the 13 commits above it.

Remote-only relative to local includes the actual `origin/main` line: tickets such as Electric consumer, sandbox quota, agent/session/workspace shapes, rate limits, where parser hardening, workspace snapshots, run-inspection shape, and `44f0a7eb9 feat(oauth2): 0156 - expose /api/oauth2/revoke-all`. Do not merge the local `main` line wholesale into current `origin/main`; it contains duplicate/parallel history.

### `/Users/williamcory/gui`

- Current branch: `initiative/ios-remote-sandboxes`.
- Current HEAD: `c5cedb375fcdc368044da0ad4486b416fb815a81`.
- `origin/initiative/ios-remote-sandboxes`: same `c5cedb37`.
- `origin/main`: `cfc163fad8f6975242b140fbea61e3ad2a21fcaf`.
- Local `main`: `fe6ccf2b`, stale relative to `origin/main`.

The initiative branch is pushed. In addition to the user-mentioned `779abfc7`, `a00193b5`, and `c5cedb37`, `2b0a65d2` is also in the pushed branch history because `origin/initiative/ios-remote-sandboxes` points at `c5cedb37`.

## Uncommitted Inventory

### `plue`

No staged changes.

Do not commit:
- `.claude/worktrees/`
- `.worktrees/`

Likely topic batches:

| Topic | Files | Likely owner-agent | Notes |
| --- | --- | --- | --- |
| `feat(plue): add GET /api/user/repos` | `cmd/server/main.go`, `internal/routes/user_repos.go`, `internal/routes/user_repos_test.go`, `internal/routes/user_repos_integration_test.go`, `internal/db/repos.sql.go`, `oss/apps/server/src/db/repos_sql.ts`, `oss/db/queries/repos.sql` | Ticket 0170 user-repos agent | Adds route, envelope, repo aliases, `updated_at`, and recent-first query order. Generated Go/TS SQL outputs must be regenerated from the final query after rebasing onto `origin/main`. |
| `db(plue): add ticket 0158 remediation migrations` | `db/migrations/000049...000054...sql`, `db/migrations/atlas.sum` | Ticket 0158 remediation agent | Adds OAuth2 code hash/used-at, protected-bookmark checks, dispatch inputs, and workflow-step repo denorm. Needs migration-number and atlas checksum reconciliation against current `origin/main`, whose migration series already differs from local HEAD. |
| `test(plue): add route integration coverage` | `internal/routes/integration_harness_integration_test.go`, `approvals_integration_test.go`, `devtools_snapshots_integration_test.go`, `user_workspaces_integration_test.go`, `workflow_run_aliases_integration_test.go` | Route-hardening / audit follow-up agents | Good review batch after product code is settled. The harness is shared and may become a conflict center. |
| `test/fix(plue): harden Electric where parser` | `internal/electric/where_parser_property_test.go`, `internal/electric/testdata/where_parser_owasp_attacks.txt` | Ticket 0163 Electric authz/parser agent | These appeared during audit. They are tests only; no `where_normalizer` implementation changes are present, so expect failures unless paired with the actual parser hardening. |

### `gui`

No staged changes.

Do not commit:
- `.worktrees/`

Likely topic batches:

| Topic | Files | Likely owner-agent | Notes |
| --- | --- | --- | --- |
| Ticket docs/status cleanup | Deleted `.smithers/tickets/0097...0157`, modified `0103`, `0104`, `0108`, `0109`, `0113`, `0120`-`0123`, `0132`, `0134`-`0136`, `0158`, new `0159`-`0172` | Audit/status agents | Keep docs-only. Verify deleted tickets are intentionally superseded before committing; many were pushed initiative artifacts. |
| `feat(auth): validate restored sessions` | `Shared/Sources/SmithersAuth/AuthViewModel.swift`, `OAuth2Client.swift`, `SignInView.swift`, `Shared/Tests/SmithersAuthTests/MockedServerIntegrationTests.swift`, `ios/Sources/SmithersiOS/SmithersApp.swift`, `ios/Tests/SmithersiOSTests/AuthPKCETests.swift`, `macos/Sources/Smithers/Smithers.RemoteMode.swift` | Auth lifecycle / Agent H area | Adds `.restoringSession`, `/api/user` token validation, and iOS startup validation. Does not fix plue's browser-native authorize flow. |
| `feat(flags): harden remote sandbox kill switch` | `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift`, `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift`, `ios/Tests/SmithersiOSTests/FeatureFlagGateTests.swift`, `ios/Tests/SmithersiOSE2ETests/SmithersiOSE2EFeatureFlagsTests.swift` | Kill-switch agent | Uses `PLUE_REMOTE_SANDBOX_ENABLED` override and otherwise honors server/default false. Validate production behavior with no env override. |
| `feat(ios): workspace switcher repo filter/create/actions` | `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift`, `WorkspaceSwitcherView.swift`, `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift`, `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift`, `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift`, related tests | Agent Q / 0170 client side | Large cross-cutting batch. Depends on plue `GET /api/user/repos`; client has fallback behavior but the route should land first. |
| `feat(ios): workspace session presence and detail terminal mount` | `Shared/Sources/SmithersStore/WorkspaceSessionPresenceProbe.swift`, `Shared/Tests/SmithersStoreTests/WorkspaceSessionPresenceProbeTests.swift`, `ios/Tests/SmithersiOSTests/WorkspaceSessionPresenceProbeViewTests.swift`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift` | Terminal/session discovery agent | Still E2E-seeded in places. Must reconcile with ticket 0164 terminal route mismatch. |
| `feat(ios): agent chat UI` | `ios/Sources/SmithersiOS/Chat/AgentChatView.swift`, `ios/Tests/SmithersiOSTests/AgentChatViewTests.swift`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift` | Agent P | Polling and transcript UI. Ticket 0168 flags a self-retaining polling loop. |
| `feat(ios): approvals inbox` | `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift`, `ios/Tests/SmithersiOSTests/ApprovalsInboxViewTests.swift`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift` | Agent R | Approval list/decide UI. Ticket 0160 has a11y/touch target findings. |
| `feat(ios): devtools snapshots panel` | `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift`, `ios/Tests/SmithersiOSTests/DevtoolsPanelViewTests.swift`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift` | Devtools agent | Ticket 0168 flags screenshot memory pressure; ticket 0159 flags server session-binding risk. |
| `feat(ios): workflow runs list/detail` | `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift`, `ios/Tests/SmithersiOSTests/WorkflowRunsListViewTests.swift`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift` | Workflow-runs agent | Depends on route shape consistency and auth refresh strategy. |
| `feat(ios): onboarding/settings surfaces` | `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift`, `ios/Sources/SmithersiOS/Settings/SettingsView.swift`, `ios/Sources/SmithersiOS/SmithersApp.swift` | Product-readiness / onboarding agent | Ticket 0172 says this introduces `UserDefaults`, requiring `PrivacyInfo.xcprivacy` before TestFlight. |
| `feat(terminal): runtime PTY state/reconnect` | `Shared/Sources/SmithersRuntime/SmithersRuntime.swift`, `TerminalSurface.swift`, `ios/Tests/SmithersiOSTests/RuntimePTYTransportTests.swift`, `TerminalSurfaceConnectionStateTests.swift`, `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift` | 0171 / terminal agent | Current code still uses real `Task.sleep`; tests wait up to 35s. Ticket 0171 is not implemented yet despite the file existing. |
| `feat(ios): ghostty terminal renderer` | `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift`, `TerminalIOSGhostty.swift`, `project.yml`, `SmithersGUI.xcodeproj/project.pbxproj`, `ghostty` submodule | Agent T / 0161 area | Dirty submodule (`ghostty`) plus generated project wiring. Ticket 0161 flags a partial-construction leak in `TerminalIOSGhostty`. |
| `test(macos-e2e): add remote-mode coverage` | `macos/Tests/SmithersMacOSE2ETests/*`, scheme/project wiring | macOS E2E agent | Keep separate from iOS code so failures are attributable. |
| `build(ios): everything-up and TestFlight preflight` | `build.zig`, `project.yml`, `SmithersGUI.xcodeproj/project.pbxproj`, `.smithers/tickets/0172...` | Build/TestFlight agent | `build.zig` adds `everything-up`; 0172 says TestFlight is blocked by ghostty artifact, Xcode version, privacy manifest, and app icon. |

Likely uncommitted test files in `gui`:
- `ios/Tests/SmithersiOSTests/RuntimePTYTransportTests.swift`
- `ios/Tests/SmithersiOSTests/WorkspaceDetailActionsTests.swift`
- `ios/Tests/SmithersiOSTests/WorkspaceSessionPresenceProbeViewTests.swift`
- `ios/Tests/SmithersiOSTests/AgentChatViewTests.swift`
- `ios/Tests/SmithersiOSTests/ApprovalsInboxViewTests.swift`
- `ios/Tests/SmithersiOSTests/DevtoolsPanelViewTests.swift`
- `ios/Tests/SmithersiOSTests/RepoSelectorSheetTests.swift`
- `ios/Tests/SmithersiOSTests/TerminalSurfaceConnectionStateTests.swift`
- `ios/Tests/SmithersiOSTests/WorkflowRunsListViewTests.swift`
- `ios/Tests/SmithersiOSTests/TestSupport.swift`
- `macos/Tests/SmithersMacOSE2ETests/SmithersMacOSE2EApprovalsTests.swift`
- `macos/Tests/SmithersMacOSE2ETests/SmithersMacOSE2EAuthTests.swift`
- `macos/Tests/SmithersMacOSE2ETests/SmithersMacOSE2EChatTests.swift`
- `macos/Tests/SmithersMacOSE2ETests/SmithersMacOSE2ESwitcherTests.swift`
- `macos/Tests/SmithersMacOSE2ETests/SmithersMacOSE2ETerminalTests.swift`

## Recommended Commit Batching

Recommended total: 15 commits if everything is ready to land, split as 4 `plue` commits and 11 `gui` commits.

### `plue` recommended commits

1. `feat(plue): add authenticated user repos route`
   - Include route, query, generated SQL, unit test, and user-repos integration test.
2. `db(plue): add remaining 0158 schema remediation migrations`
   - Include migrations and `atlas.sum` only after rebasing/renumbering against `origin/main`.
3. `test(plue): add route integration harness coverage`
   - Include shared harness and approvals/devtools/user-workspaces/workflow-alias integration tests.
4. `fix(plue): harden Electric where parser`
   - Include the new property tests only with implementation. If implementation is not ready, keep this out of the green landing stack or mark it explicitly as a failing-test commit.

### `gui` recommended commits

1. `docs(tickets): reconcile iOS remote sandbox audit status`
2. `feat(auth): validate restored iOS sessions before mounting shell`
3. `feat(flags): centralize remote sandbox override handling`
4. `feat(ios): add workspace repo picker, filters, and detail actions`
5. `feat(ios): probe workspace session presence before terminal mount`
6. `feat(ios): add agent chat surface`
7. `feat(ios): add approvals inbox surface`
8. `feat(ios): add devtools snapshots panel`
9. `feat(ios): add workflow runs list and detail views`
10. `feat(terminal): add runtime PTY connection states and retry UI`
11. `feat(ios): add ghostty-backed terminal renderer and build wiring`
12. Optional if kept separate from 11: `build(ios): add everything-up developer stack command`
13. Optional if tests are complete: `test(macos-e2e): add remote-mode end-to-end coverage`

If you want a smaller review stack, combine the four iOS data surfaces (agent chat, approvals, devtools, workflow runs) into two commits: `feat(ios): add collaboration surfaces` and `feat(ios): add operations surfaces`. Do not squash the whole wave into one commit; `ContentShell.iOS.swift` and the project file are too broad to review that way.

## Merge Strategy

Use topic-level squashes, not one all-agent squash and not raw per-file commits.

For `plue`, start clean branches from current `origin/main`, then replay only the wanted topic patches. Do not merge local `main`/detached `a5dbc1265` into `origin/main`; that line contains duplicate parallel history and will drag in unrelated old OSS/docs/UI/deps work. Treat `origin/remediation/tickets-0151-0158` as an archive/reference branch, not the landing base.

For `gui`, keep working on top of `origin/initiative/ios-remote-sandboxes`, because that branch is pushed and current. Split uncommitted work into topic commits. Regenerate or update `SmithersGUI.xcodeproj/project.pbxproj` only after deciding which source/test files belong to each commit; otherwise the project file will reference files that are not present in the same review slice.

Generated files should travel with their source-of-truth:
- SQL query changes with `internal/db/*.sql.go` and `oss/apps/server/src/db/*_sql.ts`.
- `project.yml` and `SmithersGUI.xcodeproj/project.pbxproj` with the app/test files they wire.
- `atlas.sum` only with the exact migration files it signs.

## Risk Assessment

Highest conflict/behavior risk:

1. `gui/ios/Sources/SmithersiOS/ContentShell.iOS.swift`
   - Diff size: roughly 913 additions / 94 deletions.
   - It now coordinates feature flags, onboarding, workspace switcher, terminal probing, agent chat, devtools, approvals, workflow runs, and detail actions. Multiple agents touched the same shell, so this is the top multi-agent conflict zone.

2. `gui/SmithersGUI.xcodeproj/project.pbxproj`, `gui/project.yml`, and `gui/ghostty`
   - Project wiring references many untracked files and a dirty submodule. A partial commit can easily break the build. Ticket 0172 also says clean CI will not have `ghostty-vt.xcframework`.

3. `plue` database/generated SQL drift
   - Local HEAD and `origin/main` have different migration histories and generated SQL baselines. The uncommitted 0158 migrations plus `ListReadableReposForUser` generated outputs need a clean regeneration pass on the actual landing base.

Secondary risks:
- `gui/TerminalSurface.swift` and `Shared/Sources/SmithersRuntime/SmithersRuntime.swift` interact with the 0166 concurrency findings. Current Swift `RuntimePTY` still stores only the raw handle and does not obviously retain its owning `RuntimeSession`.
- `plue/internal/electric/where_parser_property_test.go` appears without parser implementation, so it may be a red CI batch.
- `.smithers/tickets` deletions are broad and could erase useful initiative audit history if committed without intent.

## Contradictions / Incomplete Claims

- `remote_sandbox_enabled` default false vs kill-switch wiring: current iOS gate honors the false default unless `PLUE_REMOTE_SANDBOX_ENABLED` overrides it. The E2E script forces the flag on for local runs, so verify a production launch with no env override shows the disabled state and does not mount terminal/workspace surfaces.
- Ticket 0171 says retry clock injection is the goal, but `RuntimePTYTransport` still uses `Task.sleep`, and `RuntimePTYTransportTests` still wait through real backoff windows up to 35 seconds. Do not mark 0171 shipped.
- Ticket 0164 says the production WS PTY route is repo-scoped, but `libsmithers/src/core/transport.zig` still builds `/api/workspace/sessions/{id}/terminal`, and `ContentShell.iOS.swift` still seeds `wsPtyURL` from `baseURL/pty`. Terminal attachability is not production-resolved.
- Ticket 0166 flags `RuntimePTY` lifetime safety; the uncommitted Swift wrapper still keeps a raw PTY box without retaining the owning `RuntimeSession`. Pair any PTY UI landing with a runtime lifetime fix or explicitly gate it.
- Ticket 0165 says plue `/api/oauth2/authorize` is not browser-native. The uncommitted GUI restored-session validation helps E2E bearer startup but does not make native OAuth sign-in complete.
- The new Electric parser tests in `plue` assert parser hardening, but no matching parser code changes are in the current working tree.

## Immediate Next Steps

1. Freeze new agent writes or move each active agent into its own worktree before making commits. `plue` changed during this audit.
2. For `plue`, create a clean branch from `origin/main` and port the four batches manually/topic-by-topic.
3. For `gui`, split commits on `initiative/ios-remote-sandboxes`, starting with docs/status and then small feature batches.
4. Run focused tests per batch before committing: route unit/integration tests for `plue`; Swift unit tests for each iOS surface; then one full iOS build after project/ghostty wiring.
