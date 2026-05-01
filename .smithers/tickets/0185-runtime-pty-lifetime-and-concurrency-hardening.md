# 0185 Runtime PTY Lifetime And Concurrency Hardening

Audit date: 2026-04-30

## Summary

The Swift runtime PTY wrapper can outlive its owning `RuntimeSession`, and the Zig transport audit identified worker lifetime races around subscription and PTY workers. This is the highest-risk native runtime boundary because it crosses Swift, C ABI, Zig threads, WebSocket PTY, and terminal teardown.

## Parallel Ownership

Primary owner writes:

- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift`
- `Shared/Tests/SmithersRuntimeTests`
- `libsmithers/src/core/transport.zig`
- `libsmithers/src/core/ffi.zig`
- `libsmithers/test/**` as needed

Avoid touching iOS UI terminal files; ticket 0186 owns UI/product attach behavior.

## Requirements

- Make `RuntimePTY` retain or otherwise safely tie itself to its owning `RuntimeSession` until detach/deinit completes.
- Ensure `RuntimeSession` disconnect cannot free Zig session state while Swift PTY handles can still call write, resize, or detach.
- Fix worker publication races: workers must not be visible to unsubscribe/destroy paths before their thread/lifetime fields are initialized.
- Fix write/resize vs detach/destroy races by adding explicit lifetime protection or locked ownership discipline.
- Preserve public API shape where practical, but prefer a breaking internal initializer over unsafe lifetime semantics.

## Acceptance Criteria

- [ ] Swift tests cover PTY handle outliving local `RuntimeSession` references without use-after-free behavior.
- [ ] Zig tests cover attach/write/resize/detach/destroy race paths with deterministic fake transport or stress loop.
- [ ] `smithers_core_disconnect` is safe with outstanding PTY wrappers.
- [ ] Destroy/unsubscribe paths cannot free a worker before its thread handle is initialized.
- [ ] No UI behavior changes are required by this ticket.

## Verification

```sh
cd libsmithers && zig build test --summary all
cd .. && swift test
```

## Related

- `.smithers/tickets/0166-libsmithers-concurrency-audit.md`
- `.smithers/tickets/0161-zig-swift-ffi-audit-ghostty.md`
