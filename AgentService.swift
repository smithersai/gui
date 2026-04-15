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
    private let callbackLock = NSLock()
    private var callbackContexts: [UnsafeMutableRawPointer] = []

    init?(
        cwd: String,
        model: String?,
        reasoningEffort: CodexReasoningEffort?,
        approvalPolicy: CodexApprovalPolicy?,
        sandboxMode: CodexSandboxMode?,
        createCancellationToken: CodexCreateCancellationToken?
    ) {
        let createCancellationTokenID = createCancellationToken?.id ?? 0
        AppLogger.codex.info(
            "CodexBridge init",
            metadata: [
                "cwd": cwd,
                "model": model ?? "default",
                "reasoning_effort": reasoningEffort?.rawValue ?? "default",
                "approval_policy": approvalPolicy?.rawValue ?? "default",
                "sandbox_mode": sandboxMode?.rawValue ?? "default",
                "create_cancellation_token_id": "\(createCancellationTokenID)",
            ]
        )

        handle = cwd.withCString { cwdPtr in
            withOptionalCString(model) { modelPtr in
                withOptionalCString(reasoningEffort?.rawValue) { effortPtr in
                    withOptionalCString(approvalPolicy?.rawValue) { approvalPtr in
                        withOptionalCString(sandboxMode?.rawValue) { sandboxPtr in
                            codex_create_with_options_and_cancellation(
                                cwdPtr,
                                modelPtr,
                                effortPtr,
                                approvalPtr,
                                sandboxPtr,
                                createCancellationTokenID
                            )
                        }
                    }
                }
            }
        }
        if handle == nil {
            AppLogger.codex.error("CodexBridge codex_create_with_options returned NULL")
            return nil
        }
        AppLogger.codex.info("CodexBridge codex_create_with_options succeeded")
    }

    deinit {
        if let h = handle {
            codex_destroy(h)
        }
        releaseCallbackContexts()
    }

    /// Send a prompt. Blocks the calling thread. Calls `onEvent` for each JSONL chunk.
    func send(prompt: String, onEvent: @escaping (String) -> Void) -> Bool {
        guard let h = handle else { return false }

        let context = retainCallbackContext(CallbackBox(onEvent))

        let result = prompt.withCString { promptPtr in
            codex_send(h, promptPtr, { (eventJson, userData) in
                guard let eventJson = eventJson, let userData = userData else { return }
                let json = String(cString: eventJson)
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.callback(json.hasSuffix("\n") ? json : json + "\n")
            }, context)
        }

        return result == 0
    }

    func cancel() {
        if let h = handle {
            codex_cancel(h)
        }
    }

    private func retainCallbackContext(_ box: CallbackBox) -> UnsafeMutableRawPointer {
        let context = Unmanaged.passRetained(box).toOpaque()
        callbackLock.lock()
        callbackContexts.append(context)
        callbackLock.unlock()
        return context
    }

    private func releaseCallbackContexts() {
        callbackLock.lock()
        let contexts = callbackContexts
        callbackContexts.removeAll()
        callbackLock.unlock()

        for context in contexts {
            Unmanaged<CallbackBox>.fromOpaque(context).release()
        }
    }
}

/// Helper to box a closure for Unmanaged pointer passing.
private class CallbackBox {
    let callback: (String) -> Void
    init(_ callback: @escaping (String) -> Void) { self.callback = callback }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value else {
        return body(nil)
    }
    return value.withCString { ptr in
        body(ptr)
    }
}

final class CodexCreateCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var tokenID: Int64

    init?() {
        let allocatedTokenID = codex_create_cancellation_token_new()
        guard allocatedTokenID > 0 else {
            AppLogger.codex.error("Codex create cancellation token allocation failed")
            return nil
        }
        tokenID = allocatedTokenID
    }

    var id: Int64 {
        lock.lock()
        let id = tokenID
        lock.unlock()
        return id
    }

    func cancel() {
        let id: Int64
        lock.lock()
        id = tokenID
        lock.unlock()
        guard id > 0 else { return }
        codex_create_cancellation_token_cancel(id)
    }

    deinit {
        let id: Int64
        lock.lock()
        id = tokenID
        tokenID = 0
        lock.unlock()
        guard id > 0 else { return }
        codex_create_cancellation_token_free(id)
    }
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

    func create(
        cwd: String,
        model: String?,
        reasoningEffort: CodexReasoningEffort?,
        approvalPolicy: CodexApprovalPolicy?,
        sandboxMode: CodexSandboxMode?,
        createCancellationToken: CodexCreateCancellationToken?,
        if shouldCreate: () -> Bool
    ) -> CodexBridge? {
        lock.lock()
        defer { lock.unlock() }

        guard shouldCreate() else {
            return nil
        }

        return CodexBridge(
            cwd: cwd,
            model: model,
            reasoningEffort: reasoningEffort,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            createCancellationToken: createCancellationToken
        )
    }
}

// MARK: - Agent Service

@MainActor
class AgentService: ObservableObject {
    @Published private(set) var transcriptUpdateToken: UInt64 = 0
    @Published var messages: [ChatMessage] = [] {
        didSet {
            transcriptUpdateToken &+= 1
        }
    }
    @Published var isRunning = false
    @Published private(set) var activeThreadID: String?
    @Published private(set) var recentErrorMessage: String?

    private var messageCounter = 0
    private var partialText = ""
    private var commandMessageIDsByItemID: [String: String] = [:]
    private var statusMessageIDsByItemID: [String: String] = [:]
    private var toolMessageIDsByItemID: [String: String] = [:]
    private var thinkingMessageIDsByItemID: [String: String] = [:]
    private var currentTurnFailed = false
    private var lastNonFatalWarningMessage = ""
    private var lastNonFatalWarningAt = Date.distantPast
    private let workingDir: String
    private var modelOverride: String?
    private var reasoningEffortOverride: CodexReasoningEffort?
    private var approvalPolicyOverride: CodexApprovalPolicy?
    private var sandboxModeOverride: CodexSandboxMode?

    // Bridge lives on a background thread, never touched from MainActor
    private var bridgeTask: Task<Void, Never>?
    private let bridgeLifecycle = CodexBridgeLifecycle<CodexBridge>()
    private let bridgeCreationQueue = CodexBridgeCreationQueue()
    private var bridgeCreationCancellationToken: CodexCreateCancellationToken?
    private var currentTurnID = UUID()

    var workingDirectory: String { workingDir }

    init(
        workingDir: String? = nil,
        modelOverride: String? = nil,
        reasoningEffortOverride: CodexReasoningEffort? = nil,
        approvalPolicyOverride: CodexApprovalPolicy? = nil,
        sandboxModeOverride: CodexSandboxMode? = nil
    ) {
        self.workingDir = CWDResolver.resolve(workingDir)
        self.modelOverride = modelOverride?.nilIfBlank
        self.reasoningEffortOverride = reasoningEffortOverride
        self.approvalPolicyOverride = approvalPolicyOverride
        self.sandboxModeOverride = sandboxModeOverride
    }

    func updateModelSelection(model: String, reasoningEffort: CodexReasoningEffort?) {
        modelOverride = model.nilIfBlank
        reasoningEffortOverride = reasoningEffort
    }

    func updateApprovalSelection(approvalPolicy: CodexApprovalPolicy, sandboxMode: CodexSandboxMode) {
        approvalPolicyOverride = approvalPolicy
        sandboxModeOverride = sandboxMode
    }

    func sendMessage(_ prompt: String, displayText: String? = nil) {
        AppLogger.agent.info("AgentService sendMessage", metadata: ["prompt_length": "\(prompt.count)"])
        currentTurnID = UUID()
        let turnID = currentTurnID
        commandMessageIDsByItemID.removeAll()
        statusMessageIDsByItemID.removeAll()
        toolMessageIDsByItemID.removeAll()
        thinkingMessageIDsByItemID.removeAll()
        currentTurnFailed = false

        bridgeTask?.cancel()
        bridgeTask = nil
        cancelBridgeCreationToken()
        cancelBridge(bridgeLifecycle.beginTurn(turnID))

        let visiblePrompt: String
        if let displayText, !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visiblePrompt = displayText
        } else {
            visiblePrompt = prompt
        }

        messageCounter += 1
        let userMsg = ChatMessage(
            id: "u\(messageCounter)",
            type: .user,
            content: visiblePrompt,
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
                AppLogger.agent.debug("AgentService simulated UI test turn", metadata: ["turn": "\(responseNumber)"])
            }
            return
        }

        let cwd = workingDir
        let modelOverride = modelOverride
        let reasoningEffortOverride = reasoningEffortOverride
        let approvalPolicyOverride = approvalPolicyOverride
        let sandboxModeOverride = sandboxModeOverride
        let bridgeLifecycle = bridgeLifecycle
        let bridgeCreationQueue = bridgeCreationQueue
        let bridgeCreationCancellationToken = CodexCreateCancellationToken()
        self.bridgeCreationCancellationToken = bridgeCreationCancellationToken

        bridgeTask = Task.detached {
            [
                cwd,
                prompt,
                turnID,
                bridgeLifecycle,
                bridgeCreationQueue,
                modelOverride,
                reasoningEffortOverride,
                approvalPolicyOverride,
                sandboxModeOverride,
                bridgeCreationCancellationToken,
                weak self,
            ] in
            AppLogger.agent.info(
                "AgentService starting codex turn",
                metadata: [
                    "cwd": cwd,
                    "model": modelOverride ?? "default",
                    "reasoning_effort": reasoningEffortOverride?.rawValue ?? "default",
                    "approval_policy": approvalPolicyOverride?.rawValue ?? "default",
                    "sandbox_mode": sandboxModeOverride?.rawValue ?? "default",
                ]
            )

            let bridge = bridgeCreationQueue.create(
                cwd: cwd,
                model: modelOverride,
                reasoningEffort: reasoningEffortOverride,
                approvalPolicy: approvalPolicyOverride,
                sandboxMode: sandboxModeOverride,
                createCancellationToken: bridgeCreationCancellationToken
            ) {
                !Task.isCancelled && bridgeLifecycle.isCurrent(turnID)
            }
            await self?.clearBridgeCreationTokenIfCurrent(bridgeCreationCancellationToken, turnID: turnID)
            guard let bridge = bridge else {
                if Task.isCancelled || !bridgeLifecycle.isCurrent(turnID) {
                    AppLogger.agent.debug("AgentService bridge creation skipped (stale/cancelled turn)")
                    return
                }
                AppLogger.agent.error("AgentService bridge creation failed")
                await self?.handleBridgeCreationFailure(cwd: cwd, turnID: turnID)
                return
            }
            guard !Task.isCancelled, bridgeLifecycle.activate(bridge, for: turnID) else {
                AppLogger.agent.debug("AgentService discarding bridge (stale/cancelled turn)")
                bridge.cancel()
                return
            }

            let eventBuffer = CodexJSONLLineBuffer()
            let (eventStream, eventContinuation) = AsyncStream<CodexEvent>.makeStream()
            let eventConsumer = Task { [weak self] in
                for await event in eventStream {
                    await MainActor.run {
                        guard let self,
                              self.currentTurnID == turnID
                        else { return }
                        self.handleEvent(event)
                    }
                }
            }

            let success = bridge.send(prompt: prompt) { chunk in
                AppLogger.codex.debug("AgentService event chunk", metadata: ["size": "\(chunk.count)"])
                for event in eventBuffer.append(chunk) {
                    eventContinuation.yield(event)
                }
            }
            for event in eventBuffer.finish() {
                eventContinuation.yield(event)
            }
            eventContinuation.finish()
            await eventConsumer.value
            bridgeLifecycle.clear(ifSame: bridge, for: turnID)

            await self?.finishDetachedTurn(success: success, turnID: turnID)
        }
    }

    func cancel() {
        AppLogger.agent.info("AgentService cancel requested")
        currentTurnID = UUID()
        bridgeTask?.cancel()
        bridgeTask = nil
        cancelBridgeCreationToken()
        cancelBridge(bridgeLifecycle.cancelTurn(currentTurnID))
        partialText = ""
        commandMessageIDsByItemID.removeAll()
        statusMessageIDsByItemID.removeAll()
        toolMessageIDsByItemID.removeAll()
        thinkingMessageIDsByItemID.removeAll()
        currentTurnFailed = false
        isRunning = false
    }

    private nonisolated func cancelBridge(_ bridge: CodexBridge?) {
        guard let bridge else { return }
        Task.detached {
            bridge.cancel()
        }
    }

    private func cancelBridgeCreationToken() {
        bridgeCreationCancellationToken?.cancel()
        bridgeCreationCancellationToken = nil
    }

    private func clearBridgeCreationTokenIfCurrent(_ token: CodexCreateCancellationToken?, turnID: UUID) {
        guard currentTurnID == turnID else { return }
        guard bridgeCreationCancellationToken === token else { return }
        bridgeCreationCancellationToken = nil
    }

    private func handleBridgeCreationFailure(cwd: String, turnID: UUID) {
        guard currentTurnID == turnID else { return }
        trackRecentError("Could not initialize a Codex session.")
        appendAssistantMessage("Failed to initialize Codex. cwd=\(cwd)")
        AppNotifications.shared.post(
            title: "Codex failed to start",
            message: "Could not initialize a Codex session.",
            level: .error,
            nativeWhenInactive: true
        )
        isRunning = false
        bridgeTask = nil
    }

    private func finishDetachedTurn(success: Bool, turnID: UUID) {
        guard currentTurnID == turnID else { return }
        if !success && isRunning {
            trackRecentError("Codex exited before completing a response.")
            appendAssistantMessage("Codex turn failed")
            if !currentTurnFailed {
                AppNotifications.shared.post(
                    title: "Codex turn failed",
                    message: "Codex exited before completing a response.",
                    level: .error,
                    nativeWhenInactive: true
                )
            }
        } else if success {
            AppNotifications.shared.post(
                title: "Codex completed",
                message: "Agent response is ready.",
                level: .completion,
                nativeWhenInactive: true
            )
        }
        partialText = ""
        isRunning = false
        bridgeTask = nil
    }

    func clearMessages() {
        messages.removeAll()
        partialText = ""
        commandMessageIDsByItemID.removeAll()
        statusMessageIDsByItemID.removeAll()
        toolMessageIDsByItemID.removeAll()
        thinkingMessageIDsByItemID.removeAll()
        activeThreadID = nil
        recentErrorMessage = nil
    }

    func appendStatusMessage(_ text: String, tool: ToolMessagePayload? = nil) {
        messageCounter += 1
        messages.append(ChatMessage(
            id: "s\(messageCounter)",
            type: .status,
            content: text,
            timestamp: Self.now(),
            command: nil,
            diff: nil,
            tool: tool
        ))
    }

    func appendDiffMessage(_ diff: Diff) {
        messageCounter += 1
        messages.append(ChatMessage(
            id: "d\(messageCounter)",
            type: .diff,
            content: diff.snippet,
            timestamp: Self.now(),
            command: nil,
            diff: diff
        ))
    }

    func handleEvent(_ event: CodexEvent) {
        if let threadID = event.threadId?.nilIfBlank {
            activeThreadID = threadID
        }

        switch event.type {
        case "item.completed", "item.started", "item.updated", "item.progress":
            guard let item = event.item, let itemType = normalizedItemType(item.type) else {
                return
            }

            switch itemType {
            case "agent_message":
                if let text = item.text {
                    if partialText.isEmpty {
                        partialText = text
                    } else {
                        partialText += "\n\n" + text
                    }
                    updateOrAppendAssistantMessage(partialText)
                }
            case "reasoning":
                updateOrAppendThinkingMessage(for: item)
            case "command_execution":
                updateOrAppendCommandMessage(for: item, eventType: event.type)
            case "todo_list":
                let content = todoListStatusContent(for: item) ?? "Plan updated"
                updateOrAppendToolStatusMessage(
                    for: item,
                    eventType: event.type,
                    content: content,
                    category: .todos,
                    title: toolDisplayName(for: .todos, itemType: itemType),
                    subtitle: todoProgressSubtitle(for: item),
                    output: todoListOutput(for: item)
                )
            case "web_search":
                let content = webSearchStatusContent(for: item) ?? "Web search"
                let query = item.query?.nilIfBlank
                updateOrAppendToolStatusMessage(
                    for: item,
                    eventType: event.type,
                    content: content,
                    category: .search,
                    title: toolDisplayName(for: .search, itemType: itemType),
                    subtitle: query,
                    input: query
                )
            case "mcp_tool_call":
                let content = mcpToolCallStatusContent(for: item) ?? "MCP tool"
                let target = [item.server?.nilIfBlank, item.tool?.nilIfBlank]
                    .compactMap { $0 }
                    .joined(separator: "/")
                updateOrAppendToolStatusMessage(
                    for: item,
                    eventType: event.type,
                    content: content,
                    category: .mcp,
                    title: toolDisplayName(for: .mcp, itemType: itemType),
                    subtitle: target.nilIfBlank
                )
            case "file_change":
                if let content = fileChangeStatusContent(for: item) {
                    updateOrAppendToolStatusMessage(
                        for: item,
                        eventType: event.type,
                        content: content,
                        category: .file,
                        title: toolDisplayName(for: .file, itemType: itemType),
                        output: fileChangeOutput(for: item)
                    )
                }
            case "error":
                let message = item.message?.nilIfBlank ?? item.text?.nilIfBlank ?? "Unknown item error"
                trackRecentError(message)
                updateOrAppendToolStatusMessage(
                    for: item,
                    eventType: event.type,
                    content: "Codex item error:\n\(message)",
                    category: .generic,
                    title: "Tool error",
                    details: item.details?.nilIfBlank,
                    forceStatus: .error
                )
            default:
                if shouldRenderAsDedicatedTool(itemType) {
                    updateOrAppendDedicatedToolMessage(for: item, eventType: event.type, itemType: itemType)
                }
            }

        case "turn.completed":
            break

        case "turn.failed":
            let errorMsg = event.error?.message ?? event.message ?? "Unknown error"
            currentTurnFailed = true
            trackRecentError(errorMsg)
            let details = (event.error?.message != nil ? event.message?.nilIfBlank : nil)
            appendAssistantMessage(
                "Error: \(errorMsg)",
                assistant: AssistantMessageMetadata(
                    errorMessage: errorMsg,
                    errorDetails: details
                )
            )
            AppNotifications.shared.post(
                title: "Codex turn failed",
                message: errorMsg,
                level: .error,
                nativeWhenInactive: true
            )
            if let guidance = Self.codexAuthGuidance(for: errorMsg) {
                appendStatusMessage(guidance)
            }

        case "error":
            // Non-fatal errors (e.g. MCP login warnings) stay non-blocking.
            if let msg = event.message {
                trackRecentError(msg)
                AppLogger.agent.warning("AgentService non-fatal error", metadata: ["message": msg])
                let now = Date()
                if msg != lastNonFatalWarningMessage || now.timeIntervalSince(lastNonFatalWarningAt) > 5 {
                    lastNonFatalWarningMessage = msg
                    lastNonFatalWarningAt = now
                    AppNotifications.shared.post(
                        title: "Codex warning",
                        message: msg,
                        level: .warning
                    )
                }
            }

        default:
            break
        }
    }

    private func updateOrAppendAssistantMessage(_ text: String, assistant: AssistantMessageMetadata? = nil) {
        if let lastIdx = messages.indices.last,
           messages[lastIdx].type == .assistant,
           messages[lastIdx].tool == nil,
           !isThinkingOnlyAssistantMessage(messages[lastIdx]) {
            messages[lastIdx] = ChatMessage(
                id: messages[lastIdx].id,
                type: .assistant,
                content: text,
                timestamp: Self.now(),
                command: nil,
                diff: nil,
                assistant: assistant ?? messages[lastIdx].assistant
            )
        } else {
            messageCounter += 1
            messages.append(ChatMessage(
                id: "a\(messageCounter)",
                type: .assistant,
                content: text,
                timestamp: Self.now(),
                command: nil,
                diff: nil,
                assistant: assistant
            ))
        }
    }

    private func updateOrAppendCommandMessage(for item: CodexItem, eventType: String) {
        let itemID = normalizedItemID(item.id)
        let existingIndex = itemID
            .flatMap { commandMessageIDsByItemID[$0] }
            .flatMap { messageID in messages.firstIndex { $0.id == messageID } }
        let existingMessage = existingIndex.map { messages[$0] }
        let existingCommand = existingMessage?.command
        let category = inferredToolCategory(for: item)
        let status = toolExecutionStatus(for: item, eventType: eventType)
        let details = [item.status?.nilIfBlank, item.message?.nilIfBlank]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nilIfBlank
        let command = Command(
            itemID: itemID,
            cmd: item.command ?? existingCommand?.cmd ?? "unknown",
            cwd: existingCommand?.cwd ?? workingDir,
            output: item.aggregatedOutput ?? existingCommand?.output ?? "",
            exitCode: item.exitCode ?? existingCommand?.exitCode,
            running: commandIsRunning(eventType: eventType, item: item),
            toolCategory: category,
            toolDisplayName: toolDisplayName(for: category, itemType: item.type),
            details: details
        )
        let payload = ToolMessagePayload(
            itemID: itemID,
            category: category,
            title: toolDisplayName(for: category, itemType: item.type),
            subtitle: nil,
            input: item.command ?? existingCommand?.cmd,
            output: item.aggregatedOutput ?? existingCommand?.output,
            details: details,
            status: status
        )

        if let existingIndex {
            messages[existingIndex] = ChatMessage(
                id: messages[existingIndex].id,
                type: .command,
                content: messages[existingIndex].content,
                timestamp: messages[existingIndex].timestamp,
                command: command,
                diff: nil,
                tool: payload
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
            diff: nil,
            tool: payload
        ))
    }

    private func updateOrAppendStatusMessage(
        for item: CodexItem,
        content: String,
        tool: ToolMessagePayload? = nil
    ) {
        let itemID = normalizedItemID(item.id)
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
                diff: nil,
                tool: tool
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
            diff: nil,
            tool: tool
        ))
    }

    private func updateOrAppendToolStatusMessage(
        for item: CodexItem,
        eventType: String,
        content: String,
        category: ToolCategory,
        title: String,
        subtitle: String? = nil,
        input: String? = nil,
        output: String? = nil,
        details: String? = nil,
        compact: Bool = false,
        forceStatus: ToolExecutionStatus? = nil
    ) {
        let payload = ToolMessagePayload(
            itemID: normalizedItemID(item.id),
            category: category,
            title: title,
            subtitle: subtitle,
            input: input,
            output: output,
            details: details,
            status: forceStatus ?? toolExecutionStatus(for: item, eventType: eventType),
            compact: compact
        )
        updateOrAppendStatusMessage(for: item, content: content, tool: payload)
    }

    private func updateOrAppendDedicatedToolMessage(for item: CodexItem, eventType: String, itemType: String) {
        let itemID = normalizedItemID(item.id)
        let existingIndex = itemID
            .flatMap { toolMessageIDsByItemID[$0] }
            .flatMap { messageID in messages.firstIndex { $0.id == messageID } }

        let category = inferredToolCategory(for: item)
        let title = toolDisplayName(for: category, itemType: itemType)
        let subtitle = item.tool?.nilIfBlank
            ?? item.query?.nilIfBlank
            ?? item.path?.nilIfBlank
            ?? item.url?.nilIfBlank
        let input = item.input?.nilIfBlank
            ?? item.command?.nilIfBlank
            ?? item.arguments?.nilIfBlank
            ?? item.prompt?.nilIfBlank
        let output = item.output?.nilIfBlank
            ?? item.aggregatedOutput?.nilIfBlank
            ?? item.text?.nilIfBlank
            ?? item.message?.nilIfBlank
        let details = item.details?.nilIfBlank
        let status = toolExecutionStatus(for: item, eventType: eventType)
        let payload = ToolMessagePayload(
            itemID: itemID,
            category: category,
            title: title,
            subtitle: subtitle,
            input: input,
            output: output,
            details: details,
            status: status
        )
        let content = output ?? subtitle ?? title

        if let existingIndex {
            messages[existingIndex] = ChatMessage(
                id: messages[existingIndex].id,
                type: .tool,
                content: content,
                timestamp: messages[existingIndex].timestamp,
                command: nil,
                diff: nil,
                tool: payload
            )
            return
        }

        messageCounter += 1
        let messageID = "t\(messageCounter)"
        if let itemID {
            toolMessageIDsByItemID[itemID] = messageID
        }
        messages.append(ChatMessage(
            id: messageID,
            type: .tool,
            content: content,
            timestamp: Self.now(),
            command: nil,
            diff: nil,
            tool: payload
        ))
    }

    private func updateOrAppendThinkingMessage(for item: CodexItem) {
        let itemID = normalizedItemID(item.id)
        let thinkingText = item.text?.nilIfBlank ?? "Thinking..."

        let existingIndex = itemID
            .flatMap { thinkingMessageIDsByItemID[$0] }
            .flatMap { messageID in messages.firstIndex { $0.id == messageID } }

        if let existingIndex {
            messages[existingIndex] = ChatMessage(
                id: messages[existingIndex].id,
                type: .assistant,
                content: "",
                timestamp: messages[existingIndex].timestamp,
                command: nil,
                diff: nil,
                assistant: AssistantMessageMetadata(thinking: thinkingText)
            )
            return
        }

        messageCounter += 1
        let messageID = "r\(messageCounter)"
        if let itemID {
            thinkingMessageIDsByItemID[itemID] = messageID
        }
        messages.append(ChatMessage(
            id: messageID,
            type: .assistant,
            content: "",
            timestamp: Self.now(),
            command: nil,
            diff: nil,
            assistant: AssistantMessageMetadata(thinking: thinkingText)
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

    private func fileChangeStatusContent(for item: CodexItem) -> String? {
        guard let changes = item.changes else {
            return nil
        }
        if changes.isEmpty {
            return "File changes:\nNo changes"
        }
        let summary = changes.map { "\($0.kind): \($0.path)" }.joined(separator: "\n")
        return "File changes:\n\(summary)"
    }

    private func fileChangeOutput(for item: CodexItem) -> String? {
        item.changes?
            .map { "\($0.kind): \($0.path)" }
            .joined(separator: "\n")
            .nilIfBlank
    }

    private func todoProgressSubtitle(for item: CodexItem) -> String? {
        guard let todos = item.items, !todos.isEmpty else { return nil }
        let completed = todos.filter(\.completed).count
        return "\(completed)/\(todos.count) completed"
    }

    private func todoListOutput(for item: CodexItem) -> String? {
        guard let todos = item.items, !todos.isEmpty else { return nil }
        return todos
            .map { "\($0.completed ? "[x]" : "[ ]") \($0.text)" }
            .joined(separator: "\n")
            .nilIfBlank
    }

    private func normalizedItemType(_ type: String?) -> String? {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    private func normalizedItemID(_ id: String?) -> String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func shouldRenderAsDedicatedTool(_ itemType: String) -> Bool {
        if itemType.hasPrefix("mcp_") && itemType != "mcp_tool_call" {
            return true
        }

        switch itemType {
        case "bash",
             "view", "write", "edit", "multi_edit", "download",
             "glob", "grep", "ls", "sourcegraph",
             "fetch", "web_fetch", "agentic_fetch",
             "agent",
             "diagnostics",
             "references",
             "lsp_restart", "lsprestart", "restart_lsp",
             "todos",
             "tool", "tool_call", "tool_result":
            return true
        default:
            return false
        }
    }

    private func inferredToolCategory(for item: CodexItem) -> ToolCategory {
        let type = normalizedItemType(item.type) ?? ""

        switch type {
        case "command_execution", "bash":
            return inferredToolCategory(forCommand: item.command)
        case "view", "write", "edit", "multi_edit", "download", "file_change", "file":
            return .file
        case "glob", "grep", "ls", "sourcegraph", "search", "web_search":
            return .search
        case "fetch", "web_fetch", "agentic_fetch":
            return .fetch
        case "agent":
            return .agent
        case "diagnostics":
            return .diagnostics
        case "references":
            return .references
        case "lsp_restart", "lsprestart", "restart_lsp":
            return .lspRestart
        case "todo_list", "todos":
            return .todos
        case "mcp_tool_call":
            return .mcp
        default:
            if type.hasPrefix("mcp_") {
                return .mcp
            }
            if let toolName = item.tool?.lowercased(), toolName.contains("reference") {
                return .references
            }
            if let command = item.command, !command.isEmpty {
                return inferredToolCategory(forCommand: command)
            }
            return .generic
        }
    }

    private func inferredToolCategory(forCommand command: String?) -> ToolCategory {
        guard let command = command?.lowercased().nilIfBlank else {
            return .bash
        }

        if command.contains("lsp") && (command.contains("restart") || command.contains("reload")) {
            return .lspRestart
        }
        if command.hasPrefix("curl ") || command.hasPrefix("wget ") || command.contains("http://") || command.contains("https://") {
            return .fetch
        }
        if command.hasPrefix("rg ") || command.hasPrefix("grep ") || command.hasPrefix("find ") || command.hasPrefix("fd ") || command.hasPrefix("ls ") {
            return .search
        }
        if command.hasPrefix("cat ") || command.hasPrefix("head ") || command.hasPrefix("tail ") ||
            command.hasPrefix("sed ") || command.hasPrefix("awk ") || command.hasPrefix("nl ") ||
            command.hasPrefix("wc ") || command.hasPrefix("cp ") || command.hasPrefix("mv ") ||
            command.hasPrefix("rm ") || command.hasPrefix("touch ") || command.hasPrefix("mkdir ") ||
            command.hasPrefix("chmod ") || command.hasPrefix("chown ") {
            return .file
        }
        if command.contains("diagnostic") || command.contains("lint") || command.contains("test") || command.contains("build") {
            return .diagnostics
        }
        return .bash
    }

    private func toolDisplayName(for category: ToolCategory, itemType: String?) -> String {
        switch category {
        case .bash:
            return "Bash"
        case .file:
            return "File"
        case .search:
            return "Search"
        case .fetch:
            return "Fetch"
        case .agent:
            return "Agent"
        case .diagnostics:
            return "Diagnostics"
        case .references:
            return "Find references"
        case .lspRestart:
            return "Restart LSP"
        case .todos:
            return "To-Do"
        case .mcp:
            return "MCP tool"
        case .generic:
            if let itemType = normalizedItemType(itemType) {
                return itemType.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return "Tool"
        }
    }

    private func toolExecutionStatus(for item: CodexItem, eventType: String) -> ToolExecutionStatus {
        if normalizedItemType(item.type) == "error" {
            return .error
        }

        let commandLike = isCommandLikeItem(item)

        if let exitCode = item.exitCode {
            return exitCode == 0 ? .success : .error
        }

        switch item.status?.lowercased() {
        case "completed", "success", "succeeded", "done":
            if commandLike {
                return .unknown
            }
            return .success
        case "failed", "error":
            return .error
        case "cancelled", "canceled", "aborted":
            return .canceled
        case "running", "started", "in_progress", "pending":
            return .running
        default:
            break
        }

        if eventType == "item.completed" {
            return commandLike ? .unknown : .success
        }
        return .running
    }

    private func isCommandLikeItem(_ item: CodexItem) -> Bool {
        if item.command?.nilIfBlank != nil {
            return true
        }

        switch normalizedItemType(item.type) {
        case "command_execution", "bash":
            return true
        default:
            return false
        }
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

    private func appendAssistantMessage(_ text: String, assistant: AssistantMessageMetadata? = nil) {
        messageCounter += 1
        messages.append(ChatMessage(
            id: "a\(messageCounter)",
            type: .assistant,
            content: text,
            timestamp: Self.now(),
            command: nil,
            diff: nil,
            assistant: assistant
        ))
    }

    private func isThinkingOnlyAssistantMessage(_ message: ChatMessage) -> Bool {
        guard message.type == .assistant else { return false }
        guard let thinking = message.assistant?.thinking?.nilIfBlank else { return false }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thinking.isEmpty
    }

    private static func now() -> String {
        DateFormatters.hourMinute.string(from: Date())
    }

    private func trackRecentError(_ message: String) {
        guard let normalized = message.nilIfBlank else { return }
        recentErrorMessage = normalized
    }

    private static func codexAuthGuidance(for message: String) -> String? {
        let normalized = message.lowercased()
        let authHints = [
            "unauthorized",
            "not logged in",
            "authentication",
            "openai_api_key",
            "api key",
            "login required",
        ]

        guard authHints.contains(where: normalized.contains) else {
            return nil
        }

        return "Codex authentication error. Open Chat and use the auth panel to sign in or configure an API key."
    }
}
