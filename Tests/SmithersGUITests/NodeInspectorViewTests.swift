import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension NodeInspectorView: @retroactive Inspectable {}
extension NodeInspectorHeader: @retroactive Inspectable {}
extension GhostBanner: @retroactive Inspectable {}
extension NodeErrorBanner: @retroactive Inspectable {}
extension InspectorTabSwitcher: @retroactive Inspectable {}

@MainActor
final class NodeInspectorViewTests: XCTestCase {

    private func makeStore() -> LiveRunDevToolsStore {
        LiveRunDevToolsStore()
    }

    private func makeTaskNode(
        id: Int = 1,
        name: String = "ReviewTask",
        state: String = "running",
        nodeId: String = "task:review:0",
        agent: String? = "claude-opus-4-7",
        props: [String: JSONValue] = [:]
    ) -> DevToolsNode {
        var mergedProps = props
        mergedProps["state"] = .string(state)
        if let agent {
            mergedProps["agent"] = .string(agent)
        }
        return DevToolsNode(
            id: id,
            type: .task,
            name: name,
            props: mergedProps,
            task: DevToolsTaskInfo(
                nodeId: nodeId,
                kind: "agent",
                agent: agent,
                label: name,
                outputTableName: nil,
                iteration: 1
            ),
            children: [],
            depth: 1
        )
    }

    private func makeWorkflowNode(id: Int = 10, name: String = "MyWorkflow") -> DevToolsNode {
        DevToolsNode(
            id: id,
            type: .workflow,
            name: name,
            props: ["state": .string("running")],
            task: nil,
            children: [],
            depth: 0
        )
    }

    // MARK: - Empty state

    func testEmptyStateWhenNoSelection() throws {
        let store = makeStore()
        var tab: InspectorTab = .output
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let view = NodeInspectorView(store: store, selectedTab: binding)
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Select a node to inspect"))
    }

    // MARK: - Task node selection

    func testTaskNodeShowsHeaderAndTabs() throws {
        let store = makeStore()
        let node = makeTaskNode()
        let snapshot = DevToolsSnapshot(
            runId: "run-1", frameNo: 1, seq: 1,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: [node])
        )
        store.applyEvent(.snapshot(snapshot))
        store.selectNode(1)

        var tab: InspectorTab = .logs
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let view = NodeInspectorView(store: store, selectedTab: binding)
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "<ReviewTask>"))
        XCTAssertNoThrow(try inspected.find(text: "RUNNING"))
        XCTAssertNoThrow(try inspected.find(ViewType.Button.self, where: { button in
            let id = try? button.accessibilityIdentifier()
            return id == "inspector.header.copyNodeId"
        }))
    }

    // MARK: - Non-task node

    func testNonTaskNodeHidesTabsShowsRoleDescription() throws {
        let store = makeStore()
        let node = makeWorkflowNode()
        let snapshot = DevToolsSnapshot(runId: "run-1", frameNo: 1, seq: 1, root: node)
        store.applyEvent(.snapshot(snapshot))
        store.selectNode(10)

        var tab: InspectorTab = .output
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let view = NodeInspectorView(store: store, selectedTab: binding)
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Root workflow container that orchestrates all child tasks."))
    }

    // MARK: - Ghost banner

    func testGhostBannerVisible() throws {
        let banner = GhostBanner(isVisible: true, onClear: {})
        let inspected = try banner.inspect()
        XCTAssertNoThrow(try inspected.find(text: "This node is no longer in the running tree."))
    }

    func testGhostBannerHiddenWhenNotGhost() throws {
        let banner = GhostBanner(isVisible: false, onClear: {})
        let inspected = try banner.inspect()
        XCTAssertThrowsError(try inspected.find(text: "This node is no longer in the running tree."))
    }

    func testGhostBannerClearCallsAction() throws {
        var cleared = false
        let banner = GhostBanner(isVisible: true, onClear: { cleared = true })
        try banner.inspect().find(button: "Clear").tap()
        XCTAssertTrue(cleared)
    }

    func testGhostBannerShowsUnmountedFrameBadge() throws {
        let banner = GhostBanner(isVisible: true, unmountedFrameNo: 42, onClear: {})
        let inspected = try banner.inspect()
        XCTAssertNoThrow(try inspected.find(text: "This node is no longer in the running tree (unmounted at frame 42)."))
    }

    func testSelectedGhostKeepsLastKnownValuesAndShowsUnmountedFrameBadge() throws {
        let store = makeStore()
        let node = makeTaskNode(
            id: 5,
            name: "GhostedTask",
            state: "failed",
            nodeId: "task:ghosted:5",
            props: [
                "state": .string("failed"),
                "output": .string("last-known-output"),
                "error": .string("boom"),
            ]
        )
        store.applyEvent(.snapshot(DevToolsSnapshot(
            runId: "run-1",
            frameNo: 10,
            seq: 10,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: [node])
        )))
        store.selectNode(5)
        store.applyEvent(.snapshot(DevToolsSnapshot(
            runId: "run-1",
            frameNo: 11,
            seq: 11,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: [])
        )))

        XCTAssertTrue(store.isGhost)
        XCTAssertEqual(store.selectedGhostRecord?.unmountedFrameNo, 11)
        XCTAssertEqual(store.selectedNode?.props["output"], .string("last-known-output"))
        XCTAssertEqual(store.selectedNode?.props["error"], .string("boom"))

        var tab: InspectorTab = .output
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let inspected = try NodeInspectorView(store: store, selectedTab: binding).inspect()

        XCTAssertNoThrow(try inspected.find(text: "<GhostedTask>"))
        XCTAssertNoThrow(try inspected.find(text: "This node is no longer in the running tree (unmounted at frame 11)."))
    }

    // MARK: - Error banner

    func testErrorBannerVisibleForFailedTask() throws {
        let node = makeTaskNode(state: "failed", props: ["error": .string("Timeout exceeded")])
        let banner = NodeErrorBanner(node: node, runSupportsRetry: true, onRetry: { _ in })
        let inspected = try banner.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Task Failed"))
        XCTAssertNoThrow(try inspected.find(text: "Timeout exceeded"))
    }

    func testErrorBannerHiddenForRunningTask() throws {
        let node = makeTaskNode(state: "running")
        let banner = NodeErrorBanner(node: node, runSupportsRetry: true, onRetry: { _ in })
        let inspected = try banner.inspect()
        XCTAssertThrowsError(try inspected.find(text: "Task Failed"))
    }

    func testRetryButtonCallsStore() throws {
        var retriedNodeId: String?
        let node = makeTaskNode(state: "failed")
        let banner = NodeErrorBanner(node: node, runSupportsRetry: true, onRetry: { nodeId in
            retriedNodeId = nodeId
        })
        try banner.inspect().find(button: "Retry").tap()
        XCTAssertEqual(retriedNodeId, "task:review:0")
    }

    func testRetryButtonDisabledWhenNotSupported() throws {
        let node = makeTaskNode(state: "failed")
        let banner = NodeErrorBanner(node: node, runSupportsRetry: false, onRetry: { _ in })
        let button = try banner.inspect().find(button: "Retry")
        XCTAssertTrue(try button.isDisabled())
    }

    // MARK: - Tab switcher

    func testTabSwitcherShowsAllTabs() throws {
        var tab: InspectorTab = .output
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let switcher = InspectorTabSwitcher(selectedTab: binding, availableTabs: InspectorTab.allCases)
        let inspected = try switcher.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Output"))
        XCTAssertNoThrow(try inspected.find(text: "Diff"))
        XCTAssertNoThrow(try inspected.find(text: "Logs"))
    }

    // MARK: - Ghost + Error simultaneous

    func testGhostAndErrorBothVisible() throws {
        let store = makeStore()
        let node = makeTaskNode(state: "failed", props: ["error": .string("Crashed")])
        let snapshot = DevToolsSnapshot(runId: "run-1", frameNo: 1, seq: 1,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: [node]))
        store.applyEvent(.snapshot(snapshot))
        store.selectNode(1)

        let removeSnapshot = DevToolsSnapshot(runId: "run-1", frameNo: 2, seq: 2,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: []))
        store.applyEvent(.snapshot(removeSnapshot))

        XCTAssertTrue(store.isGhost)
        XCTAssertNotNil(store.selectedNode)

        let selectedNode = store.selectedNode!
        let state: String
        if case .string(let s) = selectedNode.props["state"] { state = s } else { state = "pending" }
        XCTAssertEqual(state, "failed")
    }

    // MARK: - Store clearSelection

    func testClearSelectionDeselectsAndClearsGhost() {
        let store = makeStore()
        let node = makeTaskNode()
        let snapshot = DevToolsSnapshot(runId: "run-1", frameNo: 1, seq: 1,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: [node]))
        store.applyEvent(.snapshot(snapshot))
        store.selectNode(1)

        store.clearSelection()
        XCTAssertNil(store.selectedNodeId)
        XCTAssertFalse(store.isGhost)
    }

    func testNodeSelectionUpdatesInspectorWithinOneFrameBudget() throws {
        let store = makeStore()
        let first = makeTaskNode(id: 1, name: "TaskOne", nodeId: "task:1")
        let second = makeTaskNode(id: 2, name: "TaskTwo", nodeId: "task:2")
        let snapshot = DevToolsSnapshot(
            runId: "run-1",
            frameNo: 1,
            seq: 1,
            root: DevToolsNode(id: 0, type: .workflow, name: "Root", children: [first, second])
        )
        store.applyEvent(.snapshot(snapshot))
        store.selectNode(1)

        var tab: InspectorTab = .logs
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let view = NodeInspectorView(store: store, selectedTab: binding)
        _ = try view.inspect()

        let start = CFAbsoluteTimeGetCurrent()
        store.selectNode(2)
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "<TaskTwo>"))

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(
            elapsedMs,
            16.7,
            "Inspector selection handoff budget is one frame (16.7ms @60fps)."
        )
    }
}
