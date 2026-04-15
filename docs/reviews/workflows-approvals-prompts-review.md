# Workflows Approvals Prompts Review

Review scope: `WORKFLOWS`, `APPROVALS`, and `PROMPTS` feature groups, focused on `WorkflowsView.swift`, `ApprovalsView.swift`, `PromptsView.swift`, `SmithersModels.swift`, `SmithersClient.swift`, and the related unit/UI test files. Per request, `swift test` was not run.

## Findings

### High: Prompt preview ignores the edited source buffer

`PromptsView.swift:496` captures the current editor source before rendering, but `PromptsView.swift:513` calls `smithers.previewPrompt(id, input: selectedValues)` and never passes that captured source. The only source-aware overload in `SmithersClient.swift:2890` discards its `source` parameter and delegates back to the saved-prompt path at `SmithersClient.swift:2891`.

That means Preview can render the saved file or backend prompt while the editor contains unsaved changes. This breaks the prompt editing/preview loop: a user can edit `{props.name}` text, see a preview, and get output from stale source. The current test locks in the wrong behavior: `Tests/SmithersGUITests/PromptsViewTests.swift:428` expects the id/input overload to be called and `Tests/SmithersGUITests/PromptsViewTests.swift:430` expects the source overload not to be called.

Recommendation: make preview rendering accept the editor source and use it for local rendering or transport requests. Then update the test to assert `previewPromptSourceCalledWith?.source == "Unsaved {props.name}"` and add a regression that saved source and editor source differ.

### High: Approval actions cannot target non-zero task iterations

`Approval` has `runId` and `nodeId`, but no `iteration` field in `SmithersModels.swift:587`. `ApprovalsView.swift:441` and `ApprovalsView.swift:463` call `approveNode`/`denyNode` with only run id and node id. The client defaults missing iterations to `0` at `SmithersClient.swift:1388` and `SmithersClient.swift:1427`, and synthetic approval discovery drops `RunTask.iteration` when creating approvals at `SmithersClient.swift:3497`.

For repeated tasks, retries, or DAG nodes that can be blocked at iteration `1+`, the queue can approve or deny the wrong gate. The lower-level client already supports `--iteration` and has tests for the CLI args, but the queue model and view cannot carry that value to the action.

Recommendation: add `iteration: Int?` to `Approval` and `ApprovalDecision`, decode it from transports, include it in synthetic approvals, show it in metadata when present, and pass it through `approveNode`/`denyNode`. Add an ApprovalsView regression with two pending approvals sharing `runId/nodeId` and different iterations.

### Medium: The list/detail layouts are fixed HStacks, not adaptive split views

All three feature views hand-roll split layout with fixed list widths: `WorkflowsView.swift:153` and `WorkflowsView.swift:155` use a `HStack` plus a 280 pt list, `ApprovalsView.swift:35` and `ApprovalsView.swift:37` use a 300 pt list, and `PromptsView.swift:104` and `PromptsView.swift:106` use a 240 pt list. None of the three uses `NavigationSplitView` or adapts for compact widths.

This is serviceable on a wide macOS window, but it means the list always consumes fixed horizontal space and the detail pane can become cramped instead of collapsing, resizing, or using native selection/sidebar behavior. The tests mostly assert the magic widths, for example `Tests/SmithersGUITests/WorkflowsViewTests.swift:88` and `Tests/SmithersGUITests/PromptsViewTests.swift:126`, so they preserve the current rigidity instead of protecting usability.

Recommendation: either move these to `NavigationSplitView` or extract named width constants with min/max/adaptive rules. Add UI coverage at a narrow window size that selects a row and verifies the detail remains usable.

### Medium: Prompt inputs do not track unsaved variable edits

Prompt inputs are loaded from the selected prompt record and from `discoverPromptProps(promptId)` in `PromptsView.swift:418` and `PromptsView.swift:442`. Editing source only increments `sourceEditGeneration` at `PromptsView.swift:92` and schedules preview work at `PromptsView.swift:115`; it does not rediscover variables from the edited source.

If a user adds `{props.ticket}` or removes `{props.name}` in the editor, the Inputs tab can remain stale until save/reselect. Combined with the stale-source preview issue above, variable substitution is not trustworthy for unsaved prompt edits.

Recommendation: derive inputs from the current editor buffer during debounce, or expose a client/helper that discovers props from a source string. Preserve existing user-entered values for matching keys and add/remove controls as the source changes. Add tests for adding, removing, and renaming variables in the editor.

### Medium: Approval wait time and color coding do not update while the queue sits open

`Approval.waitTime` computes from `Date()` every time it is read at `SmithersModels.swift:634`, and `ApprovalsView.swift:355` computes color thresholds from `Date()` as well. `ApprovalsView` has manual refresh and `.refreshable`, but no timer, poll, stream, or injectable clock that forces periodic re-rendering.

An approval that crosses the 5 minute or 30 minute threshold while the view is open can continue showing the old label/color until some unrelated state change or refresh occurs. This weakens the queue urgency signal.

Recommendation: add a lightweight timer tick while the Approvals view is active, or refresh/poll the queue on a defined interval. Extract the threshold logic behind an injectable clock so tests can assert boundary transitions without duplicating private implementation.

### Medium: Workflow launch validation is post-submit only and can mark a workflow as failed without launching

The dynamic launch form supports string, number, boolean, object, array, and json controls in `WorkflowsView.swift:961`. Validation happens in `buildLaunchInputs()` at `WorkflowsView.swift:1403`, and invalid numbers or JSON throw before `smithers.runWorkflow` is called. The catch block at `WorkflowsView.swift:1396` then sets `lastRunStatusByWorkflowID[workflow.id] = .failed` at `WorkflowsView.swift:1398`.

A local form validation error can therefore create a "failed" last-run badge even though no run was created. The form also has no inline field error, so the user only sees the generic launch error under the button.

Recommendation: distinguish local validation failures from launch failures. Keep validation errors attached to the relevant field or section, and only update last-run status after the backend returns a run or launch failure.

### Low: Prompt save can leave global saving state stuck after selection changes

`PromptsView.savePrompt()` sets `isSaving` from the button action at `PromptsView.swift:249`, then returns early if the selected prompt changes before the async save completes at `PromptsView.swift:469` or `PromptsView.swift:473`. Those early returns happen before `isSaving = false` at `PromptsView.swift:476`, and `applySelection` does not reset `isSaving`.

This can leave the next selected prompt with a disabled/spinning Save button after a save races with prompt switching.

Recommendation: use `defer { isSaving = false }`, or track saving by prompt id so switching prompts does not inherit stale global save state.

## Coverage Review

The feature areas have useful model and transport coverage, especially typed workflow input serialization in `Tests/SmithersGUITests/SmithersClientTests.swift:712`, approval decision decoding/transport coverage around `Tests/SmithersGUITests/SmithersClientTests.swift:1001`, and prompt filesystem/render transport coverage around `Tests/SmithersGUITests/SmithersClientTests.swift:1941`.

The view-level coverage is much weaker:

- Many tests are documentation-style assertions (`XCTAssertTrue(true)`) or copied logic rather than behavior. Examples include `Tests/SmithersGUITests/WorkflowsViewTests.swift:431`, `Tests/SmithersGUITests/ApprovalsViewTests.swift:301`, and `Tests/SmithersGUITests/PromptsViewTests.swift:475`.
- Several tests are stale relative to the current implementation. `Tests/SmithersGUITests/PromptsViewTests.swift:505` says switching prompts silently discards changes, but `PromptsView.swift:404` now gates selection with an unsaved-changes alert. `Tests/SmithersGUITests/ApprovalsViewTests.swift:311` says history mode fetches pending approvals first, but `ApprovalsView.swift:414` branches directly to `listRecentDecisions()`. `Tests/SmithersGUITests/WorkflowsViewTests.swift:460` says the run button is usable before DAG load, but `WorkflowsView.swift:639` disables it and `WorkflowsView.swift:1345` returns while the DAG is loading.
- Some E2E expectations no longer match the Workflows UI. `Tests/SmithersGUIUITests/DashboardWorkflowsE2ETests.swift:45` expects `workflows.launchForm` and `Tests/SmithersGUIUITests/DashboardWorkflowsE2ETests.swift:49` expects `workflows.launchButton`, but the current `WorkflowsView` renders launch fields inline and only exposes `workflows.runButton`.
- Workflows view tests do not exercise `buildLaunchInputs()` behavior for invalid numbers, invalid JSON, object/array type enforcement, default booleans, or the "validation failure is not a backend failed run" distinction.
- Approvals tests duplicate private wait-color logic at `Tests/SmithersGUITests/ApprovalsViewTests.swift:495` instead of testing production code through an injectable clock or internal helper.
- Prompt tests currently assert that source-aware preview is not used at `Tests/SmithersGUITests/PromptsViewTests.swift:430`, which hides the most important prompt preview bug.
- Prompt E2E coverage has trouble selecting rows because `PromptsView` does not expose row, list, tab, or root accessibility identifiers beyond the source editor. `PromptsLandingsSQLE2ETests.swift:18` searches for an icon-like identifier that the prompt rows do not set.

## Feature Coverage Summary

- Split list/detail layouts: implemented in all three views, but fixed-width and non-adaptive.
- Dynamic workflow launch forms: implemented inline in the Launch tab with typed controls and JSON parsing, but validation feedback and failed-run status handling need cleanup.
- Input schema display: workflow fields show name/type/key/default; prompt inputs show name/type/default placeholders. Neither path displays richer schema constraints, required fields, descriptions, or enum choices.
- Approval queue: pending queue, inline approve/deny, deny confirmation, payload display, synthetic-source labeling, and decision history toggle are present.
- Wait time color coding: present with 5 minute warning and 30 minute danger thresholds, but not live-updating.
- Decision history: present and backed by `listRecentDecisions`, with detail metadata for note/reason when selected.
- Prompt editing/preview: source editing, unsaved-change prompt switching, save, inputs, and preview tabs are present, but preview does not render unsaved source and inputs do not follow unsaved variable edits.
- Variable substitution: client-side fallback uses one regex path for discovery/render, but only for saved source; the UI tests contain stale expectations from an older literal replacement implementation.

## Verification

Commands used during review were read-only source inspections (`rg`, `nl`, `sed`, `wc`, `find`, and `git status`). `swift test` was not run, per request.
