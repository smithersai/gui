# Client: iOS productization umbrella

## Context

The original 0113 tried to cover build setup, navigation refactors, terminal portability, remote data wiring, release plumbing, and the underlying runtime shift in one ticket. That is too large to implement or review safely. The gui repo is still macOS-only in both `Package.swift:4-95` and `project.yml:1-192`, `ContentView.swift:730-2431` still mixes app entry, navigation shell, route switching, and AppKit hooks in one file, and `TerminalView.swift:430-1815` is still an AppKit terminal surface.

The main spec and execution plan already imply a staged implementation: `libsmithers-core` becomes the architectural center of gravity first, target/build work can parallelize with that, and the shared SwiftUI refactors plus remote wiring follow once the production FFI exists. This ticket now tracks that split instead of owning implementation itself.

## Problem

Keeping 0113 as a single implementation bucket would hide the real dependency graph, block parallel work, and make review quality collapse. It also leaves desktop-remote phase 1 under-tracked, even though ticket 0101 says desktop-remote ships before iOS.

## Goal

Turn 0113 into the coordination umbrella for the client productization slice, with the actual work split into narrowly-scoped tickets that can be implemented and validated independently.

## Scope

- This umbrella coordinates these implementation tickets:
  - `0120` — `libsmithers-core` production runtime.
  - `0121` — macOS+iOS target/build-system setup.
  - `0122` — shared navigation and state refactor.
  - `0123` — terminal portability via libghostty pipes backend.
  - `0124` — remote data wiring to shapes, PTY, and HTTP writes.
  - `0125` — iOS release plumbing and TestFlight path.
  - `0126` — desktop-remote productization for rollout phase 1.
- This umbrella owns cross-ticket ordering and scope boundaries only. No feature work should land “under 0113” unless it is a drive-by cross-reference update.
- Dependency ordering for the split:
  - `0120` is architecturally first.
  - `0121` can run in parallel with `0120`.
  - `0122`, `0123`, and `0124` start after `0120` exposes the production FFI they consume.
  - `0125` follows `0121` once the iOS target exists.
  - `0126` consumes `0120` plus the shared refactors, and is the first rollout phase from `0101`.
- Every child ticket assumes `0106` and `0109` exist for auth.
- Every child ticket that consumes Electric-backed state depends on tickets `0114`-`0118` (the full production-shapes set, per `.smithers/specs/ios-and-remote-sandboxes-production-shapes.md`). Notably `0118` (`agent_parts`) is required to render chat-message bodies and tool blocks — without it the transcript UI can subscribe to message envelopes but has no content.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/specs/ios-and-remote-sandboxes-execution.md`
- `.smithers/tickets/0100-design-migration-strategy.md`
- `.smithers/tickets/0101-design-rollout-plan.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `.smithers/tickets/0112-plue-add-new-feature-flags.md`
- `Package.swift:4-95`
- `project.yml:1-192`
- `ContentView.swift:730-2431`
- `TerminalView.swift:430-1815`

## Acceptance criteria

- Tickets `0120` through `0126` exist and collectively replace the original implementation scope of 0113.
- 0113 clearly states that it is an umbrella and names the child tickets plus their ordering.
- The child tickets do not duplicate ownership:
  - `0120` owns runtime and FFI.
  - `0121` owns targets/build/CI.
  - `0122` owns shared SwiftUI shell refactors.
  - `0123` owns terminal portability.
  - `0124` owns remote data subscriptions and writes.
  - `0125` owns signing/TestFlight.
  - `0126` owns macOS desktop-remote product behavior.
- Cross-references to `0106`, `0109`, `0112`, and `0114`-`0117` are present where needed.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies 0113 no longer claims to implement the whole feature, every split ticket is narrow enough to review on its own, and desktop-remote has a concrete ticket instead of being left implicit.

## Risks / unknowns

- Ticket boundaries can still drift if implementation work starts before the runtime/API boundary in `0120` is stabilized.
- The shape-ticket details in `0114`-`0117` are being written in parallel, so some dependency wording may need a follow-up once those ticket titles are finalized.
- Desktop-remote and iOS share most of the same runtime work; if the child tickets ignore that shared center of gravity, scope will leak back into this umbrella.
