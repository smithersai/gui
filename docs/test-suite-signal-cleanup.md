# Test Suite Signal Cleanup

Date: 2026-05-02

Scope reviewed for ticket 0192:

- `Tests/SmithersGUITests/ApprovalsViewTests.swift`
- `Tests/SmithersGUITests/WorkspacesViewTests.swift`
- `Tests/SmithersGUITests/RunsViewTests.swift`
- `Tests/SmithersGUITests/MemoryViewTests.swift`
- `Tests/SmithersGUITests/ScoresViewTests.swift`
- `Tests/SmithersGUITests/SearchViewTests.swift`

Outcome:

- No `XCTAssertTrue(true, ...)`, `_BUG`, `testBug`, `BUG DOCUMENTED`, or lowercase `documentation` markers remain in the first-scope files.
- Known behavior in the first-scope files is now represented by concrete assertions, source-backed fixture checks, or review notes outside the executable test path.
- Broader suite cleanup remains separately tracked by review docs for non-first-scope files, especially terminal, prompts, workflows, issues, and landings tests.

Verification command:

```sh
rg -n "XCTAssertTrue\\(true|_BUG|testBug|BUG DOCUMENTED|documentation" \
  Tests/SmithersGUITests/ApprovalsViewTests.swift \
  Tests/SmithersGUITests/WorkspacesViewTests.swift \
  Tests/SmithersGUITests/RunsViewTests.swift \
  Tests/SmithersGUITests/MemoryViewTests.swift \
  Tests/SmithersGUITests/ScoresViewTests.swift \
  Tests/SmithersGUITests/SearchViewTests.swift
```
