import XCTest
@testable import SmithersGUI

actor MockNodeDiffClient: NodeDiffFetching {
    struct QueuedResponse {
        let delayNs: UInt64
        let result: Result<NodeDiffBundle, Error>
    }

    private(set) var calls: [DiffTabRequest] = []
    private(set) var cancellationCount = 0
    private var queue: [QueuedResponse] = []

    func enqueue(_ result: Result<NodeDiffBundle, Error>, delayNs: UInt64 = 0) {
        queue.append(QueuedResponse(delayNs: delayNs, result: result))
    }

    func getNodeDiff(runId: String, nodeId: String, iteration: Int) async throws -> NodeDiffBundle {
        calls.append(DiffTabRequest(runId: runId, nodeId: nodeId, iteration: iteration))
        let response = queue.isEmpty
            ? QueuedResponse(delayNs: 0, result: .success(NodeDiffBundle(seq: 1, baseRef: "base", patches: [])))
            : queue.removeFirst()

        if response.delayNs > 0 {
            do {
                try await Task.sleep(nanoseconds: response.delayNs)
            } catch {
                cancellationCount += 1
                throw CancellationError()
            }
        }

        if Task.isCancelled {
            cancellationCount += 1
            throw CancellationError()
        }

        return try response.result.get()
    }
}

@MainActor
final class DiffTabTests: XCTestCase {

    private func makePatch(path: String, diff: String) -> NodeDiffPatch {
        NodeDiffPatch(path: path, oldPath: nil, operation: .modify, diff: diff, binaryContent: nil)
    }

    private func makeBundle(patches: [NodeDiffPatch]) -> NodeDiffBundle {
        NodeDiffBundle(seq: 1, baseRef: "base", patches: patches)
    }

    private func waitForIdle(_ model: DiffTabModel, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testLoadingStateTransitions() async {
        let client = MockNodeDiffClient()
        await client.enqueue(.success(makeBundle(patches: [])), delayNs: 200_000_000)

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-1", nodeId: "task:1", iteration: 0))

        XCTAssertTrue(model.isLoading)
        await waitForIdle(model)
        XCTAssertFalse(model.isLoading)
    }

    func testEmptyPatchesShowsNoFiles() async {
        let client = MockNodeDiffClient()
        await client.enqueue(.success(makeBundle(patches: [])))

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-1", nodeId: "task:1", iteration: 0))

        await waitForIdle(model)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.lastError)
    }

    func testNormalDiffParsesFiles() async {
        let client = MockNodeDiffClient()
        let diff = """
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        await client.enqueue(.success(makeBundle(patches: [makePatch(path: "src/main.swift", diff: diff)])))

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-2", nodeId: "task:2", iteration: 0))

        await waitForIdle(model)
        XCTAssertEqual(model.files.count, 1)
        XCTAssertEqual(model.files.first?.path, "src/main.swift")
        XCTAssertEqual(model.files.first?.additions, 1)
        XCTAssertEqual(model.files.first?.deletions, 1)
    }

    func testLargeDiffShowsWarningAndCollapsesAll() async {
        let client = MockNodeDiffClient()
        let patches = (0..<51).map { index in
            makePatch(path: "f\(index).txt", diff: "@@ -1,1 +1,1 @@\n-old\n+new\n")
        }
        await client.enqueue(.success(makeBundle(patches: patches)))

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-large", nodeId: "task:large", iteration: 0))

        await waitForIdle(model)
        XCTAssertTrue(model.showLargeDiffWarning)
        XCTAssertTrue(model.expandedFileIDs.isEmpty)
    }

    func testErrorRetryCallsClientAgain() async {
        let client = MockNodeDiffClient()
        await client.enqueue(.failure(DevToolsClientError.diffTooLarge("truncated at 50 MB")))
        await client.enqueue(.success(makeBundle(patches: [makePatch(path: "ok.txt", diff: "@@ -1 +1 @@\n-old\n+new\n")])))

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-error", nodeId: "task:error", iteration: 0))

        await waitForIdle(model)
        XCTAssertNotNil(model.lastError)

        model.retry()
        await waitForIdle(model)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.files.count, 1)
        let calls = await client.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testRefreshOnIterationChangeRequestsNewDiff() async {
        let client = MockNodeDiffClient()
        await client.enqueue(.success(makeBundle(patches: [makePatch(path: "iter0.txt", diff: "@@ -1 +1 @@\n-a\n+b\n")])))
        await client.enqueue(.success(makeBundle(patches: [makePatch(path: "iter1.txt", diff: "@@ -1 +1 @@\n-a\n+b\n")])))

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-iter", nodeId: "task:iter", iteration: 0))
        await waitForIdle(model)

        model.load(DiffTabRequest(runId: "run-iter", nodeId: "task:iter", iteration: 1))
        await waitForIdle(model)

        XCTAssertEqual(model.files.first?.path, "iter1.txt")
        let calls = await client.calls
        XCTAssertEqual(calls.map(\.iteration), [0, 1])
    }

    func testInflightRequestCancelledWhenRequestChanges() async {
        let client = MockNodeDiffClient()
        await client.enqueue(
            .success(makeBundle(patches: [makePatch(path: "slow.txt", diff: "@@ -1 +1 @@\n-a\n+b\n")])),
            delayNs: 500_000_000
        )
        await client.enqueue(.success(makeBundle(patches: [makePatch(path: "fast.txt", diff: "@@ -1 +1 @@\n-x\n+y\n")])))

        let model = DiffTabModel(client: client)
        model.load(DiffTabRequest(runId: "run-cancel", nodeId: "task:cancel", iteration: 0))

        try? await Task.sleep(nanoseconds: 50_000_000)

        model.load(DiffTabRequest(runId: "run-cancel", nodeId: "task:cancel", iteration: 1))
        await waitForIdle(model)

        XCTAssertEqual(model.files.first?.path, "fast.txt")
        let cancellations = await client.cancellationCount
        XCTAssertGreaterThanOrEqual(cancellations, 1)
    }
}
