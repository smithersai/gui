# Client: recent-first remote workspace switcher

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md:253-260`. The spec wants a recent-first workspace switcher, full-screen on iOS and a sidebar/dropdown on desktop, with local and remote visually separated on desktop. The current gui code has two unrelated precursors:

- Local filesystem recents on the welcome screen, backed by `recent_workspaces` in libsmithers SQLite (`/Users/williamcory/gui/libsmithers/src/persistence/sqlite.zig:232-345`, `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.Workspace.swift:18-55`, `/Users/williamcory/gui/WelcomeView.swift:87-115`).
- A repo-local workspace management view that calls `smithers.listWorkspaces()` and renders only `id`, `name`, `status`, and `created_at` (`/Users/williamcory/gui/macos/Sources/Smithers/Smithers.Client.swift:538-545`, `/Users/williamcory/gui/SmithersModels.swift:3759-3823`, `/Users/williamcory/gui/WorkspacesView.swift:437-461`).

Neither surface is the cross-repo remote switcher the spec promises.

## Problem

If 0113 is only split into generic cross-platform scaffolding and sign-in/runtime plumbing lands elsewhere, the switcher can still fall through the cracks.

The current model types are too thin, the current remote list is repo-local, and the current local recents path is desktop-only. The switcher needs one intentional UI that consumes the new remote listing contract from 0135 and live sync from 0137 when available.

## Goal

Build the iOS/macOS workspace switcher view and state flow for remote workspaces, ordered recent-first by server recency and rendered as one list across repos.

On desktop, keep local workspaces visually separate from remote workspaces per spec, but do not split the remote half by repo.

## Scope

- **In scope**
- Add a switcher row model richer than the current `Workspace` type, including repo owner/name, workspace title, state, last-accessed timestamp, and source kind (`local` vs `remote` where needed).
- Initial remote load uses 0135. Request `limit=100` so the product cap fits in one fetch even though the API remains paginated.
- If 0137 lands, pin the workspace-switcher shape and apply live inserts/updates/deletes without manual refresh.
- If 0137 does not land in time, fall back to explicit refresh on open/foreground; do not invent a bespoke polling loop hidden from product/infra review.
- iOS presentation: full-screen modal or equivalent dedicated switcher surface matching the spec.
- macOS presentation: integrate into the desktop switcher affordance as a distinct Remote section, with Local recents remaining separate and backed by the existing local SQLite path.
- Remote ordering must come from server recency (`last_accessed_at` fallback contract from 0135/0136), not from client-side `created_at`.
- Each remote row renders repo name, workspace title, state, and relative/absolute recency.
- Deleting a remote workspace remains an explicit confirmed action and calls the delete surface that **ticket 0105 owns** (not the current `DeleteWorkspace` which only stops the VM and leaves the row per `workspace_lifecycle.go:53`). 0105 decides between hard-delete and soft-delete-to-terminal-state; the switcher must call whichever surface 0105 ships and must reflect the resulting state accurately — if soft-delete, deleted rows disappear from the switcher's view via the shape; if hard-delete, the row is gone outright. This ticket gates on 0105 having landed, and on 0105's decision being reflected in 0116's shape (tombstone vs. hard-delete semantics).
- Empty states must distinguish:
- signed in, no remote workspaces yet;
- signed out / auth expired;
- backend unavailable.
- Add view-model/UI tests for sort order, row rendering, delete confirmation, empty state, and auth-expired behavior.
- Add cross-platform integration coverage once the 0113 split and 0120-0124 runtime scaffolding exist.
- **Out of scope**
- Backend listing/sync primitives; those belong to 0135 (listing + readable-repos) and 0116 (workspaces shape). 0137 is closed as redundant with 0116.
- Local workspace persistence redesign. Reuse the existing local recents store for the desktop Local section.
- Reworking the old repo-local `WorkspacesView` into the switcher. It can coexist as a management screen if the split 0113 work still wants it.

## Dependencies

- Ticket 0109 for sign-in.
- Tickets in the 0120-0124 range for `libsmithers-core` runtime and cross-platform client plumbing.
- The tickets that split 0113 into cross-platform view/scaffold work.
- Ticket 0135 is required.
- Ticket 0137 is optional but strongly preferred for live sync.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:253-260` — first-run and switcher UX contract.
- `/Users/williamcory/gui/libsmithers/src/persistence/sqlite.zig:232-345` — current local recents model and ordering.
- `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.Workspace.swift:18-55` — current desktop-only recent workspace type.
- `/Users/williamcory/gui/WelcomeView.swift:87-115` — current recent-workspaces UI is local-only.
- `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.Client.swift:538-545` — current remote workspace client call surface.
- `/Users/williamcory/gui/SmithersModels.swift:3759-3823` — current `Workspace` model lacks repo/recency fields.
- `/Users/williamcory/gui/WorkspacesView.swift:437-461` — current remote loading path is management-oriented and repo-local.

## Acceptance criteria

- iOS has a full-screen remote workspace switcher.
- macOS shows a Remote recent-first list plus a visually separate Local section.
- Remote rows are ordered by server recency, not by creation time.
- Remote rows render repo name, workspace title, state, and last-accessed metadata.
- Delete is explicit and confirmed.
- Auth-expired returns the user to the signed-out state rather than leaving stale remote rows visible.
- Tests cover ordering, rendering, empty states, and delete confirmation.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the remote list is genuinely cross-repo, verifies desktop keeps Local and Remote visually distinct, verifies a touched workspace moves to the top after a real backend recency update, and verifies the implementation is wired through the new client/runtime path rather than another `SmithersClient` one-off.

## Risks / unknowns

- The exact presentation hook depends on the parallel 0113 split; this ticket should attach to that scaffolding rather than invent a second navigation shell.
- If 0137 is deferred, the UX needs an explicit refresh story so "recent-first" does not become "recent-at-launch."
- The current `Workspace` model is shared by other views; migrating the switcher to a richer type may expose accidental coupling in older management screens.
