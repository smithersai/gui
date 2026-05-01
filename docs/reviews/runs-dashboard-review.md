# Runs And Dashboard Review

Review date: 2026-04-15

Scope:

- `RunsView.swift`
- `RunInspectView.swift`
- `ContentView.swift` dashboard wiring
- `DashboardView.swift`, included because `ContentView.swift` delegates the dashboard section there
- `Tests/SmithersGUITests/ScoresViewTests.swift`
- `Tests/SmithersGUIUITests/RunInspectorE2ETests.swift`

`swift test` was not run, per request.

## Findings

### High - Inline approve/deny drops the node iteration

`RunsView` finds a blocked task, but only passes `runId` and `nodeId` into the approve and deny calls:

- `RunsView.swift:578` selects `blockedNode`.
- `RunsView.swift:581` calls `approveNode(runId:nodeId:)` without `blockedNode.iteration`.
- `RunsView.swift:584` calls `requestDenyNode(runId:nodeId:)` without `blockedNode.iteration`.
- `RunsView.swift:860` and `RunsView.swift:873` keep the local approve/deny helpers iteration-less.

The lower client API supports iteration, but normalizes a missing iteration to `0`:

- `SmithersClient.swift:1378` accepts `iteration: Int? = nil`.
- `SmithersClient.swift:1388` maps nil to `0` for approve.
- `SmithersClient.swift:1417` accepts `iteration: Int? = nil`.
- `SmithersClient.swift:1427` maps nil to `0` for deny.

This is risky for repeated gates or any workflow where the blocked task has `iteration > 0`: the UI may approve or deny the wrong iteration, or the backend may reject the action.

Recommendation: carry the selected `RunTask` or at least `(nodeId, iteration)` through `PendingDenyNode`, `approveNode`, and `denyNode`. Call `smithers.approveNode(runId:nodeId:iteration:)` and `smithers.denyNode(runId:nodeId:iteration:)` with `blockedNode.iteration`.

### High - Lazy inspection failures leave approve/deny stuck disabled

Expanded rows depend on the inspection cache before enabling inline approve/deny:

- `RunsView.swift:578` only enables approve/deny if `inspections[run.runId]` exists and has a blocked task.
- `RunsView.swift:604` renders node details only when the inspection cache exists.
- `RunsView.swift:646` otherwise shows `Loading nodes...`.

But `loadInspection` silently ignores errors:

- `RunsView.swift:843` starts the fetch.
- `RunsView.swift:847` catches errors.
- `RunsView.swift:848` intentionally no-ops.

If inspection fails for a waiting-approval run, the row stays in a loading state and inline approve/deny remain disabled with no error, retry, or reason. This makes `RUNS_INLINE_APPROVE`, `RUNS_INLINE_DENY`, and `RUNS_LAZY_INSPECTION_LOADING` fragile in the exact case where the user needs to act.

Recommendation: track per-run inspection loading and error state, show an inline retry, and keep the disabled approve/deny controls labeled with the reason. Consider preloading inspections for visible `waitingApproval` runs so approval actions do not require the user to expand first.

### High - Dashboard partial load failures are shown as zero-valued stats

`DashboardView.loadAll()` does load the Smithers datasets in parallel:

- `DashboardView.swift:527` starts `runsResult`.
- `DashboardView.swift:528` starts `workflowsResult`.
- `DashboardView.swift:529` starts `approvalsResult`.
- `DashboardView.swift:531` awaits the tuple.

But partial failures are swallowed. Each loader returns `[]` plus an error, and `loadAll()` only surfaces an error when all three Smithers calls fail:

- `DashboardView.swift:533` assigns `runs = loadedRuns.value`.
- `DashboardView.swift:534` assigns `workflows = loadedWorkflows.value`.
- `DashboardView.swift:535` assigns `approvals = loadedApprovals.value`.
- `DashboardView.swift:538` checks `allSmithersFailed`.
- `DashboardView.swift:539` only sets `error` for all-source failure.

The JJHub group has the same problem, except individual errors are ignored entirely:

- `DashboardView.swift:550` starts `landingsResult`.
- `DashboardView.swift:551` starts `issuesResult`.
- `DashboardView.swift:552` starts `workspacesResult`.
- `DashboardView.swift:555` assigns `landings = loadedLandings.value`.
- `DashboardView.swift:556` assigns `issues = loadedIssues.value`.
- `DashboardView.swift:557` assigns `workspaces = loadedWorkspaces.value`.

This directly affects dashboard stat cards. A failed approvals request becomes `Pending Approvals = 0`; a failed workflows request becomes `Workflows = 0`; failed JJHub requests become zero open landings/issues/workspaces. Those zeros are indistinguishable from real empty data.

Recommendation: surface source-level errors in the overview, preserve last-known-good values where practical, or render affected stat cards as unavailable instead of `0`. Keep the current `async let` parallelism, but make partial failures visible.

### Medium - Progress bars are hidden for approval-gated active runs

Both run list rows and dashboard run rows only show the progress bar for `.running`:

- `RunsView.swift:481` checks `run.status == .running && run.totalNodes > 0`.
- `DashboardView.swift:1030` checks `run.status == .running, run.totalNodes > 0`.

The same views classify `waitingApproval` as active:

- `RunsView.swift:412` includes `.waitingApproval` in the ACTIVE section.
- `DashboardView.swift:42` includes `.waitingApproval` in `activeRuns`.

A run paused at an approval gate can be mostly complete, but the UI hides its progress bar and percentage. That makes approval-gated runs look less informative than running runs, even though their progress data is still available.

Recommendation: show progress for non-terminal runs with node summaries, or at least for `.running` and `.waitingApproval`. The model-level `RunSummary.progress` already supports the needed data.

### Medium - Cancelled runs are grouped as failed, but the dashboard failed stat excludes them

`RunsView` groups cancelled runs under the `FAILED` section:

- `RunsView.swift:414` builds `failed` from `.failed || .cancelled`.
- `RunsView.swift:422` renders that group with the `FAILED` heading.

The dashboard stat card counts only `.failed`:

- `DashboardView.swift:229` labels the card `Failed Runs`.
- `DashboardView.swift:230` uses `runs.filter { $0.status == .failed }.count`.

This creates a mismatch between the Runs sectioning and the dashboard overview. A cancelled run appears in a failure bucket on one screen but not in the dashboard failure count. It also affects status filtering semantics: filtering to `CANCELLED` still displays the result under a `FAILED` section header.

Recommendation: either separate cancelled runs from failed runs in `RunsView`, or rename/count the dashboard card consistently, for example `Failed / Cancelled`.

### Medium - Elapsed time for active runs does not tick unless some other state changes

`RunSummary.elapsedString` computes active elapsed time from `Date()` when `finishedAt` is nil:

- `SmithersModels.swift:44` defines `elapsedString`.
- `SmithersModels.swift:46` uses `finishedAt ?? Date()`.

The views render that string:

- `RunsView.swift:490`
- `DashboardView.swift:1035`
- `RunInspectView.swift:173`

There is no timer-driven invalidation in the dashboard, and `RunsView` only refreshes from SSE events or polling fallback. If the SSE connection is healthy but no events arrive, the elapsed display can stay frozen. The inspector has the same issue after initial load.

Recommendation: use a lightweight timer or `TimelineView` for active runs, or refresh active run summaries on an interval even when the SSE stream is connected. Also consider clamping negative durations to `0s` for future or skewed timestamps.

### Low - Date/status filter details can confuse users and automation

The status filter itself is straightforward exact matching:

- `RunsView.swift:110` applies the selected `RunStatus`.
- `RunsView.swift:270` builds the status menu.

The rough edges are around adjacent filter behavior:

- `RunsView.swift:135` labels the preset as `This Week`, but implements a rolling seven-day cutoff rather than calendar week.
- `RunsView.swift:113` filters the selected workflow with `localizedCaseInsensitiveContains`, so choosing a workflow named `Deploy` also matches `Deploy Prod`.
- `RunsView.swift:273` does not assign identifiers to individual status menu options, which makes UI automation harder than it needs to be.

Recommendation: use calendar week semantics or rename the preset to `Last 7 Days`; make workflow menu selections exact; add stable identifiers for status menu options if these are meant to be covered by UI tests.

## Coverage Notes

`RunInspectorE2ETests.swift` covers two happy paths:

- `Tests/SmithersGUIUITests/RunInspectorE2ETests.swift:4` verifies hijack opens a terminal resume command.
- `Tests/SmithersGUIUITests/RunInspectorE2ETests.swift:18` verifies inspector navigation, node detail, DAG mode, snapshots, and close.

It does not cover status filtering, progress bars, elapsed time behavior, inline approve/deny, deny confirmation, cancel, approval-gated progress, dashboard stat cards, or dashboard loading failures.

`ScoresViewTests.swift` does not cover the dashboard or run inspector. The `SCORES_PARALLEL_DATA_LOADING` section is not a useful proxy for `DASHBOARD_PARALLEL_DATA_LOADING`:

- `Tests/SmithersGUITests/ScoresViewTests.swift:286` names parallel loading.
- `Tests/SmithersGUITests/ScoresViewTests.swift:292` only asserts a documentation-style statement.
- `Tests/SmithersGUITests/ScoresViewTests.swift:300` manually replicates aggregation math.

Several `ScoresViewTests` bug comments are stale against current source:

- `Tests/SmithersGUITests/ScoresViewTests.swift:275` says `ScoresView` creates a `DateFormatter` per call, but `ScoresView.swift:583` uses a static formatter.
- `Tests/SmithersGUITests/ScoresViewTests.swift:313` says even-count P50 is wrong, but `SmithersModels.swift:872` averages the two middle values.
- `Tests/SmithersGUITests/ScoresViewTests.swift:392` says fallback names differ, but `SmithersModels.swift:843` uses `scorerDisplayName` for both display and aggregation.

Existing nearby run/dashboard tests have the same maintenance problem: some tests replicate private logic or document bugs that are already fixed, instead of exercising the actual view behavior. Examples include waiting-approval node icon handling, singular run count display, rounded progress percentage, and dashboard active-run counting.

Recommended coverage additions:

- Unit/view test for `RunsView` status filtering, including `.waitingApproval`, `.cancelled`, and clear filters.
- View test or UI test that an approval-gated run with progress renders a progress bar.
- Unit test that inline approve/deny passes `RunTask.iteration` through to `SmithersClient`.
- UI test for deny confirmation and approve success on a waiting-approval fixture.
- View test for per-run inspection failure state once that state exists.
- Dashboard tests with a controllable client that can make one parallel source fail while others succeed, asserting the affected stat is not silently shown as `0`.
- Dashboard stat tests for failed vs cancelled semantics once the product decision is made.
- Elapsed-time test around active run ticking or a pure formatter test that clamps negative durations.
