# 0192 Test Suite Signal Cleanup

Audit date: 2026-04-30

## Summary

The local test suite passes, but many tests document known bugs with names or assertions that still pass. This weakens the signal for leadership and CI: green does not always mean acceptable behavior.

## Parallel Ownership

Primary owner writes tests only unless fixing a tiny local helper is cheaper than preserving a misleading test.

Recommended first scope:

- `Tests/SmithersGUITests/ApprovalsViewTests.swift`
- `Tests/SmithersGUITests/WorkspacesViewTests.swift`
- `Tests/SmithersGUITests/RunsViewTests.swift`
- `Tests/SmithersGUITests/MemoryViewTests.swift`
- `Tests/SmithersGUITests/ScoresViewTests.swift`
- `Tests/SmithersGUITests/SearchViewTests.swift`

Avoid files owned by active feature tickets until they land.

## Requirements

- Inventory tests whose names include `BUG`, `_BUG`, `documentation`, or use `XCTAssertTrue(true)` as documentation.
- For each case, choose one:
  - convert to a real regression test that asserts desired behavior,
  - mark with `XCTExpectFailure` if the bug is intentionally unresolved,
  - move prose to a ticket and delete the non-test,
  - fix the small bug and assert the fixed behavior.
- Do not silently delete useful coverage.
- Keep the suite passing, but make pass/fail semantics honest.

## Acceptance Criteria

- [ ] Add a short checked-in inventory note or commit summary mapping cleaned tests to outcomes.
- [ ] No bare `XCTAssertTrue(true, "BUG...")` remains in the first-scope files.
- [ ] Known unresolved behavior uses `XCTExpectFailure` or a referenced ticket, not a passing fake test.
- [ ] At least one stale bug-documentation block is converted into a real production-behavior regression test.

## Verification

```sh
swift test
rg -n "XCTAssertTrue\\(true|_BUG|testBug|BUG DOCUMENTED|documentation" Tests/SmithersGUITests
```

## Scheduling Note

This ticket can run in parallel with product work if the owner avoids files under active edits. Otherwise run it after the feature tickets land.
