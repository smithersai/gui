import SwiftUI

struct NodeErrorBanner: View {
    let node: DevToolsNode
    let runSupportsRetry: Bool
    let onRetry: (String) -> Void

    @State private var isStackExpanded = false

    private var nodeState: String? {
        if case .string(let s) = node.props["state"] { return s }
        return nil
    }

    private var errorSummary: String? {
        if case .string(let s) = node.props["error"] { return s }
        return nil
    }

    private var errorStack: String? {
        if case .string(let s) = node.props["errorStack"] { return s }
        return nil
    }

    private var nodeId: String? {
        node.task?.nodeId
    }

    var body: some View {
        if nodeState == "failed" {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.danger)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Task Failed")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.danger)

                        if let summary = errorSummary {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(3)
                        }
                    }

                    Spacer()

                    if let nodeId {
                        Button("Retry") {
                            onRetry(nodeId)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(runSupportsRetry ? .white : Theme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(runSupportsRetry ? Theme.danger : Theme.danger.opacity(0.3))
                        .cornerRadius(4)
                        .buttonStyle(.plain)
                        .disabled(!runSupportsRetry)
                        .accessibilityIdentifier("inspector.error.retry")
                        .accessibilityLabel(runSupportsRetry ? "Retry failed task" : "Retry unavailable")
                    }
                }

                if let stack = errorStack {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isStackExpanded.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: isStackExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8))
                            Text(isStackExpanded ? "Hide Stack" : "Show Stack")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inspector.error.toggleStack")

                    if isStackExpanded {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(stack)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                        .padding(6)
                        .background(Theme.danger.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
            }
            .padding(12)
            .background(Theme.danger.opacity(0.10))
            .overlay(
                Rectangle()
                    .fill(Theme.danger.opacity(0.4))
                    .frame(height: 1),
                alignment: .bottom
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("inspector.error.banner")
        }
    }
}
