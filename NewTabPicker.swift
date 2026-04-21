import SwiftUI

#if os(macOS)
import AppKit
#endif

enum ChatTargetKind: String {
    case externalAgent
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

func chatTargetStatusLabel(_ status: String) -> String {
    switch status {
    case "likely-subscription": return "Signed in"
    case "api-key": return "API key"
    case "binary-only": return "Binary only"
    default: return "Available"
    }
}

enum NewTabSelection: Equatable {
    case terminal
    case browser
    case externalAgent(ChatTargetOption)

    static func == (lhs: NewTabSelection, rhs: NewTabSelection) -> Bool {
        switch (lhs, rhs) {
        case (.terminal, .terminal),
             (.browser, .browser):
            return true
        case (.externalAgent(let a), .externalAgent(let b)):
            return a.id == b.id
        default:
            return false
        }
    }
}

private struct NewTabOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let iconTint: Color
    let selection: NewTabSelection
    let isEnabled: Bool
    let searchTokens: [String]
}

struct NewTabPicker: View {
    @ObservedObject var smithers: SmithersClient
    let onSelect: (NewTabSelection) -> Void
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex = 0
    @State private var agents: [SmithersAgent] = []
    @State private var isLoadingAgents = false
    @FocusState private var isInputFocused: Bool

    private var allOptions: [NewTabOption] {
        var options: [NewTabOption] = [
            NewTabOption(
                id: "tab.terminal",
                title: "New Terminal",
                subtitle: "Open a new shell in this workspace",
                icon: "terminal.fill",
                iconTint: Theme.textSecondary,
                selection: .terminal,
                isEnabled: true,
                searchTokens: ["terminal", "shell", "new", "tab", "command"]
            ),
            NewTabOption(
                id: "tab.browser",
                title: "New Browser",
                subtitle: "Open a web browser in a new tab",
                icon: "safari",
                iconTint: Theme.textSecondary,
                selection: .browser,
                isEnabled: true,
                searchTokens: ["browser", "web", "safari", "new", "tab", "url"]
            ),
        ]

        for agent in agents where agent.usable {
            let binary = agent.binaryPath.isEmpty ? agent.command : agent.binaryPath
            let target = ChatTargetOption(
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
            options.append(
                NewTabOption(
                    id: "agent.\(agent.id)",
                    title: agent.name,
                    subtitle: agentSubtitle(status: agent.status, roles: agent.roles),
                    icon: agentIconName(agent.name),
                    iconTint: Theme.textSecondary,
                    selection: .externalAgent(target),
                    isEnabled: true,
                    searchTokens: [agent.name, agent.id] + agent.roles
                )
            )
        }

        return options
    }

    private var filteredOptions: [NewTabOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return allOptions }
        return allOptions.filter { option in
            if option.title.lowercased().contains(trimmed) { return true }
            if option.subtitle.lowercased().contains(trimmed) { return true }
            for token in option.searchTokens {
                if token.lowercased().contains(trimmed) { return true }
            }
            return false
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                header
                Divider().background(Theme.border)
                resultList
            }
            .frame(minWidth: 560, maxWidth: 720)
            .background(Theme.surface1)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 120)
            .padding(.horizontal, 24)
        }
        .task {
            await loadAgents()
            DispatchQueue.main.async { isInputFocused = true }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            let options = filteredOptions
            guard !options.isEmpty else { return .ignored }
            selectedIndex = min(selectedIndex + 1, options.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            let options = filteredOptions
            guard !options.isEmpty else { return .ignored }
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            activateSelection()
            return .handled
        }
        .accessibilityIdentifier("newTabPicker.root")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textTertiary)

            TextField("Search or open a new tab…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .focused($isInputFocused)
                .accessibilityIdentifier("newTabPicker.input")

            if isLoadingAgents {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }

            Text("Esc")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.inputBg)
                .cornerRadius(4)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.surface2)
    }

    @ViewBuilder
    private var resultList: some View {
        let options = filteredOptions
        if options.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.textTertiary)
                Text("No matches")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Theme.surface1)
            .accessibilityIdentifier("newTabPicker.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        NewTabPickerRow(
                            option: option,
                            isSelected: index == selectedIndex,
                            onTap: { activate(option) },
                            onHover: { selectedIndex = index }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
            .background(Theme.surface1)
        }
    }

    private func activateSelection() {
        let options = filteredOptions
        guard options.indices.contains(selectedIndex) else { return }
        activate(options[selectedIndex])
    }

    private func activate(_ option: NewTabOption) {
        guard option.isEnabled else { return }
        onSelect(option.selection)
    }

    private func loadAgents() async {
        isLoadingAgents = true
        defer { isLoadingAgents = false }
        do {
            agents = try await smithers.listAgents()
        } catch {
            agents = []
        }
    }

    private func agentIconName(_ name: String) -> String {
        switch name.lowercased() {
        case "claude code": return "chevron.left.forwardslash.chevron.right"
        case "codex": return "cpu"
        case "gemini": return "sparkles"
        case "opencode": return "curlybraces"
        case "amp": return "bolt.fill"
        case "forge": return "hammer.fill"
        case "kimi": return "globe.asia.australia.fill"
        case "aider": return "wrench.and.screwdriver.fill"
        default: return "terminal.fill"
        }
    }

    private func agentSubtitle(status: String, roles: [String]) -> String {
        var parts = [chatTargetStatusLabel(status)]
        if !roles.isEmpty {
            parts.append(roles.map { $0.capitalized }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

private struct NewTabPickerRow: View {
    let option: NewTabOption
    let isSelected: Bool
    let onTap: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(option.iconTint.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: option.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(option.iconTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(option.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.accent : .clear)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            if hovering { onHover() }
        }
        .accessibilityIdentifier("newTabPicker.item.\(option.id)")
    }
}
