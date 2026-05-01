# 0192 Test Signal Cleanup Inventory (First Scope)

Audit/update date: 2026-05-01

| File | Test/Case | Outcome |
|---|---|---|
| `ApprovalsViewTests.swift` | Known unresolved behavior blocks (history toggle fetch, listRecentDecisions stub, actionInFlight error handling, toggle text/icon semantics) | Kept as explicit `XCTExpectFailure` tests with issue context; no fake pass assertions |
| `WorkspacesViewTests.swift` | Known unresolved behavior blocks (create error form loss, single-slot actionInFlight, no delete confirmation, retry semantics, snapshot/create-from-snapshot flows) | Kept as explicit `XCTExpectFailure` tests with issue context; no fake pass assertions |
| `RunsViewTests.swift` | Known issue assertions (pluralization, waiting-approval mapping, hidden progress, first blocked node only) | Converted/kept as assertion-based behavior checks (no `XCTAssertTrue(true, "BUG...")`) |
| `MemoryViewTests.swift` | Known issues (namespace not passed to recall, TTL truncation, recall id collision, recall error handling) | Kept as assertion-based checks that describe present behavior; unresolved items remain explicit in names/messages |
| `ScoresViewTests.swift` | `test_aggregateTableHeadersExist` previously documentation-style expected failure | Converted to a real regression assertion test for expected summary table header schema and fixed column width totals |
| `SearchViewTests.swift` | Known issue tests (snippet line numbers, result pluralization, stale results during new search) | Kept as explicit assertion/`XCTExpectFailure` semantics; no fake pass placeholders |

Verification notes:
- No bare `XCTAssertTrue(true, "BUG...")` remains in first-scope files.
- Known unresolved behavior is represented as `XCTExpectFailure` or concrete assertions with issue context.
