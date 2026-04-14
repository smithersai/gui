import Foundation
import SwiftUI
import CCodexFFI

// MARK: - Codex FFI Bridge

/// Swift wrapper around the codex-ffi C library.
class CodexBridge {
    private var handle: OpaquePointer?

    init?(cwd: String) {
        handle = cwd.withCString { codex_create($0) }
        if handle == nil { return nil }
    }

    deinit {
        if let h = handle {
            codex_destroy(h)
        }
    }

    /// Send a prompt. Blocks the calling thread. Calls `onEvent` for each JSONL event.
    func send(prompt: String, onEvent: @escaping (String) -> Void) -> Bool {
        guard let h = handle else { return false }

        // Box the closure so we can pass it through void*
        let context = Unmanaged.passRetained(Box(onEvent)).toOpaque()

        let result = prompt.withCString { promptPtr in
            codex_send(h, promptPtr, { (eventJson, userData) in
                guard let eventJson = eventJson, let userData = userData else { return }
                let json = String(cString: eventJson)
                let box = Unmanaged<Box<(String) -> Void>>.fromOpaque(userData).takeUnretainedValue()
                box.value(json)
            }, context)
        }

        // Release the boxed closure
        Unmanaged<Box<(String) -> Void>>.fromOpaque(context).release()
        return result == 0
    }

    func cancel() {
        if let h = handle {
            codex_cancel(h)
        }
    }
}

/// Helper class to box a value for Unmanaged pointer passing.
private class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Agent Service

@MainActor
class AgentService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false

    private var bridge: CodexBridge?
    private var messageCounter = 0
    private var partialText = ""
    private let workingDir: String

    init(workingDir: String = FileManager.default.currentDirectoryPath) {
        self.workingDir = workingDir
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

        Task.detached { [weak self] in
            await self?.runCodex(prompt: prompt)
        }
    }

    func cancel() {
        bridge?.cancel()
    }

    private func runCodex(prompt: String) async {
        // Create bridge if needed (lazy init, so first message pays the cost)
        if bridge == nil {
            let cwd = workingDir
            NSLog("[SmithersGUI] Creating CodexBridge with cwd: \(cwd)")
            bridge = CodexBridge(cwd: cwd)
        }

        guard let bridge = bridge else {
            await MainActor.run {
                self.appendAssistantMessage("Failed to initialize Codex session. Check console for [codex-ffi] logs. cwd=\(self.workingDir)")
                self.isRunning = false
            }
            return
        }

        let success = bridge.send(prompt: prompt) { [weak self] json in
            // This callback runs on the background thread
            guard let self = self else { return }

            // Parse the JSONL event
            guard let data = json.data(using: .utf8),
                  let event = try? JSONDecoder().decode(CodexEvent.self, from: data)
            else { return }

            DispatchQueue.main.async {
                self.handleEvent(event)
            }
        }

        await MainActor.run {
            if !success {
                self.appendAssistantMessage("Codex turn failed")
            }
            self.partialText = ""
            self.isRunning = false
        }
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
                    // Show file changes as a status message
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

        case "error", "turn.failed":
            let errorMsg = event.error?.message ?? "Unknown error"
            appendAssistantMessage("Error: \(errorMsg)")

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
