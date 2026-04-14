import Foundation
import SwiftUI
import CCodexFFI

// MARK: - Codex FFI Bridge

/// Swift wrapper around the codex-ffi C library.
/// Not bound to any actor — all methods are synchronous and block the caller.
class CodexBridge {
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

    /// Send a prompt. Blocks the calling thread. Calls `onEvent` for each JSONL event.
    func send(prompt: String, onEvent: @escaping (String) -> Void) -> Bool {
        guard let h = handle else { return false }

        let context = Unmanaged.passRetained(CallbackBox(onEvent)).toOpaque()

        let result = prompt.withCString { promptPtr in
            codex_send(h, promptPtr, { (eventJson, userData) in
                guard let eventJson = eventJson, let userData = userData else { return }
                let json = String(cString: eventJson)
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.callback(json)
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

// MARK: - Agent Service

@MainActor
class AgentService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false

    private var messageCounter = 0
    private var partialText = ""
    private let workingDir: String

    // Bridge lives on a background thread, never touched from MainActor
    private var bridgeTask: Task<Void, Never>?

    init(workingDir: String? = nil) {
        // Use the actual process cwd (set by the shell that launched us),
        // falling back to home directory if it's "/" (Finder launch).
        let cwd = FileManager.default.currentDirectoryPath
        self.workingDir = workingDir ?? (cwd == "/" ? NSHomeDirectory() : cwd)
    }

    func sendMessage(_ prompt: String) {
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

        let cwd = workingDir

        bridgeTask = Task.detached { [weak self] in
            NSLog("[AgentService] Starting codex turn on background thread, cwd=%@", cwd)

            let bridge = CodexBridge(cwd: cwd)
            guard let bridge = bridge else {
                NSLog("[AgentService] Bridge creation failed")
                await MainActor.run {
                    self?.appendAssistantMessage("Failed to initialize Codex. cwd=\(cwd)")
                    self?.isRunning = false
                }
                return
            }

            let success = bridge.send(prompt: prompt) { json in
                NSLog("[AgentService] Event: %@", json)
                guard let data = json.data(using: .utf8),
                      let event = try? JSONDecoder().decode(CodexEvent.self, from: data)
                else { return }

                DispatchQueue.main.async {
                    self?.handleEvent(event)
                }
            }

            await MainActor.run {
                if !success {
                    self?.appendAssistantMessage("Codex turn failed")
                }
                self?.partialText = ""
                self?.isRunning = false
            }
        }
    }

    func cancel() {
        bridgeTask?.cancel()
        isRunning = false
    }

    private func handleEvent(_ event: CodexEvent) {
        switch event.type {
        case "item.completed", "item.started":
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
                    messageCounter += 1
                    let cmdMsg = ChatMessage(
                        id: "c\(messageCounter)",
                        type: .command,
                        content: "",
                        timestamp: Self.now(),
                        command: Command(
                            cmd: item.command ?? "unknown",
                            cwd: workingDir,
                            output: item.aggregatedOutput ?? "",
                            exitCode: item.exitCode ?? 0,
                            running: event.type == "item.started"
                        ),
                        diff: nil
                    )
                    messages.append(cmdMsg)
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
