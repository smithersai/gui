import XCTest
@testable import SmithersGUI

@MainActor
final class LiveRunSessionRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LiveRunSessionRegistry.shared.resetForTests()
    }

    override func tearDown() {
        LiveRunSessionRegistry.shared.resetForTests()
        super.tearDown()
    }

    func testPinnedRunTabKeepsSessionAlive() {
        let runId = "run-pinned"
        let smithers = SmithersClient()
        let registry = LiveRunSessionRegistry.shared

        registry.pinRunTab(runId: runId)
        let first = registry.session(for: runId, smithers: smithers)

        // Background-tab release should be a no-op while pinned.
        registry.releaseIfUnpinned(runId: runId)
        let second = registry.session(for: runId, smithers: smithers)
        XCTAssertTrue(first.store === second.store)
        XCTAssertTrue(first.lastLogStore === second.lastLogStore)

        registry.unpinRunTab(runId: runId)
        let recreated = registry.session(for: runId, smithers: smithers)
        XCTAssertFalse(first.store === recreated.store)
    }

    func testUnpinnedReleaseDisposesSession() {
        let runId = "run-unpinned"
        let smithers = SmithersClient()
        let registry = LiveRunSessionRegistry.shared

        let first = registry.session(for: runId, smithers: smithers)
        registry.releaseIfUnpinned(runId: runId)
        let second = registry.session(for: runId, smithers: smithers)

        XCTAssertFalse(first.store === second.store)
    }
}
