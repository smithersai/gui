import SwiftUI

struct NodeInspectorHeader: View {
    let node: DevToolsNode

    private var nodeState: String {
        if case .string(let s) = node.props["state"] { return s }
        return "pending"
    }

    private var iteration: Int? {
        node.task?.iteration
    }

    private var timing: String? {
        if case .string(let s) = node.props["timing"] { return s }
        if case .number(let n) = node.props["durationMs"] {
            return formatDuration(n)
        }
        return nil
    }

    private var nodeId: String {
        node.task?.nodeId ?? "node:\(node.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("<\(node.name)>")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(node.name)

                stateBadge

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(nodeId, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Text(nodeId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy node ID \(nodeId)")
                .accessibilityIdentifier("inspector.header.copyNodeId")

                if let iteration {
                    Text("iteration \(iteration)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }

                if let timing {
                    Text(timing)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface1)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.header")
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: runInspectorTaskStateIcon(nodeState))
                .font(.system(size: 10))
            Text(runInspectorTaskStateLabel(nodeState))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(runInspectorTaskStateColor(nodeState))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(runInspectorTaskStateColor(nodeState).opacity(0.12))
        .cornerRadius(4)
        .accessibilityLabel("State: \(runInspectorTaskStateLabel(nodeState))")
        .accessibilityIdentifier("inspector.header.state")
    }

    private func formatDuration(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
