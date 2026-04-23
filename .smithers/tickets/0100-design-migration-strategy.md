# Design: migration strategy for current libsmithers → core + engine

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, task D4. Design-only. The current `libsmithers/src/` tree contains both "engine" code (PTY, SQLite, workspace/cwd) and "core" code (devtools, chat streams, models, palette). The spec splits these — engine code moves to plue (Go), core code stays Zig as `libsmithers-core`. Sequencing matters: the desktop app must remain functional at every step of the migration.

## Goal

A written migration plan at `.smithers/specs/ios-and-remote-sandboxes-migration.md` that orders the tree transformations so the current macOS app never regresses.

## Scope of the output doc

This ticket is **gui-tree migration only.** Cross-repo cutover prerequisites that depend on plue changes, or on the separate desktop-local spec, are listed as a prerequisites appendix, not baked into the commit sequence.

- **Inventory against the current gui tree.** For each file/package under `libsmithers/src/`, classify as: delete (has plue equivalent), move-to-core (stays Zig), repurpose-in-core (e.g. `persistence/sqlite.zig` becomes Electric cache backend), or split. Starting point from the main spec's "Cut against the current tree" list; this ticket refines file-by-file.
- **Dependency graph.** Which moves/deletions depend on which, *within gui*. External dependencies (plue changes, desktop-local spec landing) are called out separately.
- **Sequenced commits (gui-side).** A numbered commit-by-commit plan. Each commit leaves the app in a working state. Example steps:
  1. Add protocol-client stubs in Zig alongside the existing FFI.
  2. Route one non-critical read through the stub, keep old path in parallel.
  3. Verify parity in tests, remove old path.
  4. Repeat for each engine call.
- **Dual-path window.** How long we run both the old Zig engine code and the new plue-backed path side-by-side before deletion. Propose a default (one successful production release under each read/write migrated before cutover).
- **Data migration is NOT locked yet.** Today libsmithers owns a local SQLite with `recent_workspaces`, `workspace_sessions`, `workspace_chat_sessions`. The destination for this data depends on desktop-local's choices (its own spec). This migration doc states the constraint ("existing desktop users must not lose recent-workspace history") but does not prescribe the export/import mechanism — that's a follow-up once desktop-local's persistence is settled.
- **Per-stage rollback.** For each commit in the sequence, the rollback plan (revert, reinstall, delete local file, etc.).
- **Desktop-app compatibility gates.** Before each commit lands, which manual or automated checks confirm the desktop app still works (build succeeds, existing unit tests pass, a smoke test launches a session + runs a command).
- **Prerequisites appendix.** External items the commit sequence waits on: (a) plue shape definitions for the tables gui reads, (b) plue Electric docker-compose wiring (PoC-B1 outcome), (c) desktop-local spec decisions.

## Acceptance criteria

- Doc lives at `.smithers/specs/ios-and-remote-sandboxes-migration.md`.
- Every file currently under `libsmithers/src/` appears in the inventory table exactly once.
- Dependency graph is a real graph (ASCII art or numbered list), not just prose.
- Sequenced commit plan has at least 10 concrete steps.
- Reviewed and approved before any Stage 3 implementation begins.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer walks the sequenced commit plan on paper and confirms no step leaves the app non-building, no step requires a not-yet-written PoC, and the data migration is idempotent (re-running doesn't corrupt).

## Out of scope

- Executing any part of the migration — that's Stage 3 implementation.
- Changes to plue's tree layout — this doc covers the gui side only; plue internal reorganization is plue's problem.
