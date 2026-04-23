# libghostty-ios PoC (ticket 0092)

Minimal SwiftUI iOS app that embeds **libghostty-vt** (the terminal-only slice
of the Ghostty terminal emulator) and feeds it a canned PTY byte stream,
asserting correctness via a cell-buffer XCTest. De-risks the core claim of
the iOS + remote sandboxes spec: "libghostty renders correctly on iOS".

## Results (this PoC)

- [x] iPhone 17 simulator (iOS 26.3.1): **all 4 XCTest cases pass** in ~0.01s.
- [x] Device slice (`generic/platform=iOS`, arm64, iOS 17+): **build succeeds**.
- [x] Cell-buffer asserted as plain-text via `ghostty_formatter_format_alloc`
      — no Metal/CoreGraphics pixel hashing.
- [x] Fixture is checked-in readable text (`Tests/PoCTests/Fixtures/ls-la.vt`)
      with `\e`-escape decoding handled by the Swift loader.

## Layout

```
poc/libghostty-ios/
├── project.yml                  # xcodegen spec (regenerates project.pbxproj)
├── scripts/
│   └── build-xcframework.sh     # runs `zig build` in ../../ghostty
├── Sources/
│   ├── LibGhosttyWrapper/       # Swift framework
│   │   ├── Terminal.swift       #   GhosttyVT class (pure render API)
│   │   └── FixtureLoader.swift  #   .vt fixture → []UInt8 decoder
│   └── PoC/                     # SwiftUI demo app
│       ├── PoCApp.swift
│       └── Info.plist
└── Tests/PoCTests/
    ├── CellBufferTests.swift    # 4 XCTest cases
    └── Fixtures/
        ├── ls-la.vt             # readable VT byte recording
        └── ls-la.expected.txt   # golden cell-buffer state
```

## One-time setup

1. **Toolchain:**
   - Xcode 15+ with iOS 17+ SDK (this PoC verified against Xcode 26.3 + iOS
     SDK 26.2).
   - `zig` 0.15.2 (matches `ghostty/build.zig.zon`'s `minimum_zig_version`).
     If your `zig version` prints anything else:
     ```
     zvm install 0.15.2
     zvm use 0.15.2
     ```
   - `xcodegen` (`brew install xcodegen`).
2. **Git submodules:** `git submodule update --init --recursive ghostty`.

## Build the XCFramework

```
./scripts/build-xcframework.sh
```

`zig build` produces two xcframeworks; the PoC uses the second:

1. `ghostty/macos/GhosttyKit.xcframework` — the apprt (application-runtime) API.
   Includes `ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64` slices.
   **NOT used by this PoC** — its umbrella header deliberately omits the VT
   API; the VT `@export fn`s in `ghostty/src/lib_vt.zig` only activate when
   that file is the root module.

2. `ghostty/zig-out/lib/ghostty-vt.xcframework` — the render-only libghostty-vt
   API (`ghostty_terminal_new`, `ghostty_formatter_*`, etc.). Same three slices.
   **This is what the PoC links.** Its umbrella header is `ghostty/vt.h` and
   its Clang module is named `GhosttyVt`.

Wall time: ~90 s on an M-series Mac (first build; subsequent builds cache).

## Generate + build Xcode project

```
xcodegen generate
```

### Run the tests on iPhone simulator

```
# iPhone 17 / iOS 26.3.1 is what this PoC is verified against.
# Any iOS 17+ simulator should work.
xcodebuild \
    -project LibGhosttyIOS.xcodeproj \
    -scheme PoC \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' \
    -configuration Debug \
    test
```

Expected: `Test Suite 'All tests' passed`. Four test cases:
- `testWriteHelloProducesExpectedCells` — smoke test, cursor advancement.
- `testSGRDoesNotAppearInPlainText` — escape sequences stripped.
- `testLsLaFixtureMatchesGolden` — full fixture → cell-buffer matches golden.
- `testReplayDeterminism` — two independent replays produce identical state.

### Build for iOS device (aarch64)

```
xcodebuild \
    -project LibGhosttyIOS.xcodeproj \
    -scheme PoC \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
```

Expected: `** BUILD SUCCEEDED **`. Product at
`~/Library/Developer/Xcode/DerivedData/LibGhosttyIOS-*/Build/Products/Debug-iphoneos/PoC.app/PoC`
verifiable with `lipo -info` → `arm64`, `otool -l` → platform 2 (iOS), minos 17.0.

### Run on a physical device (user hand-off)

I don't have an iOS device; this PoC's acceptance bar is device-build-only.
To run on your plugged-in device:

```
# List attached devices:
xcrun devicectl list devices

# Build signed (substitute YOUR TEAMID):
xcodebuild \
    -project LibGhosttyIOS.xcodeproj \
    -scheme PoC \
    -destination 'id=<YOUR-DEVICE-UDID>' \
    -configuration Debug \
    DEVELOPMENT_TEAM=<YOUR-TEAMID> \
    build

# Install + run:
xcrun devicectl device install app --device <YOUR-DEVICE-UDID> \
    ~/Library/Developer/Xcode/DerivedData/LibGhosttyIOS-*/Build/Products/Debug-iphoneos/PoC.app

xcrun devicectl device process launch --device <YOUR-DEVICE-UDID> \
    com.smithers.libghostty-ios-poc.app
```

Alternatively: open `LibGhosttyIOS.xcodeproj` in Xcode, pick your device as
the run destination, press Cmd-R.

## Fixture format

`Tests/PoCTests/Fixtures/ls-la.vt` is readable text. The loader
(`FixtureLoader.swift`) strips `#`-comment and blank lines, then decodes
`\e` → `0x1B`, `\r` → `0x0D`, `\n` → `0x0A`, `\\` → `0x5C`; all other
characters are UTF-8 literal. This lets us diff fixtures as text in git
while still producing a deterministic byte stream.

`Tests/PoCTests/Fixtures/ls-la.expected.txt` is the expected cell-buffer
projection (plain-text, per the formatter's `PLAIN` emit mode with trim).
The test compares whitespace-trimmed strings.

## Cell-buffer assertion vs pixel hashing

This PoC deliberately **does not** hash Metal or CoreGraphics pixel output
of the terminal. Pixel hashes flake across:

- Simulator vs device builds (different Metal drivers).
- Font availability (system font fallbacks).
- SubpixelAA settings / Retina scale.
- macOS vs iOS rendering paths.

Instead we assert the **terminal's cell buffer**: rows of codepoints + styles
as the VT state machine sees them, projected to plain text via the
`ghostty_formatter_*` C API. This is deterministic across platforms and
font stacks, and is the right level of abstraction for validating that
libghostty's terminal emulation works on iOS.

## Known quirks + gotchas

1. **`GhosttyKit.xcframework` does NOT expose VT symbols.** The apprt
   xcframework includes `ghostty_app_*`, `ghostty_surface_*`, etc., but the
   VT C API is only compiled in when `src/lib_vt.zig` is the root module —
   which happens in a separate build product, `ghostty-vt.xcframework`.
   The PoC links the latter.
2. **`libghostty-vt.a` requires `-force_load` when linking into a dynamic
   framework** — else the C symbols dead-strip away because the Swift
   wrapper's references only appear at runtime through dlsym-style resolution
   in the Clang module. Our `OTHER_LDFLAGS` handles this.
3. **`libghostty-vt` pulls in C++ (`utfcpp`).** We link `-lc++` in the
   wrapper framework.
4. **Shell env pollution on the host.** If your shell exports `SDKROOT` or
   `LIBRARY_PATH` pointing at `/Library/Developer/CommandLineTools/...`
   (common in Rust-heavy dev boxes), `xcodebuild` will prefer the macOS
   SDK's libobjc.A.tbd and fail with:

   ```
   ld: building for 'iOS-simulator', but linking in dylib
       (.../libobjc.A.tbd) built for 'macOS ...'
   ```

   Work around by invoking `xcodebuild` with `env -u SDKROOT -u LIBRARY_PATH
   -u RUSTFLAGS xcodebuild ...` (as the test command line in this README
   does not do by default — prefer starting from a clean shell).
5. **Iphone 15 simulator may not be provisioned** on newer Xcodes. Any
   iOS 17+ simulator runtime works; `xcrun simctl list devices available`
   shows what's on hand.

## What this PoC DOES NOT prove

- Metal renderer on iOS (out of scope; ticket 0092 is explicitly VT-only).
- Network / WebSocket PTY streaming (covered by ticket 0094).
- Swift ↔ Zig FFI beyond the minimal wrapper (covered by tickets 0095, 0103).
- Input handling, copy/paste, accessibility (covered by ticket 0113).
- On-device run (intentionally handed off to the user per ticket scope).
