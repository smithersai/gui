import Foundation

struct GatewayMutationResult: Equatable, Sendable {
    let auditRowId: String?
}

/// Gateway-backed devtools transport wrapper.
///
/// The app still uses `SmithersClient` as the concrete transport implementation
/// so local/libsmithers and remote/gateway modes share one call surface.
@MainActor
final class DevToolsClient: DevToolsStreamProvider, @unchecked Sendable {
    private let smithers: SmithersClient
    private var lastSeqSeenByRunId: [String: Int] = [:]

    init(smithers: SmithersClient) {
        self.smithers = smithers
    }

    func streamDevTools(runId: String, afterSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        let resumeSeq = afterSeq ?? lastSeqSeenByRunId[runId]
        let upstream = smithers.streamDevTools(runId: runId, afterSeq: resumeSeq)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    for try await event in upstream {
                        switch event {
                        case .snapshot(let snapshot):
                            self.lastSeqSeenByRunId[runId] = max(self.lastSeqSeenByRunId[runId] ?? 0, snapshot.seq)
                        case .delta(let delta):
                            self.lastSeqSeenByRunId[runId] = max(self.lastSeqSeenByRunId[runId] ?? 0, delta.seq)
                        case .gapResync(let gapResync):
                            self.lastSeqSeenByRunId[runId] = max(self.lastSeqSeenByRunId[runId] ?? 0, gapResync.toSeq)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func getDevToolsSnapshot(runId: String, frameNo: Int?) async throws -> DevToolsSnapshot {
        try await smithers.getDevToolsSnapshot(runId: runId, frameNo: frameNo)
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult {
        try await smithers.jumpToFrame(runId: runId, frameNo: frameNo, confirm: confirm)
    }

    func approve(runId: String, nodeId: String, iteration: Int?) async throws -> GatewayMutationResult {
        try await smithers.approveNode(runId: runId, nodeId: nodeId, iteration: iteration)
        return GatewayMutationResult(auditRowId: nil)
    }

    func deny(runId: String, nodeId: String, iteration: Int?) async throws -> GatewayMutationResult {
        try await smithers.denyNode(runId: runId, nodeId: nodeId, iteration: iteration)
        return GatewayMutationResult(auditRowId: nil)
    }

    func cancel(runId: String) async throws -> GatewayMutationResult {
        try await smithers.cancelRun(runId)
        return GatewayMutationResult(auditRowId: nil)
    }

    func resume(runId: String) async throws -> GatewayMutationResult {
        _ = try await smithers.call(
            "runs.resume",
            args: ["runId": AnyEncodable(runId)],
            as: GatewayMutationAck.self
        )
        return GatewayMutationResult(auditRowId: nil)
    }

    func signal(runId: String, signal: String, payload: JSONValue? = nil) async throws -> GatewayMutationResult {
        _ = try await smithers.call(
            "signals.send",
            args: [
                "runId": AnyEncodable(runId),
                "signal": AnyEncodable(signal),
                "payload": AnyEncodable(payload),
            ],
            as: GatewayMutationAck.self
        )
        return GatewayMutationResult(auditRowId: nil)
    }
}

private struct GatewayMutationAck: Decodable {
    let ok: Bool?
}
