## Status (audited 2026-04-21, closed as obsolete 2026-04-22)

The specific code paths referenced in this ticket have been deleted and not
replaced. In commit `65255682` ("feat(libsmithers): cut over SwiftUI app to
libsmithers C ABI"), the following were removed entirely:

- `AgentService.swift` (1278 lines) — the file that contained the described
  `activeBridge.take()` race at line 116 and the bridge-creation path at
  lines 157/168.
- `AgentProtocol.swift`, `CodexMCPStatus.swift`, `CodexModelSelection.swift`,
  and all associated tests.
- `codex-ffi/` Rust crate, `CCodexFFI/` module map, and `codex-ffi.h` (see
  git status: all currently shown as deleted).

`libsmithers/` (the replacement Zig core) does NOT implement a codex bridge.
Only codex agent metadata remains (`libsmithers/src/client/agents.zig:24`,
`libsmithers/src/models/mod.zig:17`). There is no `codex_create`,
`codex_send`, or `codex_cancel` FFI surface anywhere in the current tree.

Resolution:
- Close this ticket as obsolete. The affected Swift/Codex bridge code path no
  longer ships in the current architecture.
- If a Codex streaming bridge is reintroduced (for example, via a Zig rewrite),
  open a new implementation ticket and carry forward the original acceptance
  criteria below: cancellation must cover `codex_create`, stale bridges must
  never replace active ones, and rapid turns must not leak processes.

Review stubs in `docs/reviews/chat-codex-review.md` and
`docs/reviews/platform-navigation-review.md` were updated on 2026-04-22 to
mark the affected Codex bridge findings as historical.

Original ticket body follows.

---

# Fix Codex Cancel Race with Bridge Creation

## Problem

If a cancel or new turn is requested while `codex_create` is still running,
the cancel has no effect because `activeBridge` has not been set yet. The
old bridge can overwrite the new one when it finally returns.

Review: streaming_ffi.

## Current State

- `AgentService.swift:116` cancels via `activeBridge.take()` which is nil
  during `codex_create`.
- `AgentService.swift:157` creates the bridge before registering at line 168.

## Proposed Changes

- Use a cancellation token or task-based cancellation that covers the
  `codex_create` phase.
- Ensure a late-returning bridge does not overwrite a newer one.

## Files

- `AgentService.swift`
- Codex bridge files

## Acceptance Criteria

- Cancel during `codex_create` aborts the pending bridge creation.
- A stale bridge never overwrites an active one.
- Rapid turn submission does not leak Codex processes.
