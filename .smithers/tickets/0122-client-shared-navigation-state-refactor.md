# Client: shared navigation and state refactor

## Status (audited 2026-04-24) — PARTIAL

- Done: ContentView decomposed from 2450 → 1736 lines; `SharedNavigation.swift` and `DetailRouter.swift` extracted.
- Remaining: Platform-specific shell separation incomplete; ContentView still 1736 lines; AppKit cleanup ongoing.

## Context

`ContentView.swift` is 2450 lines and currently owns nearly every concern of the app shell. The same file constructs `SessionStore` and `SmithersClient` (`ContentView.swift:734-740`), owns dozens of navigation and palette state variables (`744-771`), contains the entire `detailContent` route switch (`826-1024`), renders the macOS `NavigationSplitView` shell (`1063-1225`), still performs AppKit-specific actions such as `NSOpenPanel`, `NSWorkspace.shared.open`, `NSApplication.shared.terminate`, and `NSPasteboard` operations (`1907-2166`), and even embeds `@main`, `SmithersRootView`, and `AppDelegate` at the bottom of the file (`2323-2431`).

The spec requires one SwiftUI codebase that composes differently on macOS and iOS: `NavigationSplitView` on macOS, `NavigationStack` on iOS. That is impossible to maintain cleanly while the current monolith stays in place.

## Problem

If the shared app shell is not refactored first, every iOS change will either duplicate `ContentView.swift` or add more `#if os(macOS)` branches into a file that already mixes navigation, state, platform entry points, and local-only affordances.

## Goal

Split the current `ContentView.swift` responsibilities into a platform-neutral navigation/state layer plus thin platform shells, so the same route model and shared views can back macOS and iOS without duplicating the feature surface.

## Scope

- **In scope**
  - Extract the route/state model currently embedded in `ContentView.swift:744-771` into a shared navigation/state owner that both platform shells can observe.
  - Extract the `detailContent` switch from `ContentView.swift:826-1024` into a dedicated shared detail router. The existing leaf views such as `DashboardView.swift`, `RunsView.swift`, `RunInspectView.swift`, `ApprovalsView.swift`, `WorkspacesView.swift`, and `WorkspaceContentView.swift` should remain the leaves; the ticket is about routing/composition, not rewriting every screen.
  - Extract the loading/bootstrap branch from `ContentView.swift:1027-1061` into a shared root-shell stage so both platforms can use the same “block until connected / first snapshot” behavior from the spec.
  - Split the current shell layout from `ContentView.swift:1063-1225` into:
    - a macOS container that keeps `NavigationSplitView`, toolbar items, `GUIControlSidebar`, and desktop-only affordances,
    - an iOS container that uses `NavigationStack`, iOS-appropriate toolbars/sheets, and no AppKit assumptions.
  - Move the app-entry types currently embedded in `ContentView.swift:2323-2431` out of that file. The macOS entry point belongs in `macos/Sources/Smithers/Smithers.App.swift`; the iOS app target gets its own entry point instead of sharing the macOS `AppDelegate`.
  - Move AppKit-only actions behind platform adapters or the existing macOS support layer:
    - `NSOpenPanel` and recent-workspace launch stay in `macos/Sources/Smithers/Smithers.Workspace.swift`,
    - macOS window relocation stays in the macOS app delegate,
    - file-open, clipboard, and terminate-app actions are not left in shared shell code.
  - Preserve destination parity. The same `NavDestination` model in `SidebarView.swift` remains the cross-platform route vocabulary even if specific UI affordances differ by platform.
- **Out of scope**
  - Replacing the terminal renderer itself; that is `0123`.
  - Rewiring data sources from local/CLI calls to production shapes and remote writes; that is `0124`.
  - Build-target setup and TestFlight plumbing.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `ContentView.swift:734-1225`
- `ContentView.swift:1907-2166`
- `ContentView.swift:2323-2431`
- `SidebarView.swift`
- `WelcomeView.swift`
- `WorkspacesView.swift`
- `macos/Sources/Smithers/Smithers.App.swift`
- `macos/Sources/Smithers/Smithers.Workspace.swift:37-170`

## Acceptance criteria

- `ContentView.swift` no longer owns app entry, app delegate, route switch, bootstrap state, and platform shell layout all in one file.
- A shared navigation/state owner drives both platforms.
- macOS continues to use `NavigationSplitView`; iOS uses `NavigationStack`.
- Shared shell files compile without importing AppKit.
- MacOS-only helpers stay isolated to the macOS support layer.
- A reviewer can grep the tree and see clear separation between shared shell code and platform entry code.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the route set did not fork between platforms, there is no new large “ContentView_iOS.swift” copy of the old file, and shared shell files do not contain `NSOpenPanel`, `NSWorkspace`, `NSApplication`, or `NSPasteboard` calls.

## Risks / unknowns

- The current `NavDestination` set is desktop-shaped; some destinations may need iOS presentation changes even if the route model stays shared.
- Moving app entry out of `ContentView.swift` can collide with `0121` target work if the source membership split is not settled first.
- This ticket should resist scope creep into runtime/data changes. The goal is shell decomposition, not transport migration.
