# Landings / Issues / Workspaces Review

Scope: `LANDINGS`, `ISSUES`, `WORKSPACES`, `TIMELINE_AND_SNAPSHOTS`, and `CODEX_EVENT_HANDLING`, covering the relevant views, `SmithersModels.swift`, `SmithersClient.swift`, `AgentService.swift`, and related tests.

Per request, I did not run `swift test`.

## Findings

### 1. High: Codex bridge event handling is not ordered before turn finalization

`AgentService.sendMessage` parses JSONL chunks on a detached task, but each parsed event is handed to an unstructured `Task { @MainActor ... handleEvent(event) }` and not awaited (`AgentService.swift:351-369`). Immediately after scheduling those tasks, the bridge is cleared and `finishDetachedTurn` is awaited (`AgentService.swift:370-372`).

Impact:

- Final `item.completed`, `turn.failed`, command completion, or todo updates can be processed after `finishDetachedTurn` has already marked the run complete.
- Multiple item events can be reordered by the scheduler, which can regress command/tool lifecycle rows keyed by item id.
- A visible success state can race ahead of a final error or final assistant message.

Recommended fix: keep event dispatch sequential. For example, from the detached task call `await MainActor.run { self.handleEvent(event) }` for each parsed event, then process `finish()` events the same way, and only then call `finishDetachedTurn`. If chunk callbacks cannot be async, push events into a serial async queue owned by the service.

Coverage gap: existing tests call `handleEvent` directly and synchronously (`Tests/SmithersGUITests/AgentServiceTests.swift:340-415`), and background tests only assert initial state/cancel behavior (`Tests/SmithersGUITests/AgentServiceTests.swift:734-773`). There is no test that drives the bridge callback path and asserts event order relative to turn completion.

### 2. High: Codex event parsing drops whole events when tool payload fields are JSON objects or arrays

`CodexItem` models `input`, `output`, `details`, and `arguments` as `String?` (`AgentProtocol.swift:24-54`). If a supported tool event contains `arguments` as an object, `input` as an object, or `output` as an array/object, synthesized decoding fails the whole `CodexEvent`. The line buffer then logs and drops the event (`AgentProtocol.swift:126-136`).

Impact:

- Generic `tool` / `tool_call` / `function_call` events can silently vanish even though `AgentService` has rendering paths for dedicated tools (`AgentService.swift:757-789`).
- MCP-like and function-call payloads commonly use structured JSON arguments, so this is likely to hide useful tool activity rather than merely ignore unknown metadata.
- Since malformed lines are dropped, users see no chat row explaining that a tool call happened.

Recommended fix: introduce a small `JSONValue` type or lossy field decoder for dynamic fields. Preserve strings as-is, stringify objects/arrays for display, and keep decoding the rest of the item even when an optional display field has an unexpected shape.

Coverage gap: parser tests cover string fields, partial lines, invalid JSON, command events, MCP basics, and file changes (`Tests/SmithersGUITests/AgentProtocolTests.swift:118-150`, `Tests/SmithersGUITests/AgentProtocolAdditionalTests.swift:96-170`), but not object-valued `arguments`, object-valued `input`, array-valued `output`, or a malformed optional field that should not drop the event.

### 3. Medium: Landings state filtering can hide valid JJHub states

The client normalizes JJHub landing filters so `ready` and `open` map to `open`, while `landed` and `merged` map to `merged` (`SmithersClient.swift:3909-3922`). The view then applies a second exact client-side filter: `landings.filter { $0.state == filter }` (`LandingsView.swift:99-103`). The menu uses `Open`, `Draft`, and `Merged` (`LandingsView.swift:132-137`), while model/tests still accept `ready` and `landed` as landing states (`Tests/SmithersGUITests/SmithersModelsTests.swift:723-730`).

Impact:

- If JJHub returns `ready` for an open/ready landing, selecting `Open` can hide it after the server already returned it.
- If JJHub returns `landed`, selecting `Merged` can hide it.
- This is especially easy to miss because fixture/stub paths currently return `open` in the client test (`Tests/SmithersGUITests/SmithersClientTests.swift:1541-1544`).

Recommended fix: use the same normalized state helper for view filtering, or remove the second client-side filter and trust the server response for filtered loads.

Test note: `LandingsViewTests` contains stale documentation saying filter changes do not refetch (`Tests/SmithersGUITests/LandingsViewTests.swift:169-184`), but the current view uses `.task(id: stateFilter)` (`LandingsView.swift:117`).

### 4. Medium: Landings diff output does not use the unified diff renderer

`ChangesView` renders change diffs through `UnifiedDiffView` (`ChangesView.swift:395-409`), which provides file sections, stats, and line-number-aware rows (`UnifiedDiffView.swift:137-220`). `LandingsView` renders landing diffs as raw monospaced `Text(diff)` (`LandingsView.swift:461-483`).

Impact:

- Landing diffs lose file-level grouping, added/deleted counts, and line numbering.
- `SmithersClient.landingDiff` concatenates multiple change diffs with a textual `Change <id>` header (`SmithersClient.swift:4044-4058`); the current raw text view preserves that header, but gives a lower-quality diff experience than the Changes feature group.

Recommended fix: either feed each landing change diff into `UnifiedDiffView` separately with a small change header, or teach `UnifiedDiffView` to preserve non-diff section headers before each parsed diff section.

Coverage gap: parser tests cover basic unified diff parsing well (`Tests/SmithersGUITests/DiffParserTests.swift:18-177`), and `UnifiedDiffViewTests` has a render smoke test (`Tests/SmithersGUITests/UnifiedDiffViewTests.swift:9-33`). There is no test for landing multi-change diff text, `Change <id>` headers, or JJHub-specific diff output.

### 5. Medium: Issue CRUD is incomplete and can produce confusing state after create/close

The issue detail shows a Reopen button for closed issues, but it is permanently disabled (`IssuesView.swift:267-280`). `reopenIssue` only sets an error saying the action is not implemented (`IssuesView.swift:390-397`). Close uses `smithers.closeIssue(number:comment:)`, but always passes `comment: nil` from the UI (`IssuesView.swift:399-407`), despite client support for `-c` comments (`SmithersClient.swift:4215-4227`).

There is also a filter edge case: `createIssue` creates an open issue, sets `selectedId`, then reloads with the current `stateFilter` (`IssuesView.swift:374-383`). If the user is on the Closed filter, the newly created open issue is filtered out and selection is cleared by `loadIssues` (`IssuesView.swift:351-367`).

Impact:

- CRUD is not complete: reopen is visible but unavailable.
- Close cannot collect a closing reason even though the client and CLI path support it.
- Creating from the Closed view can make the new issue appear to disappear.

Recommended fix: add `SmithersClient.reopenIssue` if JJHub supports it, or hide Reopen until available. Add a close-confirm sheet with an optional comment. After creating, switch to Open/All before reload or insert the created issue optimistically if it does not match the current filter.

Coverage gap: issue tests document parts of this as comments/source assertions (`Tests/SmithersGUITests/IssuesViewTests.swift:453-482`) rather than exercising the view state transitions. Client tests verify `issue close -c` can be constructed (`Tests/SmithersGUITests/SmithersClientTests.swift:1740-1748`), but the UI path never supplies a comment.

### 6. Medium: Workspace restore-from-snapshot does not name or select the restored workspace

`createWSFromSnapshot` passes an empty workspace name to the client and only switches to the Workspaces tab after creation (`WorkspacesView.swift:514-519`). The client then omits `--name` when the normalized name is empty (`SmithersClient.swift:4257-4274`). `openSnapshotWorkspace` validates by calling `viewWorkspace`, switches tabs, and reloads, but it does not select, scroll to, or otherwise surface the target workspace (`WorkspacesView.swift:526-534`).

Impact:

- Restored workspaces depend on backend default naming, even though tests and user-facing expectations imply a deterministic name derived from the snapshot (`Tests/SmithersGUITests/WorkspacesViewTests.swift:486-500`).
- After opening/restoring from a snapshot, users land on the Workspaces tab without a clear indication of which workspace was affected.

Recommended fix: generate a stable restore name in the view, such as `(snap.name ?? snap.id)-from-snapshot`, pass it to `createWorkspace`, and track/select the returned workspace id. If selection is not part of the current Workspaces UI, at least post a success banner with the new or opened workspace name/id.

Test note: `WorkspacesViewTests` contains stale bug documentation saying create-from-snapshot has no in-flight indicator (`Tests/SmithersGUITests/WorkspacesViewTests.swift:511-519`), but the current view does use `actionInFlight` (`WorkspacesView.swift:514-523`).

### 7. Medium: Run snapshots ignore child timelines and fork/replay only accepts frame-style snapshot ids

`Timeline.snapshots()` maps only the current timeline's `frames` and ignores `children` (`SmithersModels.swift:1251-1272`). `SmithersClient.listSnapshots` returns only that flattened result (`SmithersClient.swift:2921-2937`). The snapshot sheet displays and acts on that list (`RunInspectView.swift:673-688`, `RunInspectView.swift:940-953`).

Fork/replay then requires every selected snapshot id to parse as `runId:frameNo` (`SmithersClient.swift:2940-2978`, `SmithersClient.swift:2988-2995`). That works for frame snapshots generated by `Snapshot.init` (`SmithersModels.swift:1310-1334`), but not for explicit snapshot ids decoded from an API/CLI response (`SmithersModels.swift:1340-1361`).

Impact:

- Forked child timelines can be absent from the snapshot browser.
- Manual/error/fork snapshots with explicit ids may render, but Fork/Replay fails with "Expected runId:frameNo".
- The sheet labels kinds as `manual` by default (`RunInspectView.swift:836-843`, `RunInspectView.swift:870-878`), but the actual action path is frame-only.

Recommended fix: decide whether the sheet is a frame timeline browser or a general snapshot manager. If it is general, recursively flatten `children`, preserve snapshot refs/action metadata, and make Fork/Replay call APIs that accept real snapshot ids. If it is frame-only, name it accordingly and disable/hide unsupported snapshot kinds.

Coverage gap: the model test only covers a timeline with empty `children` (`Tests/SmithersGUITests/SmithersModelsTests.swift:569-600`). There are no tests for recursive child timelines, explicit non-frame snapshot ids, failed parse behavior, or the sheet's Fork/Replay buttons.

### 8. Low: Workspace snapshot decoding silently accepts missing workspace ids

`WorkspaceSnapshot` decodes `workspaceId` from either `workspaceId` or `workspace_id`, but falls back to an empty string if neither is present (`SmithersModels.swift:1832-1841`). The "open workspace" action then trims the empty id and silently returns (`WorkspacesView.swift:526-528`).

Impact:

- A malformed or changed JJHub response produces a row whose open action does nothing and gives no user feedback.
- The underlying data issue is hidden during decode instead of surfacing as a parse error.

Recommended fix: either make `workspaceId` optional and render a disabled action with an explanation, or require a non-empty id during decoding and fail fast.

Coverage gap: tests cover camelCase and snake_case positive paths (`Tests/SmithersGUITests/SmithersModelsTests.swift:798-814`), but not the missing-id case.

## JJHub Integration Notes

The command-shape coverage for JJHub is useful: `SmithersClientJJHubStubTests` verifies landings, issues, workspaces, workspace snapshots, and change diffs against a temporary `jjhub` stub (`Tests/SmithersGUITests/SmithersClientTests.swift:1431-1893`). The client also handles common JJHub model differences, including issue numeric ids and name-ref labels/assignees (`SmithersModels.swift:1690-1755`), landing author objects and `target_bookmark` (`SmithersModels.swift:1600-1629`), and workspace/snapshot snake-case timestamps (`SmithersModels.swift:1794-1801`, `SmithersModels.swift:1832-1841`).

Remaining integration risks:

- Error envelope and failure-path coverage is thin for JJHub commands. Most stub commands return happy-path JSON.
- Workspace models intentionally discard many JJHub fields from the stub, such as VM id, persistence, fork status, parent workspace id, updated timestamp, and snapshot id (`Tests/SmithersGUITests/SmithersClientTests.swift:1472-1495`). That may be fine for this UI, but lifecycle screens cannot explain fork lineage or VM state with the current model.
- UI tests run fixture mode rather than real JJHub flows, so they validate navigation and presence more than actual CLI lifecycle behavior.

## Test Coverage Gaps

Recommended tests to add or update:

- Agent bridge integration test with a fake bridge emitting several JSONL chunks, asserting ordered chat rows and that `finishDetachedTurn` happens after the last event.
- Codex decoding tests for object-valued `arguments`, object/array `input` and `output`, and lossy preservation of unknown dynamic fields.
- Agent message handling test for multiple `agent_message` events, including an `item.updated` shape if supported, to prevent duplicate paragraph accumulation (`AgentService.swift:473-482`).
- Landings view test for server-returned `ready` under the Open filter and `landed` under the Merged filter.
- Landing diff test using multi-change text from `landingDiff`, including `Change <id>` separators.
- Issue UI tests for create while Closed filter is active, close-with-comment flow, missing-number feedback, and reopen availability once client support exists.
- Workspace restore tests asserting generated name, returned workspace visibility/selection, and malformed snapshot `workspaceId` behavior.
- Timeline snapshot tests with non-empty `children`, explicit non-frame snapshot ids, and Fork/Replay disabled/error behavior.

Several existing tests are stale or mostly source-inspection documentation. Examples include the Landings filter refetch comment (`Tests/SmithersGUITests/LandingsViewTests.swift:169-184`), workspace snapshot auto-name expectations (`Tests/SmithersGUITests/WorkspacesViewTests.swift:415-433` versus `WorkspacesView.swift:502-507`), create-from-snapshot in-flight comments (`Tests/SmithersGUITests/WorkspacesViewTests.swift:511-519`), and the old weak-capture syntax note in `AgentServiceTests` (`Tests/SmithersGUITests/AgentServiceTests.swift:700-705` versus current weak capture in `AgentService.swift:303-315`).

## Summary

The highest-risk issues are in Codex event ingestion: ordered delivery is not guaranteed, and dynamic tool payloads can be dropped during decoding. For JJHub-backed features, the client command coverage is a good base, but the UI still has product-facing gaps around landing state normalization, landing diff rendering, issue reopen/close comments, workspace restore naming, and snapshot lineage. The tests should move from source-inspection comments toward behavioral coverage of the lifecycle edges above.
