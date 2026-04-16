import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension OutputTab: @retroactive Inspectable {}
extension OutputPendingView: @retroactive Inspectable {}
extension OutputFailedView: @retroactive Inspectable {}

@MainActor
final class OutputTabTests: XCTestCase {

    func testMountCallsGetNodeOutputExactlyOnce() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.success(.init(status: .pending, row: nil, schema: sampleSchema())))

        let controller = OutputTabController(outputProvider: provider)
        controller.activate(
            context: OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 1),
            runtimeState: "running"
        )
        await waitUntil { provider.callCount == 1 }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.calls.first?.runId, "run-1")
        XCTAssertEqual(provider.calls.first?.nodeId, "task:review:0")
        XCTAssertEqual(provider.calls.first?.iteration, 1)
    }

    func testPendingToProducedAutoRefetchesOnRuntimeTransition() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.success(.init(status: .pending, row: nil, schema: sampleSchema())))
        provider.enqueue(.success(.init(
            status: .produced,
            row: ["rating": .string("approve")],
            schema: sampleSchema()
        )))

        let controller = OutputTabController(outputProvider: provider)
        let context = OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 1)

        controller.activate(context: context, runtimeState: "running")
        await waitUntil { provider.callCount == 1 && controller.response?.status == .pending }

        controller.observeRuntimeState("finished")
        await waitUntil { provider.callCount == 2 && controller.response?.status == .produced }
    }

    func testFailedWithPartialRendersPartialSection() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.success(.init(
            status: .failed,
            row: nil,
            schema: sampleSchema(),
            partial: ["rating": .string("changes_requested")]
        )))

        let controller = OutputTabController(outputProvider: provider)
        controller.activate(
            context: OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 1),
            runtimeState: "failed"
        )
        await waitUntil { provider.callCount == 1 && controller.response?.status == .failed }

        let failedView = OutputFailedView(partial: controller.response?.partial)
        let inspected = try failedView.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Task failed before producing final output."))
        XCTAssertNoThrow(try inspected.find(text: "Last partial output"))
    }

    func testRetryCallsProviderAgainAndShowsLoading() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.failure(DevToolsClientError.network(URLError(.timedOut))))
        provider.enqueue(
            .success(.init(status: .pending, row: nil, schema: sampleSchema())),
            delayNs: 200_000_000
        )

        let controller = OutputTabController(outputProvider: provider)
        let context = OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 1)

        controller.activate(context: context, runtimeState: "running")
        await waitUntil { provider.callCount == 1 && controller.error != nil }

        controller.retry()
        XCTAssertTrue(controller.isLoading)

        await waitUntil { provider.callCount == 2 && controller.isLoading == false }
        XCTAssertEqual(controller.response?.status, .pending)
    }

    func testSwitchingAwayCancelsInFlightRPC() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.success(.init(status: .pending, row: nil, schema: sampleSchema())), delayNs: 700_000_000)

        let controller = OutputTabController(outputProvider: provider)
        controller.activate(
            context: OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 1),
            runtimeState: "running"
        )
        await waitUntil { provider.callCount == 1 }

        controller.cancelInFlight()
        await waitUntil { provider.cancellationCount == 1 }

        XCTAssertEqual(provider.cancellationCount, 1)
    }

    func testNodeHasNoOutputErrorIsPreserved() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.failure(DevToolsClientError.nodeHasNoOutput))

        let controller = OutputTabController(outputProvider: provider)
        controller.activate(
            context: OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 1),
            runtimeState: "finished"
        )

        await waitUntil { provider.callCount == 1 && controller.error != nil }
        XCTAssertEqual(controller.error, .nodeHasNoOutput)
    }

    func testIterationNotFoundErrorIsPreservedAndRetryUsesSelectedIteration() async throws {
        let provider = MockNodeOutputProvider()
        provider.enqueue(.failure(DevToolsClientError.iterationNotFound(4)))

        let controller = OutputTabController(outputProvider: provider)
        controller.activate(
            context: OutputRequestContext(runId: "run-1", nodeId: "task:review:0", iteration: 4),
            runtimeState: "finished"
        )

        await waitUntil { provider.callCount == 1 && controller.error != nil }
        XCTAssertEqual(controller.error, .iterationNotFound(4))

        controller.retry(using: 1)
        await waitUntil { provider.callCount == 2 && controller.response?.status == .pending }
        XCTAssertEqual(provider.calls.last?.iteration, 1)
    }

    private func sampleSchema() -> OutputSchemaDescriptor {
        OutputSchemaDescriptor(fields: [
            OutputSchemaFieldDescriptor(
                name: "rating",
                type: .string,
                optional: false,
                nullable: false,
                description: "Review decision",
                enumValues: [.string("approve"), .string("changes_requested")]
            )
        ])
    }

    private func makeStore(nodeState: String) -> LiveRunDevToolsStore {
        let store = LiveRunDevToolsStore()
        let taskNode = DevToolsNode(
            id: 5,
            type: .task,
            name: "Task",
            props: ["state": .string(nodeState)],
            task: DevToolsTaskInfo(
                nodeId: "task:review:0",
                kind: "agent",
                agent: "claude-opus-4-7",
                label: "Review",
                outputTableName: "review",
                iteration: 1
            ),
            children: [],
            depth: 2
        )

        let root = DevToolsNode(
            id: 1,
            type: .workflow,
            name: "Workflow",
            props: ["state": .string("running")],
            children: [taskNode],
            depth: 0
        )

        store.runId = "run-1"
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run-1", frameNo: 1, seq: 1, root: root)))
        store.selectNode(5)
        return store
    }

    private func waitUntil(
        timeout: TimeInterval = 1.5,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor
private final class MockNodeOutputProvider: NodeOutputProvider {
    struct Call: Equatable {
        let runId: String
        let nodeId: String
        let iteration: Int?
    }

    struct QueuedResponse {
        let delayNs: UInt64
        let result: Result<NodeOutputResponse, Error>
    }

    private(set) var calls: [Call] = []
    private(set) var cancellationCount: Int = 0

    private var queuedResponses: [QueuedResponse] = []

    var callCount: Int { calls.count }

    func enqueue(_ result: Result<NodeOutputResponse, Error>, delayNs: UInt64 = 0) {
        queuedResponses.append(QueuedResponse(delayNs: delayNs, result: result))
    }

    func getNodeOutput(runId: String, nodeId: String, iteration: Int?) async throws -> NodeOutputResponse {
        calls.append(Call(runId: runId, nodeId: nodeId, iteration: iteration))

        let queued = queuedResponses.isEmpty
            ? QueuedResponse(delayNs: 0, result: .success(.init(status: .pending, row: nil, schema: nil)))
            : queuedResponses.removeFirst()

        if queued.delayNs > 0 {
            do {
                try await Task.sleep(nanoseconds: queued.delayNs)
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }

        switch queued.result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}
