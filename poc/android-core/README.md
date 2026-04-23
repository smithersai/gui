# PoC: Android core canary (ticket 0104)

`libsmithers-core` (Zig) must compile for `aarch64-linux-android` and link
into a Kotlin app via JNI on every PR. This PoC is the continuous build
canary that enforces it — no user-facing Android release is being built
here.

Mirror of the [0095 Zig ↔ Swift FFI](../zig-swift-ffi/) counter, exposed
as JNI methods instead of Swift `@_silgen_name` bindings.

## Why this exists

If we wait until Stage 2 to prove Android compiles, any choice we make
in Stage 0 or Stage 1 that accidentally forecloses Android (platform-
specific code, an iOS-only symbol, a Foundation dependency leaking into
the core) won't surface until after it's baked in. This PoC's CI job
fails loudly the moment that happens.

The canary's contract:

- `poc/android-core/src/jni_bindings.zig` `@import`s
  `poc/zig-swift-ffi/src/ffi_poc.zig` **directly and unmodified**.
- Any symbol rename, type change, or signature change in that file that
  isn't mirrored in the JNI layer breaks the Zig build.
- Any platform-specific code sneaking into the core (non-portable libc,
  Darwin-only syscalls, etc.) breaks the `aarch64-linux-android` Zig
  cross-compile.
- CI runs `zig build --release=small` and `gradle assembleDebug` on
  every PR and blocks the PR on failure.

Do **not** fork `poc/zig-swift-ffi/src/ffi_poc.zig` into this directory.
Forking defeats the canary.

## Pinned tool versions

| Tool | Version | Where pinned |
|------|---------|--------------|
| Zig | `0.15.2` | `build.zig` (`required_zig` comptime check) |
| Android NDK | `26.3.11579264` (r26d) | `.github/workflows/ci.yml` (`ANDROID_NDK_VERSION`) |
| `minSdkVersion` | `29` | `app/build.gradle.kts` + `build.zig` (`android_api`) |
| `compileSdkVersion` | `34` | `app/build.gradle.kts` |
| Android Gradle Plugin | `8.4.0` | root `build.gradle.kts` |
| Kotlin | `1.9.23` | root `build.gradle.kts` |
| Gradle | `8.7` | `gradle/wrapper/gradle-wrapper.properties` |
| JDK | `17` | CI + `compileOptions` |

Bumping the NDK or `minSdk` is a real review event — it can shift which
Bionic libc symbols the Zig core links against.

## Target triple

`aarch64-linux-android` — 64-bit ARM only. 32-bit Android (`armv7`) and
x86_64 emulators are intentionally out of scope for this canary:

- Play Store rejects new 32-bit-only APKs, so armv7 is never on the
  Stage 2 release path.
- `x86_64-linux-android` would be useful for emulator runs on x86 CI
  hosts, but the ticket explicitly accepts build-only CI. Adding it is
  cheap when we actually want emulator runs (see "Running locally").

## JNI binding shape

Kotlin side — `CoreBridge.kt`:

```kotlin
object CoreBridge {
    init { System.loadLibrary("smithers_core") }
    external fun nativeNewSession(): Long
    external fun nativeCloseSession(session: Long)
    external fun nativeTick(session: Long): Long
    external fun nativeSubscribe(session: Long): Long
    external fun nativeLatestCounter(observer: Long): Long
    external fun nativeUnsubscribe(session: Long, observer: Long)
}
```

Zig side — `src/jni_bindings.zig` emits matching `Java_com_smithers_androidcore_CoreBridge_<method>`
exports. JVM resolves them by name on first call; no `RegisterNatives`.

All handles (`session`, `observer`) are 64-bit pointers packed into
`jlong`. Kotlin treats them as opaque.

### Threading model

- Zig spawns one Bionic pthread per session ("event-loop thread").
- `nativeTick`, `nativeSubscribe`, `nativeUnsubscribe`,
  `nativeLatestCounter` are safe from any thread.
- The subscribe path on Android does NOT call back into the JVM. It
  installs a pure-C observer that atomically stores the latest counter
  value in the session's observer struct. Kotlin polls
  `nativeLatestCounter()` from the UI handler at ~60 Hz.
- This deliberately sidesteps JNI thread attachment (`AttachCurrentThread`)
  on the Zig side. When the production Android app needs JVM-bound
  callbacks (logging, async completion), that work lands in a separate
  ticket and can reuse the same `ffi_subscribe` shape — the core's
  contract doesn't change.

### Adding a new FFI call without breaking Android

When you add `ffi_foo` to `poc/zig-swift-ffi/src/ffi_poc.zig`:

1. Add a `Java_com_smithers_androidcore_CoreBridge_nativeFoo` export to
   `poc/android-core/src/jni_bindings.zig`.
2. Add a matching `external fun nativeFoo(...)` to `CoreBridge.kt`.
3. CI will refuse to merge if either side is missing — the Zig build
   fails if `jni_bindings.zig` references a removed symbol; the Android
   runtime smoke test (once we add one) fails if the JNI side misses a
   name. Today the build-only gate catches the former case.

Do NOT:

- Add Android-specific code paths to `ffi_poc.zig`. If a feature
  genuinely can't be portable, isolate it behind a `std.builtin.os.tag`
  switch in a separate file and teach both the iOS Swift bridge and
  this Kotlin bridge to probe feature flags.
- Fork `ffi_poc.zig` into this directory. The import path is the
  canary.

## Size

Measured after `zig build --release=small`:

```
$ ls -l zig-out/lib/libsmithers_core.*
```

- **Static archive** (no NDK): `~13 KB` (`libsmithers_core.a`).
  What you see when building without `ANDROID_NDK_ROOT` set — proves
  the source cross-compiles; final linking needs the NDK.
- **Shared library** (with NDK): recorded in CI's step summary on every
  run. Expected shape: tens of KB for ReleaseSmall; hundreds in Debug.
  If it balloons past ~500 KB without a clear reason, investigate
  before merging.

## Running locally

### Prerequisites

- Zig 0.15.2 (see `.zig-version` at repo root).
- Android SDK. On macOS install via Android Studio or
  `brew install --cask android-commandlinetools`.
- Android NDK r26d (`26.3.11579264`). Install with:
  ```
  sdkmanager "ndk;26.3.11579264"
  ```
  Then either export `ANDROID_NDK_ROOT` or let Gradle's
  `android.ndkDirectory` resolve it.
- JDK 17.
- Gradle 8.7 (or use the wrapper once `gradle wrapper` has populated
  `gradlew` — see below).

### Build the native library only

```
cd poc/android-core
zig build --release=small
ls -l zig-out/lib/libsmithers_core.so   # requires NDK
```

Without the NDK: the build still succeeds but emits
`libsmithers_core.a` only. That's enough to verify portability.

### Build the APK

```
cd poc/android-core
gradle wrapper      # once, to populate gradlew + wrapper jar
./gradlew assembleDebug
```

The `preBuild` task chain invokes `zig build --release=small` and
stages `libsmithers_core.so` into `app/build/generated/zig-jniLibs/arm64-v8a/`
before AGP packs the APK.

### Run on an emulator (optional)

```
sdkmanager "system-images;android-29;google_apis;arm64-v8a"
avdmanager create avd -n canary -k "system-images;android-29;google_apis;arm64-v8a"
emulator -avd canary -no-window -no-audio &
./gradlew installDebug
adb shell am start -n com.smithers.androidcore/.MainActivity
```

Press "Tick"; the counter label should advance. This is NOT part of
CI — it's a dev-local smoke test.

## CI

See `.github/workflows/ci.yml` job `android-core-canary`.

- Installs pinned NDK via `sdkmanager`.
- Runs `zig build --release=small` for the Android target (independent
  check; fast-fails before Gradle spin-up).
- Runs `gradle --no-daemon assembleDebug`.
- Uploads the produced APK as a diagnostic artifact.
- **Blocking**, not advisory: a failure prevents merge.

Emulator run on CI is deliberately absent (costly, flaky, and the
ticket says build-only is sufficient for the canary).

## Known gaps / future tickets

- No emulator smoke test in CI. When Stage 2 promotes Android to a
  real release target, add an `actions/android-emulator-runner` job
  that runs `CoreBridgeSmokeTest` on an API-29 arm64 image.
- No x86_64 slice. Add when CI hosts are x86 and emulator runs become
  cheap.
- No Kotlin-side unit test for the JNI contract yet. A JVM-only test
  that loads the .so and asserts counter-roundtrip semantics belongs
  in a follow-up ticket (depends on 0097's testing strategy).
- `nativeSubscribe` polls atomics instead of invoking a JVM callback.
  Production Android will want JVM-bound subscribers (for logs, Room
  observers, etc.) — that lands when Stage 2 picks up.
