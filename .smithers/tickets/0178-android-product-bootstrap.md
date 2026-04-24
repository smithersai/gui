# Android product bootstrap

## Status (audited 2026-04-24) -- NOT STARTED

- `android/` does not exist at the repository root.
- `poc/android-core/` exists and belongs to ticket 0104 as a Stage 0 build canary only.
- No Android product app, package name, Gradle wrapper, secure-store integration, release signing path, or product CI entry point exists.

## Context

The main iOS/remote-sandboxes spec intentionally keeps Android out of the current user-facing rollout. Android's only load-bearing role today is the `poc/android-core/` continuous canary: prove `libsmithers-core` can still compile for `aarch64-linux-android` and link through JNI.

If the product decision changes, the repository needs an Android bootstrap that starts from production runtime contracts rather than copying iOS/macOS UI surfaces. This ticket defines that first product scaffold.

## Problem

There is no root Android app structure to productize:

- no `android/settings.gradle.kts`, app module, wrapper, or Android Studio project metadata;
- no production JNI/Kotlin bridge over `libsmithers/include/smithers.h`;
- no Android Keystore-backed credential provider for the runtime;
- no Android SQLite/cache ownership policy;
- no launch, instrumentation, or CI script for a product app;
- no release-signing, crash-reporting, or Play distribution decisions.

The existing PoC should remain a canary. Growing it into a product app would mix Stage 0 proof code with shipping app concerns and weaken the canary's purpose.

## Goal

Create a minimal root `android/` product scaffold that can launch a native Android Smithers shell backed by the production `libsmithers-core` ABI, while keeping the existing `poc/android-core/` canary intact.

The first milestone is not a public Android release. It is a product-grade bootstrap that answers: build shape, runtime bridge, auth storage, app lifecycle, tests, and CI.

## Scope

- Create `android/` as a standalone Gradle project:
  - `android/settings.gradle.kts`
  - `android/build.gradle.kts`
  - `android/app/build.gradle.kts`
  - Gradle wrapper pinned to the same reviewed Gradle/JDK line as the canary unless Android product needs a newer AGP.
- Add app identity and package naming:
  - package: `com.smithers.app` unless product/legal chooses another name;
  - debug-only launcher label: `Smithers`;
  - no release signing in the first patch beyond documented placeholders.
- Add a production runtime bridge:
  - JNI/Kotlin bindings generated or manually mapped from `libsmithers/include/smithers.h`;
  - no dependency on `poc/zig-swift-ffi/`;
  - Android ABI slices at least `arm64-v8a`, with `x86_64` added for emulator coverage if Zig/NDK linking is stable.
- Add credential storage:
  - Android Keystore-backed refresh-token storage;
  - in-memory access-token handling;
  - runtime credential-provider callbacks matching the production `libsmithers-core` contract.
- Add first app shell:
  - native Android entry point with sign-in/bootstrap state;
  - remote-disabled state when the server flag is off;
  - workspace list placeholder wired only after production routes and shapes are available;
  - no iOS surface porting or one-for-one view translation.
- Add local data ownership:
  - app-owned files directory for bounded SQLite/cache artifacts;
  - sign-out wipe that clears Keystore entries, runtime sessions, cache files, and in-memory state.
- Add test and script coverage:
  - `android/scripts/run-canary.sh` for build + launch smoke;
  - JVM tests for bridge argument validation where possible;
  - instrumentation test that launches the shell and verifies the disabled/bootstrap state without requiring production plue.
- Add CI:
  - Android product build job runs separately from `poc/android-core`;
  - build failures block PRs only after the scaffold reaches a stable milestone;
  - emulator/instrumentation job can start as scheduled or manual if CI cost is too high.

## Out of scope

- Shipping a public Android app.
- Porting iOS/macOS SwiftUI surfaces.
- Replacing or deleting `poc/android-core/`.
- Adding or changing plue routes.
- Android terminal rendering with libghostty.
- Play Store release automation.

## Implementation plan

1. **Bootstrap project layout**
   - Create root `android/` Gradle project and app module.
   - Pin AGP, Kotlin, Gradle, JDK, `compileSdk`, `minSdk`, and NDK versions in one documented place.
   - Add a debug launcher activity that renders only bootstrap/disabled state.

2. **Wire native build**
   - Add Gradle tasks that build `libsmithers-core` for Android through Zig + NDK.
   - Stage produced `.so` files into AGP `jniLibs`.
   - Keep the PoC canary import path unchanged.

3. **Define JNI boundary**
   - Map only the production runtime session lifecycle first: create session, close session, subscribe to state/errors, and sign-out cleanup.
   - Document ownership for every pointer/handle crossing JNI.
   - Add Kotlin wrappers that fail closed on null/zero native handles.

4. **Add secure credentials**
   - Implement Android Keystore refresh-token storage.
   - Inject bearer/refresh callbacks into the runtime.
   - Add sign-out and auth-expired wipe tests.

5. **Add product launch smoke**
   - Add instrumentation test that launches the app in remote-disabled mode.
   - Extend the test to a fake-auth bootstrap once a local test plue harness is available.
   - Provide `android/scripts/run-canary.sh` as the one-command local smoke entry.

6. **Add CI guardrails**
   - Build the Android product app on PRs after the native bridge compiles reliably.
   - Keep `poc/android-core` CI as the architecture canary.
   - Track APK size and native `.so` size separately from the PoC.

## Acceptance criteria

- `android/` exists and opens in Android Studio without referencing PoC-only source.
- `android/scripts/run-canary.sh` builds the debug app and runs the launch smoke on an attached emulator/device.
- The Android app links the production `libsmithers-core` ABI, not the PoC FFI counter.
- Sign-out wipes Android Keystore credentials and local runtime/cache state.
- CI has separate jobs for `poc/android-core` canary and root `android/` product scaffold.
- Documentation states Android is still not in a public rollout phase until the rollout plan is updated.

## Risks / unknowns

- JNI ownership mistakes can crash the process; keep the first bridge narrow and heavily tested.
- Android Keystore behavior varies across API levels; choose the supported API matrix before release work.
- Emulator runtime coverage may require `x86_64-linux-android`, while the current PoC focuses on `aarch64-linux-android`.
- Terminal rendering is intentionally deferred; a product Android app without terminal support may only be useful for workspace/run inspection until a renderer ticket lands.
