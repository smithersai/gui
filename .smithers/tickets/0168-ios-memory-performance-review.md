# iOS Memory / Leak Review + Baseline Performance Sanity

Date: 2026-04-24

Scope reviewed: `ios/Sources`, `Shared/Sources`, and the shared `TerminalSurface.swift` used by iOS.

Method: static analysis only. No profiler run. No fixes applied.

## Severity Counts

- Critical: 0
- High: 1
- Medium: 2
- Low: 3

## Findings

### HIGH-01 - Devtools screenshots retain raw payloads and re-decode images from SwiftUI body

Files:

- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:94`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:217`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:239`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:391`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:547`

`DevtoolsPanelViewModel` keeps `[DevtoolsSnapshotItem]`, and each item stores `payload: Any`. The parser uses `JSONSerialization` and preserves the full parsed snapshot payload, including base64 screenshot strings. Rendering a screenshot card then walks the payload and calls `Data(base64Encoded:)` plus `UIImage(data:)` from the SwiftUI body path. A large screenshot can therefore exist as response `Data`, parsed JSON/base64 `String`, decoded image `Data`, and a `UIImage`/decoded surface during rendering. Re-renders can repeat the decode.

Specific fix: convert snapshot payloads into a typed, memory-bounded model at fetch time. For screenshots, cap accepted encoded byte size, downsample via `CGImageSourceCreateThumbnailAtIndex`, cache the resulting thumbnail once, and discard the raw base64 string after decode. Prefer server-provided thumbnail URLs or snapshot IDs for full-size screenshots instead of retaining full image payloads in `@Published` state.

### MEDIUM-01 - Agent chat polling task self-retains the view model for the lifetime of the loop

Files:

- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:181`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:246`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:248`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:249`

`AgentChatViewModel` owns `pollingTask`, and the task closure captures `[weak self]` but immediately upgrades with `guard let self else { return }` before entering the `while !Task.isCancelled` loop. After that upgrade, the task strongly retains the model until cancellation. `.onDisappear { model.stopPolling() }` exists at `AgentChatView.swift:108`, but the object still forms a cycle if disappearance cancellation is missed or delayed.

Specific fix: re-acquire `self` inside each loop iteration instead of before the loop, or capture stable dependencies outside the closure and only hop back to `self` weakly for state publication. Add `deinit { pollingTask?.cancel() }` as a backstop.

### MEDIUM-02 - Feature flag refresh loop self-retains the access gate model

Files:

- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:22`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:48`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:49`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:52`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:60`

`IOSRemoteAccessGateModel` owns `refreshLoopTask`. The task uses `[weak self]` but upgrades to a strong `self` before the infinite refresh loop, so the task keeps the model alive until `deactivate()` cancels it. `SignedInRemoteAccessSurface` calls `deactivate()` on disappear, but the model has no `deinit` cancellation guard, and the retained loop is still a cycle while active.

Specific fix: move `guard let self else { return }` inside the loop after each sleep, or capture `featureFlags`, `sleep`, and intervals outside the closure and update model state through a weak `self`. Add `deinit { deactivate(resetState: false) }`.

### LOW-01 - Feature flag refresh publishes unchanged state and recomputes the signed-in shell

Files:

- `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:79`
- `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:139`
- `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:185`
- `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:200`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:73`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:76`
- `ios/Sources/SmithersiOS/SmithersApp.swift:107`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:112`

The gate refreshes every 60 seconds with `force: true`. `FeatureFlagsClient` publishes `isRefreshing`, `snapshot`, `lastRefreshAt`, and errors, and `apply(snapshot:at:)` assigns even when the flag values are unchanged. The access gate also assigns `.enabled` or `.disabled` on every successful refresh. Because the root signed-in surface observes both `access` and `featureFlags`, unchanged refreshes can invalidate and recompute the shell.

Specific fix: only assign `snapshot` when it differs from the existing snapshot, only assign `state` when it changes, and consider splitting the observed feature flag surface into a small derived `Equatable` state that contains only the booleans needed by iOS shell rendering.

### LOW-02 - Terminal byte publishing can force full-buffer renderer work per PTY event

Files:

- `TerminalSurface.swift:131`
- `TerminalSurface.swift:207`
- `TerminalSurface.swift:217`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:178`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:179`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift:365`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift:419`

`TerminalSurfaceModel.recentBytes` is capped at 64 KiB, so this is bounded memory, not an unbounded leak. The performance issue is that every PTY byte append publishes the whole `Data` value. The fallback iOS text renderer converts the full buffer to `String` on every update, and the Ghostty path can snapshot/feed on each published update. High-throughput PTY output can therefore produce excessive main-thread work and transient allocations.

Specific fix: coalesce PTY byte updates before publishing to SwiftUI, for example a small main-actor buffer flushed on a display-link or 30-60 Hz task. Keep the 64 KiB cap, but publish a render tick or append batches rather than triggering renderer work for every incoming event.

### LOW-03 - Shared token refresh task captures its owner while being stored by that owner

Files:

- `Shared/Sources/SmithersAuth/TokenManager.swift:51`
- `Shared/Sources/SmithersAuth/TokenManager.swift:90`
- `Shared/Sources/SmithersAuth/TokenManager.swift:98`
- `Shared/Sources/SmithersAuth/TokenManager.swift:123`
- `Shared/Sources/SmithersAuth/TokenManager.swift:124`

`TokenManager` stores `inFlightRefresh`, and `makeRefreshTask` creates `Task { [self, client, store] in ... }`. The normal path clears `inFlightRefresh` in `defer`, so this is not an expected permanent leak. Still, while a refresh is hung or very slow, the owner retains the task and the task retains the owner, with no cancellation or explicit request timeout in this layer.

Specific fix: avoid capturing `self` in the task stored on `self`. Capture `client`, `store`, and `current`; return a result to `refresh()` and update/clear manager state after awaiting. Alternatively move in-flight coordination into a small separate box/actor and add an explicit cancellation/timeout policy.

## Validated Non-Findings

- `RuntimePTYTransport` retry scheduling is not a retain cycle in the current code: the retry task at `TerminalSurface.swift:444` captures `[weak self]`, and `stop()` cancels it and removes the runtime listener at `TerminalSurface.swift:364`.
- No `Timer.scheduledTimer` sites were found in the reviewed scope. `PlaceholderPTYTransport` has a `timer` field, but the current implementation does not schedule it and invalidates it in `stop()` at `TerminalSurface.swift:527`.
- No `URLSessionDelegate` or `URLSession(configuration:delegate:delegateQueue:)` usage was found in `ios/Sources`, `Shared/Sources`, or `TerminalSurface.swift`. The reviewed clients use `.shared` or injected `URLSession` with `data(for:)`, so the common session-task-delegate retain cycle is not present.
- No `@StateObject` instances were found inside `ForEach` row bodies. Row views such as `WorkflowRunsListRow`, `ApprovalInboxRow`, `AgentChatMessageRow`, `DevtoolsSnapshotCard`, and repo rows are value views. `WorkflowRunDetailView` uses `@StateObject`, but it is mounted through `navigationDestination`, not as a list row object.
- `WorkflowRunsListView` uses finite `.task`, button, and refreshable work. No unbounded polling loop, timer, or retained URLSession delegate was found there.
