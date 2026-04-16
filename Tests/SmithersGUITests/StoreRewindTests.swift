import XCTest
@testable import SmithersGUI

@MainActor
final class StoreRewindTests: XCTestCase {
    private func makeSnapshot(runId: String = "run-test", frameNo: Int, seq: Int, name: String, state: String = "running") -> DevToolsSnapshot {
        let root = DevToolsNode(
            id: 1,
            type: .workflow,
            name: name,
            props: ["state": .string(state)],
            children: [],
            depth: 0
        )
        return DevToolsSnapshot(runId: runId, frameNo: frameNo, seq: seq, root: root)
    }

    private func prepareHistorical(store: LiveRunDevToolsStore, provider: MockDevToolsStreamProvider) async {
        store.runId = "run-test"
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live")))
        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 101, name: "historical")
        await store.scrubTo(frameNo: 1)
        XCTAssertEqual(store.mode, .historical(frameNo: 1))
    }

    func testRewindWithoutConfirmationDoesNothing() async {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        await prepareHistorical(store: store, provider: provider)

        await store.rewind(to: 1, confirm: false)

        XCTAssertEqual(provider.jumpCallCount, 0)
        XCTAssertEqual(store.mode, .historical(frameNo: 1))
        XCTAssertEqual(store.tree?.name, "historical")
    }

    func testRewindWithConfirmationSuccessReturnsToLiveAndFiresToast() async {
        let provider = MockDevToolsStreamProvider()
        var toasts: [String] = []
        let store = LiveRunDevToolsStore(streamProvider: provider, toastSink: { toasts.append($0) })
        await prepareHistorical(store: store, provider: provider)

        provider.snapshotToReturn = makeSnapshot(frameNo: 4, seq: 200, name: "live-after-rewind")
        await store.rewind(to: 1, confirm: true)

        XCTAssertEqual(provider.jumpCallCount, 1)
        XCTAssertEqual(provider.lastJumpFrameNo, 1)
        XCTAssertEqual(provider.lastJumpConfirm, true)
        XCTAssertEqual(store.mode, .live)
        XCTAssertEqual(store.tree?.name, "live-after-rewind")
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(store.lastToastMessage, "Rewound to frame 1.")
    }

    func testRewindBusyKeepsHistoricalModeAndSurfacesBannerError() async {
        let provider = MockDevToolsStreamProvider()
        provider.jumpError = DevToolsClientError.busy

        let store = LiveRunDevToolsStore(streamProvider: provider)
        await prepareHistorical(store: store, provider: provider)

        await store.rewind(to: 1, confirm: true)

        XCTAssertEqual(store.mode, .historical(frameNo: 1))
        XCTAssertEqual(store.rewindError, .busy)
        XCTAssertEqual(store.rewindError?.displayMessage, "Another rewind is in progress.")
    }

    func testRewindUnsupportedSandboxKeepsHistoricalModeAndSurfacesHint() async {
        let provider = MockDevToolsStreamProvider()
        provider.jumpError = DevToolsClientError.unsupportedSandbox("Sandbox unsupported")

        let store = LiveRunDevToolsStore(streamProvider: provider)
        await prepareHistorical(store: store, provider: provider)

        await store.rewind(to: 1, confirm: true)

        XCTAssertEqual(store.mode, .historical(frameNo: 1))
        XCTAssertEqual(store.rewindError, .unsupportedSandbox("Sandbox unsupported"))
        XCTAssertEqual(store.rewindError?.hint, "This run cannot be rewound in-place. Use historical view-only mode.")
    }

    func testRewindNetworkErrorKeepsHistoricalStateAndSupportsRetryPrompt() async {
        let provider = MockDevToolsStreamProvider()
        provider.jumpError = URLError(.notConnectedToInternet)

        let store = LiveRunDevToolsStore(streamProvider: provider)
        await prepareHistorical(store: store, provider: provider)

        await store.rewind(to: 1, confirm: true)

        XCTAssertEqual(store.mode, .historical(frameNo: 1))
        if case .network = store.rewindError {
            XCTAssertNotNil(store.rewindError?.hint)
        } else {
            XCTFail("Expected network rewind error")
        }
    }

    func testRewindDisabledWhenRunFinished() async {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        await prepareHistorical(store: store, provider: provider)
        store.setRunStatus(.finished)

        await store.rewind(to: 1, confirm: true)

        XCTAssertEqual(provider.jumpCallCount, 0)
        XCTAssertEqual(store.mode, .historical(frameNo: 1))
        XCTAssertEqual(store.rewindError, .rewindFailed("Run is no longer live; rewind is unavailable."))
    }

    func testLocalSingleFlightGuardPreventsDoubleSubmit() async {
        let provider = MockDevToolsStreamProvider()
        provider.jumpDelayNs = 200_000_000

        let store = LiveRunDevToolsStore(streamProvider: provider)
        await prepareHistorical(store: store, provider: provider)
        provider.snapshotToReturn = makeSnapshot(frameNo: 4, seq: 222, name: "live-after-rewind")

        let first = Task { @MainActor in
            await store.rewind(to: 1, confirm: true)
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        await store.rewind(to: 1, confirm: true)
        _ = await first.value

        XCTAssertEqual(provider.jumpCallCount, 1)
    }
}
