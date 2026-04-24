# PoC: Android core canary

## Status (audited 2026-04-24) — PARTIAL

- Done: `poc/android-core/` exists with `build.gradle.kts` and Zig build integration.
- Remaining: CI wiring skeletal; Gradle/Kotlin test harness and emulator coverage not verified.

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-C1, promoted to Stage 0. The main spec commits to an Android **continuous build canary** — no user-facing Android release in this pass, but `libsmithers-core` must compile for `aarch64-linux-android` and link into a minimal Kotlin test app on every PR. This canary exists so architectural decisions don't foreclose a future Android release. If we wait until Stage 2 to stand it up, any Stage 0 or Stage 1 choice that accidentally foreclosed Android won't surface until after it's been baked into code.

## Problem

`libsmithers-core` (Zig) is supposed to target `aarch64-linux-android` and link into Kotlin via JNI. No one has proven this for the current `libsmithers/src/` tree, nor for the future core after the split. Every subsequent ticket could make choices that break Android silently; we need a canary that fails loudly instead.

## Goal

A minimal Android app that links `libsmithers-core` (or, for Stage 0, its current libsmithers-equivalent) via JNI and runs the same FFI smoke test as PoC-A4 (Zig ↔ Swift FFI). The CI pipeline gains an Android build job that runs on every PR; breakage blocks the PR.

## Scope

- **In scope**
  - `poc/android-core/` — new Gradle project, Kotlin-based minimal UI.
  - Zig build target for `aarch64-linux-android` via the Android NDK (Zig natively supports this; no cgo involved).
  - JNI binding for a minimal FFI surface equivalent to PoC-A4's counter (`ffi_new_session`, `ffi_subscribe`, `ffi_tick`, `ffi_close_session`).
  - Kotlin app on an emulator that exercises the counter via JNI and displays updates.
  - CI job: build Android target on every PR to gui main. Failing build blocks the PR. No runtime-on-device test required in CI.
  - Size measurement: emitted `.so` size recorded in README.
- **Out of scope**
  - Full Android app UI — one button + one counter display is enough.
  - Android-specific observability, networking, or persistence — those come when Android actually ships, not now.
  - Physical-device testing — emulator is sufficient.
  - libghostty on Android — separate concern, not this PoC.

## References

- PoC-A4 (ticket 0095) — the FFI pattern being mirrored.
- Zig docs: cross-compilation to `aarch64-linux-android`.
- Android NDK JNI reference.

## Acceptance criteria

- `poc/android-core/` builds via `./gradlew assembleDebug`.
- Android emulator test: press button, counter ticks, all `ffi_tick` calls reflected in UI.
- CI configuration (`.github/workflows/` or equivalent) adds an Android build step to the existing PR pipeline. Breaking a symbol `libsmithers-core` exports (or adding platform-specific code that doesn't cross-compile) fails CI.
- README documents: NDK version pinned, Zig target triple, JNI binding shape, how future tickets add new FFI calls without breaking Android.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the CI job actually runs on every PR (not a separate workflow that can be ignored) and the emulator test is genuine (not a build-only test mislabeled).

## Risks / unknowns

- Zig + Android NDK linker flags may need tuning across Zig versions; lock the Zig version in `.zig-version` if not already locked.
- SwiftUI patterns (from 0095) don't translate to Jetpack Compose one-for-one; the callback threading model must be re-validated for the Android event loop.
- CI minutes — Android builds are slow; consider whether the build-only job is cached aggressively.
