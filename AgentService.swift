import Foundation
import SwiftUI
import CCodexFFI

// MARK: - Codex FFI Bridge

protocol CodexBridgeControlling: AnyObject, Sendable {
    func cancel()
}

/// Swift wrapper around the codex-ffi C library.
/// Not bound to any actor — all methods are synchronous and block the caller.
final class CodexBridge: CodexBridgeControlling, @unchecked Sendable {
    private var handle: OpaquePointer?

    init?(cwd: String) {
        NSLog("[CodexBridge] init with cwd: %@", cwd)
        handle = cwd.withCString { codex_create($0) }
        if handle == nil {
            NSLog("[CodexBridge] codex_create returned NULL")
            return nil
        }
        NSLog("[CodexBridge] codex_create succeeded")
    }

    deinit {
        if let h = handle {
            codex_destroy(h)
        }
    }

    /// Send a prompt. Blocks the calling thread. Calls `onEvent` for each JSONL chunk.
    func send(prompt: String, onEvent: @escaping (String) -> Void) -> Bool {
        guard let h = handle else { return false }

        let context = Unmanaged.passRetained(CallbackBox(onEvent)).toOpaque()

        let result = prompt.withCString { promptPtr in
            codex_send(h, promptPtr, { (eventJson, userData) in
                guard let eventJson = eventJson, let userData = userData else { return }
                let json = String(cString: eventJson)
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.callback(json.hasSuffix("\n") ? json : json + "\n")
            }, context)
        }

        Unmanaged<CallbackBox>.fromOpaque(context).release()
        return result == 0
    }

    func cancel() {
        if let h = handle {
            codex_cancel(h)
        }
    }
}

/// Helper to box a closure for Unmanaged pointer passing.
private class CallbackBox {
    let callback: (String) -> Void
    init(_ callback: @escaping (String) -> Void) { self.callback = callback }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class CodexBridgeLifecycle<Bridge: CodexBridgeControlling>: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTurnID = UUID()
    private var bridge: Bridge?

    func beginTurn(_ turnID: UUID) -> Bridge? {
        lock.lock()
        currentTurnID = turnID
        let current = bridge
        bridge = nil
        lock.unlock()
        return current
    }

    func cancelTurn(_ turnID: UUID) -> Bridge? {
        lock.lock()
        currentTurnID = turnID
        let current = bridge
        bridge = nil
        lock.unlock()
        return current
    }

    func isCurrent(_ turnID: UUID) -> Bool {
        lock.lock()
        let isCurrent = currentTurnID == turnID
        lock.unlock()
        return isCurrent
    }

    func activate(_ bridge: Bridge, for turnID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard currentTurnID == turnID, self.bridge == nil else {
            return false
        }

        self.bridge = bridge
        return true
    }

    func clear(ifSame bridge: Bridge, for turnID: UUID) {
        lock.lock()
        if currentTurnID == turnID, self.bridge === bridge {
            self.bridge = nil
        }
        lock.unlock()
    }
}

/// Serializes `codex_create` so cancelled turns cannot race multiple bridge creations.
private final class CodexBridgeCreationQueue: @unchecked Sendable {
    private let lock = NSLock()

    func create(cwd: String, if shouldCreate: () -> Bool) -> CodexBridge? {
        lock.lock()
        defer { lock.unlock() }

        guard shouldCreate() else {
            return nil
        }

        return CodexBridge(cwd: cwd)
    }
}

// MARK: - Agent Service

@MainActor
class AgentService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false

    private var messageCounter = 0
    private var partialText = ""
    private var commandMessageIDsByItemID: [String: String] = [:]
    private var statusMessageIDsByItemID: [String: String] = [:]
    private let workingDir: String

    // Bridge lives on a background thread, never touched from MainActor
    private var bridgeTask: Task<Void, Never>?
    private let bridgeLifecycle = CodexBridgeLifecycle<CodexBridge>()
    private let bridgeCreationQueue = CodexBridgeCreationQueue()
    private var currentTurnID = UUID()

    var workingDirectory: String { workingDir }

    init(workingDir: String? = nil) {
        self.workingDir = CWDResolver.resolve(workingDir)
    }

    func sendMessage(_ prompt: String) {
        currentTurnID = UUID()
        let turnID = currentTurnID
        commandMessageIDsByItemID.removeAll()
        statusMessageIDsByItemID.removeAll()

        bridgeTask?.cancel()
        bridgeTask = nil
        cancelBridge(bridgeLifecycle.beginTurn(turnID))

        messageCounter += 1
        let userMsg = ChatMessage(
            id: "u\(messageCounter)",
            type: .user,
            content: prompt,
            timestamp: Self.now(),
            command: nil,
            diff: nil
        )
        messages.append(userMsg)
        partialText = ""
        isRunning = true

        if UITestSupport.isEnabled || UITestSupport.isRunningUnitTests {
            let responseNumber = messageCounter
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.isRunning, self.currentTurnID == turnID else { return }
                self.appendAssistantMessage("UI test response for: \(prompt)")
                self.partialText = ""
                self.isRunning = false
                NSLog("[AgentService] Simulated UI test turn %@", "\(responseNumber)")
            }
            return
        }

        let cwd = workingDir
        let bridgeLifecycle = bridgeLifecycle
        let bridgeCreationQueue = bridgeCreationQueue

        weak var weakSelf = self
        bridgeTask = Task.detached { [cwd, prompt, turnID, bridgeLifecycle, bridgeCreationQueue, weakSelf] in
            NSLog("[AgentService] Starting codex turn on background thread, cwd=%@", cwd)

            let bridge = bridgeCreationQueue.create(cwd: cwd) {
                !Task.isCancelled && bridgeLifecycle.isCurrent(turnID)
            }
            guard let bridge = bridge else {
                if Task.isCancelled || !bridgeLifecycle.isCurrent(turnID) {
                    NSLog("[AgentService] Bridge creation skipped for stale or cancelled turn")
                    return
                }
                NSLog("[AgentService] Bridge creation failed")
                await MainActor.run {
                    guard let self = weakSelf, self.currentTurnID == turnID else { return }
                    self.appendAssistantMessage("Failed to initialize Codex. cwd=\(cwd)")
                    self.isRunning = false
                    self.bridgeTask = nil
                }
                return
            }
            guard !Task.isCancelled, bridgeLifecycle.activate(bridge, for: turnID) else {
                NSLog("[AgentService] Discarding bridge for stale or cancelled turn")
                bridge.cancel()
                return
            }

            let eventBuffer = CodexJSONLLineBuffer()
            func enqueueEvent(_ event: CodexEvent) {
                Task { @MainActor in
                    guard let self = weakSelf,
                          self.currentTurnID == turnID
                    else { return }
                    self.handleEvent(event)
                }
            }

            let success = bridge.send(prompt: prompt) { chunk in
                NSLog("[AgentService] Event chunk: %@", chunk)
                for event in eventBuffer.append(chunk) {
                    enqueueEvent(event)
                }
            }
            for event in eventBuffer.finish() {
                enqueueEvent(event)
            }
            bridgeLifecycle.clear(ifSame: bridge, for: turnID)

            await MainActor.run {
                guard let self = weakSelf, self.currentTurnID == turnID else { return }
                if !success && self.isRunning {
                    self.appendAssistantMessage("Codex turn failed")
                }
                self.partialText = ""
                self.isRunning = false
                self.bridgeTask = nil
            }
        }
    }

    func cancel() {
        currentTurnID = UUID()
        bridgeTask?.cancel()
        bridgeTask = nil
        cancelBridge(bridgeLifecycle.cancelTurn(currentTurnID))
        partialText = ""
        commandMessageIDsByItemID.removeAll()
        statusMessageIDsByItemID.removeAll()
        isRunning = false
    }

    private nonisolated func cancelBridge(_ bridge: CodexBridge?) {
        guard let bridge else { return }
        Task.detached {
            bridge.cancel()
        }
    }

    func clearMessages() {
        messages.removeAll()
        partialText = ""
        commandMessageIDsByItemID.removeAll()
        statusMessageIDsByItemID.removeAll()
    }

    func appendStatusMessage(_ text: String) {
        messageCounter += 1
        messages.append(ChatMessage(
            id: "s\(messageCounter)",
            type: .status,
            content: text,
            timestamp: Self.now(),
            command: nil,
            diff: nil
        ))
    }

    func handleEvent(_ event: CodexEvent) {
        switch event.type {
        case "item.completed", "item.started", "item.updated", "item.progress":
            if let item = event.item {
                if item.type == "agent_message", let text = item.text {
                    if partialText.isEmpty {
                        partialText = text
                    } else {
                        partialText += "\n\n" + text
                    }
                    updateOrAppendAssistantMessage(partialText)
                }

                if item.type == "command_execution" {
                    updateOrAppendCommandMessage(for: item, eventType: event.type)
                }

                if item.type == "todo_list", let content = todoListStatusContent(for: item) {
                    updateOrAppendStatusMessage(for: item, content: content)
                }

                if item.type == "web_search", let content = webSearchStatusContent(for: item) {
                    updateOrAppendStatusMessage(for: item, content: content)
                }

                if item.type == "mcp_tool_call", let content = mcpToolCallStatusContent(for: item) {
                    updateOrAppendStatusMessage(for: item, content: content)
                }

                if item.type == "error", let message = item.message?.nilIfBlank {
                    updateOrAppendStatusMessage(for: item, content: "Codex item error:\n\(message)")
                }

                if item.type == "file_change" {
                    if let changes = item.changes {
                        let summary = changes.map { "\($0.kind): \($0.path)" }.joined(separator: "\n")
                        messageCounter += 1
                        messages.append(ChatMessage(
                            id: "f\(messageCounter)",
                            type: .status,
                            content: "File changes:\n\(summary)",
                            timestamp: Self.now(),
                            command: nil,
                            diff: nil
                        ))
                    }
                }
            }

        case "turn.completed":
            break

        case "turn.failed":
            let errorMsg = event.error?.message ?? event.message ?? "Unknown error"
            appendAssistantMessage("Error: \(errorMsg)")

        case "error":
            // Non-fatal errors (e.g. MCP login warnings) — log but don't show
            if let msg = event.message {
                NSLog("[AgentService] non-fatal error: %@", msg)
            }

        default:
            break
        }
    }

    private func updateOrAppendAssistantMessage(_ text: String) {
        if let lastIdx = messages.indices.last, messages[lastIdx].type == .assistant {
            messages[lastIdx] = ChatMessage(
                id: messages[lastIdx].id,
                type: .assistant,
                content: text,
                timestamp: Self.now(),
                command: nil,
                diff: nil
            )
        } else {
            messageCounter += 1
            messages.append(ChatMessage(
                id: "a\(messageCounter)",
                type: .assistant,
                content: text,
                timestamp: Self.now(),
                command: nil,
                diff: nil
            ))
        }
    }

    private func updateOrAppendCommandMessage(for item: CodexItem, eventType: String) {
        let itemID = normalizedCommandItemID(item.id)
        let existingIndex = itemID
            .flatMap { commandMessageIDsByItemID[$0] }
            .flatMap { messageID in messages.firstIndex { $0.id == messageID } }
        let existingMessage = existingIndex.map { messages[$0] }
        let existingCommand = existingMessage?.command
        let command = Command(
            itemID: itemID,
            cmd: item.command ?? existingCommand?.cmd ?? "unknown",
            cwd: existingCommand?.cwd ?? workingDir,
            output: item.aggregatedOutput ?? existingCommand?.output ?? "",
            exitCode: item.exitCode ?? existingCommand?.exitCode ?? 0,
            running: commandIsRunning(eventType: eventType, item: item)
        )

        if let existingIndex {
            messages[existingIndex] = ChatMessage(
                id: messages[existingIndex].id,
                type: .command,
                content: messages[existingIndex].content,
                timestamp: messages[existingIndex].timestamp,
                command: command,
                diff: nil
            )
            return
        }

        messageCounter += 1
        let messageID = "c\(messageCounter)"
        if let itemID {
            commandMessageIDsByItemID[itemID] = messageID
        }
        messages.append(ChatMessage(
            id: messageID,
            type: .command,
            content: "",
            timestamp: Self.now(),
            command: command,
            diff: nil
        ))
    }

    private func updateOrAppendStatusMessage(for item: CodexItem, content: String) {
        let itemID = normalizedCommandItemID(item.id)
        let existingIndex = itemID
            .flatMap { statusMessageIDsByItemID[$0] }
            .flatMap { messageID in messages.firstIndex { $0.id == messageID } }

        if let existingIndex {
            messages[existingIndex] = ChatMessage(
                id: messages[existingIndex].id,
                type: .status,
                content: content,
                timestamp: messages[existingIndex].timestamp,
                command: nil,
                diff: nil
            )
            return
        }

        messageCounter += 1
        let messageID = "s\(messageCounter)"
        if let itemID {
            statusMessageIDsByItemID[itemID] = messageID
        }
        messages.append(ChatMessage(
            id: messageID,
            type: .status,
            content: content,
            timestamp: Self.now(),
            command: nil,
            diff: nil
        ))
    }

    private func todoListStatusContent(for item: CodexItem) -> String? {
        guard let todos = item.items else {
            return "Plan updated"
        }

        guard !todos.isEmpty else {
            return "Plan updated\nNo steps"
        }

        let lines = todos.map { todo in
            "\(todo.completed ? "[x]" : "[ ]") \(todo.text)"
        }
        return "Plan updated\n" + lines.joined(separator: "\n")
    }

    private func webSearchStatusContent(for item: CodexItem) -> String? {
        guard let query = item.query?.nilIfBlank else {
            return "Web search"
        }
        return "Web search\n\(query)"
    }

    private func mcpToolCallStatusContent(for item: CodexItem) -> String? {
        let server = item.server?.nilIfBlank
        let tool = item.tool?.nilIfBlank
        let target = [server, tool].compactMap { $0 }.joined(separator: "/")
        let name = target.isEmpty ? "MCP tool" : "MCP tool: \(target)"

        guard let status = item.status?.nilIfBlank else {
            return name
        }
        return "\(name)\nStatus: \(status)"
    }

    private func normalizedCommandItemID(_ id: String?) -> String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func commandIsRunning(eventType: String, item: CodexItem) -> Bool {
        switch item.status?.lowercased() {
        case "completed", "failed", "cancelled", "canceled":
            return false
        case "running", "started", "in_progress":
            return true
        default:
            return eventType != "item.completed"
        }
    }

    private func appendAssistantMessage(_ text: String) {
        messageCounter += 1
        messages.append(ChatMessage(
            id: "a\(messageCounter)",
            type: .assistant,
            content: text,
            timestamp: Self.now(),
            command: nil,
            diff: nil
        ))
    }

    private static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: Date())
    }
}
