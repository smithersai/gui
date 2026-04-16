import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

private struct GUIControlSidebarMessage: Identifiable, Equatable {
    enum Role {
        case user
        case agent
        case system
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
}

struct GUIControlSidebar: View {
    @Binding var isExpanded: Bool
    @ObservedObject var store: SessionStore
    @ObservedObject var smithers: SmithersClient
    let destination: NavDestination
    var onNavigate: (NavDestination) -> Void

    @State private var inputText = ""
    @State private var showScreenshotCaptureConfirmation = false
    @State private var messages: [GUIControlSidebarMessage] = [
        GUIControlSidebarMessage(
            role: .system,
            text: "Ready for app control. Start a Smithers run to inspect the app and act.",
            timestamp: Date()
        ),
    ]

    var body: some View {
        Group {
            if isExpanded {
                expandedPanel
            } else {
                collapsedRail
            }
        }
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .accessibilityIdentifier(isExpanded ? "guiControl.sidebar.expanded" : "guiControl.sidebar.collapsed")
        .confirmationDialog(
            "Capture app screenshot?",
            isPresented: $showScreenshotCaptureConfirmation,
            titleVisibility: .visible
        ) {
            Button("Capture and Save…") {
                captureScreenshot()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Screenshots may include chat history, terminal output, and other sensitive data.")
        }
    }

    private var collapsedRail: some View {
        Button {
            isExpanded = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 13, weight: .semibold))
                Text("Agent")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 52)
            }
            .foregroundColor(Theme.textSecondary)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .background(Theme.surface1)
            .border(Theme.border, edges: [.leading])
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guiControl.sidebar.open")
    }

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            header
            statusStrip
            messageList
            quickActions
            composer
        }
        .frame(width: 360)
        .background(Theme.surface1)
        .border(Theme.border, edges: [.leading])
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Smithers Operator")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Route: \(destination.label)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                isExpanded = false
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("guiControl.sidebar.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Theme.surface2)
        .border(Theme.border, edges: [.bottom])
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            statusPill("CLI", active: smithers.cliAvailable)
                .accessibilityIdentifier("guiControl.status.cli")
            statusPill("Server", active: smithers.isConnected)
                .accessibilityIdentifier("guiControl.status.server")
            statusPill("\(store.terminalTabs.count) terminals", active: !store.terminalTabs.isEmpty)
                .accessibilityIdentifier("guiControl.status.terminals")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .border(Theme.border, edges: [.bottom])
    }

    private func statusPill(_ text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Theme.success : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.inputBg)
        .cornerRadius(6)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    messageBubble(message)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.base.opacity(0.55))
        .accessibilityIdentifier("guiControl.messages")
    }

    private func messageBubble(_ message: GUIControlSidebarMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label(for: message.role))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color(for: message.role))
                Text(Self.timeString(for: message.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
            }

            Text(message.text)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill(for: message.role))
        .cornerRadius(8)
    }

    private func label(for role: GUIControlSidebarMessage.Role) -> String {
        switch role {
        case .user: return "USER"
        case .agent: return "AGENT"
        case .system: return "SYSTEM"
        }
    }

    private func color(for role: GUIControlSidebarMessage.Role) -> Color {
        switch role {
        case .user: return Theme.accent
        case .agent: return Theme.success
        case .system: return Theme.warning
        }
    }

    private func fill(for role: GUIControlSidebarMessage.Role) -> Color {
        switch role {
        case .user: return Theme.bubbleUser
        case .agent: return Theme.bubbleAssistant
        case .system: return Theme.bubbleStatus
        }
    }

    private var quickActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                quickAction("Snapshot", identifier: "guiControl.action.snapshot") {
                    append(.agent, buildSnapshot())
                }
                quickAction("Screenshot", identifier: "guiControl.action.screenshot") {
                    showScreenshotCaptureConfirmation = true
                }
            }

            HStack(spacing: 8) {
                quickAction("Terminal", identifier: "guiControl.action.terminal") {
                    captureFocusedTerminal()
                }
                quickAction("Smithers TUI", identifier: "guiControl.action.smithersTUI") {
                    openCommand("smithers tui", title: "Smithers TUI")
                }
            }

            HStack(spacing: 8) {
                quickAction("Codex", identifier: "guiControl.action.codex") {
                    openCommand("codex", title: "Codex")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .border(Theme.border, edges: [.top, .bottom])
    }

    private func quickAction(_ title: String, identifier: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? "guiControl.action.\(title)")
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Give the operator a goal", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .onSubmit(sendComposerMessage)
                .accessibilityIdentifier("guiControl.input")

            Button {
                sendComposerMessage()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("guiControl.send")
        }
        .padding(12)
    }

    private func sendComposerMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        append(.user, text)

        let sessionID = store.ensureActiveSession()
        store.selectSession(sessionID)
        store.sendMessage(text)
        append(
            .system,
            "Forwarded to chat session \(String(sessionID.prefix(8))). Open Chat to monitor execution."
        )
    }

    private func buildSnapshot() -> String {
        var lines: [String] = []
        lines.append("Route: \(destination.label)")
        lines.append("Smithers CLI: \(smithers.cliAvailable ? "available" : "missing")")
        lines.append("Smithers server: \(smithers.isConnected ? "connected" : "offline")")

        if let session = store.activeSession {
            lines.append("Active chat: \(session.title)")
            lines.append("Chat messages: \(session.agent.messages.count)")
        } else {
            lines.append("Active chat: none")
        }

        lines.append("Chats: \(store.sessions.filter { !$0.isArchived }.count)")
        lines.append("Runs: \(store.runTabs.count)")
        lines.append("Terminals: \(store.terminalTabs.count)")

        for tab in store.terminalTabs.prefix(4) {
            let cwd = tab.workingDirectory ?? "-"
            let command = tab.command ?? "shell"
            lines.append("Terminal \(tab.title): \(command) @ \(cwd)")
        }

        if case .terminal(let terminalId) = destination,
           let workspace = store.terminalWorkspaceIfAvailable(terminalId) {
            lines.append("Workspace surfaces: \(workspace.orderedSurfaces.count)")
            for surface in workspace.orderedSurfaces.prefix(6) {
                switch surface.kind {
                case .terminal:
                    lines.append("Surface \(surface.id): terminal \(surface.title)")
                case .browser:
                    lines.append("Surface \(surface.id): browser \(surface.title) \(surface.browserURLString ?? "")")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func captureFocusedTerminal() {
        guard case .terminal(let terminalId) = destination else {
            append(.system, "Open a terminal workspace first.")
            return
        }
        guard let workspace = store.terminalWorkspaceIfAvailable(terminalId) else {
            append(.system, "Terminal workspace is not ready yet.")
            return
        }
        let focused = workspace.focusedSurfaceId.flatMap { workspace.surfaces[$0] }
        let terminalSurface = focused?.kind == .terminal
            ? focused
            : workspace.orderedSurfaces.first { $0.kind == .terminal }
        guard let surface = terminalSurface,
              let socketName = surface.tmuxSocketName,
              let sessionName = surface.tmuxSessionName
        else {
            append(.system, "No tmux-backed terminal surface is available.")
            return
        }

        do {
            let captured = try TmuxController.capturePane(socketName: socketName, sessionName: sessionName, lines: 120)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            append(.agent, captured.isEmpty ? "Focused terminal is empty." : captured)
        } catch {
            append(.system, "Terminal capture failed: \(error.localizedDescription)")
        }
    }

    private func captureScreenshot() {
        #if os(macOS)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView
        else {
            append(.system, "No visible app window is available for screenshot capture.")
            return
        }

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            append(.system, "Could not allocate screenshot buffer.")
            return
        }

        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            append(.system, "Could not encode screenshot PNG.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultScreenshotFileName()
        panel.title = "Save Smithers GUI screenshot"
        panel.message = "Review screenshot contents before sharing."

        guard panel.runModal() == .OK, let url = panel.url else {
            append(.system, "Screenshot capture canceled.")
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            append(.agent, "Screenshot saved:\n\(url.path)")
        } catch {
            append(.system, "Screenshot save failed: \(error.localizedDescription)")
        }
        #else
        append(.system, "Screenshot capture is only available on macOS.")
        #endif
    }

    private func defaultScreenshotFileName() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "smithers-gui-screenshot-\(timestamp)-\(suffix).png"
    }

    private func openCommand(_ command: String, title: String) {
        let cwd = store.activeAgent?.workingDirectory
            ?? store.terminalTabs.first?.workingDirectory
            ?? smithers.workingDirectory
        onNavigate(.terminalCommand(binary: command, workingDirectory: cwd, name: title))
        append(.system, "Opened \(title) in a terminal.")
    }

    private func append(_ role: GUIControlSidebarMessage.Role, _ text: String) {
        messages.append(GUIControlSidebarMessage(role: role, text: text, timestamp: Date()))
    }

    private static func timeString(for date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
