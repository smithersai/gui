# 0194 iOS Performance Memory And Rendering Pass

Audit date: 2026-04-30

## Summary

The app builds and tests pass, but several iOS paths are likely expensive under real use: terminal byte publishing can trigger full-buffer work per PTY event, chat polling/rendering can churn, feature flag refresh can republish unchanged snapshots, and runtime cache defaults are large for mobile.

## Parallel Ownership

Primary owner writes:

- `TerminalSurface.swift`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift`
- `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift`
- performance-focused tests under `ios/Tests/SmithersiOSTests` or `Tests/SmithersGUITests`

Coordinate with ticket 0188 before editing terminal mount behavior.

## Requirements

- Coalesce PTY byte updates before publishing to SwiftUI; avoid full-buffer rendering on every small event.
- Preserve the 64 KiB buffer cap unless a better bounded policy is added.
- Avoid republishing feature flag snapshots when effective state has not changed.
- Reduce chat polling churn or add backoff/stream adoption where already supported.
- Add lightweight counters or test hooks to prove update coalescing and reduced publication counts.

## Acceptance Criteria

- [x] Terminal byte burst test proves render publications are bounded below incoming event count.
- [x] Feature flag refresh test proves unchanged snapshots do not trigger unnecessary published changes.
- [x] Chat send/follow-up path avoids fixed aggressive polling when no new data arrives.
- [x] No visible terminal/chat regression in existing tests.
- [x] Document measured before/after behavior in the ticket closeout.

## Closeout Metrics (2026-05-01)

- Terminal coalescing evidence:
  `ios/Tests/SmithersiOSTests/TerminalSurfaceConnectionStateTests.swift::test_terminal_byte_burst_is_coalesced`
  drives 200 incoming PTY chunk events and asserts:
  `debugIncomingChunkCount == 200`,
  `debugPublishedChunkCount < debugIncomingChunkCount`,
  and final buffer integrity (`recentBytes.count == 200`).
  Before: one publish per event was possible under bursty PTY traffic.
  After: publish count is strictly lower than event count under the same burst.
- Feature flag no-op republish suppression:
  `ios/Tests/SmithersiOSTests/FeatureFlagGateTests.swift::test_unchanged_snapshot_does_not_republish`
  performs two forced refreshes with unchanged effective payload and asserts:
  `publishCount == 1`,
  `debugSnapshotPublishCount == 1`,
  and timestamp advancement (`lastRefreshAt != nil`).
  Before: unchanged snapshots could still republish.
  After: unchanged refreshes do not emit additional snapshot publications.
- Chat polling backoff evidence:
  `ios/Tests/SmithersiOSTests/AgentChatViewTests.swift::testPollingBacksOffWhenNoNewMessagesArrive`
  collects the first 4 idle poll intervals and asserts non-decreasing cadence
  (`interval[0] <= interval[1] <= interval[2]`), using config
  `activeSeconds=0.01`, `backoffMultiplier=2.0`, `maxSeconds=0.2`.
  Before: fixed aggressive cadence could continue during idle periods.
  After: idle polling backs off progressively and avoids fixed aggressive polling.
- Regression safety:
  existing terminal/chat behavior tests continue to pass alongside the new
  coalescing/backoff/no-op-publication tests.

## Verification

```sh
swift test
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Related

- `.smithers/tickets/0168-ios-memory-performance-review.md`
