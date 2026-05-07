# Scores, Memory, And Search Review

Review scope: `SCORES`, `MEMORY`, and `SEARCH` feature groups, focused on `ScoresView.swift`, `MemoryView.swift`, `SearchView.swift`, `SmithersModels.swift`, `SmithersClient.swift`, and the related unit/UI test files.

`swift test` was not run per instruction.

## Findings

No high severity issues found.

### Medium: Scores summary mixes selected-run scores with unscoped global metrics

`ScoresView.swift:666` selects a run, `ScoresView.swift:669` loads scores for that run, and `ScoresView.swift:672` computes aggregates from those selected-run rows. The summary panel then labels itself "Today's Summary" at `ScoresView.swift:150`, but the token, latency, and cost calls at `ScoresView.swift:693`, `ScoresView.swift:694`, and `ScoresView.swift:695` use default `MetricsFilter()` values.

That means the aggregate score table is run-scoped while the adjacent summary tiles can be all-time/global metrics. Switching runs also calls only `loadScores(for:)` from `ScoresView.swift:720`, so the metrics do not reload when the selected run changes. Users can read one selected run's evaluation count and mean next to unrelated token, latency, cache, and cost totals.

Recommendation: pass a run-scoped `MetricsFilter(runId: selectedRunId, ...)` when a run is selected, reload metrics from `selectRun(_:)`, and either apply an explicit day filter/grouping for the "Today's Summary" copy or rename the panel to match the actual metric scope.

### Medium: Recall and search loading flags are vulnerable to stale async completions

`MemoryView.doRecall()` increments `recallGeneration` and correctly guards result/error writes at `MemoryView.swift:550` and `MemoryView.swift:553`, but its `defer { isRecalling = false }` at `MemoryView.swift:542` is not generation-gated. An older recall can return after a newer recall starts, hit the generation guard, and still clear the loading state for the newer recall.

`SearchView.search()` has the same shape: it increments `searchGeneration` at `SearchView.swift:212`, guards result/error writes at `SearchView.swift:228` and `SearchView.swift:231`, but always clears `isSearching` in the `defer` at `SearchView.swift:215`. Fast tab switches or repeated submissions can temporarily show an idle empty state while the latest request is still in flight.

Recommendation: gate the loading-flag reset on the same generation value used for results, for example `defer { if generation == searchGeneration { isSearching = false } }` and the equivalent for recall.

### Medium: Code search line numbers are wrong for discontiguous matches

`SmithersClient.decodeCodeSearchResults` preserves per-match line numbers while parsing matches, but then flattens all match text into one `snippet` at `SmithersClient.swift:4601` and stores only the first non-nil line number at `SmithersClient.swift:4606`. `SearchView.swift:137` to `SearchView.swift:142` then labels every snippet line by incrementing from that single starting line.

This works only when the snippet lines are contiguous. If JJHub returns multiple `text_matches` from lines 12 and 80, the UI will render the second match as line 13. The result is especially misleading because the view now presents inline line numbers.

Recommendation: keep snippets as structured ranges with their own starting lines, or format line prefixes during decoding while each match's line number is still available. Add a decode/view test with two non-contiguous matches.

### Medium: Namespace selection can be overwritten by an in-flight memory refresh

`MemoryView.loadFacts()` captures `requestedNamespace` before the async fetch at `MemoryView.swift:499`, then uses that old value to compute `validNamespace` at `MemoryView.swift:515`. If the user changes the namespace while a refresh is in flight, the completion can restore or clear the stale pre-refresh selection at `MemoryView.swift:519` and `MemoryView.swift:520`.

Because the same `namespaceFilter` drives both list filtering and semantic recall scope, this race can change the visible fact set and the next recall namespace without a direct user action.

Recommendation: validate the current `namespaceFilter` after the fetch completes instead of the captured value, and only clear it when the current selection is absent from the new namespace list.

### Low: Score color thresholds are duplicated and unguarded

`ScoresView.scoreColor(_:)` at `ScoresView.swift:577` to `ScoresView.swift:581` and `MemoryView.scoreColor(_:)` at `MemoryView.swift:429` to `MemoryView.swift:433` duplicate the same `>= 0.8`, `>= 0.5`, and fallback-danger thresholds. The tests in `ScoresViewTests.swift:159` to `ScoresViewTests.swift:165` mirror a private helper rather than exercising production code, and `MemoryViewTests.swift:281` to `MemoryViewTests.swift:288` only checks that theme colors exist.

The implementation also assumes scores are normalized finite values. Out-of-range values silently map through the same thresholds, so a score above 1.0 renders success and a non-finite or unexpected value is not distinguished from a valid low score.

Recommendation: centralize score coloring in a small internal helper that can be tested directly. Decide whether to clamp, reject, or render an "unknown" color for non-finite and out-of-range values.

### Low: Recall results hide available metadata

`MemoryRecallResult` carries `metadata` at `SmithersModels.swift:1244`, and the UI allows recall across all namespaces via `MemoryView.swift:544` to `MemoryView.swift:548`. The recall result row in `MemoryView.swift:361` to `MemoryView.swift:365` displays only content, so all-namespace results do not expose namespace/key metadata even when the backend returns it.

This makes namespace filtering hard to verify visually and makes mixed-namespace recall results less actionable.

Recommendation: render concise metadata under the result content when present, especially namespace/key or source fact identifiers.

## Aggregate Stats Review

`AggregateScore.aggregate(_:)` in `SmithersModels.swift:864` to `SmithersModels.swift:888` is in good shape for the core stats requested in this review. It groups by `ScoreRow.scorerDisplayName`, computes count/mean/min/max, averages the two middle values for even-count P50, and sorts scorer names for stable display.

The most important aggregate-stats risk is not the model computation itself. It is the scope mismatch in `ScoresView`: selected-run aggregates sit next to unscoped metrics, and the summary label implies a daily view that the fetches do not enforce.

## Coverage Review

The related tests have broad file coverage, but much of the suite is source-inspection or documentation-style testing. Several tests are stale relative to current code, so they can pass while asserting the wrong risk.

Specific stale or weak areas:

- `ScoresViewTests.swift:178` to `ScoresViewTests.swift:181` says summary scores use three decimals, but `ScoresView.swift:566` formats aggregate cells with two decimals.
- `ScoresViewTests.swift:275` to `ScoresViewTests.swift:283` documents a per-call `DateFormatter` bug, but `ScoresView.swift:583` to `ScoresView.swift:588` now uses a static formatter.
- `ScoresViewTests.swift:313` to `ScoresViewTests.swift:328` documents even-count P50 as broken, but `SmithersModels.swift:872` to `SmithersModels.swift:874` now averages the middle values.
- `MemoryViewTests.swift:253` to `MemoryViewTests.swift:264` and `MemoryViewTests.swift:327` to `MemoryViewTests.swift:340` claim recall does not pass the namespace, but `MemoryView.swift:544` to `MemoryView.swift:548` passes `namespaceFilter`, `workflowPath`, and `topK`.
- `MemoryViewTests.swift:542` to `MemoryViewTests.swift:554` says the namespace filter is hidden in recall mode, but the toolbar renders the namespace menu outside the mode switch at `MemoryView.swift:109` to `MemoryView.swift:175`.
- `MemoryViewTests.swift:514` to `MemoryViewTests.swift:537` describes a shared error state that no longer exists; current code uses `listError` and `recallError`.
- `SearchViewTests.swift:170` to `SearchViewTests.swift:187` says snippets are not line-numbered, but `SearchView.swift:135` to `SearchView.swift:145` now prefixes snippet lines when `lineNumber` is available.
- `SearchViewTests.swift:222` to `SearchViewTests.swift:233` documents a result-count pluralization bug, but `SearchView.swift:82` handles the singular case.
- `SearchViewTests.swift:253` to `SearchViewTests.swift:268` says search does not clear old results before loading, but `SearchView.swift:216` clears `results` before the async request.
- `SearchViewTests.swift:441` to `SearchViewTests.swift:452` says search errors are swallowed, but `SearchView.swift:230` to `SearchView.swift:233` stores the error and the empty state displays it at `SearchView.swift:95` to `SearchView.swift:101`.

Recommended coverage additions:

- Add direct `AggregateScore.aggregate(_:)` tests for odd/even P50, fallback scorer names, sorting, and out-of-range score policy.
- Replace copied color-threshold helpers with tests against a shared production score-color helper.
- Add a `SearchView` mock-client test that switches Code/Issues/Repos and asserts the correct client method and issue state are used.
- Add a search decode/view test for multiple discontiguous code matches to catch incorrect line numbering.
- Add a `MemoryView` mock-client interaction test that selects a namespace, performs recall, and asserts the recall call receives that namespace and topK.
- Add async race tests for search and recall generation handling so stale completions cannot clear the latest loading state.
- Update or remove tests that only assert `XCTAssertTrue(true)` or stale "BUG" comments. They currently create false confidence and obscure real regressions.

## Verification

Commands run during review:

```text
rg --files | rg '(ScoresView|MemoryView|Search|Score|Memory|Tests|Spec)'
git status --short
nl -ba ScoresView.swift
nl -ba MemoryView.swift
nl -ba SearchView.swift
nl -ba Tests/SmithersGUITests/ScoresViewTests.swift
nl -ba Tests/SmithersGUITests/MemoryViewTests.swift
nl -ba Tests/SmithersGUITests/SearchViewTests.swift
rg -n 'aggregateScores|listRecentScores|searchCode|searchIssues|searchRepos|recallMemory|listAllMemoryFacts|getTokenUsageMetrics|getLatencyMetrics|getCostTracking' SmithersClient.swift AgentService.swift SmithersModels.swift Models.swift
nl -ba SmithersClient.swift | sed -n '1800,2075p'
nl -ba SmithersClient.swift | sed -n '4460,4745p'
nl -ba SmithersModels.swift | sed -n '820,1265p'
nl -ba SmithersModels.swift | sed -n '2730,2765p'
nl -ba Tests/SmithersGUIUITests/RunsScoresMemoryE2ETests.swift
nl -ba Tests/SmithersGUIUITests/SearchIssuesE2ETests.swift
nl -ba Tests/SmithersGUITests/SmithersModelsTests.swift | sed -n '360,455p'
nl -ba Tests/SmithersGUITests/SmithersClientTests.swift | sed -n '490,640p'
nl -ba Tests/SmithersGUITests/SmithersClientTests.swift | sed -n '735,805p'
nl -ba Tests/SmithersGUITests/SmithersClientTests.swift | sed -n '1370,1435p'
nl -ba Tests/SmithersGUITests/SmithersClientTests.swift | sed -n '1880,1945p'
```

No build or test command was run.
