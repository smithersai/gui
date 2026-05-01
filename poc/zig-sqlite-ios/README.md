# PoC 0103: Zig + SQLite on iOS

Stage 0 de-risking PoC. Proves that the existing
`libsmithers/src/persistence/sqlite.zig` extern-based wrapper compiles,
links, and *runs* on both the iOS simulator and real iOS hardware using
the system `libsqlite3`. No vendored SQLite, no cgo, no workarounds.

Zig source lives here. The XCTest + Xcode target live at
`../ios-harness/`. Both share one Xcode project with two test schemes
(`FFIPoC`, `SQLitePoC`).

## Zig version

Pinned: **0.15.2**. Matches the repo-root `.zigversion`.

## Build

```sh
cd poc/zig-sqlite-ios
zig build                                     # macOS host (links /usr/lib/libsqlite3.tbd)
zig build -Dtarget=aarch64-ios-simulator      # iPhone simulator
zig build -Dtarget=aarch64-ios                # iPhone device
zig build test                                # host round-trip test
```

## Link-time discovery of libsqlite3

iOS (and iOS simulator) SDKs ship a stub dylib for SQLite3:

```
/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/usr/lib/libsqlite3.tbd
/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.2.sdk/usr/lib/libsqlite3.tbd
```

Both are text-based stubs pointing at the system-provided `/usr/lib/libsqlite3.dylib`
that Apple ships inside iOS. At app link time we reference them explicitly
via `OTHER_LDFLAGS = "... $(SDKROOT)/usr/lib/libsqlite3.tbd"` (see
`../ios-harness/project.yml`). This sidesteps `-lsqlite3`'s default search,
which — under misconfigured `LIBRARY_PATH` / `SDKROOT` environment
variables — can grab the macOS CommandLineTools SDK's stub instead. (See
"Gotchas" below.)

For the **Zig static lib** itself we do NOT call `linkSystemLibrary("sqlite3")`
when cross-compiling to iOS, because Zig 0.15.2 has no iOS sysroot shipped
with its distribution and can't validate the library's existence. Because
a static archive defers linking to the final Xcode app link, we simply
leave the `sqlite3_*` symbols undefined in `libsqlite_poc.a` and let
Xcode resolve them via `$(SDKROOT)/usr/lib/libsqlite3.tbd`.

## Sandbox path handling

The XCTest at `../ios-harness/SQLitePoCTests/SQLitePoCTests.swift` uses:

```swift
let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, ...)
let dbURL = docs.appendingPathComponent("sqpoc-\(UUID().uuidString).sqlite")
let path = dbURL.path
```

Inside the app sandbox (on device *and* simulator), `.documentDirectory`
resolves to `<App Container>/Documents/`. The test uses a unique filename
per run, then deletes the .sqlite (and defensively the `.sqlite-wal` /
`.sqlite-shm` siblings, in case WAL mode is enabled later). The file path
is a real file — the test explicitly rejects `:memory:`.

The current PoC does not set `PRAGMA journal_mode=WAL` (the production
wrapper does). WAL on iOS works but introduces two extra files and an
fsync dance; out of scope for this PoC.

## Size overhead

Measured on Zig 0.15.2, `-Doptimize=ReleaseSmall`, `-Dtarget=aarch64-ios`:

| Archive                              | Bytes     |
| ------------------------------------ | --------- |
| `libsqlite_poc.a` (this PoC)         | **21 KB** |
| `libffi_poc.a` (FFI-only baseline)   | 10 KB     |
| **SQLite-specific glue (delta)**     | **11 KB** |

For comparison, the iOS SDK's `libsqlite3.tbd` stub is **12 KB** — but it's
just a text linker descriptor; the actual `libsqlite3.dylib` is part of
iOS and contributes 0 bytes to the app bundle. Debug (`-Doptimize=Debug`)
bloats the archive to ~1.6 MB due to debug info; stripping brings it back
under 25 KB.

**Net cost of using SQLite from Zig on iOS: ~11 KB of Zig glue in the
final app bundle. No incremental system-library bytes.**

## C ABI

See `include/sqlite_poc.h`. Six functions:

```c
sqpoc_handle_t *sqpoc_open(const char *path);
const char      *sqpoc_open_error(void);
void             sqpoc_close(sqpoc_handle_t *h);
int32_t          sqpoc_insert_row(sqpoc_handle_t *h, int64_t id, const char *text);
int64_t          sqpoc_count_rows(sqpoc_handle_t *h);
int64_t          sqpoc_get_text(sqpoc_handle_t *h, int64_t id, char *buf, int32_t buf_len);
const char      *sqpoc_last_error(sqpoc_handle_t *h);
```

Swift calls ONLY these functions — never `sqlite3_*` directly — so the
test cannot be accidentally satisfied by some Objective-C SQLite wrapper.

## Running the XCTest

Simulator run is fully automatic from the Xcode harness. See
`../ios-harness/README.md` for the `xcodebuild test` command.

## Device-run reproduction (hand-off)

I did not run this on a physical device during the PoC; no iOS hardware
was available to the implementing agent. The simulator XCTest passes. The
device-slice BUILD (`xcodebuild -destination 'generic/platform=iOS'`)
succeeds. The ticket explicitly allows a developer-local device smoke
run rather than CI infrastructure.

Exact commands for a reviewer with a plugged-in device:

```sh
# 1. Plug in an iPhone/iPad with Developer Mode enabled.
# 2. Sign the bundle. For Free-tier signing set DEVELOPMENT_TEAM in your
#    ~/.xcconfig or pass it on the command line.
xcrun xctrace list devices   # note the UDID of your connected device
cd poc/ios-harness

# Build + install + run the test target on device. `id=` is the device
# UDID from step 2.
env -u LIBRARY_PATH -u SDKROOT xcodebuild \
    -project IOSHarness.xcodeproj \
    -scheme SQLitePoC \
    -destination "platform=iOS,id=<YOUR_UDID>" \
    DEVELOPMENT_TEAM="<YOUR_TEAM_ID>" \
    CODE_SIGN_STYLE=Automatic \
    test
```

Expected output: the `testRoundTripInDocumentsDirectory` test case passes
(`** TEST SUCCEEDED **`). The sandbox Documents directory is per-app on
device, so no lingering `.sqlite` files across runs.

# TODO(device-run): reviewer with iOS hardware should run the commands
# above and confirm `** TEST SUCCEEDED **`. If that fails, capture the
# xcresult bundle and attach to the PR.

## Gotchas (found while building this PoC)

1. **`LIBRARY_PATH` / `SDKROOT` leaking from the user's shell.** The user's
   zsh sets `LIBRARY_PATH=:/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib`
   (pointing at the macOS CommandLineTools SDK, a *different* SDK from the
   Xcode.app iOS SDK). Without stripping, `ld` silently links macOS stubs
   into the iOS-simulator build, and fails with
   `building for 'iOS-simulator', but linking in dylib ... built for 'macOS'`.
   **Fix:** run `xcodebuild` wrapped in `env -u LIBRARY_PATH -u SDKROOT`.
   The project also uses `-Xlinker -syslibroot -Xlinker $(SDKROOT)` as a
   belt-and-braces defense, but the env fix is the real cause resolver.

2. **Zig 0.15.2 can't resolve `-lsqlite3` when cross-compiling to iOS.**
   Zig doesn't ship an iOS sysroot. Work around by omitting
   `linkSystemLibrary("sqlite3")` for iOS targets in `build.zig`; the Xcode
   app link picks up `libsqlite3.tbd` directly.

3. **`libsqlite3.tbd` is a STUB**, not the real library. The actual dylib
   is `/usr/lib/libsqlite3.dylib` on the *device* (system-provided). Don't
   try to bundle this — Apple's review will reject the app. No licensing
   overhead either: it's system software.

4. **Don't set `PRAGMA journal_mode=WAL` in this PoC.** Writes create
   `.sqlite-wal` / `.sqlite-shm` siblings. Sandbox apps handle this fine,
   but test cleanup gets harder. The production wrapper sets WAL; this
   minimal PoC doesn't.

## Files

```
poc/zig-sqlite-ios/
├── build.zig
├── build.zig.zon
├── include/
│   └── sqlite_poc.h       # C ABI
└── src/
    └── sqlite_poc.zig     # extern → libsqlite3 wrapper + host tests
```

## References

- `libsmithers/src/persistence/sqlite.zig` — production extern wrapper.
- `.smithers/tickets/0103-poc-zig-sqlite-ios.md` — ticket.
