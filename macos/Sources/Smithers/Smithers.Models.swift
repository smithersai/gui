import Foundation
import CSmithersKit

extension Smithers {
    enum Models {
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

        private struct ChatMessageDedupProjection: Encodable {
            let commandItemId: String?
            let toolItemId: String?
        }

        private struct ChatBlockPair: Encodable {
            let existing: ChatBlock
            let incoming: ChatBlock
        }

        private struct StreamingContentArgs: Encodable {
            let existing: String
            let incoming: String
            let existingTimestampMs: Int64?
            let incomingTimestampMs: Int64?
        }

        private struct OptionalStringResult: Decodable {
            let value: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                value = container.decodeNil() ? nil : try container.decode(String.self)
            }
        }

        private struct SSEFilterResult: Decodable {
            let event: String?
            let data: String
            let runId: String?
        }

        nonisolated(unsafe) private static let shared = SharedClient()

        static func aggregateScores(_ scores: [ScoreRow]) throws -> [AggregateScore] {
            try call(
                "models.aggregateScores",
                args: ["scores": AnyEncodable(scores)],
                as: [AggregateScore].self
            )
        }

        static func deduplicatedChatMessages(_ messages: [ChatMessage]) throws -> [ChatMessage] {
            let projections = messages.map {
                ChatMessageDedupProjection(
                    commandItemId: $0.command?.itemID,
                    toolItemId: $0.tool?.itemID
                )
            }
            let indexes = try callEncodable(
                "models.deduplicateChatMessageIndexes",
                args: ["messages": AnyEncodable(projections)],
                as: [Int].self
            )
            return indexes.compactMap { messages.indices.contains($0) ? messages[$0] : nil }
        }

        static func deduplicatedChatBlocks(_ blocks: [ChatBlock]) throws -> [ChatBlock] {
            try call(
                "models.deduplicateChatBlocks",
                args: ["blocks": AnyEncodable(blocks)],
                as: [ChatBlock].self
            )
        }

        static func chatBlockCanMerge(_ existing: ChatBlock, with incoming: ChatBlock) throws -> Bool {
            try callPair("models.chatBlockCanMerge", existing: existing, incoming: incoming, as: Bool.self)
        }

        static func chatBlockHasOverlap(_ existing: ChatBlock, with incoming: ChatBlock) throws -> Bool {
            try callPair("models.chatBlockHasOverlap", existing: existing, incoming: incoming, as: Bool.self)
        }

        static func chatBlockMerge(_ existing: ChatBlock, with incoming: ChatBlock) throws -> ChatBlock {
            try callPair("models.chatBlockMerge", existing: existing, incoming: incoming, as: ChatBlock.self)
        }

        static func mergedStreamingContent(
            existing: String,
            incoming: String,
            existingTimestampMs: Int64? = nil,
            incomingTimestampMs: Int64? = nil
        ) throws -> String {
            try callEncodable(
                "models.chatBlockMergedStreamingContent",
                args: StreamingContentArgs(
                    existing: existing,
                    incoming: incoming,
                    existingTimestampMs: existingTimestampMs,
                    incomingTimestampMs: incomingTimestampMs
                ),
                as: String.self
            )
        }

        static func filteredSSEEvent(
            event: String?,
            data: String,
            eventRunId: String?,
            expectedRunId: String?,
            requireAttributedRunId: Bool
        ) throws -> SSEEvent? {
            let result = try call(
                "models.sseFiltered",
                args: [
                    "event": AnyEncodable(event),
                    "data": AnyEncodable(data),
                    "eventRunId": AnyEncodable(eventRunId),
                    "expectedRunId": AnyEncodable(expectedRunId),
                    "requireAttributedRunId": AnyEncodable(requireAttributedRunId),
                ],
                as: Optional<SSEFilterResult>.self
            )
            guard let result else { return nil }
            return SSEEvent(event: result.event, data: result.data, runId: result.runId)
        }

        static func sseExtractRunId(from data: String) throws -> String? {
            try call(
                "models.sseExtractRunId",
                args: ["data": AnyEncodable(data)],
                as: OptionalStringResult.self
            ).value
        }

        static func sseRunId(_ actualRunId: String?, matches expectedRunId: String?) throws -> Bool {
            try call(
                "models.sseRunIdMatches",
                args: [
                    "actualRunId": AnyEncodable(actualRunId),
                    "expectedRunId": AnyEncodable(expectedRunId),
                ],
                as: Bool.self
            )
        }

        static func sseNormalizedRunId(_ runId: String?) throws -> String? {
            try call(
                "models.sseNormalizedRunId",
                args: ["runId": AnyEncodable(runId)],
                as: OptionalStringResult.self
            ).value
        }

        private static func callPair<Value: Decodable>(
            _ method: String,
            existing: ChatBlock,
            incoming: ChatBlock,
            as type: Value.Type
        ) throws -> Value {
            try callEncodable(
                method,
                args: ChatBlockPair(existing: existing, incoming: incoming),
                as: Value.self
            )
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
            if Value.self == String.self,
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded as! Value
            }
            return try JSONDecoder().decode(Value.self, from: data)
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
