# 0192 Test Signal Cleanup Inventory

- SearchViewTests.test_defaultFilterLabelIsAll: converted to real regression assertion (`issueState` nil defaults label semantics to `All`), removed fake expected-failure comparison.
- SearchViewTests unresolved bug-doc tests: kept with `XCTExpectFailure` + `XCTFail` for explicit unresolved behavior (`search` stale results, issue-state persistence).
- ApprovalsViewTests bug-doc blocks: kept as explicit unresolved checks using `XCTExpectFailure` + `XCTFail` (no fake pass assertions).
- WorkspacesViewTests bug-doc blocks: kept as explicit unresolved checks using `XCTExpectFailure` + `XCTFail`.
- MemoryViewTests/ScoresViewTests bug-doc blocks in scope: kept as explicit unresolved checks using `XCTExpectFailure` + `XCTFail`.
- Removed prior unhandled test-target markdown approach; inventory now lives under `.smithers/notes` to avoid `swift test` unhandled-file warnings.
