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

- [ ] Terminal byte burst test proves render publications are bounded below incoming event count.
- [ ] Feature flag refresh test proves unchanged snapshots do not trigger unnecessary published changes.
- [ ] Chat send/follow-up path avoids fixed aggressive polling when no new data arrives.
- [ ] No visible terminal/chat regression in existing tests.
- [ ] Document measured before/after behavior in the ticket closeout.

## Verification

```sh
swift test
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Related

- `.smithers/tickets/0168-ios-memory-performance-review.md`
