import Foundation
import CSmithersKit

extension Smithers {
    enum DevTools {
        private final class SharedClient {
            let app: smithers_app_t?
            let client: smithers_client_t?

            init() {
                app = smithers_app_new(nil)
                if let app {
                    client = smithers_client_new(app)
                } else {
                    client = nil
                }
            }

            deinit {
                if let client { smithers_client_free(client) }
                if let app { smithers_app_free(app) }
            }
        }

        private struct ValidationResult: Decodable {
            let valid: Bool
        }

        private struct ApplyResult<Tree: Decodable>: Decodable {
            let ok: Bool
            let tree: Tree?
            let error: String?
            let id: Int?
            let parentId: Int?
            let index: Int?
            let childCount: Int?
        }

        private struct ApplyDeltaArgs: Encodable {
            let delta: DevToolsDelta
            let tree: DevToolsNode?
        }

        private struct ApplyOpArgs: Encodable {
            let op: DevToolsDeltaOp
            let tree: DevToolsNode?
        }

        private struct OptionalStringResult: Decodable {
            let value: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                value = container.decodeNil() ? nil : try container.decode(String.self)
            }
        }

        nonisolated(unsafe) private static let shared = SharedClient()

        static func validateRunId(_ runId: String) throws -> Bool {
            try call("devtools.validateRunId", args: ["runId": AnyEncodable(runId)], as: ValidationResult.self).valid
        }

        static func validateNodeId(_ nodeId: String) throws -> Bool {
            try call("devtools.validateNodeId", args: ["nodeId": AnyEncodable(nodeId)], as: ValidationResult.self).valid
        }

        static func validateIteration(_ iteration: Int) throws -> Bool {
            try call("devtools.validateIteration", args: ["iteration": AnyEncodable(iteration)], as: ValidationResult.self).valid
        }

        static func validateFrameNo(_ frameNo: Int) throws -> Bool {
            try call("devtools.validateFrameNo", args: ["frameNo": AnyEncodable(frameNo)], as: ValidationResult.self).valid
        }

        static func sqlQuote(_ value: String) throws -> String {
            try call("devtools.sqlQuote", args: ["value": AnyEncodable(value)], as: String.self)
        }

        static func normalizeNodeState(_ state: String) throws -> String {
            try call("devtools.normalizeNodeState", args: ["state": AnyEncodable(state)], as: String.self)
        }

        static func rolledUpState(childStates: [String]) throws -> String? {
            try call("devtools.rolledUpState", args: ["states": AnyEncodable(childStates)], as: OptionalStringResult.self).value
        }

        static func nodeStateQuery(runId: String) throws -> String {
            try call("devtools.nodeStateQuery", args: ["runId": AnyEncodable(runId)], as: String.self)
        }

        static func attemptQuery(runId: String) throws -> String {
            try call("devtools.attemptQuery", args: ["runId": AnyEncodable(runId)], as: String.self)
        }

        static func nodeStateDict(fromRows rows: [[String: Any]]) throws -> [String: DevToolsNodeStateEntry] {
            try callJSON("devtools.nodeStateDict", args: ["rows": rows], as: [String: DevToolsNodeStateEntry].self)
        }

        static func attemptEntries(fromRows rows: [[String: Any]]) throws -> [DevToolsAttemptEntry] {
            try callJSON("devtools.attemptEntries", args: ["rows": rows], as: [DevToolsAttemptEntry].self)
        }

        static func nodeStatesAtTimestamp(
            attempts: [DevToolsAttemptEntry],
            frameTimestampMs: Int64
        ) throws -> [String: DevToolsNodeStateEntry] {
            try call(
                "devtools.nodeStatesAtTimestamp",
                args: [
                    "attempts": AnyEncodable(attempts),
                    "frameTimestampMs": AnyEncodable(frameTimestampMs),
                ],
                as: [String: DevToolsNodeStateEntry].self
            )
        }

        static func buildTree(
            xml: DevToolsFrameXMLNode,
            taskIndex: [DevToolsTaskIndexEntry],
            nodeStates: [String: DevToolsNodeStateEntry]
        ) throws -> DevToolsNode {
            try call(
                "devtools.buildTree",
                args: [
                    "xml": AnyEncodable(xml),
                    "taskIndex": AnyEncodable(taskIndex),
                    "nodeStates": AnyEncodable(nodeStates),
                ],
                as: DevToolsNode.self
            )
        }

        static func applyFrameDeltas(
            _ deltas: [DevToolsFrameDelta],
            toKeyframe keyframe: DevToolsFrameXMLNode
        ) throws -> DevToolsFrameXMLNode {
            try call(
                "devtools.applyFrameDeltas",
                args: [
                    "deltas": AnyEncodable(deltas),
                    "keyframe": AnyEncodable(keyframe),
                ],
                as: DevToolsFrameXMLNode.self
            )
        }

        static func applyDelta(_ delta: DevToolsDelta, to tree: DevToolsNode?) throws -> DevToolsNode? {
            let result = try callEncodable(
                "devtools.applyDelta",
                args: ApplyDeltaArgs(delta: delta, tree: tree),
                as: ApplyResult<DevToolsNode>.self
            )
            return try unwrap(result)
        }

        static func applyOp(_ op: DevToolsDeltaOp, to tree: DevToolsNode?) throws -> DevToolsNode? {
            let result = try callEncodable(
                "devtools.applyDeltaOp",
                args: ApplyOpArgs(op: op, tree: tree),
                as: ApplyResult<DevToolsNode>.self
            )
            return try unwrap(result)
        }

        private static func unwrap(_ result: ApplyResult<DevToolsNode>) throws -> DevToolsNode? {
            if result.ok { return result.tree }
            switch result.error {
            case "unknownParent":
                throw ApplyDeltaError.unknownParent(result.id ?? -1)
            case "unknownNode":
                throw ApplyDeltaError.unknownNode(result.id ?? -1)
            case "indexOutOfBounds":
                throw ApplyDeltaError.indexOutOfBounds(
                    parentId: result.parentId ?? -1,
                    index: result.index ?? -1,
                    childCount: result.childCount ?? 0
                )
            default:
                throw SmithersError.api(result.error ?? "devtools delta application failed")
            }
        }

        private static func call<Value: Decodable>(
            _ method: String,
            args: [String: AnyEncodable],
            as type: Value.Type
        ) throws -> Value {
            let data = try callData(method, args: args)
            if Value.self == String.self,
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded as! Value
            }
            if Value.self == String.self {
                return String(decoding: data, as: UTF8.self) as! Value
            }
            return try JSONDecoder().decode(Value.self, from: data)
        }

        private static func callEncodable<Value: Decodable, Args: Encodable>(
            _ method: String,
            args: Args,
            as type: Value.Type
        ) throws -> Value {
            let argsData = try JSONEncoder().encode(args)
            let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
            let data = try callData(method, argsJSON: argsJSON)
            return try JSONDecoder().decode(Value.self, from: data)
        }

        private static func callJSON<Value: Decodable>(
            _ method: String,
            args: [String: Any],
            as type: Value.Type
        ) throws -> Value {
            let data = try JSONSerialization.data(withJSONObject: args, options: [])
            let argsJSON = String(data: data, encoding: .utf8) ?? "{}"
            return try JSONDecoder().decode(Value.self, from: callData(method, argsJSON: argsJSON))
        }

        private static func callData(_ method: String, args: [String: AnyEncodable]) throws -> Data {
            let argsData = try JSONEncoder().encode(args)
            let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
            return try callData(method, argsJSON: argsJSON)
        }

        private static func callData(_ method: String, argsJSON: String) throws -> Data {
            try withClient { client in
                var outError = smithers_error_s(code: 0, msg: nil)
                let result = method.withCString { methodPtr in
                    argsJSON.withCString { argsPtr in
                        smithers_client_call(client, methodPtr, argsPtr, &outError)
                    }
                }
                if let message = Smithers.message(from: outError) {
                    smithers_string_free(result)
                    throw SmithersError.api(message)
                }
                defer { smithers_string_free(result) }
                return Data(Smithers.string(from: result, free: false).utf8)
            }
        }

        private static func withClient<Value>(_ body: @escaping (smithers_client_t) throws -> Value) throws -> Value {
            let run = {
                guard let client = shared.client else {
                    throw SmithersError.notAvailable("libsmithers client is unavailable")
                }
                return try body(client)
            }
            if Thread.isMainThread {
                return try run()
            }
            return try DispatchQueue.main.sync(execute: run)
        }
    }
}
