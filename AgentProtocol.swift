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

        let line = pending
        pending = ""
        return decodeLine(line).map { [$0] } ?? []
    }

    private func drainCompleteLines() -> [CodexEvent] {
        var events: [CodexEvent] = []

        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)

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
