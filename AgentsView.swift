import SwiftUI

struct AgentsView: View {
    @ObservedObject var smithers: SmithersClient

    @State private var agents: [SmithersAgent] = []
    @State private var isLoading = true
    @State private var error: String?

    private var availableAgents: [SmithersAgent] {
        agents.filter(\.usable)
    }

    private var unavailableAgents: [SmithersAgent] {
        agents.filter { !$0.usable }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading {
                loadingView
            } else if let error {
                errorView(error)
            } else if agents.isEmpty {
                emptyView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !availableAgents.isEmpty {
                            section(title: "Available (\(availableAgents.count))", agents: availableAgents, faded: false)
                        }

                        if !unavailableAgents.isEmpty {
                            section(title: "Not Detected (\(unavailableAgents.count))", agents: unavailableAgents, faded: true)
                        }
                    }
                    .padding(20)
                }
                .refreshable { await loadAgents() }
            }
        }
        .background(Theme.surface1)
        .task { await loadAgents() }
    }

    private var header: some View {
        HStack {
            Text("Agents")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadAgents() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private func section(title: String, agents: [SmithersAgent], faded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textTertiary)

            ForEach(agents) { agent in
                agentCard(agent, faded: faded)
            }
        }
    }

    private func agentCard(_ agent: SmithersAgent, faded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(statusIcon(agent.status))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(statusColor(agent.status))

                Text(agent.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(faded ? Theme.textSecondary : Theme.textPrimary)

                Spacer()

                statusTag("Availability", value: agent.usable ? "Detected" : "Not Detected")
                statusTag("Usable", value: agent.usable ? "Yes" : "No")
            }

            infoRow("Status", value: agent.status)
            infoRow("Roles", value: formattedRoles(agent.roles))
            infoRow("Command", value: agent.command, monospaced: true)
            infoRow("Binary", value: agent.binaryPath.isEmpty ? "-" : agent.binaryPath, monospaced: true)
            infoRow("Auth", value: yesNo(agent.hasAuth))
            infoRow("API Key", value: yesNo(agent.hasAPIKey))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2.opacity(faded ? 0.7 : 1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func infoRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func statusTag(_ label: String, value: String) -> some View {
        Text("\(label): \(value)")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .themedPill(cornerRadius: 5)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading agents...")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.system(size: 24))
                .foregroundColor(Theme.textTertiary)
            Text("No agents found.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await loadAgents() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadAgents() async {
        isLoading = true
        error = nil
        do {
            agents = try await smithers.listAgents()
        } catch {
            self.error = error.localizedDescription
            agents = []
        }
        isLoading = false
    }

    private func formattedRoles(_ roles: [String]) -> String {
        guard !roles.isEmpty else { return "-" }
        return roles.map(capitalizeRole).joined(separator: ", ")
    }

    private func capitalizeRole(_ role: String) -> String {
        guard let first = role.first else { return role }
        return first.uppercased() + role.dropFirst()
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "likely-subscription", "api-key":
            return "●"
        case "binary-only":
            return "◐"
        default:
            return "○"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "likely-subscription":
            return Theme.success
        case "api-key":
            return Theme.warning
        case "binary-only":
            return Theme.textTertiary
        default:
            return Theme.textSecondary
        }
    }
}
