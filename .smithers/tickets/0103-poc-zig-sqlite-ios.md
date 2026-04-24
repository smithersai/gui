# PoC: Zig + SQLite on iOS

## Status (audited 2026-04-24) — PARTIAL

- Done: `poc/zig-sqlite-ios/` exists with `build.zig` and `src/`; Xcode project scaffolding in place.
- Remaining: on-device XCTest runtime validation unconfirmed; real-device performance/crash data not yet captured.

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-A6, added to Stage 0 based on the Codex review of the initial ticket set. The spec commits to a bounded SQLite cache inside `libsmithers-core` as the storage primitive for all Electric-synced state. That SQLite integration has never been proven on iOS from Zig, and it's central to client architecture — if it doesn't work, the entire Section 4 changes shape.

## Problem

The current `libsmithers/src/persistence/sqlite.zig` uses externs to the system SQLite3 library (on desktop macOS + Linux). iOS ships a system SQLite too, but building a Zig static lib that links against it and runs on both iOS simulator and iOS device is not a given — it depends on the Zig SDK, framework-path discovery, iOS SDK linker quirks, and sandboxed-app filesystem rules.

## Goal

Prove that the existing Zig SQLite wrapper (or a minimal adaptation of it) builds, links, and **runs** correctly on both iOS simulator and iOS device, using the system `libsqlite3` — no vendored SQLite, no cgo, no workarounds. XCTest confirms basic open/write/read/close end-to-end on both destinations. Device-runtime coverage is load-bearing for this PoC because the whole point is de-risking client-side storage on real Apple hardware, where file-path, sandbox, and linker behavior differ from simulator.

## Scope

- **In scope**
  - `poc/zig-sqlite-ios/` — a minimal Zig library adapting `libsmithers/src/persistence/sqlite.zig`'s extern approach for iOS.
  - Xcode project (can live in the same directory) with a SwiftUI target that links the Zig static lib.
  - Build products for both `aarch64-ios-simulator` (simulator) and `aarch64-ios` (device).
  - XCTest: open a SQLite file in the app's Documents directory, create a table, insert N rows, query them back, close. Assert round-trip integrity. **Test must run on both simulator AND at least one real iOS device** (a single developer device smoke-run is sufficient; we're not building device-farm infrastructure). Running on device may be a developer-local step documented in the README rather than a CI job.
  - README explains how the system `libsqlite3` is discovered at link time, how the DB file path is resolved inside the iOS app sandbox, and how to reproduce the on-device smoke run.
  - Measured size overhead (extra binary bytes added by linking `libsqlite3`) recorded in README.
- **Out of scope**
  - Electric shape delta storage — that's PoC-A2's problem; this PoC only proves SQLite works.
  - Encryption (e.g. SQLCipher) — out of scope; platform data protection handles this.
  - WAL-mode concurrency testing, crash-recovery testing — just open/write/read.
  - Linux/Android variants of the SQLite story — separate concerns.

## References

- `libsmithers/src/persistence/sqlite.zig` — existing extern-based wrapper.
- Apple docs: SQLite is system-provided on iOS via `libsqlite3.tbd`.
- Any existing PoC in `plue/poc/` that links against `libsqlite3` (none known; this PoC may be first).

## Acceptance criteria

- Zig lib builds for both `aarch64-ios-simulator` and `aarch64-ios`.
- Xcode target runs on iOS simulator; XCTest passes end-to-end.
- Xcode target runs on at least one real iOS device; XCTest passes end-to-end there too (developer-local smoke run is acceptable; must be reproducible from the README).
- README documents: link-time flag choices, library discovery, file path inside the app sandbox, size overhead, device-run repro steps, any gotchas found during the build or on-device run.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the test actually opens a real file (not `:memory:`) in the app's sandboxed Documents directory and that the Zig lib is the one linked (not an Objective-C SQLite wrapper replacing it).

## Risks / unknowns

- Zig's iOS SDK support requires the right `--sysroot` and framework-path flags; the PoC surfaces these.
- `libsqlite3` on iOS lives as a `.tbd` (text-based stub dylib) in the iOS SDK; Zig's linker needs to find and use it.
- App sandbox may have subtle differences for SQLite journal file creation; test must actually commit.
