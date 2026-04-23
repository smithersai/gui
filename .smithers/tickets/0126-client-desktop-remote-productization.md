# Client: desktop-remote productization for rollout phase 1

## Context

Ticket `0101` says the first real rollout phase is desktop-remote, not iOS. The current macOS app is still local-first. `Smithers.Client.swift:22-33` and `1131-1137` model connectivity as local CLI reachability and set `connectionTransport = .cli`. `Smithers.Workspace.swift:37-137` only manages local folder opening and recent local workspaces. `WelcomeView.swift` only offers “Open Folder…” and local recents. `project.yml:121-123`, `Smithers.SessionStore.swift:138-220`, and `Smithers.SessionController.swift:93-183` still assume daemon-backed local PTY sessions.

There is no ticket owning the work to make the macOS app connect to a JJHub sandbox while keeping local mode available. That is a gap in the rollout plan.

## Problem

Without a dedicated desktop-remote ticket, the first rollout phase in `0101` has no implementation owner. The shared runtime work alone will not produce a usable macOS remote product.

## Goal

Make the existing macOS app capable of connecting to JJHub sandboxes in addition to its current local mode, using the shared `libsmithers-core` runtime and auth flow, while preserving the desktop-local path until the separate desktop-local track replaces it.

## Scope

- **In scope**
  - Add the macOS product surfaces needed for remote mode:
    - a sign-in entry path using `0109`,
    - a remote workspace/sandbox picker,
    - visible local-vs-remote mode distinction in the shell,
    - a route back to the existing local-folder flow.
  - Extend the current workspace entry surfaces so they can present remote mode instead of only local mode:
    - `WelcomeView.swift`,
    - `SmithersRootView` / root-shell entry flow,
    - `SidebarView.swift`,
    - `WorkspacesView.swift`,
    - any macOS-only workspace chooser UI needed by the final shell.
  - Use `0120` plus the shared refactors from `0122`-`0124` for remote tabs:
    - remote state comes from the production runtime,
    - remote terminal uses the shared terminal path,
    - remote writes use HTTP and shape echo,
    - remote tabs respect auth/session lifecycle from `0106` + `0109`.
  - Preserve hybrid desktop behavior from the spec:
    - local workspaces and remote sandboxes can both exist in the same app session,
    - signing out of JJHub closes/wipes remote state only,
    - local tabs keep working.
  - Gate all remote-mode product behavior behind `remote_sandbox_enabled` from `0112`, consistent with `0101`.
  - Implement the desktop-remote UX commitments from the spec:
    - block the remote workspace surface until the first snapshot arrives,
    - show slow-boot messaging,
    - show reconnect status without blanking the whole UI,
    - keep local and remote workspaces visually distinct.
- **Out of scope**
  - Creating the iOS target or TestFlight path.
  - Replacing the desktop-local engine; that belongs to the sibling desktop-local spec.
  - Per-user feature-flag cohorts beyond what `0101` and `0112` already cover.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/tickets/0101-design-rollout-plan.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `.smithers/tickets/0112-plue-add-new-feature-flags.md`
- Tickets `0114`-`0117` (production shape slices, authored in parallel)
- `WelcomeView.swift`
- `SidebarView.swift`
- `WorkspacesView.swift`
- `macos/Sources/Smithers/Smithers.Client.swift:22-33`
- `macos/Sources/Smithers/Smithers.Client.swift:1131-1137`
- `macos/Sources/Smithers/Smithers.Workspace.swift:37-137`
- `macos/Sources/Smithers/Smithers.SessionStore.swift:138-220`
- `macos/Sources/Smithers/Smithers.SessionController.swift:93-183`
- `project.yml:121-123`

## Acceptance criteria

- A signed-in macOS user can open a JJHub sandbox from the app in addition to opening a local folder.
- The app can hold local and remote tabs at the same time, with clear visual distinction.
- Remote-mode state uses the production runtime and shape-backed data flow, not local CLI fallbacks.
- Signing out removes remote credentials/cache/tabs while leaving local tabs intact.
- `remote_sandbox_enabled` fully gates the remote product surface.
- UI-level validation covers at least:
  - sign in,
  - open a remote sandbox,
  - view remote runs/approvals/messages,
  - open a remote terminal,
  - sign out and confirm local tabs survive.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies this is a real macOS product slice rather than just “shared code happened to make remote mode work,” local tabs continue functioning after remote sign-out, and the remote entry points disappear when `remote_sandbox_enabled` is off.

## Risks / unknowns

- Hybrid local+remote state makes shell bugs more likely than either mode alone; tab identity and sign-out boundaries need explicit tests.
- If this ticket starts rebuilding shared data/runtime layers already owned by `0120`-`0124`, it will sprawl quickly.
- The separate desktop-local spec may later replace some of the local plumbing named here; that should not block desktop-remote phase 1.
