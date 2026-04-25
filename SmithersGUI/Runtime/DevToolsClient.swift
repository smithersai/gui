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
    private nonisolated static let auditRowIDKeys: Set<String> = [
        "auditRowId",
        "audit_row_id",
        "auditId",
        "audit_id",
        "auditLogId",
        "audit_log_id",
    ]
    private nonisolated static let nestedAuditContainers = [
        "result",
        "data",
        "mutation",
        "ack",
        "payload",
        "meta",
    ]

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
        try await performMutation(
            preferredMethods: ["runs.approve", "runs.approveNode", "approvals.approve"],
            args: [
                "runId": AnyEncodable(runId),
                "nodeId": AnyEncodable(nodeId),
                "iteration": AnyEncodable(iteration),
            ],
            fallback: { [smithers] in
                try await smithers.approveNode(runId: runId, nodeId: nodeId, iteration: iteration)
            }
        )
    }

    func deny(runId: String, nodeId: String, iteration: Int?) async throws -> GatewayMutationResult {
        try await performMutation(
            preferredMethods: ["runs.deny", "runs.denyNode", "approvals.deny"],
            args: [
                "runId": AnyEncodable(runId),
                "nodeId": AnyEncodable(nodeId),
                "iteration": AnyEncodable(iteration),
            ],
            fallback: { [smithers] in
                try await smithers.denyNode(runId: runId, nodeId: nodeId, iteration: iteration)
            }
        )
    }

    func cancel(runId: String) async throws -> GatewayMutationResult {
        try await performMutation(
            preferredMethods: ["runs.cancel", "workflowRuns.cancel"],
            args: ["runId": AnyEncodable(runId)],
            fallback: { [smithers] in
                try await smithers.cancelRun(runId)
            }
        )
    }

    func resume(runId: String) async throws -> GatewayMutationResult {
        try await performMutation(
            preferredMethods: ["runs.resume", "workflowRuns.resume"],
            args: ["runId": AnyEncodable(runId)]
        )
    }

    func signal(runId: String, signal: String, payload: JSONValue? = nil) async throws -> GatewayMutationResult {
        try await performMutation(
            preferredMethods: ["signals.send", "runs.signal"],
            args: [
                "runId": AnyEncodable(runId),
                "signal": AnyEncodable(signal),
                "payload": AnyEncodable(payload),
            ]
        )
    }

    private func performMutation(
        preferredMethods: [String],
        args: [String: AnyEncodable],
        fallback: (() async throws -> Void)? = nil
    ) async throws -> GatewayMutationResult {
        var lastUnsupportedError: Error?

        for method in preferredMethods {
            do {
                let response = try await smithers.call(method, args: args, as: JSONValue.self)
                return GatewayMutationResult(auditRowId: Self.auditRowID(from: response))
            } catch {
                if Self.isUnsupportedRPCError(error) {
                    lastUnsupportedError = error
                    continue
                }
                throw error
            }
        }

        if let fallback {
            try await fallback()
            return GatewayMutationResult(auditRowId: nil)
        }

        throw lastUnsupportedError ?? SmithersError.api("No supported mutation RPC found.")
    }

    nonisolated static func auditRowID(from value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for key in auditRowIDKeys {
                if case .string(let id)? = object[key], !id.isEmpty {
                    return id
                }
            }
            for key in nestedAuditContainers {
                if let nested = object[key], let id = auditRowID(from: nested) {
                    return id
                }
            }
            return nil
        case .array(let values):
            for value in values {
                if let id = auditRowID(from: value) {
                    return id
                }
            }
            return nil
        default:
            return nil
        }
    }

    nonisolated static func isUnsupportedRPCError(_ error: Error) -> Bool {
        guard case .api(let message) = error as? SmithersError else {
            return false
        }
        let normalized = message.lowercased()
        let unsupportedPhrases = [
            "method not found",
            "unknown method",
            "unsupported method",
            "not implemented",
            "unrecognized method",
        ]
        return unsupportedPhrases.contains { normalized.contains($0) }
    }
}
