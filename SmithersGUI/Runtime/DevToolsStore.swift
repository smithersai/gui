import Foundation
import os

// MARK: - ConnectionState

enum DevToolsConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case streaming
    case error(DevToolsClientError)

    var isConnected: Bool {
        if case .streaming = self { return true }
        return false
    }
}

// MARK: - ReconnectBackoff

struct ReconnectBackoff: Sendable {
    private(set) var attempt: Int = 0
    static let initialDelay: TimeInterval = 1.0
    static let maxDelay: TimeInterval = 30.0
    static let multiplier: Double = 2.0

    var currentDelay: TimeInterval {
        guard attempt > 0 else { return Self.initialDelay }
        let delay = Self.initialDelay * pow(Self.multiplier, Double(attempt - 1))
        return min(delay, Self.maxDelay)
    }

    mutating func recordFailure() {
        attempt += 1
    }

    mutating func reset() {
        attempt = 0
    }
}

// MARK: - DevToolsStreamProvider

@MainActor
protocol DevToolsStreamProvider: Sendable {
    func streamDevTools(runId: String, afterSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error>
    func getDevToolsSnapshot(runId: String, frameNo: Int?) async throws -> DevToolsSnapshot
    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult
}

enum LiveRunDevToolsMode: Equatable, Sendable {
    case live
    case historical(frameNo: Int)

    var isHistorical: Bool {
        if case .historical = self { return true }
        return false
    }

    var historicalFrameNo: Int? {
        if case .historical(let frameNo) = self { return frameNo }
        return nil
    }
}

struct GhostNodeRecord: Equatable, Sendable {
    let key: String
    let node: DevToolsNode
    let mountedFrameNo: Int
    let unmountedFrameNo: Int
    let unmountedSeq: Int
    let capturedAt: Date

    static func == (lhs: GhostNodeRecord, rhs: GhostNodeRecord) -> Bool {
        lhs.key == rhs.key &&
            lhs.node.id == rhs.node.id &&
            lhs.mountedFrameNo == rhs.mountedFrameNo &&
            lhs.unmountedFrameNo == rhs.unmountedFrameNo &&
            lhs.unmountedSeq == rhs.unmountedSeq
    }
}

// MARK: - DevToolsStore

@MainActor
class DevToolsStore: ObservableObject {
    static let staleBannerDelaySeconds: TimeInterval = 2.0
    static let defaultGhostNodeCap: Int = 256

    @Published private(set) var tree: DevToolsNode?
    @Published private(set) var seq: Int = 0
    @Published private(set) var lastEventAt: Date?
    @Published var selectedNodeId: Int?
    @Published private(set) var isGhost: Bool = false
    @Published private(set) var connectionState: DevToolsConnectionState = .disconnected
    @Published private(set) var staleSince: Date?
    @Published private(set) var isStaleBannerVisible: Bool = false
    @Published private(set) var ghostNodes: [String: GhostNodeRecord] = [:]

    @Published private(set) var mode: LiveRunDevToolsMode = .live
    @Published private(set) var latestFrameNo: Int = 0
    @Published private(set) var scrubError: DevToolsClientError?
    @Published private(set) var rewindError: DevToolsClientError?
    @Published private(set) var rewindInFlight: Bool = false

    /// Count of nodes currently in `running` state in the displayed tree. Recomputed
    /// whenever `tree` changes. In historical mode this reflects what was in-flight
    /// at the scrubbed frame; in live mode it reflects what's in-flight right now.
    @Published private(set) var runningNodeCount: Int = 0

    /// `nodeId` strings (the ones stored on `DevToolsTaskInfo.nodeId`) of task
    /// nodes currently in `running` state. Used by the tree view to auto-expand
    /// the ancestor path when the scrubber moves to a new frame.
    @Published private(set) var runningNodeIds: Set<String> = []

    @Published private(set) var eventsApplied: Int = 0
    @Published private(set) var reconnectCount: Int = 0
    @Published private(set) var decodeErrorCount: Int = 0

    @Published private(set) var runSupportsRetry: Bool = true
    @Published private(set) var runStatus: RunStatus = .unknown
    @Published private(set) var runStateView: RunStateView?
    @Published private(set) var lastToastMessage: String?
    @Published private(set) var lastAuditRowId: String?

    var runId: String?

    private var streamTask: Task<Void, Never>?
    private var staleBannerTask: Task<Void, Never>?
    private var backoff = ReconnectBackoff()
    private let streamProvider: DevToolsStreamProvider?
    private var shouldReconnect: Bool = false
    private var stateRunId: String?
    private var selectedNodeGhostKey: String?
    private var lastSeqSeenByRunId: [String: Int] = [:]
    private var mountedFrameByGhostKey: [String: Int] = [:]
    private var ghostEvictionOrder: [String] = []
    private let ghostNodeCap: Int

    private var liveTree: DevToolsNode?
    private var liveSeq: Int = 0
    private var liveLatestFrameNo: Int = 0
    private var bufferedLiveEvents: Int = 0
    private var awaitingSnapshotAfterGapResync = false

    private let toastSink: (String) -> Void

    var heartbeatAgeMs: Int {
        guard let lastEventAt else { return Int.max }
        return Int(Date().timeIntervalSince(lastEventAt) * 1000)
    }

    var selectedNode: DevToolsNode? {
        if let selectedNodeId, let found = tree?.findNode(byId: selectedNodeId) {
            return found
        }
        if isGhost, let selectedNodeGhostKey, let ghost = ghostNodes[selectedNodeGhostKey] {
            return ghost.node
        }
        return nil
    }

    var selectedGhostRecord: GhostNodeRecord? {
        guard isGhost, let selectedNodeGhostKey else { return nil }
        return ghostNodes[selectedNodeGhostKey]
    }

    var isRunFinished: Bool {
        switch runStatus {
        case .finished, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    var isRewindEligible: Bool {
        mode.isHistorical && !isRunFinished && !rewindInFlight
    }

    var displayedFrameNo: Int {
        switch mode {
        case .live:
            return latestFrameNo
        case .historical(let frameNo):
            return frameNo
        }
    }

    var bufferedLiveEventCount: Int {
        bufferedLiveEvents
    }

    init(
        streamProvider: DevToolsStreamProvider? = nil,
        ghostNodeCap: Int? = nil,
        toastSink: @escaping (String) -> Void = { message in
            AppLogger.ui.info("Live Run toast", metadata: [
                "message_length": String(message.count),
            ])
        }
    ) {
        self.streamProvider = streamProvider
        self.ghostNodeCap = max(1, ghostNodeCap ?? Self.resolvedGhostNodeCap())
        self.toastSink = toastSink
    }

    // MARK: - Connect / Disconnect

    func connect(runId: String) {
        streamTask?.cancel()
        streamTask = nil
        staleBannerTask?.cancel()
        staleBannerTask = nil

        let preservingExistingRunState = stateRunId == runId
        self.runId = runId
        shouldReconnect = true
        connectionState = .connecting
        backoff.reset()

        mode = .live
        scrubError = nil
        rewindError = nil
        rewindInFlight = false
        bufferedLiveEvents = 0
        staleSince = nil
        isStaleBannerVisible = false
        awaitingSnapshotAfterGapResync = false
        lastToastMessage = nil
        lastAuditRowId = nil

        if !preservingExistingRunState {
            resetForNewRun(runId: runId)
        } else {
            syncDisplayedTreeWithLive()
            updateGhostState()
        }

        let resumeSeq = preservingExistingRunState ? lastSeenSeq(for: runId) : nil

        AppLogger.network.info("DevTools connect", metadata: [
            "run_id": runId,
            "after_seq": resumeSeq.map(String.init) ?? "nil",
            "preserved_state": String(preservingExistingRunState),
        ])

        startStream(runId: runId, afterSeq: resumeSeq)
    }

    func disconnect() {
        shouldReconnect = false
        streamTask?.cancel()
        streamTask = nil
        staleBannerTask?.cancel()
        staleBannerTask = nil

        if let runId {
            AppLogger.network.info("DevTools disconnect", metadata: [
                "run_id": runId,
                "events_applied": String(eventsApplied),
            ])
        }

        connectionState = .disconnected
        staleSince = nil
        isStaleBannerVisible = false
        runId = nil
    }

    // MARK: - Event Handling (pure, unit-testable)

    func applyEvent(_ event: DevToolsEvent) {
        let eventType: String
        switch event {
        case .snapshot(let snapshot):
            eventType = "snapshot"
            applySnapshot(snapshot)
        case .delta(let delta):
            eventType = "delta"
            applyDeltaEvent(delta)
        case .gapResync(let gapResync):
            eventType = "gap_resync"
            applyGapResync(gapResync)
        }

        AppLogger.network.debug("DevTools applyEvent", metadata: [
            "run_id": runId ?? "",
            "event_type": eventType,
            "seq": String(seq),
            "mode": mode.isHistorical ? "historical" : "live",
        ])

        lastEventAt = Date()
        eventsApplied += 1
        markStreamHealthy()

        if mode.isHistorical {
            bufferedLiveEvents += 1
        } else {
            updateGhostState()
        }
    }

    func applyGapResync(_ gapResync: DevToolsGapResync) {
        let preservedTree = tree?.deepCopy()
        let preservedSeq = seq
        liveTree = nil
        liveSeq = gapResync.toSeq
        if let runId {
            lastSeqSeenByRunId[runId] = gapResync.toSeq
        }
        awaitingSnapshotAfterGapResync = true
        if case .live = mode {
            // Keep the currently displayed tree until the server follows up with
            // a snapshot, so reconnect/resync does not blank the UI.
            tree = preservedTree
            seq = preservedSeq
            latestFrameNo = liveLatestFrameNo
        }

        AppLogger.network.warning("DevTools gap resync", metadata: [
            "run_id": runId ?? "",
            "from_seq": String(gapResync.fromSeq),
            "to_seq": String(gapResync.toSeq),
        ])
    }

    func applySnapshot(_ snapshot: DevToolsSnapshot) {
        guard applySnapshotToLiveState(snapshot) else { return }

        latestFrameNo = liveLatestFrameNo
        if case .live = mode {
            syncDisplayedTreeWithLive()
            updateGhostState()
        }
    }

    func applyDeltaEvent(_ delta: DevToolsDelta) {
        guard applyDeltaToLiveState(delta) else { return }

        latestFrameNo = max(latestFrameNo, liveLatestFrameNo)
        if case .live = mode {
            syncDisplayedTreeWithLive()
            updateGhostState()
        }
    }

    // MARK: - Historical Mode / Time Travel

    func scrubTo(frameNo: Int) async {
        guard let runId else {
            scrubError = .runNotFound("missing-run")
            return
        }
        guard let provider = streamProvider else {
            scrubError = .unknown("snapshot provider unavailable")
            return
        }

        let targetFrame = max(0, frameNo)
        let fromFrame = displayedFrameNo

        // Scrubbing to the latest frame exits historical mode.
        if latestFrameNo > 0, targetFrame >= latestFrameNo {
            AppLogger.ui.info("DevTools scrub", metadata: [
                "run_id": runId,
                "from_frame": String(fromFrame),
                "to_frame": String(targetFrame),
                "result": "return_live",
            ])
            returnToLive()
            return
        }

        mode = .historical(frameNo: targetFrame)

        let signpostState = AppLogger.performance.beginInterval("devtoolsScrub")
        do {
            let snapshot = try await provider.getDevToolsSnapshot(runId: runId, frameNo: targetFrame)
            tree = snapshot.root
            seq = snapshot.seq
            mode = .historical(frameNo: snapshot.frameNo)
            scrubError = nil
            refreshRunningState()
            updateGhostState()

            AppLogger.ui.info("DevTools scrub", metadata: [
                "run_id": runId,
                "from_frame": String(fromFrame),
                "to_frame": String(snapshot.frameNo),
                "result": "ok",
            ])
        } catch {
            let clientError = Self.toClientError(error)
            scrubError = clientError
            AppLogger.ui.info("DevTools scrub", metadata: [
                "run_id": runId,
                "from_frame": String(fromFrame),
                "to_frame": String(targetFrame),
                "result": "error",
                "error": clientError.displayMessage,
            ])
        }
        AppLogger.performance.endInterval("devtoolsScrub", signpostState)
    }

    func returnToLive() {
        guard mode.isHistorical else { return }

        mode = .live
        scrubError = nil
        bufferedLiveEvents = 0

        syncDisplayedTreeWithLive()
        updateGhostState()

        guard let runId, shouldReconnect else { return }
        requestResync(runId: runId)
    }

    func rewind(to frameNo: Int, confirm: Bool = false) async {
        guard confirm else { return }
        guard !rewindInFlight else { return }

        guard let runId else {
            rewindError = .runNotFound("missing-run")
            return
        }
        guard let provider = streamProvider else {
            rewindError = .unknown("rewind provider unavailable")
            return
        }
        guard !isRunFinished else {
            rewindError = .rewindFailed("Run is no longer live; rewind is unavailable.")
            return
        }
        guard mode.isHistorical else {
            rewindError = .confirmationRequired
            return
        }

        rewindInFlight = true
        rewindError = nil

        let signpostState = AppLogger.performance.beginInterval("devtoolsRewind")
        let startedAt = Date()

        do {
            let jumpResult = try await provider.jumpToFrame(runId: runId, frameNo: frameNo, confirm: true)
            let snapshot = try await provider.getDevToolsSnapshot(runId: runId, frameNo: nil)

            _ = applySnapshotToLiveState(snapshot)
            pruneGhostNodesForRewind(targetFrameNo: frameNo)
            mode = .live
            bufferedLiveEvents = 0
            scrubError = nil
            rewindError = nil
            syncDisplayedTreeWithLive()
            updateGhostState()

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastAuditRowId = jumpResult.auditRowId
            let toast = if let auditRowId = jumpResult.auditRowId, !auditRowId.isEmpty {
                "Rewound to frame \(frameNo). Audit: \(auditRowId)"
            } else {
                "Rewound to frame \(frameNo)."
            }
            lastToastMessage = toast
            toastSink(toast)

            AppLogger.ui.info("DevTools rewind confirm", metadata: [
                "run_id": runId,
                "to_frame": String(frameNo),
                "result": "ok",
                "duration_ms": String(durationMs),
            ])

            requestResync(runId: runId)
        } catch {
            let clientError = Self.toClientError(error)
            rewindError = clientError

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            AppLogger.ui.warning("DevTools rewind failed", metadata: [
                "run_id": runId,
                "to_frame": String(frameNo),
                "code": Self.errorCodeString(clientError),
                "duration_ms": String(durationMs),
            ])
        }

        rewindInFlight = false
        AppLogger.performance.endInterval("devtoolsRewind", signpostState)
    }

    func clearHistoricalError() {
        scrubError = nil
    }

    func clearRewindError() {
        rewindError = nil
    }

    func setRunStatus(_ status: RunStatus) {
        let previous = runStatus
        runStatus = status
        if isRunFinished, case .historical(let frameNo) = mode {
            mode = .historical(frameNo: frameNo)
        }
        if previous != status {
            AppLogger.state.info("DevTools runStatus changed", metadata: [
                "run_id": runId ?? "",
                "previous": String(describing: previous),
                "next": String(describing: status),
            ])
        }
    }

    // MARK: - Selection & Ghost

    func selectNode(_ nodeId: Int?) {
        let previousId = selectedNodeId
        selectedNodeId = nodeId
        if let nodeId, let node = tree?.findNode(byId: nodeId) {
            selectedNodeGhostKey = selectionKey(for: node)
        }
        updateGhostState()

        AppLogger.state.info("DevTools selectNode", metadata: [
            "run_id": runId ?? "",
            "node_id": nodeId.map(String.init) ?? "nil",
            "previous_node_id": previousId.map(String.init) ?? "nil",
            "is_ghost": String(isGhost),
            "ghost_key": selectedNodeGhostKey ?? "nil",
        ])
    }

    func clearSelection() {
        let previousId = selectedNodeId
        selectedNodeId = nil
        selectedNodeGhostKey = nil
        isGhost = false

        AppLogger.state.info("DevTools clearSelection", metadata: [
            "run_id": runId ?? "",
            "previous_node_id": previousId.map(String.init) ?? "nil",
        ])
    }

    func clearHistory() {
        ghostNodes.removeAll()
        ghostEvictionOrder.removeAll()
        mountedFrameByGhostKey.removeAll()
        updateGhostState()
    }

    func retryNode(nodeId: String) {
        guard runSupportsRetry else { return }
        AppLogger.ui.info("DevTools retryNode requested", metadata: [
            "node_id": nodeId,
        ])
    }

    private func updateGhostState() {
        guard let selectedNodeId else {
            isGhost = false
            selectedNodeGhostKey = nil
            return
        }

        if let activeNode = tree?.findNode(byId: selectedNodeId) {
            selectedNodeGhostKey = selectionKey(for: activeNode)
            isGhost = false
        } else if let selectedNodeGhostKey, ghostNodes[selectedNodeGhostKey] != nil {
            isGhost = true
        } else {
            isGhost = false
            self.selectedNodeId = nil
            self.selectedNodeGhostKey = nil
        }
    }

    func isGhostNode(_ node: DevToolsNode) -> Bool {
        guard let key = ghostMapKey(for: node) else { return false }
        return ghostNodes[key] != nil
    }

    func ghostRecord(for node: DevToolsNode) -> GhostNodeRecord? {
        guard let key = ghostMapKey(for: node) else { return nil }
        return ghostNodes[key]
    }

    // MARK: - Stream Management

    private func startStream(runId: String, afterSeq: Int?) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self, let provider = self.streamProvider else { return }

            let stream = provider.streamDevTools(runId: runId, afterSeq: afterSeq)

            do {
                await MainActor.run { self.connectionState = .connecting }

                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if case .connecting = self.connectionState {
                            self.connectionState = .streaming
                        }
                        self.applyEvent(event)
                    }
                }

                guard !Task.isCancelled else { return }
                self.handleStreamEnd(runId: runId)

            } catch {
                guard !Task.isCancelled else { return }
                self.handleStreamError(error, runId: runId)
            }
        }
    }

    private func handleStreamEnd(runId: String) {
        AppLogger.network.info("DevTools stream_end", metadata: [
            "run_id": runId,
            "should_reconnect": String(shouldReconnect),
            "events_applied": String(eventsApplied),
            "last_seq": String(liveSeq),
        ])
        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }
        markConnectionInterrupted()
        scheduleReconnect(runId: runId)
    }

    private func handleStreamError(_ error: Error, runId: String) {
        let clientError = Self.toClientError(error)
        if case .malformedEvent = clientError {
            decodeErrorCount += 1
        }

        AppLogger.error.error("DevTools stream error", metadata: [
            "run_id": runId,
            "error": clientError.displayMessage,
        ])

        connectionState = .error(clientError)
        markConnectionInterrupted()

        guard shouldReconnect else { return }
        scheduleReconnect(runId: runId)
    }

    private func scheduleReconnect(runId: String) {
        backoff.recordFailure()
        reconnectCount += 1
        let delay = backoff.currentDelay

        let plannedAfterSeq: Int?
        if case .error(let err) = connectionState, case .malformedEvent = err {
            plannedAfterSeq = nil
        } else {
            plannedAfterSeq = lastSeenSeq(for: runId)
        }

        AppLogger.network.warning("DevTools reconnect scheduled", metadata: [
            "run_id": runId,
            "attempt": String(backoff.attempt),
            "retry_count": String(reconnectCount),
            "delay_s": String(format: "%.1f", delay),
            "after_seq": plannedAfterSeq.map(String.init) ?? "nil",
        ])

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                AppLogger.network.debug("DevTools reconnect sleep interrupted", metadata: [
                    "run_id": runId,
                    "error": error.localizedDescription,
                ])
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, self.shouldReconnect else { return }

            let afterSeq: Int?
            if case .error(let err) = self.connectionState, case .malformedEvent = err {
                afterSeq = nil
            } else {
                afterSeq = self.lastSeenSeq(for: runId)
            }

            await MainActor.run {
                self.connectionState = .connecting
            }
            self.startStream(runId: runId, afterSeq: afterSeq)
        }
    }

    private func requestResync(runId: String) {
        guard shouldReconnect else { return }
        streamTask?.cancel()
        awaitingSnapshotAfterGapResync = false
        startStream(runId: runId, afterSeq: nil)
    }

    private func applySnapshotToLiveState(_ snapshot: DevToolsSnapshot) -> Bool {
        if let currentRunId = runId, snapshot.runId != currentRunId {
            AppLogger.error.error("DevTools snapshot runId mismatch", metadata: [
                "expected": currentRunId,
                "received": snapshot.runId,
            ])
            disconnect()
            return false
        }

        if snapshot.seq <= liveSeq, liveSeq > 0, !awaitingSnapshotAfterGapResync {
            AppLogger.network.warning("DevTools duplicate snapshot seq", metadata: [
                "current_seq": String(liveSeq),
                "received_seq": String(snapshot.seq),
            ])
            return false
        }

        if let previousLiveTree = liveTree {
            captureGhostNodesRemovedBySnapshot(
                previousRoot: previousLiveTree,
                nextRoot: snapshot.root,
                unmountedFrameNo: snapshot.frameNo,
                unmountedSeq: snapshot.seq
            )
        }

        awaitingSnapshotAfterGapResync = false
        liveTree = snapshot.root
        liveSeq = snapshot.seq
        liveLatestFrameNo = max(liveLatestFrameNo, snapshot.frameNo)
        runStateView = snapshot.runState
        runStatus = statusForSnapshot(snapshot)
        recordMountedFrames(from: snapshot.root, frameNo: snapshot.frameNo)
        pruneGhostNodesNowActive(in: snapshot.root)
        stateRunId = snapshot.runId
        lastSeqSeenByRunId[snapshot.runId] = snapshot.seq
        return true
    }

    private func applyDeltaToLiveState(_ delta: DevToolsDelta) -> Bool {
        if awaitingSnapshotAfterGapResync {
            AppLogger.network.warning("DevTools delta ignored while waiting for gap snapshot", metadata: [
                "seq": String(delta.seq),
                "base_seq": String(delta.baseSeq),
            ])
            return false
        }

        if delta.seq <= liveSeq, liveSeq > 0 {
            AppLogger.network.warning("DevTools backwards seq", metadata: [
                "current_seq": String(liveSeq),
                "delta_seq": String(delta.seq),
            ])
            return false
        }

        if liveSeq > 0, delta.baseSeq != liveSeq {
            AppLogger.network.warning("DevTools seq gap — requesting resync", metadata: [
                "current_seq": String(liveSeq),
                "delta_base_seq": String(delta.baseSeq),
            ])
            if let runId {
                requestResync(runId: runId)
            }
            return false
        }

        captureGhostNodes(from: delta)

        do {
            liveTree = try DevToolsDeltaApplier.applyDelta(delta, to: liveTree)
            liveSeq = delta.seq
            liveLatestFrameNo = max(liveLatestFrameNo, delta.seq)
            let inferredFrameNo = max(liveLatestFrameNo, delta.seq)
            recordMountedFrames(from: delta, frameNo: inferredFrameNo)
            if let runId {
                lastSeqSeenByRunId[runId] = delta.seq
            }
            runStatus = statusForRoot(liveTree)
            pruneGhostNodesNowActive(in: liveTree)
            return true
        } catch {
            AppLogger.error.error("DevTools applyDelta failed", metadata: [
                "error": String(describing: error),
                "seq": String(delta.seq),
            ])
            if let runId {
                requestResync(runId: runId)
            }
            return false
        }
    }

    private func syncDisplayedTreeWithLive() {
        tree = liveTree
        seq = liveSeq
        latestFrameNo = liveLatestFrameNo
        refreshRunningState()
    }

    /// Recompute `runningNodeCount` / `runningNodeIds` from the currently-displayed
    /// tree. Called whenever `tree` changes. Cheap — linear scan of node props.
    private func refreshRunningState() {
        guard let root = tree else {
            runningNodeCount = 0
            runningNodeIds = []
            return
        }
        var count = 0
        var ids: Set<String> = []
        collectRunningTaskNodes(root, count: &count, ids: &ids)
        runningNodeCount = count
        runningNodeIds = ids
    }

    private func collectRunningTaskNodes(
        _ node: DevToolsNode,
        count: inout Int,
        ids: inout Set<String>
    ) {
        // Only count leaf task nodes. Structural parents may show "running" via rollup
        // but the user-facing count should reflect discrete work units in flight.
        if node.type == .task, node.children.isEmpty {
            if case .string(let s) = node.props["state"], s == "running" {
                count += 1
                if let nodeId = node.task?.nodeId, !nodeId.isEmpty {
                    ids.insert(nodeId)
                }
            }
        }
        for child in node.children {
            collectRunningTaskNodes(child, count: &count, ids: &ids)
        }
    }

    private func resetForNewRun(runId: String) {
        stateRunId = runId
        tree = nil
        seq = 0
        liveTree = nil
        liveSeq = 0
        latestFrameNo = 0
        liveLatestFrameNo = 0
        runStatus = .unknown
        runStateView = nil
        runningNodeCount = 0
        runningNodeIds = []
        lastToastMessage = nil
        lastAuditRowId = nil
        selectedNodeId = nil
        selectedNodeGhostKey = nil
        clearHistory()
    }

    private func lastSeenSeq(for runId: String) -> Int? {
        guard stateRunId == runId, liveTree != nil, liveSeq > 0 else { return nil }
        let stored = max(lastSeqSeenByRunId[runId] ?? 0, liveSeq)
        return stored > 0 ? stored : nil
    }

    private func markConnectionInterrupted() {
        if staleSince == nil {
            staleSince = Date()
        }
        scheduleStaleBannerReveal()
    }

    private func markStreamHealthy() {
        backoff.reset()
        staleBannerTask?.cancel()
        staleBannerTask = nil
        staleSince = nil
        isStaleBannerVisible = false
    }

    private func scheduleStaleBannerReveal() {
        guard let staleSince else { return }
        staleBannerTask?.cancel()
        staleBannerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.staleBannerDelaySeconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.staleSince == staleSince else { return }
                guard self.connectionState != .streaming else { return }
                self.isStaleBannerVisible = true
            }
        }
    }

    private func ghostMapKey(for node: DevToolsNode) -> String? {
        if let nodeId = node.task?.nodeId, !nodeId.isEmpty {
            return nodeId
        }
        return nil
    }

    private func selectionKey(for node: DevToolsNode) -> String {
        if let key = ghostMapKey(for: node) {
            return key
        }
        return "selected:\(node.id)"
    }

    private func recordMountedFrames(from root: DevToolsNode, frameNo: Int) {
        recordMountedFrame(node: root, frameNo: frameNo)
        for child in root.children {
            recordMountedFrames(from: child, frameNo: frameNo)
        }
    }

    private func recordMountedFrames(from delta: DevToolsDelta, frameNo: Int) {
        for op in delta.ops {
            if case .addNode(_, _, let node) = op {
                recordMountedFrames(from: node, frameNo: frameNo)
            } else if case .replaceRoot(let node) = op {
                recordMountedFrames(from: node, frameNo: frameNo)
            }
        }
    }

    private func recordMountedFrame(node: DevToolsNode, frameNo: Int) {
        guard let key = ghostMapKey(for: node) else { return }
        if let existing = mountedFrameByGhostKey[key] {
            mountedFrameByGhostKey[key] = min(existing, frameNo)
        } else {
            mountedFrameByGhostKey[key] = frameNo
        }
    }

    private func captureGhostNodesRemovedBySnapshot(
        previousRoot: DevToolsNode,
        nextRoot: DevToolsNode,
        unmountedFrameNo: Int,
        unmountedSeq: Int
    ) {
        var nextKeys = Set<String>()
        collectGhostKeys(from: nextRoot, into: &nextKeys)
        registerRemovedGhostNodes(
            from: previousRoot,
            activeKeys: nextKeys,
            unmountedFrameNo: unmountedFrameNo,
            unmountedSeq: unmountedSeq
        )
    }

    private func collectGhostKeys(from node: DevToolsNode, into keys: inout Set<String>) {
        if let key = ghostMapKey(for: node) {
            keys.insert(key)
        }
        for child in node.children {
            collectGhostKeys(from: child, into: &keys)
        }
    }

    private func registerRemovedGhostNodes(
        from node: DevToolsNode,
        activeKeys: Set<String>,
        unmountedFrameNo: Int,
        unmountedSeq: Int
    ) {
        if let key = ghostMapKey(for: node), !activeKeys.contains(key) {
            registerGhostSubtree(node, unmountedFrameNo: unmountedFrameNo, unmountedSeq: unmountedSeq)
            return
        }
        for child in node.children {
            registerRemovedGhostNodes(
                from: child,
                activeKeys: activeKeys,
                unmountedFrameNo: unmountedFrameNo,
                unmountedSeq: unmountedSeq
            )
        }
    }

    private func captureGhostNodes(from delta: DevToolsDelta) {
        guard let liveTree else { return }
        let unmountedFrameNo = max(liveLatestFrameNo, delta.seq)
        for op in delta.ops {
            if case .removeNode(let nodeID) = op {
                if liveTree.id == nodeID {
                    registerGhostSubtree(
                        liveTree,
                        unmountedFrameNo: unmountedFrameNo,
                        unmountedSeq: delta.seq
                    )
                    continue
                }
                if let removed = liveTree.findNode(byId: nodeID) {
                    registerGhostSubtree(
                        removed,
                        unmountedFrameNo: unmountedFrameNo,
                        unmountedSeq: delta.seq
                    )
                }
            } else if case .replaceRoot(let replacementRoot) = op {
                captureGhostNodesRemovedBySnapshot(
                    previousRoot: liveTree,
                    nextRoot: replacementRoot,
                    unmountedFrameNo: unmountedFrameNo,
                    unmountedSeq: delta.seq
                )
            }
        }
    }

    private func registerGhostSubtree(
        _ node: DevToolsNode,
        unmountedFrameNo: Int,
        unmountedSeq: Int
    ) {
        registerGhostNode(node, unmountedFrameNo: unmountedFrameNo, unmountedSeq: unmountedSeq)
        for child in node.children {
            registerGhostSubtree(child, unmountedFrameNo: unmountedFrameNo, unmountedSeq: unmountedSeq)
        }
    }

    private func registerGhostNode(
        _ node: DevToolsNode,
        unmountedFrameNo: Int,
        unmountedSeq: Int
    ) {
        guard let key = ghostMapKey(for: node) else { return }
        let mountedFrameNo = mountedFrameByGhostKey[key] ?? unmountedFrameNo
        ghostNodes[key] = GhostNodeRecord(
            key: key,
            node: node.deepCopy(),
            mountedFrameNo: mountedFrameNo,
            unmountedFrameNo: unmountedFrameNo,
            unmountedSeq: unmountedSeq,
            capturedAt: Date()
        )
        ghostEvictionOrder.removeAll(where: { $0 == key })
        ghostEvictionOrder.append(key)
        enforceGhostBudget()
    }

    private func enforceGhostBudget() {
        guard ghostNodes.count > ghostNodeCap else { return }
        var keysToEvict: [String] = []
        while ghostNodes.count - keysToEvict.count > ghostNodeCap, !ghostEvictionOrder.isEmpty {
            let key = ghostEvictionOrder.removeFirst()
            keysToEvict.append(key)
        }
        removeGhostRecords(keysToEvict)
    }

    private func pruneGhostNodesNowActive(in root: DevToolsNode?) {
        guard let root else { return }
        var activeKeys = Set<String>()
        collectGhostKeys(from: root, into: &activeKeys)
        let keysToRemove = ghostNodes.keys.filter { activeKeys.contains($0) }
        removeGhostRecords(keysToRemove, removeMountTracking: false)
    }

    private func pruneGhostNodesForRewind(targetFrameNo: Int) {
        let keysToRemove = ghostNodes.values
            .filter { $0.mountedFrameNo > targetFrameNo }
            .map(\.key)
        removeGhostRecords(keysToRemove)
    }

    private func removeGhostRecords(_ keys: [String], removeMountTracking: Bool = true) {
        guard !keys.isEmpty else { return }
        let keySet = Set(keys)
        for key in keySet {
            ghostNodes.removeValue(forKey: key)
            if removeMountTracking {
                mountedFrameByGhostKey.removeValue(forKey: key)
            }
        }
        ghostEvictionOrder.removeAll(where: { keySet.contains($0) })
        if let selectedNodeGhostKey, keySet.contains(selectedNodeGhostKey) {
            if let selectedNodeId, tree?.findNode(byId: selectedNodeId) != nil {
                isGhost = false
                self.selectedNodeGhostKey = nil
            } else {
                clearSelection()
            }
        }
    }

    private func statusForRoot(_ root: DevToolsNode?) -> RunStatus {
        guard let root else { return runStatus }
        guard case .string(let rawState) = root.props["state"] else { return runStatus }

        switch rawState.lowercased() {
        case "running", "in-progress":
            return .running
        case "waitingapproval", "waiting-approval", "blocked":
            return .waitingApproval
        case "finished", "complete", "completed", "success", "succeeded", "done":
            return .finished
        case "failed", "error":
            return .failed
        case "cancelled", "canceled":
            return .cancelled
        default:
            return .unknown
        }
    }

    private func statusForSnapshot(_ snapshot: DevToolsSnapshot) -> RunStatus {
        if let runState = snapshot.runState,
           let mapped = runStatusFromRunState(runState.state) {
            return mapped
        }
        return statusForRoot(snapshot.root)
    }

    private func runStatusFromRunState(_ rawState: String) -> RunStatus? {
        switch rawState.lowercased() {
        case "running", "recovering":
            return .running
        case "waiting-approval", "waitingapproval", "waiting-event", "waitingevent", "waiting-timer", "waitingtimer":
            return .waitingApproval
        case "succeeded", "success", "finished", "complete", "completed":
            return .finished
        case "failed":
            return .failed
        case "cancelled", "canceled":
            return .cancelled
        case "unknown", "stale", "orphaned":
            return .unknown
        default:
            return nil
        }
    }

    private static func resolvedGhostNodeCap() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["SMITHERS_DEVTOOLS_GHOST_CAP"] else {
            return defaultGhostNodeCap
        }
        guard let parsed = Int(raw), parsed > 0 else {
            return defaultGhostNodeCap
        }
        return parsed
    }

    private static func toClientError(_ error: Error) -> DevToolsClientError {
        if let urlError = error as? URLError {
            return .from(urlError: urlError)
        }
        if let decodingError = error as? DecodingError {
            return .from(decodingError: decodingError)
        }
        if let devError = error as? DevToolsClientError {
            return devError
        }
        return .unknown(String(describing: error))
    }

    private static func errorCodeString(_ error: DevToolsClientError) -> String {
        switch error {
        case .runNotFound: return "RunNotFound"
        case .frameOutOfRange: return "FrameOutOfRange"
        case .invalidRunId: return "InvalidRunId"
        case .invalidFrameNo: return "InvalidFrameNo"
        case .seqOutOfRange: return "SeqOutOfRange"
        case .confirmationRequired: return "ConfirmationRequired"
        case .busy: return "Busy"
        case .unsupportedSandbox: return "UnsupportedSandbox"
        case .vcsError: return "VcsError"
        case .rewindFailed: return "RewindFailed"
        case .rateLimited: return "RateLimited"
        case .backpressureDisconnect: return "BackpressureDisconnect"
        case .network: return "Network"
        case .malformedEvent: return "MalformedEvent"
        case .unknown(let code): return code
        default: return "Unknown"
        }
    }
}
