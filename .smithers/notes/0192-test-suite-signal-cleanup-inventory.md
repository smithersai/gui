# 0192 Test Suite Signal Cleanup Inventory

- Scope: `ApprovalsViewTests.swift`, `WorkspacesViewTests.swift`, `RunsViewTests.swift`, `MemoryViewTests.swift`, `ScoresViewTests.swift`, `SearchViewTests.swift`
- Date: 2026-05-01

## Outcome Mapping

- Reworded first-scope `testBug_*`/`*_BUG` identifiers to behavior-oriented names.
- Removed `BUG DOCUMENTED`/`documentation` markers that produced false green signal.
- Kept unresolved behaviors explicit via `XCTExpectFailure(...)` in scoped tests where product behavior is not yet fixed.
- Converted stale default-filter label documentation in `SearchViewTests` into a real assertion-based regression (`nil -> "All"`).
- Removed test-target markdown inventory file that produced SwiftPM unhandled-file warnings; inventory now lives under `.smithers/notes/`.
