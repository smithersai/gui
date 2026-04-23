# PoC: Zig ↔ Swift FFI for observable state

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-A4. Stage 0 foundation. This PoC validates the FFI pattern described in the Client Architecture section of the main spec: core owns an event loop, Swift subscribes via callbacks, updates marshal correctly to the main thread, and SwiftUI re-renders.

## Problem

The spec requires platform UI (SwiftUI today, later GTK + Kotlin) to observe state owned by `libsmithers-core` (Zig) via FFI. The pattern isn't exotic, but the exact threading + lifecycle + retain-count story needs to be proved out once so every subsequent piece of real code has a clean template. Getting this wrong later produces crashes in production.

## Goal

A minimal Zig library with one synthetic observable counter, a SwiftUI app that subscribes, and an XCTest that validates the full pipeline: Zig mutation → Swift callback → main-thread dispatch → SwiftUI re-render.

## Scope

- **In scope**
  - Zig library at `poc/zig-swift-ffi/` exposing: `ffi_new_session()`, `ffi_subscribe(session, callback_ptr, user_data)`, `ffi_unsubscribe(handle)`, `ffi_close_session(session)`, plus a synthetic `ffi_tick(session)` that mutates the counter.
  - Zig owns one background thread running an event loop; callbacks are invoked on that thread, then Swift marshals to main.
  - Minimal SwiftUI app with `@Observable` view model that calls the FFI, subscribes, and displays the counter.
  - XCTest: call `ffi_tick` N times from a background queue, assert the SwiftUI model observes N updates on main within a bounded time window.
  - Memory safety: runs cleanly under Xcode's Thread Sanitizer, Address Sanitizer, and leak checker.
- **Out of scope**
  - Any network or real state sync (separate PoCs).
  - libghostty integration (separate PoC).
  - Generic FFI code-gen tooling — the three functions above are hand-written.

## References

- `libsmithers/src/ffi.zig` — today's FFI, for shape/style consistency.
- Swift `@Observable` + `Combine` or Swift 6 `AsyncSequence` — pick one, document the choice.
- `libsmithers/include/smithers.h` — current C header pattern.

## Acceptance criteria

- Zig lib builds for macOS, iOS simulator, and iOS device slices (device build-only; on-device run is not required for this PoC).
- SwiftUI app runs on simulator and the counter visibly ticks when the "tick" button is pressed.
- XCTest (simulator only is acceptable — TSan/ASan are simulator-gated for Swift UI tests): 1000 rapid ticks deliver 1000 ordered updates to the Swift observer, no drops, no reorders. Under TSan/ASan on simulator, no warnings.
- README covers the threading model in prose: where each callback runs, how Swift guarantees main-thread delivery, what lifecycles apply to the session handle and callback handle.
- README explicitly flags that on-device sanitizer coverage is out of scope for this PoC.
- The FFI surface is documented in comments that future real-FFI code can copy.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer verifies the sanitizers actually run (not silently skipped), lifecycle is tested (session closed before subscribers unsubscribe — must not crash), and callback invocation from Zig's event loop is genuine (not faked by Swift invoking itself).

## Risks / unknowns

- SwiftUI `@Observable` interaction with callbacks originating on non-main threads — make the main-thread dispatch explicit; don't rely on SwiftUI's internal queue behavior.
- Memory ownership for `user_data` context pointers — decide once, document.
