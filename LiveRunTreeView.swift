import SwiftUI
import os
#if os(macOS)
import AppKit
#endif

struct LiveRunTreeView: View {
    @ObservedObject var store: LiveRunDevToolsStore
    var onInspectNode: ((Int) -> Void)?

    @State private var expandedIds: Set<Int> = []
    @State private var userCollapsedIds: Set<Int> = []
    @State private var searchQuery: String = ""
    @State private var errorIndex = AncestorErrorIndex(root: nil, seq: 0)
    @State private var searchIndex = TreeSearchIndex(root: nil, query: "")
    @State private var lastProcessedSeq: Int = -1

    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().background(Theme.border)
            treeContent
        }
        .background(Theme.surface1)
        .onChange(of: store.seq) { newSeq in
            rebuildIndices(seq: newSeq)
        }
        .onChange(of: store.selectedNodeId) { _, newSelectedNodeId in
            guard let newSelectedNodeId else { return }
            expandPathToSelectedNode(newSelectedNodeId)
        }
        .onChange(of: searchQuery) { _ in
            searchIndex = TreeSearchIndex(root: store.tree, query: searchQuery)
        }
        .onAppear {
            rebuildIndices(seq: store.seq)
            if let selectedNodeId = store.selectedNodeId {
                expandPathToSelectedNode(selectedNodeId)
            }
        }
        .accessibilityIdentifier("liveRunTree.container")
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.textTertiary)
                .font(.system(size: 12))

            TextField("Search tree…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .focused($isSearchFieldFocused)
                .onKeyPress(.escape) {
                    if !searchQuery.isEmpty {
                        searchQuery = ""
                        return .handled
                    }
                    return .ignored
                }
                .accessibilityIdentifier("tree.search")

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textTertiary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("tree.search.clear")
            }

            Button(action: { isSearchFieldFocused = true }) {
                EmptyView()
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface2)
        .accessibilityIdentifier("tree.search.container")
    }

    // MARK: - Tree Content

    @ViewBuilder
    private var treeContent: some View {
        if let tree = store.tree {
            let visible = visibleTreeRows(root: tree, expandedIds: expandedIds)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible, id: \.id) { node in
                            let nodeId = node.id
                            TreeRowView(
                                node: node,
                                isSelected: store.selectedNodeId == nodeId,
                                isExpanded: expandedIds.contains(nodeId),
                                hasChildren: !node.children.isEmpty,
                                hasFailedDescendant: errorIndex.hasFailedDescendant(nodeId),
                                failedDescendantCount: errorIndex.failedDescendantCount(nodeId),
                                isDimmed: searchIndex.isDimmed(nodeId),
                                isHighlighted: !searchQuery.isEmpty && searchIndex.isMatch(nodeId),
                                depth: node.depth,
                                onSelect: {
                                    store.selectNode(nodeId)
                                    onInspectNode?(nodeId)
                                },
                                onToggleExpand: {
                                    toggleExpanded(nodeId)
                                }
                            )
                            .id(nodeId)
                            .transition(
                                reduceMotion
                                    ? .identity
                                    : .asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .leading))
                                            .animation(.easeOut(duration: 0.12)),
                                        removal: .opacity.animation(.easeIn(duration: 0.12))
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("liveRunTree.scroll")
                .onKeyPress(.upArrow) { handleKeyAction(.moveUp, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.downArrow) { handleKeyAction(.moveDown, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.leftArrow) { handleKeyAction(.collapse, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.rightArrow) { handleKeyAction(.expand, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.return) { handleKeyAction(.focusInspector, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.escape) { handleKeyAction(.clearSearch, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.home) { handleKeyAction(.moveToFirst, visibleRows: visible, proxy: proxy) }
                .onKeyPress(.end) { handleKeyAction(.moveToLast, visibleRows: visible, proxy: proxy) }
                .onKeyPress("f") {
                    if NSEvent.modifierFlags.contains(.command) {
                        return handleKeyAction(.focusSearch, visibleRows: visible, proxy: proxy)
                    }
                    return .ignored
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if case .error = store.connectionState {
                Text("Tree unavailable.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Button("Retry") {
                    if let runId = store.runId {
                        store.connect(runId: runId)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
                .font(.system(size: 13, weight: .medium))
            } else {
                Text("Waiting for tree data…")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("tree.empty")
    }

    // MARK: - Expand / Collapse

    private func toggleExpanded(_ nodeId: Int) {
        if expandedIds.contains(nodeId) {
            expandedIds.remove(nodeId)
            userCollapsedIds.insert(nodeId)
        } else {
            expandedIds.insert(nodeId)
            userCollapsedIds.remove(nodeId)
        }
    }

    private func autoExpandRunningPaths(root: DevToolsNode) {
        expandedIds.formUnion(runningPathExpansionIDs(root: root, userCollapsedIds: userCollapsedIds))
    }

    private func expandPathToSelectedNode(_ nodeId: Int) {
        guard let tree = store.tree else { return }
        var path: [Int] = []
        guard collectPathToNode(nodeId, in: tree, path: &path) else { return }

        let idsToExpand = Set(path.dropLast())
        expandedIds.formUnion(idsToExpand)
        userCollapsedIds.subtract(idsToExpand)
    }

    private func collectPathToNode(_ targetId: Int, in node: DevToolsNode, path: inout [Int]) -> Bool {
        path.append(node.id)
        if node.id == targetId {
            return true
        }

        for child in node.children {
            if collectPathToNode(targetId, in: child, path: &path) {
                return true
            }
        }

        path.removeLast()
        return false
    }

    // MARK: - Index Rebuilding

    private func rebuildIndices(seq: Int) {
        guard seq != lastProcessedSeq else { return }
        lastProcessedSeq = seq

        let signpostState = AppLogger.performance.beginInterval("treeIndexRebuild")
        errorIndex = AncestorErrorIndex(root: store.tree, seq: seq)
        searchIndex = TreeSearchIndex(root: store.tree, query: searchQuery)
        AppLogger.performance.endInterval("treeIndexRebuild", signpostState)

        if let tree = store.tree {
            autoExpandRunningPaths(root: tree)
            logUnknownStates(root: tree)
        }

        AppLogger.ui.debug("Tree indices rebuilt", metadata: [
            "seq": String(seq),
            "row_count": String(store.tree.map { countNodes($0) } ?? 0),
        ])
    }

    private func countNodes(_ node: DevToolsNode) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    private func logUnknownStates(root: DevToolsNode) {
        var unknownCount = 0
        countUnknownStates(node: root, total: &unknownCount)
        if unknownCount > 0 {
            AppLogger.ui.warning("Tree nodes missing state", metadata: [
                "count": String(unknownCount),
                "seq": String(lastProcessedSeq),
            ])
        }
    }

    private func countUnknownStates(node: DevToolsNode, total: inout Int) {
        if extractState(from: node) == .unknown {
            total += 1
        }
        for child in node.children {
            countUnknownStates(node: child, total: &total)
        }
    }

    // MARK: - Keyboard

    private func handleKeyAction(
        _ action: TreeKeyboardHandler.Action,
        visibleRows: [DevToolsNode],
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let result = TreeKeyboardHandler.handle(
            action: action,
            selectedId: store.selectedNodeId,
            visibleRows: visibleRows,
            expandedIds: expandedIds,
            root: store.tree
        )

        if let newId = result.selectedId, newId != store.selectedNodeId {
            store.selectNode(newId)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                proxy.scrollTo(newId, anchor: .center)
            }
        }

        if let change = result.expandedChange {
            switch change {
            case .collapse(let id):
                expandedIds.remove(id)
                userCollapsedIds.insert(id)
            case .expand(let id):
                expandedIds.insert(id)
                userCollapsedIds.remove(id)
            }
        }

        if let focus = result.focusChange {
            switch focus {
            case .inspector:
                if let selectedId = store.selectedNodeId {
                    onInspectNode?(selectedId)
                }
            case .search:
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
                }
            case .clearSearch:
                if !searchQuery.isEmpty {
                    searchQuery = ""
                } else {
                    store.selectNode(nil)
                }
            }
        }

        return .handled
    }
}

func visibleTreeRows(root: DevToolsNode, expandedIds: Set<Int>) -> [DevToolsNode] {
    var rows: [DevToolsNode] = []
    collectVisibleRows(node: root, expandedIds: expandedIds, rows: &rows)
    return rows
}

private func collectVisibleRows(node: DevToolsNode, expandedIds: Set<Int>, rows: inout [DevToolsNode]) {
    rows.append(node)
    if expandedIds.contains(node.id) {
        for child in node.children {
            collectVisibleRows(node: child, expandedIds: expandedIds, rows: &rows)
        }
    }
}

func runningPathExpansionIDs(root: DevToolsNode, userCollapsedIds: Set<Int>) -> Set<Int> {
    var ids = Set<Int>()
    collectRunningPathExpansionIDs(node: root, currentPath: [], ids: &ids)
    return ids.subtracting(userCollapsedIds)
}

private func collectRunningPathExpansionIDs(
    node: DevToolsNode,
    currentPath: [Int],
    ids: inout Set<Int>
) {
    if extractState(from: node) == .running {
        ids.formUnion(currentPath)
        ids.insert(node.id)
    }

    let newPath = currentPath + [node.id]
    for child in node.children {
        collectRunningPathExpansionIDs(node: child, currentPath: newPath, ids: &ids)
    }
}

struct LiveRunTreeUITestHarnessView: View {
    let runId: String
    var onClose: () -> Void

    private let defaultSelectedNodeId = 5

    @StateObject private var store: LiveRunDevToolsStore
    @StateObject private var smithers: SmithersClient
    @StateObject private var fixtureLogsStreamProvider: UITestFixtureChatStreamProvider

    @State private var selectedTab: InspectorTab = .logs
    @State private var showRewindConfirmation = false
    @State private var pendingRewindFrameNo: Int?
    @State private var rewindWarning: String?
    @State private var startedAt = Date()

    private var logsStreamProvider: ChatStreamProviding {
        UITestSupport.isEnabled ? fixtureLogsStreamProvider : smithers
    }

    init(runId: String, onClose: @escaping () -> Void = {}) {
        self.runId = runId
        self.onClose = onClose

        let environment = ProcessInfo.processInfo.environment
        let finishedRun = environment["SMITHERS_GUI_UITEST_TREE_FINISHED"] == "1"
        let snapshots = Self.makeFixtureSnapshots(runId: runId, finishedRun: finishedRun)
        let streamEnabled: Bool
        if let streamOverride = environment["SMITHERS_GUI_UITEST_TREE_STREAM"]?.lowercased() {
            streamEnabled = streamOverride != "0" && streamOverride != "false"
        } else {
            streamEnabled = !finishedRun
        }
        let rewindErrorMode = ProcessInfo.processInfo.environment["SMITHERS_GUI_UITEST_REWIND_ERROR"]
        let provider = LiveRunFixtureDevToolsProvider(
            runId: runId,
            snapshots: snapshots,
            streamEnabled: streamEnabled,
            rewindErrorMode: rewindErrorMode
        )
        _store = StateObject(wrappedValue: LiveRunDevToolsStore(streamProvider: provider))
        _smithers = StateObject(wrappedValue: SmithersClient())
        _fixtureLogsStreamProvider = StateObject(wrappedValue: UITestFixtureChatStreamProvider())
    }

    var body: some View {
        VStack(spacing: 0) {
            LiveRunHeaderView(
                status: store.runStatus == .unknown ? .running : store.runStatus,
                workflowName: "Live Run Tree",
                runId: runId,
                startedAt: startedAt,
                heartbeatMs: 1_000,
                lastEventAt: store.lastEventAt,
                lastSeq: store.seq,
                onCancel: nil,
                onHijack: nil,
                onOpenLogs: nil,
                onRefresh: { store.returnToLive() }
            )

            FrameScrubberView(store: store) { frameNo in
                pendingRewindFrameNo = frameNo
                showRewindConfirmation = true
            }

            if let rewindWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                    Text(rewindWarning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Dismiss") {
                        self.rewindWarning = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.warning.opacity(0.1))
                .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
                .accessibilityIdentifier("scrubber.warning")
            }

            HSplitView {
                LiveRunTreeView(store: store) { id in
                    store.selectNode(id)
                }
                .frame(minWidth: 340)

                NodeInspectorView(
                    store: store,
                    selectedTab: $selectedTab,
                    outputProvider: smithers,
                    logsStreamProvider: logsStreamProvider
                )
                    .frame(minWidth: 360)
            }
            .historicalOverlay(active: store.mode.isHistorical)
            .overlay(alignment: .topLeading) {
                if store.mode.isHistorical {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier("historical.overlay")
                }
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("view.liveRunTreeHarness")
        .onAppear {
            startedAt = Date()
            store.connect(runId: runId)
            ensureDefaultSelection()
        }
        .onChange(of: store.seq) { _, _ in
            ensureDefaultSelection()
        }
        .onDisappear {
            store.disconnect()
        }
        .onChange(of: store.isRewindEligible) { _, eligible in
            if !eligible, showRewindConfirmation {
                showRewindConfirmation = false
                rewindWarning = "Run finished before confirmation. Rewind is now unavailable."
            }
        }
        .rewindConfirmationDialog(isPresented: $showRewindConfirmation, frameNo: pendingRewindFrameNo) { frameNo in
            pendingRewindFrameNo = nil
            Task {
                await store.rewind(to: frameNo, confirm: true)
            }
        }
    }

    private func ensureDefaultSelection() {
        guard store.selectedNodeId == nil else { return }
        guard store.tree?.findNode(byId: defaultSelectedNodeId) != nil else { return }
        store.selectNode(defaultSelectedNodeId)
    }

    private static func makeFixtureSnapshots(runId: String, finishedRun: Bool) -> [DevToolsSnapshot] {
        let now = Date().timeIntervalSince1970 * 1000

        func task(
            id: Int,
            name: String,
            depth: Int,
            state: String,
            nodeId: String,
            label: String,
            agent: String? = nil,
            iteration: Int? = nil,
            startedAtOffsetMs: Double,
            finishedAtOffsetMs: Double? = nil
        ) -> DevToolsNode {
            var props: [String: JSONValue] = [
                "state": .string(state),
                "startedAtMs": .number(now + startedAtOffsetMs),
            ]
            if let finishedAtOffsetMs {
                props["finishedAtMs"] = .number(now + finishedAtOffsetMs)
            }
            if state == "failed" {
                props["error"] = .string("Fixture failure")
            }

            return DevToolsNode(
                id: id,
                type: .task,
                name: name,
                props: props,
                task: DevToolsTaskInfo(
                    nodeId: nodeId,
                    kind: "agent",
                    agent: agent,
                    label: label,
                    outputTableName: nil,
                    iteration: iteration
                ),
                children: [],
                depth: depth
            )
        }

        func rootSnapshot(seq: Int, review0State: String, review1State: String, mergeState: String) -> DevToolsSnapshot {
            let fetch = task(
                id: 3,
                name: "Task",
                depth: 2,
                state: "finished",
                nodeId: "task:fetch",
                label: "Fetch",
                startedAtOffsetMs: -9_000,
                finishedAtOffsetMs: -6_000
            )
            let review0 = task(
                id: 5,
                name: "Task",
                depth: 3,
                state: review0State,
                nodeId: "task:review:0",
                label: "Review Alpha",
                agent: "claude-opus-4-7",
                iteration: 1,
                startedAtOffsetMs: -5_000,
                finishedAtOffsetMs: review0State == "finished" ? -2_000 : nil
            )
            let review1 = task(
                id: 6,
                name: "Task",
                depth: 3,
                state: review1State,
                nodeId: "task:review:1",
                label: "Review Beta",
                agent: "claude-opus-4-7",
                iteration: 1,
                startedAtOffsetMs: -5_000,
                finishedAtOffsetMs: review1State == "finished" ? -2_000 : nil
            )
            let merge = task(
                id: 7,
                name: "Task",
                depth: 2,
                state: mergeState,
                nodeId: "task:merge",
                label: "Merge",
                startedAtOffsetMs: -2_000,
                finishedAtOffsetMs: mergeState == "finished" ? -500 : nil
            )

            let parallel = DevToolsNode(
                id: 4,
                type: .parallel,
                name: "Parallel",
                props: ["state": .string(review0State == "running" || mergeState == "running" ? "running" : "finished")],
                children: [review0, review1],
                depth: 2
            )
            let sequence = DevToolsNode(
                id: 2,
                type: .sequence,
                name: "Sequence",
                props: ["state": .string(mergeState == "finished" ? "finished" : "running")],
                children: [fetch, parallel, merge],
                depth: 1
            )

            let root = DevToolsNode(
                id: 1,
                type: .workflow,
                name: "Workflow",
                props: ["state": .string(mergeState == "finished" ? "finished" : "running")],
                children: [sequence],
                depth: 0
            )

            return DevToolsSnapshot(runId: runId, frameNo: seq, seq: seq, root: root)
        }

        return [
            rootSnapshot(seq: 1, review0State: "running", review1State: "failed", mergeState: "pending"),
            rootSnapshot(seq: 2, review0State: "finished", review1State: "failed", mergeState: "running"),
            rootSnapshot(
                seq: 3,
                review0State: "finished",
                review1State: "finished",
                mergeState: finishedRun ? "finished" : "running"
            ),
        ]
    }
}

private final class LiveRunFixtureDevToolsProvider: DevToolsStreamProvider, @unchecked Sendable {
    private let runId: String
    private let snapshotsByFrame: [Int: DevToolsSnapshot]
    private let frameOrder: [Int]
    private let streamEnabled: Bool
    private let rewindErrorMode: String?

    private let lock = NSLock()
    private var currentFrameNo: Int
    private var nextSeq: Int
    private var jumpInFlight = false
    private var emittedNetworkError = false

    init(
        runId: String,
        snapshots: [DevToolsSnapshot],
        streamEnabled: Bool,
        rewindErrorMode: String?
    ) {
        self.runId = runId
        self.snapshotsByFrame = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.frameNo, $0) })
        self.frameOrder = snapshots.map(\.frameNo).sorted()
        self.streamEnabled = streamEnabled
        self.rewindErrorMode = rewindErrorMode?.lowercased()
        self.currentFrameNo = frameOrder.last ?? 0
        self.nextSeq = (frameOrder.max() ?? 0) + 1
    }

    func streamDevTools(runId: String, fromSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard runId == self.runId else {
                    continuation.finish(throwing: DevToolsClientError.runNotFound(runId))
                    return
                }

                if let baseline = self.snapshotForCurrentFrame() {
                    continuation.yield(.snapshot(baseline))
                }

                guard self.streamEnabled, !self.frameOrder.isEmpty else {
                    continuation.finish()
                    return
                }

                var index = self.frameOrder.firstIndex(of: self.readCurrentFrameNo()) ?? 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    index = (index + 1) % self.frameOrder.count
                    let frameNo = self.frameOrder[index]
                    self.writeCurrentFrameNo(frameNo)

                    if let snapshot = self.snapshot(frameNo: frameNo) {
                        continuation.yield(.snapshot(snapshot))
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func getDevToolsSnapshot(runId: String, frameNo: Int?) async throws -> DevToolsSnapshot {
        guard runId == self.runId else {
            throw DevToolsClientError.runNotFound(runId)
        }

        let targetFrameNo = frameNo ?? readCurrentFrameNo()
        guard snapshotsByFrame[targetFrameNo] != nil else {
            throw DevToolsClientError.frameOutOfRange(targetFrameNo)
        }
        return snapshot(frameNo: targetFrameNo) ?? DevToolsSnapshot(
            runId: runId,
            frameNo: targetFrameNo,
            seq: nextSequence(),
            root: DevToolsNode(id: 1, type: .workflow, name: "Workflow")
        )
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult {
        guard runId == self.runId else {
            throw DevToolsClientError.runNotFound(runId)
        }
        guard confirm else {
            throw DevToolsClientError.confirmationRequired
        }

        lock.lock()
        if jumpInFlight {
            lock.unlock()
            throw DevToolsClientError.busy
        }
        jumpInFlight = true
        lock.unlock()

        defer {
            lock.lock()
            jumpInFlight = false
            lock.unlock()
        }

        switch rewindErrorMode {
        case "busy":
            throw DevToolsClientError.busy
        case "unsupported":
            throw DevToolsClientError.unsupportedSandbox("This sandbox type does not support rewind.")
        case "network":
            lock.lock()
            let shouldThrow = !emittedNetworkError
            if shouldThrow {
                emittedNetworkError = true
            }
            lock.unlock()
            if shouldThrow {
                throw URLError(.notConnectedToInternet)
            }
        default:
            break
        }

        guard snapshotsByFrame[frameNo] != nil else {
            throw DevToolsClientError.frameOutOfRange(frameNo)
        }

        writeCurrentFrameNo(frameNo)

        return DevToolsJumpResult(
            ok: true,
            newFrameNo: frameNo,
            revertedSandboxes: 1,
            deletedFrames: 1,
            deletedAttempts: 1,
            invalidatedDiffs: 1,
            durationMs: 20
        )
    }

    private func snapshotForCurrentFrame() -> DevToolsSnapshot? {
        snapshot(frameNo: readCurrentFrameNo())
    }

    private func snapshot(frameNo: Int) -> DevToolsSnapshot? {
        guard let template = snapshotsByFrame[frameNo] else { return nil }
        return DevToolsSnapshot(
            runId: template.runId,
            frameNo: frameNo,
            seq: nextSequence(),
            root: template.root
        )
    }

    private func readCurrentFrameNo() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentFrameNo
    }

    private func writeCurrentFrameNo(_ frameNo: Int) {
        lock.lock()
        currentFrameNo = frameNo
        lock.unlock()
    }

    private func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = nextSeq
        nextSeq += 1
        return value
    }
}

private final class UITestFixtureChatStreamProvider: ObservableObject, ChatStreamProviding {
    func streamChat(runId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let blocks = [
                ChatBlock(
                    id: "fixture-assistant-1",
                    runId: runId,
                    nodeId: "task:review:0",
                    attempt: 0,
                    role: "assistant",
                    content: "Assistant fixture message.",
                    timestampMs: now
                ),
                ChatBlock(
                    id: "fixture-stderr-1",
                    runId: runId,
                    nodeId: "task:review:0",
                    attempt: 0,
                    role: "stderr",
                    content: "warning: foo",
                    timestampMs: now + 500
                ),
                ChatBlock(
                    id: "fixture-tool-result-1",
                    runId: runId,
                    nodeId: "task:review:0",
                    attempt: 0,
                    role: "tool_result",
                    content: "Ran review script successfully",
                    timestampMs: now + 1_000
                ),
            ]

            let task = Task {
                for (index, block) in blocks.enumerated() {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    if index > 0 {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }

                    guard let data = try? JSONEncoder().encode(block),
                          let payload = String(data: data, encoding: .utf8) else {
                        continue
                    }
                    continuation.yield(SSEEvent(event: "message", data: payload, runId: runId))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
