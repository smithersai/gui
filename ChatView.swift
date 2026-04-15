import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct ChatSendRequest: Sendable {
    let prompt: String
    let displayText: String
}

private struct ChatComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let filePath: String
    let resolvedPath: String
    let fileName: String
    let mimeType: String
    let content: Data

    init(
        id: UUID = UUID(),
        filePath: String,
        resolvedPath: String,
        fileName: String,
        mimeType: String,
        content: Data
    ) {
        self.id = id
        self.filePath = filePath
        self.resolvedPath = resolvedPath
        self.fileName = fileName
        self.mimeType = mimeType
        self.content = content
    }

    var isText: Bool { mimeType.hasPrefix("text/") }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

private struct ChatMentionCandidate: Identifiable, Equatable {
    let path: String
    var id: String { path }
}

private struct ChatMentionContext {
    let tokenRange: Range<String.Index>
    let query: String
}

private struct FeedbackComposerState: Identifiable {
    let id = UUID()
    let category: FeedbackCategoryOption
    let includeLogs: Bool
    let context: FeedbackContext
}

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
    var onSendRequest: ((ChatSendRequest) -> Void)? = nil
    var smithers: SmithersClient? = nil
    var onNavigate: ((NavDestination) -> Void)? = nil
    var onToggleDeveloperDebug: (() -> Void)? = nil
    var onNewChat: (() -> Void)? = nil
    var onRunStarted: ((String, String?) -> Void)? = nil
    var codexModelSelection: CodexModelSelection = .fallback
    var onApplyCodexModelSelection: (CodexModelSelection) -> Result<CodexModelSelection, CodexModelSelectionError> = { .success($0) }
    var codexApprovalSelection: CodexApprovalSelection = .fallback
    var onApplyCodexApprovalSelection: (CodexApprovalSelection) -> Result<CodexApprovalSelection, CodexApprovalSelectionError> = { .success($0) }
    var activeViewName: String = "Chat"

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
    @State private var showModelSelectionSheet = false
    @State private var showApprovalSelectionSheet = false
    @State private var showMCPStatusSheet = false
    @State private var codexAuthState: CodexAuthState? = nil
    @State private var codexAuthActionError: String? = nil
    @State private var revealAPIKeyInput = false
    @State private var pendingAPIKey = ""
    @State private var authActionInFlight = false
    @State private var composerAttachments: [ChatComposerAttachment] = []
    @State private var mentionCandidates: [ChatMentionCandidate] = []
    @State private var mentionSuggestions: [ChatMentionCandidate] = []
    @State private var mentionSelectionIndex = 0
    @State private var mentionCompletionsLoading = false
    @State private var mentionCompletionsLoaded = false
    @State private var mentionCompletionsRoot = ""
    @State private var showFeedbackCategoryDialog = false
    @State private var showFeedbackConsentDialog = false
    @State private var pendingFeedbackCategory: FeedbackCategoryOption?
    @State private var feedbackComposerState: FeedbackComposerState?

    private static let maxAttachmentSizeBytes = 5 * 1024 * 1024
    private static let pasteLinesThreshold = 10
    private static let pasteColsThreshold = 1000
    private static let mentionCompletionMaxDepth = 8
    private static let mentionCompletionMaxItems = 2500
    private static let mentionCompletionResults = 8
    private static let supportedImageExtensions = Set(["jpg", "jpeg", "png"])

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
        agent.isRunning || loadingTargets || launchingTargetID != nil || authActionInFlight
    }

    private var chatReady: Bool {
        codexAuthState?.isReady ?? true
    }

    private var shouldShowAuthOnboarding: Bool {
        guard smithers != nil else { return false }
        guard let codexAuthState else { return false }
        return !codexAuthState.isReady
    }

    private var sendActionAllowed: Bool {
        if agent.isRunning {
            return true
        }

        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return true
        }

        return chatReady && (!trimmed.isEmpty || !composerAttachments.isEmpty)
    }

    private var availableModelPresets: [CodexModelPreset] {
        CodexModelCatalog.availablePresets(including: codexModelSelection)
    }

    private var currentModelSupportsImages: Bool {
        let model = codexModelSelection.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return false }
        return model.contains("gpt-5") || model.contains("gpt-4o") || model.contains("gpt-4.1")
    }

    private var mentionPaletteVisible: Bool {
        guard !slashPaletteVisible else { return false }
        guard Self.activeMentionContext(in: inputText) != nil else { return false }
        return mentionCompletionsLoading || !mentionSuggestions.isEmpty
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
            refreshCodexAuthState()
        }
        .sheet(isPresented: $showModelSelectionSheet) {
            CodexModelPickerSheet(
                initialSelection: codexModelSelection,
                modelPresets: availableModelPresets,
                onApply: onApplyCodexModelSelection,
                onApplied: { selection in
                    agent.appendStatusMessage(modelSelectionStatusText(for: selection))
                }
            )
            .frame(minWidth: 560, minHeight: 460)
        }
        .sheet(isPresented: $showApprovalSelectionSheet) {
            CodexApprovalPickerSheet(
                initialSelection: codexApprovalSelection,
                onApply: onApplyCodexApprovalSelection,
                onApplied: { selection in
                    agent.appendStatusMessage(approvalSelectionStatusText(for: selection))
                }
            )
            .frame(minWidth: 620, minHeight: 420)
        }
        .sheet(isPresented: $showMCPStatusSheet) {
            CodexMCPStatusSheet(cwd: agent.workingDirectory)
                .frame(minWidth: 680, minHeight: 560)
        }
        .confirmationDialog("How was this?", isPresented: $showFeedbackCategoryDialog, titleVisibility: .visible) {
            ForEach(FeedbackCategoryOption.allCases) { category in
                Button(category.title.capitalized) {
                    pendingFeedbackCategory = category
                    showFeedbackConsentDialog = true
                }
            }
            Button("Cancel", role: .cancel) {
                pendingFeedbackCategory = nil
            }
        } message: {
            Text("Choose feedback type")
        }
        .confirmationDialog("Upload logs?", isPresented: $showFeedbackConsentDialog, titleVisibility: .visible) {
            Button("Yes") {
                openFeedbackComposer(includeLogs: true)
            }
            Button("No") {
                openFeedbackComposer(includeLogs: false)
            }
            Button("Cancel", role: .cancel) {
                pendingFeedbackCategory = nil
            }
        } message: {
            Text("If you choose Yes, the GUI log file will be attached as codex-logs.log.")
        }
        .sheet(item: $feedbackComposerState) { state in
            FeedbackNoteSheet(
                state: state,
                onCancel: { feedbackComposerState = nil },
                onSubmit: { note in
                    try await submitFeedback(state: state, note: note)
                }
            )
            .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var chatSurfaceView: some View {
        VStack(spacing: 0) {
            if shouldShowAuthOnboarding {
                codexAuthOnboardingView
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }

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
                .onChange(of: agent.transcriptUpdateToken) { _, _ in
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

    private var codexAuthOnboardingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex authentication required")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Text(codexAuthOnboardingText())
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            if let codexAuthActionError {
                Text(codexAuthActionError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
            }

            if revealAPIKeyInput {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Paste OPENAI_API_KEY", text: $pendingAPIKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.surface1)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .accessibilityIdentifier("chat.auth.apiKeyInput")

                    HStack(spacing: 8) {
                        Button("Save API Key") {
                            saveAPIKeyForCodex()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .disabled(authActionInFlight)
                        .accessibilityIdentifier("chat.auth.saveApiKey")

                        Button("Cancel") {
                            pendingAPIKey = ""
                            revealAPIKeyInput = false
                            codexAuthActionError = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .disabled(authActionInFlight)
                    }
                }
            }

            HStack(spacing: 12) {
                if codexAuthState?.hasCodexCLI == true {
                    Button("Sign in with ChatGPT") {
                        startCodexChatGPTLogin()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .disabled(authActionInFlight)
                    .accessibilityIdentifier("chat.auth.chatgptLogin")
                }

                Button(revealAPIKeyInput ? "Using API Key..." : "Use API Key") {
                    codexAuthActionError = nil
                    revealAPIKeyInput.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.accent)
                .disabled(authActionInFlight)
                .accessibilityIdentifier("chat.auth.toggleApiKey")

                Button("Refresh Auth") {
                    codexAuthActionError = nil
                    refreshCodexAuthState()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .disabled(authActionInFlight)
                .accessibilityIdentifier("chat.auth.refresh")
            }
        }
        .padding(12)
        .background(Theme.surface2.opacity(0.7))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("chat.auth.onboarding")
    }

    private func codexAuthOnboardingText() -> String {
        guard let codexAuthState else {
            return "Configure Codex credentials to start chatting."
        }

        var lines: [String] = [
            "Current state: \(codexAuthState.modeLabel).",
        ]

        if codexAuthState.hasCodexCLI {
            lines.append("Sign in with ChatGPT or save an OPENAI_API_KEY.")
        } else {
            lines.append("Codex CLI is not detected, so browser login is unavailable here.")
            lines.append("Use OPENAI_API_KEY, then refresh auth status.")
        }

        lines.append("Auth file: \(codexAuthState.authFilePath)")
        return lines.joined(separator: " ")
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

                if !composerAttachments.isEmpty {
                    attachmentChipsView
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
                        if mentionPaletteVisible, applySelectedMentionCompletion() {
                            return .handled
                        }
                        if executeSelectedSlashCommand() {
                            return .handled
                        }
                        send()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if slashPaletteVisible {
                            moveSlashSelection(1)
                            return .handled
                        }
                        if mentionPaletteVisible {
                            moveMentionSelection(1)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.upArrow) {
                        if slashPaletteVisible {
                            moveSlashSelection(-1)
                            return .handled
                        }
                        if mentionPaletteVisible {
                            moveMentionSelection(-1)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.tab) {
                        if slashPaletteVisible {
                            if let command = selectedSlashCommand {
                                inputText = "/\(command.name) "
                                selectedSlashIndex = 0
                            }
                            return .handled
                        }
                        if mentionPaletteVisible, applySelectedMentionCompletion() {
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.escape) {
                        if slashPaletteVisible {
                            inputText = ""
                            selectedSlashIndex = 0
                            return .handled
                        }
                        if mentionPaletteVisible {
                            closeMentionCompletions()
                            return .handled
                        }
                        return .ignored
                    }
                    .onChange(of: inputText) { _, _ in
                        selectedSlashIndex = 0
                        refreshMentionCompletions()
                    }
#if os(macOS)
                    .onPasteCommand(of: [.image, .png, .jpeg, .tiff, .fileURL, .plainText, .utf8PlainText]) { _ in
                        handlePasteCommand()
                    }
#endif
                    .accessibilityIdentifier("chat.input")

                if mentionPaletteVisible {
                    mentionPaletteView
                }

                HStack {
                    HStack(spacing: 12) {
                        Button(action: openAttachmentPicker) {
                            Image(systemName: "paperclip")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.attachmentButton")
                        Button(action: insertMentionTrigger) {
                            Image(systemName: "at")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.mentionButton")
                        Button(action: {
                            closeMentionCompletions()
                            inputText = "/"
                        }) {
                            Image(systemName: "sparkles")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.slashButton")
                        Button(action: { showModelSelectionSheet = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "slider.horizontal.3")
                                Text(codexModelSelection.summaryLabel)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.modelButton")
                        Button(action: { showApprovalSelectionSheet = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield")
                                Text(codexApprovalSelection.summaryLabel)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.approvalsButton")
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
                    .disabled(!sendActionAllowed)
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

    private var attachmentChipsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(composerAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)

                        Text(attachment.fileName)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)

                        Button {
                            removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .themedPill(cornerRadius: 8)
                    .accessibilityIdentifier("chat.attachment.\(attachment.id.uuidString)")
                }

                Button("Clear all") {
                    clearAllAttachments()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textTertiary)
                .accessibilityIdentifier("chat.attachments.clearAll")
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("chat.attachments")
    }

    private var mentionPaletteView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mentionCompletionsLoading && mentionSuggestions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading files...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            ForEach(Array(mentionSuggestions.prefix(Self.mentionCompletionResults).enumerated()), id: \.element.id) { index, candidate in
                Button {
                    applyMentionCompletion(candidate.path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: candidate.path.hasSuffix("/") ? "folder" : "doc")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                        Text(candidate.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .themedSidebarRowBackground(isSelected: index == mentionSelectionIndex)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.mention.option.\(index)")
            }
        }
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("chat.mentionPalette")
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
            codexAuthState = smithers.codexAuthState()
        } catch {
            targetPickerError = "Failed to discover chat targets: \(error.localizedDescription)"
            hasLoadedTargets = true
            codexAuthState = smithers.codexAuthState()
        }
    }

    private func send() {
        if agent.isRunning {
            agent.cancel()
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, executeExactSlashCommand(text) {
            return
        }

        let prepared = preparePromptForSend(text)
        guard prepared.shouldSend else { return }

        guard chatReady else {
            agent.appendStatusMessage("Codex is not authenticated. Use the auth panel above to sign in or add an API key.")
            return
        }

        if prepared.droppedAttachmentCount > 0 {
            let noun = prepared.droppedAttachmentCount == 1 ? "attachment" : "attachments"
            agent.appendStatusMessage("Skipped \(prepared.droppedAttachmentCount) non-text \(noun) because the selected model does not support image/file attachments.")
        }

        let displayText = text.isEmpty ? "(sent attachments)" : text
        inputText = ""
        clearAllAttachments()
        closeMentionCompletions()
        dispatchPromptToCodex(prompt: prepared.prompt, displayText: displayText)
    }

    private func sendPromptIfReady(_ prompt: String) {
        guard chatReady else {
            agent.appendStatusMessage("Codex is not authenticated. Use the auth panel above to sign in or add an API key.")
            return
        }
        dispatchPromptToCodex(prompt: prompt, displayText: prompt)
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
        selectedSlashIndex = 0
        #if os(macOS)
        let canTerminateApp = true
        #else
        let canTerminateApp = false
        #endif
        let context = SlashCommandExecutionContext(
            inputText: inputText,
            commands: slashCommands,
            chatReady: chatReady,
            developerDebugEnabled: DeveloperDebugMode.isEnabled,
            canNavigate: onNavigate != nil,
            canToggleDeveloperDebug: onToggleDeveloperDebug != nil,
            canStartNewChat: onNewChat != nil,
            canTerminateApp: canTerminateApp,
            helpText: SlashCommandRegistry.helpText(for: slashCommands),
            statusText: statusText()
        )
        let effects = SlashCommandExecutionEffects(
            setInputText: { inputText = $0 },
            appendStatusMessage: { agent.appendStatusMessage($0) },
            clearMessages: { agent.clearMessages() },
            navigate: { onNavigate?($0) },
            toggleDeveloperDebug: { onToggleDeveloperDebug?() },
            startNewChat: { onNewChat?() },
            sendPromptIfReady: { sendPromptIfReady($0) },
            showGitDiff: { showGitDiff() },
            refreshMentionCompletions: { refreshMentionCompletions() },
            showModelSelection: { showModelSelectionSheet = true },
            showApprovalSelection: { showApprovalSelectionSheet = true },
            showMCPStatus: { showMCPStatusSheet = true },
            performCodexLogout: { performCodexLogout() },
            terminateApp: {
                #if os(macOS)
                NSApplication.shared.terminate(nil)
                #endif
            },
            startFeedbackFlow: { startFeedbackFlow() },
            runWorkflow: { workflow, args in runWorkflow(workflow, args: args) },
            runSmithersPrompt: { promptId, args in runSmithersPrompt(promptId, args: args) }
        )
        SlashCommandExecutor.execute(command, context: context, effects: effects)
    }

    private func startFeedbackFlow() {
        pendingFeedbackCategory = nil
        feedbackComposerState = nil
        showFeedbackConsentDialog = false
        showFeedbackCategoryDialog = true
    }

    private func openFeedbackComposer(includeLogs: Bool) {
        showFeedbackConsentDialog = false
        guard let category = pendingFeedbackCategory else { return }
        let context = FeedbackContext.make(
            workspace: agent.workingDirectory,
            activeView: activeViewName,
            threadID: agent.activeThreadID,
            recentError: agent.recentErrorMessage
        )
        feedbackComposerState = FeedbackComposerState(
            category: category,
            includeLogs: includeLogs,
            context: context
        )
        pendingFeedbackCategory = nil
    }

    private func submitFeedback(state: FeedbackComposerState, note: String?) async throws {
        let reporter = FeedbackReporter()
        let request = FeedbackSubmissionRequest(
            category: state.category,
            note: note,
            includeLogs: state.includeLogs,
            context: state.context
        )
        let result = try await reporter.submit(request)

        let prefix = result.includeLogs ? "Feedback uploaded." : "Feedback recorded (no logs)."
        agent.appendStatusMessage(
            """
            \(prefix) Open an issue with:
            \(result.issueURL.absoluteString)

            Or mention thread ID \(result.threadID) in an existing issue.
            """
        )
        feedbackComposerState = nil
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
                sendPromptIfReady(prompt)
            } catch {
                agent.appendStatusMessage("Failed to render prompt \(promptId): \(error.localizedDescription)")
            }
        }
    }

    private func showGitDiff() {
        let cwd = agent.workingDirectory
        Task.detached {
            let result = LocalGitDiff.result(cwd: cwd)
            await MainActor.run {
                switch result {
                case .diff(let diff):
                    agent.appendDiffMessage(diff)
                case .status(let message):
                    agent.appendStatusMessage(message)
                }
            }
        }
    }

    private func statusText() -> String {
        let authMode = codexAuthState?.modeLabel ?? "Unknown"
        let readyText = chatReady ? "yes" : "no"
        return """
Workspace: \(agent.workingDirectory)
Messages: \(agent.messages.count)
Running: \(agent.isRunning ? "yes" : "no")
Model: \(codexModelSelection.model)
Reasoning: \(codexModelSelection.reasoningEffort?.rawValue ?? "default")
Approval: \(codexApprovalSelection.approvalPolicy.rawValue)
Sandbox: \(codexApprovalSelection.sandboxMode.rawValue)
Auth: \(authMode)
Ready: \(readyText)
"""
    }

    private func modelSelectionStatusText(for selection: CodexModelSelection) -> String {
        let reasoningText = selection.reasoningEffort?.rawValue ?? "default"
        if let profile = selection.activeProfile, !profile.isEmpty {
            return "Model changed to \(selection.model) with \(reasoningText) reasoning for \(profile) profile."
        }
        return "Model changed to \(selection.model) with \(reasoningText) reasoning."
    }

    private func approvalSelectionStatusText(for selection: CodexApprovalSelection) -> String {
        let mode = CodexApprovalPresetCatalog.preset(for: selection)?.label ?? "Custom"
        return "Approval mode changed to \(mode) (\(selection.approvalPolicy.rawValue), \(selection.sandboxMode.rawValue))."
    }

    private func refreshCodexAuthState() {
        guard let smithers else {
            codexAuthState = nil
            return
        }

        codexAuthState = smithers.codexAuthState()
    }

    private func startCodexChatGPTLogin() {
        guard let state = codexAuthState, state.hasCodexCLI else {
            codexAuthActionError = "Codex CLI is not available on PATH."
            return
        }

        codexAuthActionError = nil
        onNavigate?(.terminalCommand(
            binary: "codex login",
            workingDirectory: agent.workingDirectory,
            name: "Codex Login"
        ))
        agent.appendStatusMessage("Opened Codex login in terminal. Complete login, then return and refresh auth status.")
    }

    private func saveAPIKeyForCodex() {
        guard let smithers else {
            codexAuthActionError = "Smithers is not available in this chat view."
            return
        }

        authActionInFlight = true
        defer { authActionInFlight = false }

        do {
            try smithers.loginCodexWithAPIKey(pendingAPIKey)
            pendingAPIKey = ""
            revealAPIKeyInput = false
            codexAuthActionError = nil
            refreshCodexAuthState()
            agent.appendStatusMessage("Saved OPENAI_API_KEY to Codex auth file.")
        } catch {
            codexAuthActionError = error.localizedDescription
            agent.appendStatusMessage("Failed to save Codex API key: \(error.localizedDescription)")
        }
    }

    private func performCodexLogout() {
        guard let smithers else {
            agent.appendStatusMessage("Codex logout is unavailable because Smithers is not connected.")
            return
        }

        authActionInFlight = true
        defer { authActionInFlight = false }

        do {
            let removed = try smithers.logoutCodex()
            refreshCodexAuthState()
            if removed {
                agent.appendStatusMessage("Logged out of Codex.")
            } else {
                agent.appendStatusMessage("Codex was already logged out.")
            }

            if codexAuthState?.hasAPIKey == true {
                agent.appendStatusMessage("OPENAI_API_KEY is still set in your environment, so Codex remains ready.")
            }
        } catch {
            codexAuthActionError = error.localizedDescription
            agent.appendStatusMessage("Failed to log out Codex: \(error.localizedDescription)")
        }
    }

    private struct PreparedPrompt {
        let prompt: String
        let shouldSend: Bool
        let droppedAttachmentCount: Int
    }

    private func dispatchPromptToCodex(prompt: String, displayText: String) {
        if let onSendRequest {
            onSendRequest(ChatSendRequest(prompt: prompt, displayText: displayText))
            return
        }
        onSend(prompt)
    }

    private func preparePromptForSend(_ text: String) -> PreparedPrompt {
        var attachments = composerAttachments
        var droppedAttachmentCount = 0

        if !currentModelSupportsImages {
            let filtered = attachments.filter(\.isText)
            droppedAttachmentCount = attachments.count - filtered.count
            attachments = filtered
        }

        let prompt = Self.composePrompt(text: text, attachments: attachments)
        let shouldSend = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return PreparedPrompt(
            prompt: prompt,
            shouldSend: shouldSend,
            droppedAttachmentCount: droppedAttachmentCount
        )
    }

    private func clearAllAttachments() {
        composerAttachments.removeAll()
    }

    private func removeAttachment(_ id: UUID) {
        composerAttachments.removeAll { $0.id == id }
    }

    private func insertMentionTrigger() {
        if let last = inputText.last, !last.isWhitespace {
            inputText.append(" ")
        }
        inputText.append("@")
        refreshMentionCompletions()
    }

    private func moveMentionSelection(_ delta: Int) {
        let count = mentionSuggestions.count
        guard count > 0 else {
            mentionSelectionIndex = 0
            return
        }
        mentionSelectionIndex = (mentionSelectionIndex + delta + count) % count
    }

    @discardableResult
    private func applySelectedMentionCompletion() -> Bool {
        guard mentionSuggestions.indices.contains(mentionSelectionIndex) else { return false }
        applyMentionCompletion(mentionSuggestions[mentionSelectionIndex].path)
        return true
    }

    private func applyMentionCompletion(_ path: String) {
        if let context = Self.activeMentionContext(in: inputText) {
            inputText.replaceSubrange(context.tokenRange, with: path + " ")
        } else {
            inputText.append(path + " ")
        }

        attachMentionCompletion(path)
        closeMentionCompletions()
    }

    private func attachMentionCompletion(_ candidatePath: String) {
        let path = candidatePath.hasSuffix("/") ? String(candidatePath.dropLast()) : candidatePath
        guard !path.isEmpty else { return }

        let base = URL(fileURLWithPath: agent.workingDirectory, isDirectory: true)
        let resolvedURL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : base.appendingPathComponent(path)

        _ = addAttachment(from: resolvedURL, filePathForPrompt: path)
    }

    private func closeMentionCompletions() {
        mentionSuggestions = []
        mentionSelectionIndex = 0
    }

    private func refreshMentionCompletions() {
        if mentionCompletionsRoot != agent.workingDirectory {
            mentionCompletionsRoot = agent.workingDirectory
            mentionCompletionsLoaded = false
            mentionCompletionsLoading = false
            mentionCandidates = []
        }

        guard let context = Self.activeMentionContext(in: inputText), !slashPaletteVisible else {
            closeMentionCompletions()
            return
        }

        loadMentionCandidatesIfNeeded()
        mentionSuggestions = Self.filterMentionCandidates(
            mentionCandidates,
            query: context.query,
            limit: Self.mentionCompletionResults
        )
        if mentionSelectionIndex >= mentionSuggestions.count {
            mentionSelectionIndex = 0
        }
    }

    private func loadMentionCandidatesIfNeeded() {
        let root = agent.workingDirectory
        let maxDepth = Self.mentionCompletionMaxDepth
        let maxItems = Self.mentionCompletionMaxItems
        guard !mentionCompletionsLoading else { return }
        guard !mentionCompletionsLoaded || mentionCompletionsRoot != root else { return }

        mentionCompletionsLoading = true
        mentionCompletionsRoot = root

        Task {
            let candidates = await Task.detached(priority: .utility) {
                Self.collectMentionCandidates(
                    rootPath: root,
                    maxDepth: maxDepth,
                    maxItems: maxItems
                )
            }.value

            await MainActor.run {
                guard mentionCompletionsRoot == root else { return }
                mentionCandidates = candidates.map { ChatMentionCandidate(path: $0) }
                mentionCompletionsLoaded = true
                mentionCompletionsLoading = false
                refreshMentionCompletions()
            }
        }
    }

    private func openAttachmentPicker() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: agent.workingDirectory, isDirectory: true)

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            _ = addAttachment(from: url, filePathForPrompt: url.path)
        }
#endif
    }

    @discardableResult
    private func addAttachment(from url: URL, filePathForPrompt: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            agent.appendStatusMessage("Cannot attach a directory: \(url.lastPathComponent)")
            return false
        }

        guard let data = try? Data(contentsOf: url) else {
            agent.appendStatusMessage("Unable to read attachment: \(url.lastPathComponent)")
            return false
        }

        if data.count > Self.maxAttachmentSizeBytes {
            agent.appendStatusMessage("Attachment is too large (>5MB): \(url.lastPathComponent)")
            return false
        }

        let mimeType = Self.detectMimeType(data: data, fileName: url.lastPathComponent)
        if mimeType.hasPrefix("image/"), !currentModelSupportsImages {
            agent.appendStatusMessage("Model \(codexModelSelection.model) does not support image attachments.")
            return false
        }

        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if composerAttachments.contains(where: { $0.resolvedPath == resolvedPath }) {
            return false
        }

        composerAttachments.append(
            ChatComposerAttachment(
                filePath: filePathForPrompt,
                resolvedPath: resolvedPath,
                fileName: url.lastPathComponent,
                mimeType: mimeType,
                content: data
            )
        )
        return true
    }

    @discardableResult
    private func addGeneratedAttachment(
        fileName: String,
        mimeType: String,
        content: Data
    ) -> Bool {
        if content.count > Self.maxAttachmentSizeBytes {
            agent.appendStatusMessage("Attachment is too large (>5MB): \(fileName)")
            return false
        }

        let filePath: String
        let resolvedPath: String
        if mimeType.hasPrefix("text/") {
            filePath = fileName
            resolvedPath = fileName
        } else {
            do {
                let url = try Self.persistGeneratedAttachment(
                    fileName: fileName,
                    content: content
                )
                filePath = url.path
                resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            } catch {
                agent.appendStatusMessage("Unable to prepare attachment: \(fileName)")
                return false
            }
        }

        if composerAttachments.contains(where: { $0.resolvedPath == resolvedPath }) {
            return false
        }

        composerAttachments.append(
            ChatComposerAttachment(
                filePath: filePath,
                resolvedPath: resolvedPath,
                fileName: fileName,
                mimeType: mimeType,
                content: content
            )
        )
        return true
    }

    private static func persistGeneratedAttachment(fileName: String, content: Data) throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("smithers-chat-attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let safeName = (fileName as NSString).lastPathComponent.nilIfBlank ?? "attachment"
        let url = base.appendingPathComponent(safeName, isDirectory: false)
        try content.write(to: url, options: .atomic)
        return url
    }

    private func handlePasteCommand() {
#if os(macOS)
        let pasteboard = NSPasteboard.general

        if currentModelSupportsImages, let image = Self.pngFromPasteboardImage(pasteboard) {
            let index = nextPasteIndex()
            _ = addGeneratedAttachment(
                fileName: "paste_\(index).png",
                mimeType: "image/png",
                content: image
            )
            return
        }

        if let pastedURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !pastedURLs.isEmpty {
            var attachedAny = false
            for url in pastedURLs {
                let promptPath = Self.relativePathIfPossible(url.path, to: agent.workingDirectory) ?? url.path
                if addAttachment(from: url, filePathForPrompt: promptPath) {
                    attachedAny = true
                }
            }
            if attachedAny {
                return
            }
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            handlePastedText(text)
        }
#endif
    }

    private func handlePastedText(_ text: String) {
        let candidatePaths = Self.parsePastedFilePaths(text)
        var attachedFromPaths = false

        for rawPath in candidatePaths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            let url: URL
            if expanded.hasPrefix("/") {
                url = URL(fileURLWithPath: expanded)
            } else {
                url = URL(fileURLWithPath: agent.workingDirectory, isDirectory: true)
                    .appendingPathComponent(expanded)
            }

            if !currentModelSupportsImages {
                let ext = url.pathExtension.lowercased()
                if Self.supportedImageExtensions.contains(ext) {
                    continue
                }
            }

            let promptPath = Self.relativePathIfPossible(url.path, to: agent.workingDirectory) ?? rawPath
            if addAttachment(from: url, filePathForPrompt: promptPath) {
                attachedFromPaths = true
            }
        }

        if attachedFromPaths {
            return
        }

        if Self.hasPasteExceededThreshold(text) {
            let data = Data(text.utf8)
            let index = nextPasteIndex()
            _ = addGeneratedAttachment(
                fileName: "paste_\(index).txt",
                mimeType: "text/plain",
                content: data
            )
            return
        }

        inputText.append(text)
    }

    private func nextPasteIndex() -> Int {
        var highest = 0
        for attachment in composerAttachments {
            guard attachment.fileName.hasPrefix("paste_") else { continue }
            let suffix = attachment.fileName.dropFirst("paste_".count)
            let numberText = suffix.prefix { $0.isNumber }
            if let value = Int(numberText) {
                highest = max(highest, value)
            }
        }
        return highest + 1
    }

    private static func composePrompt(text: String, attachments: [ChatComposerAttachment]) -> String {
        var prompt = promptWithTextAttachments(prompt: text, attachments: attachments)
        let nonText = attachments.filter { !$0.isText }

        guard !nonText.isEmpty else {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !prompt.isEmpty {
            prompt.append("\n")
        }

        let images = nonText.filter(\.isImage)
        if !images.isEmpty {
            prompt.append("<system_info>The user attached local image files. Use them as additional visual context.</system_info>\n")
            for image in images {
                let filePath = escapeXMLAttribute(image.filePath)
                let fileName = escapeXMLText(image.fileName)
                prompt.append("<local_image path='\(filePath)'>\(fileName)</local_image>\n")
            }
        }

        let others = nonText.filter { !$0.isImage }
        if !others.isEmpty {
            prompt.append("<system_info>The user attached local files. Reference their paths in your analysis.</system_info>\n")
            for attachment in others {
                let filePath = escapeXMLAttribute(attachment.filePath)
                let mimeType = escapeXMLAttribute(attachment.mimeType)
                let fileName = escapeXMLText(attachment.fileName)
                prompt.append("<local_attachment path='\(filePath)' mime='\(mimeType)'>\(fileName)</local_attachment>\n")
            }
        }

        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func promptWithTextAttachments(
        prompt: String,
        attachments: [ChatComposerAttachment]
    ) -> String {
        var result = prompt
        var addedAttachments = false

        for attachment in attachments where attachment.isText {
            if !addedAttachments {
                result.append("\n<system_info>The files below have been attached by the user, consider them in your response</system_info>\n")
                addedAttachments = true
            }

            if !attachment.filePath.isEmpty {
                result.append("<file path='\(escapeXMLAttribute(attachment.filePath))'>\n")
            } else {
                result.append("<file>\n")
            }

            result.append("\n")
            result.append(String(decoding: attachment.content, as: UTF8.self))
            result.append("\n</file>\n")
        }

        return result
    }

    private static func escapeXMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func activeMentionContext(in text: String) -> ChatMentionContext? {
        guard !text.isEmpty else { return nil }

        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let ch = text[prev]

            if ch == "@" {
                if prev > text.startIndex {
                    let beforeAt = text[text.index(before: prev)]
                    if !beforeAt.isWhitespace {
                        return nil
                    }
                }

                let queryStart = text.index(after: prev)
                let query = String(text[queryStart..<text.endIndex])
                if query.contains(where: \.isWhitespace) {
                    return nil
                }
                return ChatMentionContext(tokenRange: prev..<text.endIndex, query: query)
            }

            if ch.isWhitespace {
                return nil
            }

            idx = prev
        }

        return nil
    }

    nonisolated private static func collectMentionCandidates(
        rootPath: String,
        maxDepth: Int,
        maxItems: Int
    ) -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }

        var paths: [String] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            return []
        }

        while let item = enumerator.nextObject() as? URL {
            let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.isEmpty {
                continue
            }

            let normalized = relative.replacingOccurrences(of: "\\", with: "/")
            let depth = normalized.split(separator: "/").count
            let isDirectory = (try? item.resourceValues(forKeys: keys).isDirectory) ?? false

            if maxDepth > 0 && depth > maxDepth {
                if isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if isDirectory != true {
                paths.append(normalized)
            }
            if maxItems > 0 && paths.count >= maxItems {
                break
            }
        }

        return paths.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func filterMentionCandidates(
        _ candidates: [ChatMentionCandidate],
        query: String,
        limit: Int
    ) -> [ChatMentionCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(candidates.prefix(limit))
        }

        let lowerQuery = trimmed.lowercased()
        let filtered = candidates.filter { candidate in
            candidate.path.lowercased().contains(lowerQuery)
        }

        let sorted = filtered.sorted { lhs, rhs in
            let leftTier = mentionPriorityTier(path: lhs.path, query: lowerQuery)
            let rightTier = mentionPriorityTier(path: rhs.path, query: lowerQuery)
            if leftTier != rightTier {
                return leftTier < rightTier
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        return Array(sorted.prefix(limit))
    }

    private static func mentionPriorityTier(path: String, query: String) -> Int {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let base = (normalized as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension

        if base == query || stem == query {
            return 0
        }
        if base.hasPrefix(query) {
            return 1
        }
        let segments = normalized.split(separator: "/").map(String.init)
        if segments.contains(query) {
            return 2
        }
        return 3
    }

    private static func hasPasteExceededThreshold(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.pasteLinesThreshold {
            return true
        }

        let widestLine = lines.map(\.count).max() ?? 0
        return widestLine > Self.pasteColsThreshold
    }

    private static func parsePastedFilePaths(_ text: String) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{0000}", with: "")
        guard !cleaned.isEmpty else { return [] }

        let quotedWindows = parseWindowsTerminalPastedFiles(cleaned)
        if !quotedWindows.isEmpty {
            return quotedWindows
        }

        if cleaned.contains("\n") {
            return cleaned
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return parseUnixPastedFiles(cleaned)
    }

    private static func parseWindowsTerminalPastedFiles(_ value: String) -> [String] {
        var paths: [String] = []
        var current = ""
        var inQuotes = false

        for ch in value {
            if ch == "\"" {
                if inQuotes {
                    if !current.isEmpty {
                        paths.append(current)
                        current = ""
                    }
                    inQuotes = false
                } else {
                    inQuotes = true
                }
                continue
            }

            if inQuotes {
                current.append(ch)
                continue
            }

            if ch != " " {
                return []
            }
        }

        if inQuotes {
            return []
        }

        if !current.isEmpty {
            paths.append(current)
        }

        return paths
    }

    private static func parseUnixPastedFiles(_ value: String) -> [String] {
        var paths: [String] = []
        var current = ""
        var escaped = false

        for ch in value {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }

            if ch == "\\" {
                escaped = true
                continue
            }

            if ch == " " {
                if !current.isEmpty {
                    paths.append(current)
                    current = ""
                }
                continue
            }

            current.append(ch)
        }

        if escaped {
            current.append("\\")
        }

        if !current.isEmpty {
            paths.append(current)
        }

        return paths
    }

    private static func detectMimeType(data: Data, fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }

        if data.starts(with: [UInt8(0x89), 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if data.starts(with: [UInt8(0xFF), 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if String(data: data.prefix(1024), encoding: .utf8) != nil {
            return "text/plain"
        }

        return "application/octet-stream"
    }

    private static func relativePathIfPossible(_ path: String, to root: String) -> String? {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path

        guard normalized.hasPrefix(rootPath + "/") else { return nil }
        return String(normalized.dropFirst(rootPath.count + 1))
    }

#if os(macOS)
    private static func pngFromPasteboardImage(_ pasteboard: NSPasteboard) -> Data? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        return rep.representation(using: .png, properties: [:])
    }
#endif

    private func loadDynamicSlashCommands() async {
        guard let smithers else { return }

        var workflows: [Workflow] = []
        do {
            workflows = try await smithers.listWorkflows()
        } catch {
            workflows = []
        }

        var prompts: [SmithersPrompt] = []
        do {
            prompts = try await smithers.listPrompts()
        } catch {
            prompts = []
        }

        let commands = SlashCommandRegistry.dynamicCommands(workflows: workflows, prompts: prompts)
        workflowCommands = commands.workflows
        promptCommands = commands.prompts
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

private struct CodexModelPickerSheet: View {
    let initialSelection: CodexModelSelection
    let modelPresets: [CodexModelPreset]
    let onApply: (CodexModelSelection) -> Result<CodexModelSelection, CodexModelSelectionError>
    let onApplied: (CodexModelSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedModel: String
    @State private var selectedEffort: CodexReasoningEffort
    @State private var errorMessage: String?

    init(
        initialSelection: CodexModelSelection,
        modelPresets: [CodexModelPreset],
        onApply: @escaping (CodexModelSelection) -> Result<CodexModelSelection, CodexModelSelectionError>,
        onApplied: @escaping (CodexModelSelection) -> Void
    ) {
        let normalized = CodexModelCatalog.normalized(initialSelection)
        self.initialSelection = initialSelection
        self.modelPresets = modelPresets
        self.onApply = onApply
        self.onApplied = onApplied
        _selectedModel = State(initialValue: normalized.model)
        _selectedEffort = State(initialValue: normalized.reasoningEffort ?? .medium)
    }

    private var selectedPreset: CodexModelPreset? {
        modelPresets.first(where: { $0.model == selectedModel }) ?? modelPresets.first
    }

    private var reasoningOptions: [CodexReasoningPreset] {
        selectedPreset?.supportedReasoningEfforts ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(modelPresets) { preset in
                            Text(preset.displayName).tag(preset.model)
                        }
                    }
                    .pickerStyle(.menu)

                    if let selectedPreset {
                        Text(selectedPreset.description)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                Section("Reasoning Effort") {
                    Picker("Reasoning", selection: $selectedEffort) {
                        ForEach(reasoningOptions) { option in
                            Text(option.effort.displayName).tag(option.effort)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let option = reasoningOptions.first(where: { $0.effort == selectedEffort }) {
                        Text(option.description)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }

                    if selectedModel == "gpt-5-codex" && selectedEffort == .high {
                        Text("High reasoning effort can quickly consume Plus plan rate limits.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.warning)
                    }
                }

                if let profile = initialSelection.activeProfile, !profile.isEmpty {
                    Section("Persistence") {
                        Text("Selection will be saved for profile: \(profile)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.danger)
                    }
                }
            }
            .navigationTitle("Model & Reasoning")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applySelection()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(modelPresets.isEmpty)
                }
            }
        }
        .onChange(of: selectedModel) { _, _ in
            guard !reasoningOptions.isEmpty else { return }
            if !reasoningOptions.contains(where: { $0.effort == selectedEffort }) {
                selectedEffort = selectedPreset?.defaultReasoningEffort ?? .medium
            }
        }
    }

    private func applySelection() {
        let selection = CodexModelSelection(
            model: selectedModel,
            reasoningEffort: selectedEffort,
            activeProfile: initialSelection.activeProfile
        )

        switch onApply(selection) {
        case .success(let persisted):
            onApplied(persisted)
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct CodexApprovalPickerSheet: View {
    let initialSelection: CodexApprovalSelection
    let onApply: (CodexApprovalSelection) -> Result<CodexApprovalSelection, CodexApprovalSelectionError>
    let onApplied: (CodexApprovalSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPresetID: String
    @State private var errorMessage: String?
    @State private var showFullAccessConfirmation = false

    init(
        initialSelection: CodexApprovalSelection,
        onApply: @escaping (CodexApprovalSelection) -> Result<CodexApprovalSelection, CodexApprovalSelectionError>,
        onApplied: @escaping (CodexApprovalSelection) -> Void
    ) {
        self.initialSelection = initialSelection
        self.onApply = onApply
        self.onApplied = onApplied
        _selectedPresetID = State(initialValue: CodexApprovalPresetCatalog.preset(for: initialSelection)?.id ?? CodexApprovalPresetCatalog.presets.first?.id ?? "read-only")
    }

    private var selectedPreset: CodexApprovalPreset? {
        CodexApprovalPresetCatalog.presets.first(where: { $0.id == selectedPresetID })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Settings") {
                    Text("Approval: \(initialSelection.approvalPolicy.rawValue)")
                    Text("Sandbox: \(initialSelection.sandboxMode.rawValue)")
                }

                Section("Preset") {
                    Picker("Mode", selection: $selectedPresetID) {
                        ForEach(CodexApprovalPresetCatalog.presets) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    .pickerStyle(.inline)

                    if let selectedPreset {
                        Text(selectedPreset.description)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }

                    if selectedPreset?.id == "full-access" {
                        Text("Full Access disables sandboxing and approval prompts. Use only in trusted environments.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.warning)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.danger)
                    }
                }
            }
            .navigationTitle("Approval & Sandbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard let selectedPreset else { return }
                        if selectedPreset.id == "full-access" {
                            showFullAccessConfirmation = true
                            return
                        }
                        applySelection(from: selectedPreset)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPreset == nil)
                }
            }
        }
        .confirmationDialog(
            "Enable Full Access?",
            isPresented: $showFullAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable Full Access", role: .destructive) {
                if let selectedPreset {
                    applySelection(from: selectedPreset)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Codex will run without sandbox restrictions and without asking for approval.")
        }
    }

    private func applySelection(from preset: CodexApprovalPreset) {
        let selection = CodexApprovalSelection(
            approvalPolicy: preset.approvalPolicy,
            sandboxMode: preset.sandboxMode
        )

        switch onApply(selection) {
        case .success(let applied):
            onApplied(applied)
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct CodexMCPStatusSheet: View {
    let cwd: String

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: CodexMCPStatusSnapshot?
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && snapshot == nil {
                    ProgressView("Loading MCP status...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot {
                    if snapshot.servers.isEmpty {
                        ContentUnavailableView(
                            "No MCP Servers Configured",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Add MCP servers in Codex config to use `/mcp`.")
                        )
                    } else {
                        List {
                            if let error = snapshot.error, !error.isEmpty {
                                Section("Bridge Error") {
                                    Text(error)
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.danger)
                                        .textSelection(.enabled)
                                }
                            }

                            if !snapshot.errors.isEmpty {
                                Section("Errors") {
                                    ForEach(snapshot.errors, id: \.self) { message in
                                        Text(message)
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.danger)
                                            .textSelection(.enabled)
                                    }
                                }
                            }

                            ForEach(snapshot.servers) { server in
                                Section(server.name) {
                                    LabeledContent("Status") {
                                        Text(server.status.capitalized)
                                            .foregroundColor(statusColor(for: server.status))
                                    }
                                    LabeledContent("Auth") {
                                        Text(server.authLabel)
                                    }
                                    if let timeout = server.startupTimeoutSec {
                                        LabeledContent("Startup Timeout") {
                                            Text(timeoutText(timeout))
                                        }
                                    }
                                    if let timeout = server.toolTimeoutSec {
                                        LabeledContent("Tool Timeout") {
                                            Text(timeoutText(timeout))
                                        }
                                    }
                                    transportDetails(server.transport)
                                    LabeledContent("Tools") {
                                        Text(joinedList(server.tools))
                                            .font(.system(size: 12, design: .monospaced))
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                    LabeledContent("Resources") {
                                        Text(joinedList(server.resources.map { $0.title ?? $0.name }))
                                            .font(.system(size: 12))
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                    LabeledContent("Resource Templates") {
                                        Text(joinedList(server.resourceTemplates.map { $0.title ?? $0.name }))
                                            .font(.system(size: 12))
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }

                                    if !server.errors.isEmpty {
                                        ForEach(server.errors, id: \.self) { message in
                                            Text(message)
                                                .font(.system(size: 12))
                                                .foregroundColor(Theme.danger)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if hasLoaded {
                    ContentUnavailableView(
                        "Failed To Load MCP Status",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Codex bridge returned invalid MCP status.")
                    )
                } else {
                    EmptyView()
                }
            }
            .navigationTitle("MCP Status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Refresh")
                        }
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        let cwd = self.cwd
        let loaded = await Task.detached(priority: .userInitiated) {
            CodexMCPStatusStore.loadStatus(cwd: cwd)
        }.value
        snapshot = loaded
        hasLoaded = true
        isLoading = false
    }

    private func joinedList(_ values: [String]) -> String {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            return "(none)"
        }
        return cleaned.joined(separator: ", ")
    }

    private func timeoutText(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return String(format: "%.2fs", seconds)
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "enabled":
            return Theme.success
        case "error":
            return Theme.danger
        case "disabled":
            return Theme.textTertiary
        default:
            return Theme.textPrimary
        }
    }

    @ViewBuilder
    private func transportDetails(_ transport: CodexMCPTransport) -> some View {
        switch transport {
        case .stdio(let command, let args, let cwd, let envKeys, let envVars):
            let cmd = ([command] + args).joined(separator: " ")
            LabeledContent("Transport") {
                Text("stdio")
            }
            LabeledContent("Command") {
                Text(cmd)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let cwd, !cwd.isEmpty {
                LabeledContent("Cwd") {
                    Text(cwd)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !envKeys.isEmpty {
                LabeledContent("Env Keys") {
                    Text(joinedList(envKeys))
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !envVars.isEmpty {
                LabeledContent("Env Vars") {
                    Text(joinedList(envVars))
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        case .streamableHTTP(let url, let bearerTokenEnvVar, let httpHeaderKeys, let envHTTPHeaders):
            LabeledContent("Transport") {
                Text("streamable_http")
            }
            LabeledContent("URL") {
                Text(url)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let bearerTokenEnvVar, !bearerTokenEnvVar.isEmpty {
                LabeledContent("Bearer Token Env") {
                    Text(bearerTokenEnvVar)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !httpHeaderKeys.isEmpty {
                LabeledContent("HTTP Headers") {
                    Text(joinedList(httpHeaderKeys))
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !envHTTPHeaders.isEmpty {
                LabeledContent("Env HTTP Headers") {
                    let entries = envHTTPHeaders.map { "\($0.name)=\($0.envVar)" }
                    Text(joinedList(entries))
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        case .unknown(let type):
            LabeledContent("Transport") {
                Text(type)
            }
        }
    }
}

private enum LocalGitDiffResult: Sendable {
    case diff(Diff)
    case status(String)
}

private enum LocalGitDiff {
    private static let maxDiffSnippetCharacters = 40_000

    static func result(cwd: String) -> LocalGitDiffResult {
        let status = runGit(["-C", cwd, "status", "--short"])
        if status.exitCode != 0 {
            return .status(status.stderr.isEmpty ? "Not inside a git repository." : status.stderr)
        }

        let diff = runGit(["-C", cwd, "diff", "--no-ext-diff", "--no-color", "HEAD", "--"])
        if diff.exitCode != 0 {
            let message = diff.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .status(message.isEmpty ? "Unable to read git diff." : message)
        }

        let cleanStatus = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDiff = diff.stdout.trimmingCharacters(in: .newlines)

        if cleanStatus.isEmpty && cleanDiff.isEmpty {
            return .status("No git changes.")
        }

        if cleanDiff.isEmpty {
            return .status("Git changes:\n\(cleanStatus)")
        }

        let files = diffFiles(cwd: cwd)
        let totalAdditions = files.reduce(0) { $0 + $1.additions }
        let totalDeletions = files.reduce(0) { $0 + $1.deletions }
        let snippet = truncatedSnippet(cleanDiff)
        return .diff(Diff(
            files: files,
            totalAdditions: totalAdditions,
            totalDeletions: totalDeletions,
            status: cleanStatus,
            snippet: snippet
        ))
    }

    private static func diffFiles(cwd: String) -> [DiffFile] {
        let numstat = runGit(["-C", cwd, "diff", "--numstat", "HEAD", "--"])
        guard numstat.exitCode == 0 else { return [] }

        return numstat.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                return DiffFile(
                    name: String(parts[2]),
                    additions: Int(parts[0]) ?? 0,
                    deletions: Int(parts[1]) ?? 0
                )
            }
    }

    private static func truncatedSnippet(_ diff: String) -> String {
        guard diff.count > maxDiffSnippetCharacters else {
            return diff
        }
        return String(diff.prefix(maxDiffSnippetCharacters)) + "\n\n... diff truncated ..."
    }

    private static func runGit(_ arguments: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCollector = GitProcessOutputBuffer()
        let stderrCollector = GitProcessOutputBuffer()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let outData = stdoutCollector.snapshot()
            let errData = stderrCollector.snapshot()
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

private final class GitProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

private enum ExternalChatLauncher {
    static func launch(binaryPath: String, workingDirectory: String) async throws {
        guard !binaryPath.isEmpty else {
            throw SmithersError.cli("Missing binary path for external chat target")
        }

        #if os(macOS)
        try await Task.detached {
            try launchCommandInTerminal(
                command: shellQuote(binaryPath),
                workingDirectory: workingDirectory
            )
        }.value
        #else
        throw SmithersError.notAvailable("External chat launch is only supported on macOS in this GUI build")
        #endif
    }

    static func launchCodexLogin(binaryPath: String, workingDirectory: String) async throws {
        guard !binaryPath.isEmpty else {
            throw SmithersError.cli("Missing codex binary path")
        }

        #if os(macOS)
        try await Task.detached {
            try launchCommandInTerminal(
                command: "\(shellQuote(binaryPath)) login",
                workingDirectory: workingDirectory
            )
        }.value
        #else
        throw SmithersError.notAvailable("Codex browser login is only supported on macOS in this GUI build")
        #endif
    }

    #if os(macOS)
    private static func launchCommandInTerminal(command: String, workingDirectory: String) throws {
        let command = "cd \(shellQuote(workingDirectory)); \(command)"
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

private let maxCollapsedThinkingLines = 10
private let maxCollapsedToolOutputLines = 10

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ToolCategory {
    var displayLabel: String {
        switch self {
        case .bash: return "BASH"
        case .file: return "FILE"
        case .search: return "SEARCH"
        case .fetch: return "FETCH"
        case .agent: return "AGENT"
        case .diagnostics: return "DIAGNOSTICS"
        case .references: return "REFERENCES"
        case .lspRestart: return "LSP"
        case .todos: return "TODO"
        case .mcp: return "MCP"
        case .generic: return "TOOL"
        }
    }
}

private extension ToolExecutionStatus {
    var iconName: String {
        switch self {
        case .pending, .running:
            return "clock"
        case .success:
            return "checkmark.circle"
        case .error:
            return "xmark.circle"
        case .canceled:
            return "slash.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            return Theme.textTertiary
        case .running:
            return Theme.warning
        case .success:
            return Theme.success
        case .error:
            return Theme.danger
        case .canceled:
            return Theme.textSecondary
        case .unknown:
            return Theme.textSecondary
        }
    }
}

private func copyTextToClipboard(_ text: String) {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
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
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy") {
                            copyTextToClipboard(message.content)
                        }
                    }
            } else if message.type == .assistant {
                VStack(alignment: .leading, spacing: 8) {
                    AssistantBubble(message: message)
                    if let cmd = message.command {
                        CommandBlock(command: cmd)
                    }
                    if let tool = message.tool {
                        ToolMessageBlock(tool: tool, fallbackContent: message.content)
                    }
                }
                Spacer()
            } else if message.type == .command {
                if let cmd = message.command {
                    CommandBlock(command: cmd)
                }
                Spacer()
            } else if let tool = message.tool {
                ToolMessageBlock(tool: tool, fallbackContent: message.content)
                Spacer()
            } else if message.type == .diff {
                if let diff = message.diff {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            SyntaxHighlightedText(diff.snippet, font: .system(size: 11, design: .monospaced))
                            Text(diff.snippet)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.clear)
                                .textSelection(.enabled)
                        }
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
                    .contextMenu {
                        Button("Copy") {
                            copyTextToClipboard(diff.snippet)
                        }
                    }
                    Spacer()
                }
            } else if message.type == .status || message.type == .tool {
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
                .contextMenu {
                    Button("Copy") {
                        copyTextToClipboard(message.content)
                    }
                }
                Spacer()
            }
        }
        .accessibilityIdentifier("chat.message.\(message.type.rawValue).\(message.id)")
    }
}

private struct AssistantBubble: View {
    let message: ChatMessage
    @State private var thinkingExpanded = false

    private var thinkingText: String? {
        message.assistant?.thinking?.nilIfBlank
    }

    private var thinkingLines: [String] {
        (thinkingText ?? "").components(separatedBy: .newlines)
    }

    private var visibleThinkingText: String {
        guard let thinkingText else { return "" }
        if thinkingExpanded || thinkingLines.count <= maxCollapsedThinkingLines {
            return thinkingText
        }
        return thinkingLines.suffix(maxCollapsedThinkingLines).joined(separator: "\n")
    }

    private var hiddenThinkingCount: Int {
        max(0, thinkingLines.count - maxCollapsedThinkingLines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if thinkingText != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thinking")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)

                    if !thinkingExpanded && hiddenThinkingCount > 0 {
                        Text("… (\(hiddenThinkingCount) lines hidden)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }

                    Text(visibleThinkingText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)

                    if hiddenThinkingCount > 0 {
                        Button(thinkingExpanded ? "Collapse" : "Expand") {
                            thinkingExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }
                }
                .padding(10)
                .background(Theme.surface2.opacity(0.8))
                .cornerRadius(8)
            }

            if let text = message.content.nilIfBlank {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }

            if let errorMessage = message.assistant?.errorMessage?.nilIfBlank {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ERROR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.danger)
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.danger)
                    if let details = message.assistant?.errorDetails?.nilIfBlank {
                        Text(details)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(Theme.danger.opacity(0.08))
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.bubbleAssistant)
        .cornerRadius(16, corners: [.topRight, .bottomLeft, .bottomRight])
        .contextMenu {
            if let text = message.content.nilIfBlank {
                Button("Copy message") {
                    copyTextToClipboard(text)
                }
            }
            if let thinkingText {
                Button("Copy thinking") {
                    copyTextToClipboard(thinkingText)
                }
            }
            if let error = message.assistant?.errorMessage?.nilIfBlank {
                Button("Copy error") {
                    copyTextToClipboard(error)
                }
            }
        }
    }
}

private struct ToolMessageBlock: View {
    let tool: ToolMessagePayload
    let fallbackContent: String

    @State private var outputExpanded = false
    @State private var detailsExpanded = false

    private var resolvedOutput: String? {
        tool.output?.nilIfBlank ?? fallbackContent.nilIfBlank
    }

    private var outputLines: [String] {
        (resolvedOutput ?? "").components(separatedBy: .newlines)
    }

    private var hiddenOutputLineCount: Int {
        max(0, outputLines.count - maxCollapsedToolOutputLines)
    }

    private var collapsedOutput: String {
        outputLines.prefix(maxCollapsedToolOutputLines).joined(separator: "\n")
    }

    private var hasDetails: Bool {
        tool.input?.nilIfBlank != nil || tool.details?.nilIfBlank != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tool.category.displayLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.warning)

                Text(tool.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                if let subtitle = tool.subtitle?.nilIfBlank {
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer()

                if tool.status == .running {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: tool.status.iconName)
                        .font(.system(size: 11))
                        .foregroundColor(tool.status.tint)
                }
            }

            if !tool.compact, let output = resolvedOutput {
                if hiddenOutputLineCount > 0 && !outputExpanded {
                    Text(collapsedOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                    Text("… (\(hiddenOutputLineCount) lines hidden)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }

            if hasDetails || hiddenOutputLineCount > 0 {
                HStack(spacing: 12) {
                    if hiddenOutputLineCount > 0 {
                        Button(outputExpanded ? "Collapse output" : "Expand output") {
                            outputExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }

                    if hasDetails {
                        Button(detailsExpanded ? "Hide details" : "Show details") {
                            detailsExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }

                    Button("Copy") {
                        copyTextToClipboard(tool.copyText)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
                }
            }

            if detailsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let input = tool.input?.nilIfBlank {
                        Text("Input")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    if let details = tool.details?.nilIfBlank {
                        Text("Details")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                        Text(details)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(Theme.surface2.opacity(0.8))
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.bubbleStatus)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .contextMenu {
            Button("Copy") {
                copyTextToClipboard(tool.copyText)
            }
            if let output = resolvedOutput {
                Button("Copy output") {
                    copyTextToClipboard(output)
                }
            }
        }
    }
}

private struct FeedbackNoteSheet: View {
    let state: FeedbackComposerState
    let onCancel: () -> Void
    let onSubmit: (String?) async throws -> Void

    @State private var note: String = ""
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.category.composerTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Text(state.category.description)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            TextEditor(text: $note)
                .font(.system(size: 12))
                .frame(minHeight: 120)
                .padding(8)
                .background(Theme.surface1)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .accessibilityIdentifier("chat.feedback.noteInput")

            if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(state.category.placeholder)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Context")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Text("Version: \(state.context.appVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text("Workspace: \(state.context.workspace)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                Text("Active view: \(state.context.activeView)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text("Thread ID: \(state.context.threadID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                if let recentError = state.context.recentError?.nilIfBlank {
                    Text("Recent error: \(recentError)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.danger)
                        .lineLimit(3)
                }
                Text(state.includeLogs ? "Logs: Included (codex-logs.log)" : "Logs: Not included")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }

            if let submitError {
                Text(submitError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
                    .accessibilityIdentifier("chat.feedback.error")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    guard !isSubmitting else { return }
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)

                Button(isSubmitting ? "Submitting..." : "Submit") {
                    submitFeedback()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.accent)
                .disabled(isSubmitting)
                .accessibilityIdentifier("chat.feedback.submit")
            }
        }
        .padding(20)
        .background(Theme.surface2)
    }

    private func submitFeedback() {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        Task {
            do {
                try await onSubmit(trimmedNote)
                await MainActor.run {
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                }
            }
        }
    }
}

struct CommandBlock: View {
    let command: Command

    @State private var outputExpanded = false
    @State private var detailsExpanded = false

    private var outputLines: [String] {
        command.output.components(separatedBy: .newlines)
    }

    private var hiddenOutputLineCount: Int {
        max(0, outputLines.count - maxCollapsedToolOutputLines)
    }

    private var collapsedOutput: String {
        outputLines.prefix(maxCollapsedToolOutputLines).joined(separator: "\n")
    }

    private var hasDetails: Bool {
        command.details?.nilIfBlank != nil
    }

    private var exitStatusLabel: String {
        guard let exitCode = command.exitCode else {
            return "exit unknown"
        }
        return "exit \(exitCode)"
    }

    private var exitStatusIconName: String {
        guard let exitCode = command.exitCode else {
            return "questionmark.circle"
        }
        return exitCode == 0 ? "checkmark.circle" : "xmark.circle"
    }

    private var exitStatusTint: Color {
        guard let exitCode = command.exitCode else {
            return Theme.textSecondary
        }
        return exitCode == 0 ? Theme.success : Theme.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let category = command.toolCategory {
                    Text(category.displayLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.warning)
                }

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
                        Image(systemName: exitStatusIconName)
                            .font(.system(size: 10))
                        Text(exitStatusLabel)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(exitStatusTint.opacity(0.15))
                    .foregroundColor(exitStatusTint)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(exitStatusTint.opacity(0.3), lineWidth: 1)
                    )
                }
            }
            .padding(12)
            .background(Theme.bubbleCommand)

            VStack(alignment: .leading, spacing: 6) {
                Text("cwd: \(command.cwd)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.bottom, 6)

                if hiddenOutputLineCount > 0 && !outputExpanded {
                    Text(collapsedOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                    Text("… (\(hiddenOutputLineCount) lines hidden)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    Text(command.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    if hiddenOutputLineCount > 0 {
                        Button(outputExpanded ? "Collapse output" : "Expand output") {
                            outputExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }

                    if hasDetails {
                        Button(detailsExpanded ? "Hide details" : "Show details") {
                            detailsExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }

                    Button("Copy") {
                        copyTextToClipboard(command.output)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
                }

                if detailsExpanded, let details = command.details?.nilIfBlank {
                    Text(details)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .background(Theme.bubbleCommand)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .contextMenu {
            Button("Copy output") {
                copyTextToClipboard(command.output)
            }
            Button("Copy command") {
                copyTextToClipboard(command.cmd)
            }
        }
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
