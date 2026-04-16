import Foundation

enum DevToolsClientError: Error, Equatable {
    case runNotFound(String)
    case frameOutOfRange(Int)
    case invalidRunId(String)
    case invalidNodeId(String)
    case invalidIteration(Int?)
    case invalidFrameNo(Int?)
    case seqOutOfRange(Int)
    case nodeNotFound(String)
    case attemptNotFound(String)
    case attemptNotFinished
    case nodeHasNoOutput
    case iterationNotFound(Int)
    case malformedOutputRow
    case payloadTooLarge(Int?)
    case confirmationRequired
    case busy
    case unsupportedSandbox(String?)
    case vcsError(String?)
    case workingTreeDirty(String?)
    case rewindFailed(String?)
    case diffTooLarge(String?)
    case rateLimited
    case backpressureDisconnect
    case network(URLError)
    case malformedEvent(String)
    case unknown(String)

    var displayMessage: String {
        switch self {
        case .runNotFound(let runId):
            return "Run not found: \(runId)"
        case .frameOutOfRange(let frame):
            return "Frame out of range: \(frame)"
        case .invalidRunId(let runId):
            return "Invalid run ID: \(runId)"
        case .invalidNodeId(let nodeId):
            return "Invalid node ID: \(nodeId)"
        case .invalidIteration(let iteration):
            if let iteration {
                return "Invalid iteration: \(iteration)"
            }
            return "Invalid iteration"
        case .invalidFrameNo(let frame):
            if let frame {
                return "Invalid frame number: \(frame)"
            }
            return "Invalid frame number"
        case .seqOutOfRange(let seq):
            return "Sequence out of range: \(seq)"
        case .nodeNotFound(let nodeRef):
            return "Node not found: \(nodeRef)"
        case .attemptNotFound(let attemptRef):
            return "Attempt not found: \(attemptRef)"
        case .attemptNotFinished:
            return "Attempt is still running."
        case .nodeHasNoOutput:
            return "This node has no output table."
        case .iterationNotFound(let iteration):
            if iteration >= 0 {
                return "Iteration not found: \(iteration)"
            }
            return "Iteration not found."
        case .malformedOutputRow:
            return "Output row is malformed and cannot be rendered."
        case .payloadTooLarge(let bytes):
            if let bytes, bytes > 0 {
                return "Output payload is too large (\(bytes) bytes)."
            }
            return "Output payload is too large."
        case .confirmationRequired:
            return "Rewind confirmation required."
        case .busy:
            return "Another rewind is in progress."
        case .unsupportedSandbox(let reason):
            if let reason, !reason.isEmpty {
                return reason
            }
            return "This run uses a sandbox that cannot be rewound."
        case .vcsError(let reason):
            if let reason, !reason.isEmpty {
                return reason
            }
            return "Failed due to a VCS error."
        case .workingTreeDirty(let reason):
            if let reason, !reason.isEmpty {
                return reason
            }
            return "Working copy is dirty and cannot be diffed safely."
        case .rewindFailed(let reason):
            if let reason, !reason.isEmpty {
                return reason
            }
            return "Rewind failed and rollback was partial."
        case .diffTooLarge(let reason):
            if let reason, !reason.isEmpty {
                return reason
            }
            return "Diff is too large to render."
        case .rateLimited:
            return "Rewind rate limit exceeded."
        case .backpressureDisconnect:
            return "Disconnected due to backpressure"
        case .network(let urlError):
            return "Network error: \(urlError.localizedDescription)"
        case .malformedEvent(let detail):
            return "Malformed event: \(detail)"
        case .unknown(let code):
            return "Unknown error: \(code)"
        }
    }

    var hint: String? {
        switch self {
        case .runNotFound:
            return "Check that the run ID is correct and the run has not been deleted."
        case .frameOutOfRange:
            return "The requested frame may no longer exist. Try the latest frame."
        case .invalidRunId:
            return "Run IDs must match [a-z0-9_-]{1,64}."
        case .invalidNodeId:
            return "Node IDs must match [a-zA-Z0-9:_-]{1,128}."
        case .invalidIteration:
            return "Iteration must be a non-negative i32."
        case .invalidFrameNo:
            return "Frame numbers must be non-negative integers."
        case .seqOutOfRange:
            return "Reconnect without fromSeq to resync."
        case .nodeNotFound:
            return "Select an existing node from the tree and retry."
        case .attemptNotFound:
            return "No attempt exists for that node iteration."
        case .attemptNotFinished:
            return "Wait for the task attempt to finish before opening Diff."
        case .nodeHasNoOutput:
            return "Run the task to completion before opening Output."
        case .iterationNotFound:
            return "Choose a valid iteration and retry."
        case .malformedOutputRow:
            return "The server returned malformed output data. Retry or inspect server logs."
        case .payloadTooLarge:
            return "Output exceeds the 100 MB limit. Narrow fields or query via CLI."
        case .confirmationRequired:
            return "Confirm the destructive action before submitting rewind."
        case .busy:
            return "Wait for the current rewind to finish and retry."
        case .unsupportedSandbox:
            return "This run cannot be rewound in-place. Use historical view-only mode."
        case .vcsError:
            return "Check repository health, then retry."
        case .workingTreeDirty:
            return "Resolve working copy conflicts or dirtiness, then retry."
        case .rewindFailed:
            return "The rewind did not complete cleanly. Retry or inspect server logs."
        case .diffTooLarge:
            return "Diff exceeds the 50 MB cap. Narrow the task or inspect via CLI."
        case .rateLimited:
            return "Too many rewinds recently. Wait and retry."
        case .backpressureDisconnect:
            return "The client fell behind. Reconnecting will resume from the latest state."
        case .network:
            return "Check your network connection and that the Smithers server is running."
        case .malformedEvent:
            return "A corrupted event was received. The stream will attempt to resync."
        case .unknown:
            return nil
        }
    }

    static func from(serverErrorCode code: String, message: String? = nil) -> DevToolsClientError {
        switch code {
        case "RunNotFound":
            return .runNotFound(message ?? code)
        case "FrameOutOfRange":
            if let msg = message, let frame = Int(msg) {
                return .frameOutOfRange(frame)
            }
            return .frameOutOfRange(-1)
        case "InvalidRunId":
            return .invalidRunId(message ?? code)
        case "InvalidNodeId":
            return .invalidNodeId(message ?? code)
        case "InvalidIteration":
            return .invalidIteration(firstInteger(in: message))
        case "InvalidFrameNo":
            if let msg = message, let frame = Int(msg) {
                return .invalidFrameNo(frame)
            }
            return .invalidFrameNo(nil)
        case "SeqOutOfRange":
            if let msg = message, let seq = Int(msg) {
                return .seqOutOfRange(seq)
            }
            return .seqOutOfRange(-1)
        case "NodeNotFound":
            return .nodeNotFound(message ?? "unknown")
        case "AttemptNotFound":
            return .attemptNotFound(message ?? "unknown")
        case "AttemptNotFinished":
            return .attemptNotFinished
        case "NodeHasNoOutput":
            return .nodeHasNoOutput
        case "IterationNotFound":
            return .iterationNotFound(firstInteger(in: message) ?? -1)
        case "MalformedOutputRow":
            return .malformedOutputRow
        case "PayloadTooLarge":
            return .payloadTooLarge(firstInteger(in: message))
        case "ConfirmationRequired":
            return .confirmationRequired
        case "Busy":
            return .busy
        case "UnsupportedSandbox":
            return .unsupportedSandbox(message)
        case "VcsError":
            return .vcsError(message)
        case "WorkingTreeDirty":
            return .workingTreeDirty(message)
        case "RewindFailed":
            return .rewindFailed(message)
        case "DiffTooLarge":
            return .diffTooLarge(message)
        case "RateLimited":
            return .rateLimited
        case "BackpressureDisconnect":
            return .backpressureDisconnect
        default:
            return .unknown(code)
        }
    }

    private static func firstInteger(in message: String?) -> Int? {
        guard let message else { return nil }
        var buffer = ""
        for char in message {
            if char.isNumber || (char == "-" && buffer.isEmpty) {
                buffer.append(char)
            } else if !buffer.isEmpty {
                return Int(buffer)
            }
        }
        return buffer.isEmpty ? nil : Int(buffer)
    }

    static func from(urlError: URLError) -> DevToolsClientError {
        .network(urlError)
    }

    static func from(decodingError: DecodingError) -> DevToolsClientError {
        .malformedEvent(String(describing: decodingError))
    }

    static func == (lhs: DevToolsClientError, rhs: DevToolsClientError) -> Bool {
        switch (lhs, rhs) {
        case (.runNotFound(let l), .runNotFound(let r)): return l == r
        case (.frameOutOfRange(let l), .frameOutOfRange(let r)): return l == r
        case (.invalidRunId(let l), .invalidRunId(let r)): return l == r
        case (.invalidNodeId(let l), .invalidNodeId(let r)): return l == r
        case (.invalidIteration(let l), .invalidIteration(let r)): return l == r
        case (.invalidFrameNo(let l), .invalidFrameNo(let r)): return l == r
        case (.seqOutOfRange(let l), .seqOutOfRange(let r)): return l == r
        case (.nodeNotFound(let l), .nodeNotFound(let r)): return l == r
        case (.attemptNotFound(let l), .attemptNotFound(let r)): return l == r
        case (.attemptNotFinished, .attemptNotFinished): return true
        case (.nodeHasNoOutput, .nodeHasNoOutput): return true
        case (.iterationNotFound(let l), .iterationNotFound(let r)): return l == r
        case (.malformedOutputRow, .malformedOutputRow): return true
        case (.payloadTooLarge(let l), .payloadTooLarge(let r)): return l == r
        case (.confirmationRequired, .confirmationRequired): return true
        case (.busy, .busy): return true
        case (.unsupportedSandbox(let l), .unsupportedSandbox(let r)): return l == r
        case (.vcsError(let l), .vcsError(let r)): return l == r
        case (.workingTreeDirty(let l), .workingTreeDirty(let r)): return l == r
        case (.rewindFailed(let l), .rewindFailed(let r)): return l == r
        case (.diffTooLarge(let l), .diffTooLarge(let r)): return l == r
        case (.rateLimited, .rateLimited): return true
        case (.backpressureDisconnect, .backpressureDisconnect): return true
        case (.network(let l), .network(let r)): return l.code == r.code
        case (.malformedEvent(let l), .malformedEvent(let r)): return l == r
        case (.unknown(let l), .unknown(let r)): return l == r
        default: return false
        }
    }
}
