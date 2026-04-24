# Client: macOS+iOS target and build-system split

## Status (audited 2026-04-24) — PARTIAL

- Done: iOS target added to CI matrix; Package.swift declares `iOS(.v17)` alongside `macOS(.v14)`; project.yml references iOS; shared sources wired.
- Remaining: Verify macOS-only binaries are fully excluded from iOS target; confirm iOS archive builds cleanly in CI.

## Context

The repo is still macOS-only at the build layer. `Package.swift:4-95` declares `.macOS(.v14)` as the only platform, links `AppKit`, and only defines the existing executable plus macOS tests. `project.yml:1-192` defines a single macOS app target, macOS unit tests, macOS UI tests, and bundles macOS-only resources such as `libsmithers/zig-out/bin/smithers-session-daemon` and `libsmithers/zig-out/bin/smithers-session-connect`.

The main spec commits to one SwiftUI codebase running on both macOS and iOS. We cannot even start that product work cleanly until the project has real iOS targets and CI coverage.

## Problem

Without a build-system ticket, iOS support gets entangled with runtime, navigation, terminal, and release work. That would make every downstream change harder to land and harder to validate.

## Goal

Add the iOS target/build scaffolding for the gui repo: `Package.swift` and `project.yml` support both platforms, shared sources are compiled into both app targets, platform-specific files stay isolated, and CI builds the macOS and iOS app/test matrix.

## Scope

- **In scope**
  - Update `Package.swift` so iOS is a first-class platform alongside macOS, and platform-specific frameworks/linker flags are no longer hard-coded as macOS-only for all targets.
  - Update `project.yml` so XcodeGen produces:
    - the existing macOS app target,
    - a new iOS app target,
    - iOS unit/UI test targets parallel to the current macOS test bundles,
    - shared source membership for cross-platform SwiftUI files,
    - macOS-only membership for `macos/Sources/Smithers/` and any remaining AppKit-only surfaces.
  - Keep `macos/Sources/Smithers/` as the macOS support layer and introduce the parallel iOS target membership needed for app entry, OAuth callback wiring, and platform adapters without duplicating the shared SwiftUI code.
  - Build/link `libsmithers-core` and libghostty for both macOS and iOS consumption, including simulator and device-compatible artifact handling at the project level.
  - Move macOS-only bundled helper binaries out of the shared target path. `smithers-session-daemon` and `smithers-session-connect` should not be unconditional resources of the iOS app target.
  - Add CI coverage so both targets are built on every change:
    - macOS app + tests,
    - iOS simulator app + tests,
    - any required XcodeGen/project-generation step.
  - Keep downstream validation unblocked: this ticket should leave the tree ready for `0122`-`0124`, not try to solve those tickets.
- **Out of scope**
  - Refactoring `ContentView.swift` into shared navigation/state.
  - Terminal renderer portability and remote runtime wiring.
  - Code signing, provisioning, or TestFlight upload in `0125`.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `Package.swift:4-95`
- `project.yml:1-192`
- `project.yml:121-147`
- `macos/Sources/Smithers/`
- `Tests/SmithersGUITests`
- `Tests/SmithersGUIUITests`

## Acceptance criteria

- `Package.swift` declares both macOS and iOS support.
- `project.yml` generates separate macOS and iOS app/test targets with shared source membership and platform-specific exclusions.
- The iOS target builds for simulator; the project structure also supports device builds once signing is added.
- macOS-only helper binaries and frameworks are no longer blindly included in the iOS build graph.
- CI runs the macOS and iOS build/test matrix on every change in this slice.
- The resulting project structure is clean enough that `0122`, `0123`, and `0124` can land without reworking target membership again.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies that iOS compilation is real rather than conditionally skipped, shared files are not accidentally duplicated per target, and the iOS target does not link AppKit-only resources from `project.yml:121-147`.

## Risks / unknowns

- The exact packaging shape for libghostty and `libsmithers-core` across device and simulator may force project-structure changes once `0123` lands.
- If target membership is sloppy, shared files will accumulate `#if os(macOS)` clutter instead of using clean platform partitions.
- There is no existing iOS CI path in this repo today, so the automation surface has to be created rather than tweaked.
