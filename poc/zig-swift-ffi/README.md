# PoC 0095: Zig ↔ Swift FFI (observable counter)

Stage 0 de-risking PoC for the iOS + remote sandboxes initiative. Validates
the exact FFI pattern the production `libsmithers-core` will use to expose
observable state to SwiftUI.

This directory ships the Zig side: a static library (`libffi_poc.a`) exposing
a minimal C ABI plus unit tests. The Swift side (SwiftUI app + XCTest target)
lives at `../ios-harness/`.

## Zig version

Pinned: **0.15.2**. Matches `/Users/williamcory/gui/.zigversion` at the repo root.

## Build

```sh
cd poc/zig-swift-ffi
zig build                                     # macOS host (arm64)
zig build -Dtarget=aarch64-ios-simulator      # iPhone simulator (arm64)
zig build -Dtarget=aarch64-ios                # iPhone device (arm64)
zig build test                                # host unit tests (Zig allocator clean)
```

The Xcode harness (`../ios-harness/`) runs `build_zig_libs.sh` as a pre-build
step, so `xcodebuild test` automatically refreshes the `.a` files for the
right SDK slice.

## C ABI surface

`include/ffi_poc.h` is the full contract. Five functions:

```c
ffi_session_t ffi_new_session(void);
void          ffi_close_session(ffi_session_t);
uint64_t      ffi_tick(ffi_session_t);
ffi_sub_t     ffi_subscribe(ffi_session_t, ffi_callback_t, void *user_data);
void          ffi_unsubscribe(ffi_session_t, ffi_sub_t);
```

The callback signature:

```c
typedef void (*ffi_callback_t)(uint64_t counter, void *user_data);
```

## Threading model

- **Session owns one background thread.** `ffi_new_session` spawns it with
  `std.Thread.spawn`; it runs `Session.loop` until `destroy()`.
- **Producers (any thread):** `ffi_tick` takes `queue_mutex`, increments the
  counter, appends to `queue`, signals `queue_cond`. Zero allocations on
  the hot path beyond `ArrayList.append`.
- **Consumer (loop thread):** waits on `queue_cond`, drains `queue` into a
  local buffer under the mutex, releases it, snapshots the subscriber list
  under `sub_mutex`, then dispatches each `(value, subscriber)` pair. Each
  dispatch re-checks the live-state under `sub_mutex` so a concurrent
  unsubscribe cannot race with an in-flight callback.
- **Unsubscribe:** safe from any thread. Blocks on `inflight_cond` only
  while the loop is actively calling the exact handle being removed.
- **Close:** sets `stop`, broadcasts, joins the loop, drains any remaining
  queued events (callbacks still fire — this is what "no drops" means),
  frees all state. Safe to call with live subscribers.

### Who marshals to the main thread?

**Swift.** The callback runs on Zig's loop thread. In the Xcode harness,
`IOSHarnessApp.swift` has a `@_cdecl` trampoline that calls
`DispatchQueue.main.async` to hop the main actor. SwiftUI's `@Observable`
publishes on whatever thread the property is mutated, so delivering on
`main` keeps the rendering invariants clean. We deliberately do NOT use
`@MainActor` on the trampoline because the Zig loop must not block on
Swift; `.async` is the safe choice.

`Session.loop` does one notable thing: it preserves the subscriber order
of insertion and the value order of insertion. That's why the XCTest can
assert "1000 ordered updates, no drops, no reorders."

## Lifecycle rules

| Rule | Who enforces |
| --- | --- |
| Session handle valid until `ffi_close_session` returns. | Core. |
| UB to touch session pointer after close. | Host. |
| Subscription handle valid until `ffi_unsubscribe` returns. | Core. |
| UB to double-close a session, or call a session method after close. | Host. |
| Close with live subscribers is defined: force-removes them. | Core. |
| After unsubscribe returns, the callback is guaranteed not to fire again. | Core. |

### `user_data` ownership

**Host owns it.** Zig only stores the raw pointer. The core never copies,
dupes, moves, or frees `user_data`. The host is responsible for:

- Keeping the pointed-to object alive for the lifetime of the
  subscription (between `ffi_subscribe` and `ffi_unsubscribe`/close).
- Freeing the object at unsubscribe, or whenever the host decides.
- Safe cross-thread access: the callback runs on Zig's loop thread, so
  whatever `user_data` points at must tolerate a read from that thread.

The Swift harness uses `Unmanaged<CounterBox>.passRetained` at subscribe
time and `.release()` in `deinit` to get the C-pointer + retain semantics.

## Sanitizer guidance

Xcode's simulator Thread Sanitizer and Address Sanitizer both pass for the
XCTest target. Run them with `-enableThreadSanitizer YES` or
`-enableAddressSanitizer YES` on the `xcodebuild test` invocation (see
`../ios-harness/README.md`).

TSan+ASan cannot be combined in the same run (clang rejects
`-sanitize=thread -sanitize=address`). Run them separately.

**On-device sanitizer coverage is out of scope for this PoC** (per ticket
0095's explicit allowance — TSan/ASan are simulator-gated for Swift UI
tests). If the production libsmithers-core picks up this FFI pattern, that
decision should be revisited for device coverage.

The Zig unit tests pass under `std.testing.allocator`, which is leak-checked.

## Files

```
poc/zig-swift-ffi/
├── build.zig           # Zig build; produces static lib + header
├── build.zig.zon
├── include/
│   └── ffi_poc.h       # C ABI (the contract)
└── src/
    └── ffi_poc.zig     # implementation + `zig build test` unit tests
```

## References

- `libsmithers/src/ffi.zig` — the production FFI style this PoC mirrors.
- `libsmithers/include/smithers.h` — header conventions.
- `.smithers/tickets/0095-poc-zig-swift-ffi.md` — ticket.
