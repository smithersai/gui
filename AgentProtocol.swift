import Foundation

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

    enum CodingKeys: String, CodingKey {
        case id, type, text, command, status, changes, query, items
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
