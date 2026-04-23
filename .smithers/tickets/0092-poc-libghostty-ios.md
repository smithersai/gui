# PoC: libghostty on iOS — pipes-backend rendering

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-A1. Stage 0 foundation. This PoC de-risks the single most architecturally load-bearing claim in the iOS-and-remote-sandboxes spec: that we can reuse libghostty for terminal rendering on iOS the same way we do on desktop, so there is no platform divergence in how the client displays PTY output.

## Problem

The spec commits to `libsmithers-core` + libghostty shipping on iOS. That hinges on libghostty's pipes-backend actually building for `aarch64-ios` and rendering correctly inside a SwiftUI app. If this doesn't work, the whole "one codebase, two targets" plan breaks. We need to prove it before writing any production iOS code.

## Goal

A minimal iOS app that embeds libghostty via ghostty's existing XCFramework build path, feeds it a canned PTY byte stream, and renders the output. Confirmed working via XCTest against terminal cell-buffer state (not Metal pixel hashes, which flake across simulator/device/font stacks).

## Scope

- **In scope**
  - Use ghostty's existing `GhosttyXCFramework` build path (`ghostty/src/build/GhosttyXCFramework.zig`, invoked from `ghostty/build.zig:213`). The framework already targets iOS + iOS simulator; we add a build invocation, not a new target.
  - Minimal SwiftUI iOS app (`poc/libghostty-ios/`) with a single view hosting the renderer.
  - Harness that replays a canned PTY byte recording (a pre-captured `ls -la` session is sufficient).
  - XCTest that asserts the resulting **terminal cell-buffer state** (rows of glyphs + styles) matches expected after deterministic playback. Do NOT hash Metal/CoreGraphics pixel output.
  - Device-slice build coverage: build the Xcode target for an `aarch64-ios` destination and confirm it links. Running on-device is optional; the build passing is the acceptance bar.
- **Out of scope**
  - Any network or WebSocket code (separate PoC).
  - Any Swift ↔ Zig state-sync FFI beyond what's needed to push bytes in (separate PoC).
  - Accessibility, input handling, copy/paste — this is a render-only proof.
  - Metal renderer tuning beyond what ships in libghostty's pipes-backend default.

## References

- `/Users/williamcory/gui/ghostty/build.zig:213` — where the XCFramework target is built.
- `/Users/williamcory/gui/ghostty/src/build/GhosttyXCFramework.zig` — iOS/iOS-simulator slicing.
- `vivy-company/vvterm` — a working third-party libghostty-on-iOS consumer; study the Swift wrapper shape.

## Acceptance criteria

- `zig build` invocation produces the XCFramework including iOS + iOS-simulator slices (as ghostty already does).
- The Xcode project in `poc/libghostty-ios/` builds and runs on iPhone simulator.
- Same Xcode project builds for `aarch64-ios` device (build-only; on-device run not required).
- XCTest: feeding the canned byte recording produces a cell-buffer state matching a committed fixture. Fixture format is documented.
- README explains how to rebuild the XCFramework, open the Xcode project, and run the test on both destinations.
- No vendored copy of libghostty — build against the existing ghostty submodule.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer should verify the Zig build actually produces `aarch64-ios` (not just macOS), the Xcode target's linked library is that artifact (not a stub), and the golden hash test is deterministic (not flaky).

## Risks / unknowns

- Zig version mismatch with ghostty's current `build.zig.zon` pin.
- libghostty's pipes-backend may have undocumented lifecycle requirements; study vvterm first.
- Simulator vs. device slice — make sure both are proven, not just simulator.
