# Test Suite Signal Cleanup

Date: 2026-05-02

Scope reviewed for ticket 0192:

- `Tests/TabmonstersTests/ApprovalsViewTests.swift`
- `Tests/TabmonstersTests/WorkspacesViewTests.swift`
- `Tests/TabmonstersTests/RunsViewTests.swift`
- `Tests/TabmonstersTests/MemoryViewTests.swift`
- `Tests/TabmonstersTests/ScoresViewTests.swift`
- `Tests/TabmonstersTests/SearchViewTests.swift`

Outcome:

- No `XCTAssertTrue(true, ...)`, `_BUG`, `testBug`, `BUG DOCUMENTED`, or lowercase `documentation` markers remain in the first-scope files.
- Known behavior in the first-scope files is now represented by concrete assertions, source-backed fixture checks, or review notes outside the executable test path.
- Broader suite cleanup remains separately tracked by review docs for non-first-scope files, especially terminal, prompts, workflows, issues, and landings tests.

Verification command:

```sh
rg -n "XCTAssertTrue\\(true|_BUG|testBug|BUG DOCUMENTED|documentation" \
  Tests/TabmonstersTests/ApprovalsViewTests.swift \
  Tests/TabmonstersTests/WorkspacesViewTests.swift \
  Tests/TabmonstersTests/RunsViewTests.swift \
  Tests/TabmonstersTests/MemoryViewTests.swift \
  Tests/TabmonstersTests/ScoresViewTests.swift \
  Tests/TabmonstersTests/SearchViewTests.swift
```
