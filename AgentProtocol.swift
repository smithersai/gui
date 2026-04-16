import Foundation
import os

// MARK: - Codex JSONL Event Types (matches codex-exec ThreadEvent format)

struct CodexEvent: Decodable {
    let type: String
    let item: CodexItem?
    let usage: CodexUsage?
    let threadId: String?
    let message: String?  // top-level message for "error" and "turn.failed" events
    let error: CodexErrorInfo?  // nested error for "turn.failed"

    enum CodingKeys: String, CodingKey {
        case type, item, usage, message, error
        case threadId = "thread_id"
    }
}

struct CodexErrorInfo: Decodable {
    let message: String?
}

struct AnyCodable: Codable, Equatable {
    private enum Storage: Equatable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([AnyCodable])
        case object([String: AnyCodable])
    }

    private let storage: Storage

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            storage = .null
        } else if let value = try? container.decode(Bool.self) {
            storage = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            storage = .number(value)
        } else if let value = try? container.decode(String.self) {
            storage = .string(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            storage = .array(value)
        } else {
            storage = .object(try container.decode([String: AnyCodable].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var displayString: String? {
        switch storage {
        case .null:
            return nil
        case .string(let value):
            return value
        case .bool, .number, .array, .object:
            return compactJSONString
        }
    }

    private var compactJSONString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct CodexItem: Decodable {
    let id: String?
    let type: String?
    let text: String?
    let command: String?
    let aggregatedOutput: String?
    let exitCode: Int?
    let status: String?
    let changes: [CodexFileChange]?
    let query: String?
    let items: [CodexTodoItem]?
    let server: String?
    let tool: String?
    let message: String?
    let details: String?
    let input: String?
    let output: String?
    let name: String?
    let path: String?
    let url: String?
    let format: String?
    let prompt: String?
    let symbol: String?
    let arguments: String?

    enum CodingKeys: String, CodingKey {
        case id, type, text, command, status, changes, query, items, server, tool, message
        case details, input, output, name, path, url, format, prompt, symbol, arguments
        case aggregatedOutput = "aggregated_output"
        case exitCode = "exit_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        aggregatedOutput = try container.decodeIfPresent(String.self, forKey: .aggregatedOutput)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        changes = try container.decodeIfPresent([CodexFileChange].self, forKey: .changes)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        items = try container.decodeIfPresent([CodexTodoItem].self, forKey: .items)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        details = try Self.decodeFlexibleDisplayString(from: container, forKey: .details)
        input = try Self.decodeFlexibleDisplayString(from: container, forKey: .input)
        output = try Self.decodeFlexibleDisplayString(from: container, forKey: .output)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        arguments = try Self.decodeFlexibleDisplayString(from: container, forKey: .arguments)
    }

    private static func decodeFlexibleDisplayString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if let string = try container.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        return try container.decodeIfPresent(AnyCodable.self, forKey: key)?.displayString
    }
}

struct CodexFileChange: Decodable {
    let path: String
    let kind: String
}

struct CodexTodoItem: Decodable {
    let text: String
    let completed: Bool
}

struct CodexUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
    }
}

final class CodexJSONLLineBuffer: @unchecked Sendable {
    private static let maxPendingBytes = 10 * 1024 * 1024

    private let lock = NSLock()
    private let decoder = JSONDecoder()
    private let logger = os.Logger(subsystem: "com.smithers.gui", category: "codex-jsonl")
    private var pending = ""

    func append(_ chunk: String) -> [CodexEvent] {
        guard !chunk.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        pending += chunk
        let events = drainCompleteLines()
        if pending.utf8.count > Self.maxPendingBytes {
            logger.warning("Codex JSONL pending buffer exceeded \(Self.maxPendingBytes, privacy: .public) bytes; dropping buffered data")
            pending = ""
        }
        return events
    }

    func finish() -> [CodexEvent] {
        lock.lock()
        defer { lock.unlock() }

        var events = drainCompleteLines()
        let line = pending
        pending = ""
        if let event = decodeLine(line) {
            events.append(event)
        }
        return events
    }

    private func drainCompleteLines() -> [CodexEvent] {
        var events: [CodexEvent] = []

        while let delimiter = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pending[..<delimiter])

            var removeEnd = pending.index(after: delimiter)
            if pending[delimiter] == "\r",
               removeEnd < pending.endIndex,
               pending[removeEnd] == "\n" {
                removeEnd = pending.index(after: removeEnd)
            }
            pending.removeSubrange(..<removeEnd)

            if let event = decodeLine(line) {
                events.append(event)
            }
        }

        return events
    }

    private func decodeLine(_ line: String) -> CodexEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return nil
        }

        do {
            return try decoder.decode(CodexEvent.self, from: data)
        } catch {
            logger.warning("Malformed Codex JSONL line dropped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
