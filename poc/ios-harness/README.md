# PoC iOS harness (FFI + SQLite)

Shared Xcode harness for PoCs 0095 (Zig↔Swift FFI) and 0103 (Zig + SQLite
on iOS). Two test schemes, one app target. The SwiftUI app shows the FFI
PoC's counter; the SQLite PoC is XCTest-only.

## Structure

```
poc/ios-harness/
├── IOSHarness/               # SwiftUI app (FFI PoC consumer)
│   ├── IOSHarnessApp.swift
│   └── Info.plist
├── FFIPoCTests/              # 0095 XCTest
│   └── FFIPoCTests.swift
├── SQLitePoCTests/           # 0103 XCTest
│   └── SQLitePoCTests.swift
├── Modules/                  # Swift module maps for the Zig C headers
│   ├── FFIPoC/{module.modulemap, ffi_poc.h (symlink)}
│   └── SQLitePoC/{module.modulemap, sqlite_poc.h (symlink)}
├── build_zig_libs.sh         # builds all Zig libs for all SDK slices
├── project.yml               # xcodegen spec
└── IOSHarness.xcodeproj      # generated
```

## Prereqs

- Xcode 26.3 (paired iOS SDK 26.2). Simulator from the same Xcode install.
- `xcodegen` (Homebrew: `brew install xcodegen`).
- Zig 0.15.2 on PATH.

## Regenerate project

```sh
cd poc/ios-harness
xcodegen generate
```

## Run simulator tests

Both schemes.

```sh
# IMPORTANT: strip LIBRARY_PATH and SDKROOT if your shell sets them to
# the CommandLineTools macOS SDK. Otherwise `ld` silently picks macOS
# stubs and complains "building for iOS-simulator but linking in dylib
# built for macOS". See poc/zig-sqlite-ios/README.md "Gotchas".
env -u LIBRARY_PATH -u SDKROOT -u RUSTFLAGS \
    xcodebuild \
    -project IOSHarness.xcodeproj \
    -scheme FFIPoC \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
    test

env -u LIBRARY_PATH -u SDKROOT -u RUSTFLAGS \
    xcodebuild \
    -project IOSHarness.xcodeproj \
    -scheme SQLitePoC \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
    test
```

### With sanitizers

TSan:

```sh
... -enableThreadSanitizer YES test
```

ASan:

```sh
... -enableAddressSanitizer YES test
```

Do **not** combine `-enableThreadSanitizer YES -enableAddressSanitizer YES`
— clang rejects `-sanitize=thread -sanitize=address` together.

## Build for iOS device (build-only)

```sh
env -u LIBRARY_PATH -u SDKROOT -u RUSTFLAGS \
    xcodebuild \
    -project IOSHarness.xcodeproj \
    -scheme FFIPoC \
    -destination 'generic/platform=iOS' \
    -sdk iphoneos \
    build

env -u LIBRARY_PATH -u SDKROOT -u RUSTFLAGS \
    xcodebuild \
    -project IOSHarness.xcodeproj \
    -scheme SQLitePoC \
    -destination 'generic/platform=iOS' \
    -sdk iphoneos \
    build
```

Both succeed without code signing (the project.yml sets `CODE_SIGNING_ALLOWED=NO`).
For an actual device install + on-device run, re-enable code signing and
supply `DEVELOPMENT_TEAM`. See `../zig-sqlite-ios/README.md` for the exact
device-run hand-off command.

## How the Zig libs get built

`build_zig_libs.sh` is invoked as a **pre-build script phase** on all three
targets. It builds:

- `.libs/iphonesimulator/libffi_poc.a`
- `.libs/iphonesimulator/libsqlite_poc.a`
- `.libs/iphoneos/libffi_poc.a`
- `.libs/iphoneos/libsqlite_poc.a`
- `.libs/macosx/libffi_poc.a`
- `.libs/macosx/libsqlite_poc.a`

`LIBRARY_SEARCH_PATHS = $(SRCROOT)/.libs/$(PLATFORM_NAME)` picks the right
slice automatically.

## Known limitations

- Free Xcode signing tier may need a personal Team selected in Xcode GUI
  once before `xcodebuild` device-run works.
- On-device sanitizer coverage is **out of scope** for this PoC (per ticket
  0095's explicit allowance). Simulator-gated sanitizer runs are the bar.
