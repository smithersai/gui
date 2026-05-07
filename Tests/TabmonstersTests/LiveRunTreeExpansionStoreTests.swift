import XCTest
@testable import SmithersGUI

/// Unit tests for `LiveRunTreeExpansionStore`.
///
/// Notes / limitations:
/// - The store is an `ObservableObject` with `@Published` private state, mutated
///   only via its public methods. Tests construct fresh instances rather than
///   using `.shared` so they remain isolated. The shared singleton is not
///   exercised here.
/// - The `runId` argument is `String?`. There is no separate concept of "node
///   exists" — `nodeId` is just an `Int` — so "non-existent node" tests assert
///   the read-back behavior of ids that were never written / were collapsed.
/// - Concurrency: the store is *not* thread-safe (plain Dictionary mutation,
///   no lock, runs on whatever actor the caller is on). The concurrency test
///   therefore serializes mutations through `MainActor` (the realistic call
///   site for an `ObservableObject`) and only verifies the final invariants
///   under that serialized model. We do not stress the type with unsynchronized
///   parallel writers, which would be a documented data race.
/// - Persistence: the store is purely in-memory. A fresh instance starts
///   empty; there is no on-disk persistence to verify. The "persistence
///   boundary" tests assert that state survives across method calls on the
///   same instance and does *not* survive across distinct instances.
final class LiveRunTreeExpansionStoreTests: XCTestCase {

    // MARK: - Empty store

    func testEmptyStore_returnsEmptySetsForAnyRunId() {
        let store = LiveRunTreeExpansionStore()
        XCTAssertTrue(store.expandedIds(runId: "run-A").isEmpty)
        XCTAssertTrue(store.userCollapsedIds(runId: "run-A").isEmpty)
        XCTAssertTrue(store.expandedIds(runId: "anything").isEmpty)
    }

    func testEmptyStore_nilRunIdReturnsEmpty() {
        let store = LiveRunTreeExpansionStore()
        XCTAssertTrue(store.expandedIds(runId: nil).isEmpty)
        XCTAssertTrue(store.userCollapsedIds(runId: nil).isEmpty)
    }

    // MARK: - Toggle: expand -> collapse -> expand

    func testToggle_expandThenCollapseThenExpand() {
        let store = LiveRunTreeExpansionStore()
        let run = "run-1"

        // First toggle: not expanded -> becomes expanded.
        store.toggle(nodeId: 42, runId: run)
        XCTAssertTrue(store.expandedIds(runId: run).contains(42))
        XCTAssertFalse(store.userCollapsedIds(runId: run).contains(42))

        // Second toggle: expanded -> becomes collapsed.
        store.toggle(nodeId: 42, runId: run)
        XCTAssertFalse(store.expandedIds(runId: run).contains(42))
        XCTAssertTrue(store.userCollapsedIds(runId: run).contains(42))

        // Third toggle: collapsed -> expanded again, and removed from collapsed.
        store.toggle(nodeId: 42, runId: run)
        XCTAssertTrue(store.expandedIds(runId: run).contains(42))
        XCTAssertFalse(store.userCollapsedIds(runId: run).contains(42))
    }

    func testToggle_doesNotAffectOtherNodes() {
        let store = LiveRunTreeExpansionStore()
        store.toggle(nodeId: 1, runId: "r")
        store.toggle(nodeId: 2, runId: "r")
        XCTAssertEqual(store.expandedIds(runId: "r"), [1, 2])
        store.toggle(nodeId: 1, runId: "r")
        XCTAssertEqual(store.expandedIds(runId: "r"), [2])
        XCTAssertEqual(store.userCollapsedIds(runId: "r"), [1])
    }

    // MARK: - Expand / collapse on never-seen nodes

    func testExpand_onPreviouslyUnknownNode_marksExpanded() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 7, runId: "r")
        XCTAssertEqual(store.expandedIds(runId: "r"), [7])
        XCTAssertTrue(store.userCollapsedIds(runId: "r").isEmpty)
    }

    func testCollapse_onPreviouslyUnknownNode_marksUserCollapsed() {
        let store = LiveRunTreeExpansionStore()
        store.collapse(nodeId: 9, runId: "r")
        XCTAssertTrue(store.expandedIds(runId: "r").isEmpty)
        XCTAssertEqual(store.userCollapsedIds(runId: "r"), [9])
    }

    func testExpand_isIdempotent() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "r")
        store.expand(nodeId: 1, runId: "r")
        store.expand(nodeId: 1, runId: "r")
        XCTAssertEqual(store.expandedIds(runId: "r"), [1])
    }

    func testCollapse_isIdempotent() {
        let store = LiveRunTreeExpansionStore()
        store.collapse(nodeId: 1, runId: "r")
        store.collapse(nodeId: 1, runId: "r")
        XCTAssertEqual(store.userCollapsedIds(runId: "r"), [1])
    }

    func testExpandThenCollapse_movesNodeBetweenSets() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 5, runId: "r")
        XCTAssertTrue(store.expandedIds(runId: "r").contains(5))

        store.collapse(nodeId: 5, runId: "r")
        XCTAssertFalse(store.expandedIds(runId: "r").contains(5))
        XCTAssertTrue(store.userCollapsedIds(runId: "r").contains(5))

        store.expand(nodeId: 5, runId: "r")
        XCTAssertTrue(store.expandedIds(runId: "r").contains(5))
        XCTAssertFalse(store.userCollapsedIds(runId: "r").contains(5))
    }

    // MARK: - Per-runId isolation

    func testRunIdIsolation_expandInOneDoesNotAffectOther() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "A")
        store.expand(nodeId: 2, runId: "A")
        store.expand(nodeId: 99, runId: "B")

        XCTAssertEqual(store.expandedIds(runId: "A"), [1, 2])
        XCTAssertEqual(store.expandedIds(runId: "B"), [99])
        XCTAssertTrue(store.userCollapsedIds(runId: "A").isEmpty)
        XCTAssertTrue(store.userCollapsedIds(runId: "B").isEmpty)
    }

    func testRunIdIsolation_sameNodeIdAcrossRunIdsIsIndependent() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 7, runId: "A")
        store.collapse(nodeId: 7, runId: "B")

        XCTAssertEqual(store.expandedIds(runId: "A"), [7])
        XCTAssertTrue(store.userCollapsedIds(runId: "A").isEmpty)

        XCTAssertTrue(store.expandedIds(runId: "B").isEmpty)
        XCTAssertEqual(store.userCollapsedIds(runId: "B"), [7])
    }

    // MARK: - nil runId

    func testToggleWithNilRunId_isNoOp() {
        let store = LiveRunTreeExpansionStore()
        store.toggle(nodeId: 1, runId: nil)
        store.expand(nodeId: 2, runId: nil)
        store.collapse(nodeId: 3, runId: nil)
        store.expandAll([4, 5], runId: nil)
        store.reset(runId: nil)

        XCTAssertTrue(store.expandedIds(runId: nil).isEmpty)
        XCTAssertTrue(store.userCollapsedIds(runId: nil).isEmpty)
    }

    func testNilRunId_doesNotPolluteOtherRunIds() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "A")
        store.expand(nodeId: 2, runId: nil) // no-op
        XCTAssertEqual(store.expandedIds(runId: "A"), [1])
    }

    // MARK: - Empty string runId

    func testEmptyStringRunId_isTreatedAsValidDistinctKey() {
        // Empty string is non-nil, so guard let succeeds and "" becomes a key.
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "")
        XCTAssertEqual(store.expandedIds(runId: ""), [1])
        XCTAssertTrue(store.expandedIds(runId: "other").isEmpty)
    }

    // MARK: - expandAll

    func testExpandAll_addsAllIdsAndClearsThemFromCollapsed() {
        let store = LiveRunTreeExpansionStore()
        store.collapse(nodeId: 1, runId: "r")
        store.collapse(nodeId: 2, runId: "r")
        store.collapse(nodeId: 3, runId: "r")

        store.expandAll([1, 2], runId: "r")

        XCTAssertEqual(store.expandedIds(runId: "r"), [1, 2])
        XCTAssertEqual(store.userCollapsedIds(runId: "r"), [3])
    }

    func testExpandAll_emptySetIsNoOp() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "r")
        store.collapse(nodeId: 2, runId: "r")

        store.expandAll([], runId: "r")

        XCTAssertEqual(store.expandedIds(runId: "r"), [1])
        XCTAssertEqual(store.userCollapsedIds(runId: "r"), [2])
    }

    func testExpandAll_unionsWithExisting() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "r")
        store.expandAll([2, 3, 4], runId: "r")
        XCTAssertEqual(store.expandedIds(runId: "r"), [1, 2, 3, 4])
    }

    func testExpandAll_isolatedPerRunId() {
        let store = LiveRunTreeExpansionStore()
        store.expandAll([1, 2, 3], runId: "A")
        XCTAssertTrue(store.expandedIds(runId: "B").isEmpty)
        XCTAssertEqual(store.expandedIds(runId: "A"), [1, 2, 3])
    }

    // MARK: - Reset / clear

    func testReset_clearsBothExpandedAndCollapsedForRunId() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "r")
        store.expand(nodeId: 2, runId: "r")
        store.collapse(nodeId: 3, runId: "r")

        store.reset(runId: "r")

        XCTAssertTrue(store.expandedIds(runId: "r").isEmpty)
        XCTAssertTrue(store.userCollapsedIds(runId: "r").isEmpty)
    }

    func testReset_doesNotAffectOtherRunIds() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "A")
        store.expand(nodeId: 2, runId: "B")

        store.reset(runId: "A")

        XCTAssertTrue(store.expandedIds(runId: "A").isEmpty)
        XCTAssertEqual(store.expandedIds(runId: "B"), [2])
    }

    func testReset_onUnknownRunIdIsNoOp() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "A")
        store.reset(runId: "unknown")
        XCTAssertEqual(store.expandedIds(runId: "A"), [1])
    }

    // MARK: - Boundary: many nodes

    func testManyNodes_canBeStoredAndRetrieved() {
        let store = LiveRunTreeExpansionStore()
        let ids = Set(0..<10_000)
        store.expandAll(ids, runId: "big")
        XCTAssertEqual(store.expandedIds(runId: "big").count, 10_000)
        XCTAssertEqual(store.expandedIds(runId: "big"), ids)
    }

    func testManyRunIds_canBeStoredIndependently() {
        let store = LiveRunTreeExpansionStore()
        for i in 0..<500 {
            store.expand(nodeId: i, runId: "run-\(i)")
        }
        for i in 0..<500 {
            XCTAssertEqual(store.expandedIds(runId: "run-\(i)"), [i])
        }
    }

    func testExtremeNodeIdValues() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: Int.min, runId: "r")
        store.expand(nodeId: Int.max, runId: "r")
        store.expand(nodeId: 0, runId: "r")
        store.expand(nodeId: -1, runId: "r")
        XCTAssertEqual(store.expandedIds(runId: "r"),
                       [Int.min, Int.max, 0, -1])
    }

    // MARK: - Persistence boundary

    func testPersistence_stateSurvivesAcrossCallsOnSameInstance() {
        let store = LiveRunTreeExpansionStore()
        store.expand(nodeId: 1, runId: "r")
        // simulated unrelated calls
        _ = store.expandedIds(runId: "other")
        _ = store.userCollapsedIds(runId: "other")
        XCTAssertEqual(store.expandedIds(runId: "r"), [1])
    }

    func testPersistence_freshInstanceStartsEmpty() {
        // Document: the store is in-memory only; there is no disk persistence.
        let a = LiveRunTreeExpansionStore()
        a.expand(nodeId: 1, runId: "r")
        let b = LiveRunTreeExpansionStore()
        XCTAssertTrue(b.expandedIds(runId: "r").isEmpty)
    }

    // MARK: - Concurrency (serialized via MainActor)

    func testConcurrentExpands_serializedThroughMainActor() async {
        // The store is not internally synchronized. Real call sites mutate it
        // from the main actor (it drives an ObservableObject view). We model
        // that here: many concurrent tasks each hop to the main actor before
        // mutating, which serializes them and matches production behavior.
        let store = await MainActor.run { LiveRunTreeExpansionStore() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    await MainActor.run {
                        store.expand(nodeId: i, runId: "r")
                    }
                }
            }
        }

        let final = await MainActor.run { store.expandedIds(runId: "r") }
        XCTAssertEqual(final.count, 200)
        XCTAssertEqual(final, Set(0..<200))
    }

    func testConcurrentToggles_endInDeterministicCount() async {
        let store = await MainActor.run { LiveRunTreeExpansionStore() }

        // Toggle each id an even number of times (4) -> all return to
        // collapsed state, none expanded.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                for i in 0..<50 {
                    group.addTask {
                        await MainActor.run {
                            store.toggle(nodeId: i, runId: "r")
                        }
                    }
                }
            }
        }

        let expanded = await MainActor.run { store.expandedIds(runId: "r") }
        let collapsed = await MainActor.run { store.userCollapsedIds(runId: "r") }
        // Even number of toggles per id => not in expanded, in collapsed.
        XCTAssertTrue(expanded.isEmpty)
        XCTAssertEqual(collapsed, Set(0..<50))
    }
}
