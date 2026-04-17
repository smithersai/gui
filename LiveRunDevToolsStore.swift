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

protocol DevToolsStreamProvider: Sendable {
    func streamDevTools(runId: String, fromSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error>
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

// MARK: - LiveRunDevToolsStore

@MainActor
final class LiveRunDevToolsStore: ObservableObject {
    @Published private(set) var tree: DevToolsNode?
    @Published private(set) var seq: Int = 0
    @Published private(set) var lastEventAt: Date?
    @Published var selectedNodeId: Int?
    @Published private(set) var isGhost: Bool = false
    @Published private(set) var connectionState: DevToolsConnectionState = .disconnected

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
    @Published private(set) var lastToastMessage: String?

    var runId: String?

    private var streamTask: Task<Void, Never>?
    private var backoff = ReconnectBackoff()
    private let streamProvider: DevToolsStreamProvider?
    private var ghostNode: DevToolsNode?
    private var shouldReconnect: Bool = false

    private var liveTree: DevToolsNode?
    private var liveSeq: Int = 0
    private var liveLatestFrameNo: Int = 0
    private var bufferedLiveEvents: Int = 0

    private let toastSink: (String) -> Void

    var heartbeatAgeMs: Int {
        guard let lastEventAt else { return Int.max }
        return Int(Date().timeIntervalSince(lastEventAt) * 1000)
    }

    var selectedNode: DevToolsNode? {
        guard let selectedNodeId else { return nil }
        if let found = tree?.findNode(byId: selectedNodeId) {
            return found
        }
        if isGhost { return ghostNode }
        return nil
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
        toastSink: @escaping (String) -> Void = { message in
            AppLogger.ui.info("Live Run toast", metadata: [
                "message_length": String(message.count),
            ])
        }
    ) {
        self.streamProvider = streamProvider
        self.toastSink = toastSink
    }

    // MARK: - Connect / Disconnect

    func connect(runId: String) {
        disconnect()

        self.runId = runId
        shouldReconnect = true
        connectionState = .connecting
        backoff.reset()

        mode = .live
        scrubError = nil
        rewindError = nil
        rewindInFlight = false
        bufferedLiveEvents = 0
        tree = nil
        seq = 0
        liveTree = nil
        liveSeq = 0
        latestFrameNo = 0
        liveLatestFrameNo = 0
        runStatus = .unknown
        runningNodeCount = 0
        runningNodeIds = []

        AppLogger.network.info("DevTools connect", metadata: [
            "run_id": runId,
            "from_seq": String(seq),
        ])

        startStream(runId: runId, fromSeq: nil)
    }

    func disconnect() {
        shouldReconnect = false
        streamTask?.cancel()
        streamTask = nil

        if let runId {
            AppLogger.network.info("DevTools disconnect", metadata: [
                "run_id": runId,
                "events_applied": String(eventsApplied),
            ])
        }

        connectionState = .disconnected
        runId = nil
    }

    // MARK: - Event Handling (pure, unit-testable)

    func applyEvent(_ event: DevToolsEvent) {
        switch event {
        case .snapshot(let snapshot):
            applySnapshot(snapshot)
        case .delta(let delta):
            applyDeltaEvent(delta)
        }

        lastEventAt = Date()
        eventsApplied += 1
        backoff.reset()

        if mode.isHistorical {
            bufferedLiveEvents += 1
        } else {
            updateGhostState()
        }
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
            _ = try await provider.jumpToFrame(runId: runId, frameNo: frameNo, confirm: true)
            let snapshot = try await provider.getDevToolsSnapshot(runId: runId, frameNo: nil)

            _ = applySnapshotToLiveState(snapshot)
            mode = .live
            bufferedLiveEvents = 0
            scrubError = nil
            rewindError = nil
            syncDisplayedTreeWithLive()
            updateGhostState()

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let toast = "Rewound to frame \(frameNo)."
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
        runStatus = status
        if isRunFinished, case .historical(let frameNo) = mode {
            mode = .historical(frameNo: frameNo)
        }
    }

    // MARK: - Selection & Ghost

    func selectNode(_ nodeId: Int?) {
        if let nodeId {
            if let node = tree?.findNode(byId: nodeId) {
                ghostNode = node.deepCopy()
            }
        }
        selectedNodeId = nodeId
        updateGhostState()
    }

    func clearSelection() {
        selectedNodeId = nil
        isGhost = false
        ghostNode = nil
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
            ghostNode = nil
            return
        }

        if tree?.findNode(byId: selectedNodeId) != nil {
            isGhost = false
        } else if ghostNode != nil {
            isGhost = true
        } else {
            isGhost = false
            self.selectedNodeId = nil
        }
    }

    // MARK: - Stream Management

    private func startStream(runId: String, fromSeq: Int?) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self, let provider = self.streamProvider else { return }

            let stream = provider.streamDevTools(runId: runId, fromSeq: fromSeq)

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
                await self.handleStreamEnd(runId: runId)

            } catch {
                guard !Task.isCancelled else { return }
                await self.handleStreamError(error, runId: runId)
            }
        }
    }

    private func handleStreamEnd(runId: String) {
        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }
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

        guard shouldReconnect else { return }
        scheduleReconnect(runId: runId)
    }

    private func scheduleReconnect(runId: String) {
        backoff.recordFailure()
        reconnectCount += 1
        let delay = backoff.currentDelay

        AppLogger.network.warning("DevTools reconnect scheduled", metadata: [
            "run_id": runId,
            "attempt": String(backoff.attempt),
            "delay_s": String(format: "%.1f", delay),
        ])

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.shouldReconnect else { return }

            let fromSeq: Int?
            if case .error(let err) = self.connectionState, case .malformedEvent = err {
                fromSeq = nil
            } else {
                fromSeq = self.liveSeq > 0 ? self.liveSeq : nil
            }

            await MainActor.run {
                self.connectionState = .connecting
            }
            self.startStream(runId: runId, fromSeq: fromSeq)
        }
    }

    private func requestResync(runId: String) {
        guard shouldReconnect else { return }
        streamTask?.cancel()
        startStream(runId: runId, fromSeq: nil)
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

        if snapshot.seq <= liveSeq, liveSeq > 0 {
            AppLogger.network.warning("DevTools duplicate snapshot seq", metadata: [
                "current_seq": String(liveSeq),
                "received_seq": String(snapshot.seq),
            ])
            return false
        }

        liveTree = snapshot.root
        liveSeq = snapshot.seq
        liveLatestFrameNo = max(liveLatestFrameNo, snapshot.frameNo)
        runStatus = statusForRoot(snapshot.root)
        return true
    }

    private func applyDeltaToLiveState(_ delta: DevToolsDelta) -> Bool {
        if delta.seq <= liveSeq, liveSeq > 0 {
            AppLogger.network.warning("DevTools backwards seq", metadata: [
                "current_seq": String(liveSeq),
                "delta_seq": String(delta.seq),
            ])
            return false
        }

        let gap = delta.baseSeq - liveSeq
        if gap > 100, liveSeq > 0 {
            AppLogger.network.warning("DevTools large seq gap — requesting resync", metadata: [
                "current_seq": String(liveSeq),
                "delta_base_seq": String(delta.baseSeq),
                "gap": String(gap),
            ])
            if let runId {
                requestResync(runId: runId)
            }
            return false
        }

        do {
            liveTree = try DevToolsDeltaApplier.applyDelta(delta, to: liveTree)
            liveSeq = delta.seq
            liveLatestFrameNo = max(liveLatestFrameNo, delta.seq)
            runStatus = statusForRoot(liveTree)
            return true
        } catch {
            AppLogger.error.error("DevTools applyDelta failed", metadata: [
                "error": String(describing: error),
                "seq": String(delta.seq),
            ])
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
