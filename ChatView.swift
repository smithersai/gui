import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

enum ChatTargetKind: String {
    case smithers
    case externalAgent = "external_agent"
}

struct ChatTargetOption: Identifiable, Equatable {
    let kind: ChatTargetKind
    let id: String
    let name: String
    let description: String
    let status: String
    let roles: [String]
    let binary: String
    let recommended: Bool
    let usable: Bool
}

func buildChatTargets(from agents: [SmithersAgent]) -> [ChatTargetOption] {
    var targets: [ChatTargetOption] = [
        ChatTargetOption(
            kind: .smithers,
            id: "smithers",
            name: "Smithers",
            description: "Use the built-in chat without leaving Smithers GUI.",
            status: "",
            roles: [],
            binary: "",
            recommended: true,
            usable: true
        ),
    ]

    for agent in agents where agent.usable {
        let binary = agent.binaryPath.isEmpty ? agent.command : agent.binaryPath
        targets.append(
            ChatTargetOption(
                kind: .externalAgent,
                id: agent.id,
                name: agent.name,
                description: "Launch the \(agent.name) CLI in this terminal.",
                status: agent.status,
                roles: agent.roles,
                binary: binary,
                recommended: false,
                usable: true
            )
        )
    }

    return targets
}

func chatTargetStatusLabel(_ status: String) -> String {
    switch status {
    case "likely-subscription":
        return "Signed in"
    case "api-key":
        return "API key"
    case "binary-only":
        return "Binary only"
    default:
        return "Available"
    }
}

struct ChatView: View {
    @ObservedObject var agent: AgentService
    var onSend: (String) -> Void
    var smithers: SmithersClient? = nil
    var onNavigate: ((NavDestination) -> Void)? = nil
    var onNewChat: (() -> Void)? = nil
    var onRunStarted: ((String, String?) -> Void)? = nil

    @State private var inputText: String = ""
    @State private var workflowCommands: [SlashCommandItem] = []
    @State private var promptCommands: [SlashCommandItem] = []
    @State private var selectedSlashIndex = 0
    @State private var chatTargets: [ChatTargetOption] = buildChatTargets(from: [])
    @State private var showTargetPicker = true
    @State private var loadingTargets = false
    @State private var hasLoadedTargets = false
    @State private var launchingTargetID: String? = nil
    @State private var targetPickerError: String? = nil
    @State private var targetLaunchStatus: String? = nil

    private var slashCommands: [SlashCommandItem] {
        SlashCommandRegistry.builtInCommands + workflowCommands + promptCommands
    }

    private var matchingSlashCommands: [SlashCommandItem] {
        SlashCommandRegistry.matches(for: inputText, commands: slashCommands)
    }

    private var slashPaletteVisible: Bool {
        inputText.trimmingCharacters(in: .whitespaces).hasPrefix("/") &&
            !inputText.contains("\n") &&
            !matchingSlashCommands.isEmpty
    }

    private var shouldShowTargetPicker: Bool {
        smithers != nil && showTargetPicker
    }

    private var headerBusy: Bool {
        agent.isRunning || loadingTargets || launchingTargetID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Text("Smithers")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.titlebarFg)
                    if headerBusy {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.titlebarBg)
            .border(Theme.border, edges: [.bottom])

            if shouldShowTargetPicker {
                targetPickerView
            } else {
                chatSurfaceView
            }
        }
        .task {
            await loadDynamicSlashCommands()
            await loadChatTargetsIfNeeded()
        }
    }

    private var chatSurfaceView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if agent.messages.isEmpty {
                            VStack(spacing: 12) {
                                Spacer().frame(height: 80)
                                Text("What can I help you build?")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text("Send a message to start a coding session with Codex.")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("chat.emptyState")
                        }
                        ForEach(deduplicatedChatMessages(agent.messages)) { message in
                            MessageRow(message: message)
                        }
                        if agent.isRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Codex is thinking...")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textTertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                .onChange(of: agent.messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom")
                    }
                }
            }
            .background(Theme.surface1)

            composerView
                .background(Theme.surface1)
        }
        .accessibilityIdentifier("chat.surface")
    }

    private var composerView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if slashPaletteVisible {
                    SlashCommandPalette(
                        commands: Array(matchingSlashCommands.prefix(8)),
                        selectedIndex: selectedSlashIndex,
                        onSelect: { command in
                            executeSlashCommand(command)
                        }
                    )
                }

                TextField("Ask anything...", text: $inputText, axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .frame(minHeight: 60, alignment: .top)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            return .ignored // let shift+return insert newline
                        }
                        if executeSelectedSlashCommand() {
                            return .handled
                        }
                        send()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard slashPaletteVisible else { return .ignored }
                        moveSlashSelection(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard slashPaletteVisible else { return .ignored }
                        moveSlashSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard slashPaletteVisible else { return .ignored }
                        if let command = selectedSlashCommand {
                            inputText = "/\(command.name) "
                            selectedSlashIndex = 0
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard slashPaletteVisible else { return .ignored }
                        inputText = ""
                        selectedSlashIndex = 0
                        return .handled
                    }
                    .onChange(of: inputText) { _, _ in
                        selectedSlashIndex = 0
                    }
                    .accessibilityIdentifier("chat.input")

                HStack {
                    HStack(spacing: 12) {
                        Button(action: { /* TODO: open file picker */ }) {
                            Image(systemName: "paperclip")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.attachmentButton")
                        Button(action: { inputText += "@" }) {
                            Image(systemName: "at")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.mentionButton")
                        Button(action: { inputText = "/" }) {
                            Image(systemName: "sparkles")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.slashButton")
                    }
                    .foregroundColor(Theme.textTertiary)
                    .font(.system(size: 14))

                    Spacer()

                    Button(action: send) {
                        Image(systemName: agent.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.surface1)
                            .frame(width: 24, height: 24)
                            .background(agent.isRunning ? Theme.danger : Theme.accent)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(agent.isRunning ? "chat.stopButton" : "chat.sendButton")
                }
            }
            .padding(12)
            .background(Theme.surface2.opacity(0.5))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Text("Return to send - / for commands")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .padding(.vertical, 8)
        }
        .accessibilityIdentifier("chat.composer")
    }

    private var targetPickerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose how you want to chat in this workspace.")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)

                ForEach(chatTargets) { target in
                    Button(action: { selectTarget(target) }) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(target.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Theme.textPrimary)
                                    if target.recommended {
                                        Text("Recommended")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Theme.success)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.success.opacity(0.15))
                                            .cornerRadius(4)
                                    } else if !target.status.isEmpty {
                                        Text("\(chatTargetStatusLabel(target.status))")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Theme.textTertiary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .themedPill(cornerRadius: 4)
                                    }
                                }

                                Text(target.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)

                                Text(targetMetaLine(target))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }

                            Spacer()

                            if launchingTargetID == target.id {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(12)
                        .background(Theme.surface2.opacity(0.5))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(launchingTargetID != nil || !target.usable)
                    .accessibilityIdentifier("chat.target.\(target.id)")
                }

                if loadingTargets {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Detecting installed agents...")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                }

                if chatTargets.count == 1 && !loadingTargets {
                    Text("No external chat agents detected on PATH.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }

                if let status = targetLaunchStatus {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }

                if let error = targetPickerError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                }

                HStack {
                    Spacer()
                    Button("Refresh") {
                        Task { await loadChatTargets(force: true) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .accessibilityIdentifier("chat.target.refresh")
                }
            }
            .padding(20)
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("chat.targetPicker")
    }

    private func targetMetaLine(_ target: ChatTargetOption) -> String {
        if target.kind == .smithers {
            return "Built in"
        }

        var parts: [String] = [chatTargetStatusLabel(target.status)]
        if !target.roles.isEmpty {
            parts.append(target.roles.map { $0.capitalized }.joined(separator: ", "))
        }
        if !target.binary.isEmpty {
            parts.append(target.binary)
        }
        return parts.joined(separator: " • ")
    }

    private func selectTarget(_ target: ChatTargetOption) {
        guard target.usable else { return }
        targetPickerError = nil
        targetLaunchStatus = nil

        if target.kind == .smithers {
            showTargetPicker = false
            return
        }

        // Launch in embedded terminal
        showTargetPicker = false
        onNavigate?(.terminalCommand(
            binary: target.binary,
            workingDirectory: agent.workingDirectory,
            name: target.name
        ))
    }

    private func loadChatTargetsIfNeeded() async {
        guard smithers != nil else {
            showTargetPicker = false
            return
        }

        await loadChatTargets(force: false)
    }

    private func loadChatTargets(force: Bool) async {
        guard let smithers else { return }
        if !force && hasLoadedTargets {
            return
        }

        loadingTargets = true
        defer { loadingTargets = false }
        targetPickerError = nil

        do {
            let agents = try await smithers.listAgents()
            chatTargets = buildChatTargets(from: agents)
            hasLoadedTargets = true
        } catch {
            targetPickerError = "Failed to discover chat targets: \(error.localizedDescription)"
            hasLoadedTargets = true
        }
    }

    private func send() {
        if agent.isRunning {
            agent.cancel()
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if executeExactSlashCommand(text) {
            return
        }
        inputText = ""
        onSend(text)
    }

    private var selectedSlashCommand: SlashCommandItem? {
        let commands = Array(matchingSlashCommands.prefix(8))
        guard commands.indices.contains(selectedSlashIndex) else { return commands.first }
        return commands[selectedSlashIndex]
    }

    private func moveSlashSelection(_ delta: Int) {
        let count = min(8, matchingSlashCommands.count)
        guard count > 0 else {
            selectedSlashIndex = 0
            return
        }
        selectedSlashIndex = (selectedSlashIndex + delta + count) % count
    }

    @discardableResult
    private func executeSelectedSlashCommand() -> Bool {
        guard slashPaletteVisible, let command = selectedSlashCommand else { return false }
        executeSlashCommand(command)
        return true
    }

    @discardableResult
    private func executeExactSlashCommand(_ text: String) -> Bool {
        guard let command = SlashCommandRegistry.exactMatch(for: text, commands: slashCommands) else {
            return false
        }
        executeSlashCommand(command)
        return true
    }

    private func executeSlashCommand(_ command: SlashCommandItem) {
        let args = SlashCommandRegistry.parse(inputText)?.args ?? ""
        selectedSlashIndex = 0

        switch command.action {
        case .codex(let codexCommand):
            executeCodexCommand(codexCommand, args: args)
        case .navigate(let destination):
            inputText = ""
            if let onNavigate {
                onNavigate(destination)
                agent.appendStatusMessage("Opened \(destination.label).")
            } else {
                agent.appendStatusMessage("Navigation to \(destination.label) is not wired into this chat view.")
            }
        case .clearChat:
            inputText = ""
            agent.clearMessages()
        case .showHelp:
            inputText = ""
            agent.appendStatusMessage(SlashCommandRegistry.helpText(for: slashCommands))
        case .runWorkflow(let workflow):
            runWorkflow(workflow, args: args)
        case .runSmithersPrompt(let promptId):
            runSmithersPrompt(promptId, args: args)
        }
    }

    private func executeCodexCommand(_ command: CodexSlashCommand, args: String) {
        switch command {
        case .new:
            inputText = ""
            if let onNewChat {
                onNewChat()
            } else {
                agent.clearMessages()
            }
        case .initialize:
            inputText = ""
            onSend(SlashCommandRegistry.initPrompt)
        case .review:
            inputText = ""
            let suffix = args.isEmpty ? "" : "\n\nFocus: \(args)"
            onSend("Review my current changes and find issues. Prioritize bugs, regressions, and missing tests.\(suffix)")
        case .compact:
            inputText = ""
            onSend("Summarize the important context from this conversation so we can continue with a shorter working history.")
        case .diff:
            inputText = ""
            showGitDiff()
        case .mention:
            inputText = "@"
        case .status:
            inputText = ""
            agent.appendStatusMessage(statusText())
        case .model:
            inputText = ""
            agent.appendStatusMessage("Model switching is not exposed by this GUI yet. Codex is using the model from your current Codex configuration.")
        case .approvals:
            inputText = ""
            agent.appendStatusMessage("Codex approval policy is fixed by the current GUI bridge: never ask, full workspace access.")
        case .mcp:
            inputText = ""
            agent.appendStatusMessage("MCP tool listing is not exposed by the current Codex FFI bridge yet.")
        case .logout:
            inputText = ""
            agent.appendStatusMessage("Codex logout is not wired into this GUI yet.")
        case .quit:
            inputText = ""
            #if os(macOS)
            NSApplication.shared.terminate(nil)
            #else
            agent.appendStatusMessage("Quit is only available on macOS.")
            #endif
        case .feedback:
            inputText = ""
            agent.appendStatusMessage("Feedback capture is not wired into this GUI yet.")
        }
    }

    private func runWorkflow(_ workflow: Workflow, args: String) {
        guard let smithers else {
            inputText = ""
            agent.appendStatusMessage("Smithers is not available in this chat view.")
            return
        }

        inputText = ""
        let inputs = SlashCommandRegistry.keyValueArgs(args)
        Task { @MainActor in
            do {
                let run = try await smithers.runWorkflow(workflow, inputs: inputs)
                agent.appendStatusMessage("Started workflow \(workflow.name).\nRun: \(run.runId)")
                onRunStarted?(run.runId, workflow.name)
                onNavigate?(.liveRun(runId: run.runId, nodeId: nil))
            } catch {
                agent.appendStatusMessage("Failed to start workflow \(workflow.name): \(error.localizedDescription)")
            }
        }
    }

    private func runSmithersPrompt(_ promptId: String, args: String) {
        guard let smithers else {
            inputText = ""
            agent.appendStatusMessage("Smithers prompts are not available in this chat view.")
            return
        }

        inputText = ""
        let inputs = SlashCommandRegistry.keyValueArgs(args)
        Task { @MainActor in
            do {
                let prompt = try await smithers.previewPrompt(promptId, input: inputs)
                onSend(prompt)
            } catch {
                agent.appendStatusMessage("Failed to render prompt \(promptId): \(error.localizedDescription)")
            }
        }
    }

    private func showGitDiff() {
        let cwd = agent.workingDirectory
        Task.detached {
            let result = LocalGitDiff.summary(cwd: cwd)
            await MainActor.run {
                agent.appendStatusMessage(result)
            }
        }
    }

    private func statusText() -> String {
        """
Workspace: \(agent.workingDirectory)
Messages: \(agent.messages.count)
Running: \(agent.isRunning ? "yes" : "no")
"""
    }

    private func loadDynamicSlashCommands() async {
        guard let smithers else { return }

        do {
            let workflows = try await smithers.listWorkflows()
            workflowCommands = SlashCommandRegistry.workflowCommands(from: workflows)
        } catch {
            workflowCommands = []
        }

        do {
            let prompts = try await smithers.listPrompts()
            promptCommands = SlashCommandRegistry.promptCommands(from: prompts)
        } catch {
            promptCommands = []
        }
    }
}

struct SlashCommandPalette: View {
    let commands: [SlashCommandItem]
    let selectedIndex: Int
    let onSelect: (SlashCommandItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button(action: { onSelect(command) }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(command.displayName)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                Text(command.category.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.textTertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .themedPill(cornerRadius: 4)
                            }
                            Text(command.description)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .themedSidebarRowBackground(isSelected: index == selectedIndex)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index != commands.count - 1 {
                    Divider().background(Theme.border)
                }
            }
        }
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("chat.slashPalette")
    }
}

private enum LocalGitDiff {
    static func summary(cwd: String) -> String {
        let status = runGit(["-C", cwd, "status", "--short"])
        if status.exitCode != 0 {
            return status.stderr.isEmpty ? "Not inside a git repository." : status.stderr
        }

        let diff = runGit(["-C", cwd, "diff", "--stat", "HEAD"])
        let cleanStatus = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDiff = diff.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanStatus.isEmpty && cleanDiff.isEmpty {
            return "No git changes."
        }

        if cleanDiff.isEmpty {
            return "Git changes:\n\(cleanStatus)"
        }

        return "Git diff:\n\(cleanDiff)\n\nStatus:\n\(cleanStatus)"
    }

    private static func runGit(_ arguments: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return (
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                process.terminationStatus
            )
        } catch {
            return ("", error.localizedDescription, 1)
        }
    }
}

private enum ExternalChatLauncher {
    static func launch(binaryPath: String, workingDirectory: String) async throws {
        guard !binaryPath.isEmpty else {
            throw SmithersError.cli("Missing binary path for external chat target")
        }

        #if os(macOS)
        try await Task.detached {
            try launchViaTerminal(binaryPath: binaryPath, workingDirectory: workingDirectory)
        }.value
        #else
        throw SmithersError.notAvailable("External chat launch is only supported on macOS in this GUI build")
        #endif
    }

    #if os(macOS)
    private static func launchViaTerminal(binaryPath: String, workingDirectory: String) throws {
        let command = "cd \(shellQuote(workingDirectory)); \(shellQuote(binaryPath))"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(command))
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SmithersError.cli(errText?.isEmpty == false ? errText! : "External launcher exited with code \(process.terminationStatus)")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    #endif
}

struct MessageRow: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.type == .user {
                Spacer()
                Text(message.content)
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.bubbleUser)
                    .cornerRadius(16, corners: [.topLeft, .bottomLeft, .bottomRight])
                    .foregroundColor(Theme.textPrimary)
            } else if message.type == .assistant {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(4)
                    
                    if let cmd = message.command {
                        CommandBlock(command: cmd)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.bubbleAssistant)
                .cornerRadius(16, corners: [.topRight, .bottomLeft, .bottomRight])
                Spacer()
            } else if message.type == .command {
                if let cmd = message.command {
                    CommandBlock(command: cmd)
                }
                Spacer()
            } else if message.type == .diff {
                if let diff = message.diff {
                    VStack(alignment: .leading, spacing: 8) {
                        SyntaxHighlightedText(diff.snippet, font: .system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Text("\(diff.files.count) file\(diff.files.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                            Text("+\(diff.totalAdditions)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.success)
                            Text("-\(diff.totalDeletions)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.danger)
                        }
                    }
                    .padding(12)
                    .themedDiffBlock()
                    Spacer()
                }
            } else if message.type == .status {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.bubbleStatus)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                Spacer()
            }
        }
        .accessibilityIdentifier("chat.message.\(message.type.rawValue).\(message.id)")
    }
}

struct CommandBlock: View {
    let command: Command
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("$ \(command.cmd)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if command.running == true {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: command.exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                            .font(.system(size: 10))
                        Text("exit \(command.exitCode)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((command.exitCode == 0 ? Theme.success : Theme.danger).opacity(0.15))
                    .foregroundColor(command.exitCode == 0 ? Theme.success : Theme.danger)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke((command.exitCode == 0 ? Theme.success : Theme.danger).opacity(0.3), lineWidth: 1)
                    )
                }
            }
            .padding(12)
            .background(Theme.bubbleCommand)
            
            // Output
            VStack(alignment: .leading, spacing: 4) {
                Text("cwd: \(command.cwd)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.bottom, 8)
                
                Text(command.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(12)
        }
        .background(Theme.bubbleCommand)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

#if os(macOS)
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        path.move(to: CGPoint(x: rect.minX + (corners.contains(.topLeft) ? radius : 0), y: rect.minY))
        
        // Top edge and Top Right corner
        path.addLine(to: CGPoint(x: rect.maxX - (corners.contains(.topRight) ? radius : 0), y: rect.minY))
        if corners.contains(.topRight) {
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        }
        
        // Right edge and Bottom Right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (corners.contains(.bottomRight) ? radius : 0)))
        if corners.contains(.bottomRight) {
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        }
        
        // Bottom edge and Bottom Left corner
        path.addLine(to: CGPoint(x: rect.minX + (corners.contains(.bottomLeft) ? radius : 0), y: rect.maxY))
        if corners.contains(.bottomLeft) {
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        }
        
        // Left edge and Top Left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (corners.contains(.topLeft) ? radius : 0)))
        if corners.contains(.topLeft) {
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        }
        
        path.closeSubpath()
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}
#endif
