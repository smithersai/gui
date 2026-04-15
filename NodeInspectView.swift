import SwiftUI

struct NodeInspectView: View {
    let runId: String
    let task: RunTask
    var onOpenLiveChat: ((String, String?) -> Void)? = nil
    var onOpenSnapshots: ((String?) -> Void)? = nil
    var onClose: () -> Void = {}

    private var label: String {
        task.label ?? task.nodeId
    }

    private var shortRunID: String {
        String(runId.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyContent
        }
        .background(Theme.surface1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("view.nodeinspect")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Node Inspector")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("\(shortRunID) · \(label)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            button("Chat", icon: "message", color: Theme.accent) {
                onClose()
                DispatchQueue.main.async {
                    onOpenLiveChat?(runId, task.nodeId)
                }
            }
            .accessibilityIdentifier("nodeinspect.action.chat")

            button("Snapshots", icon: "clock.arrow.circlepath", color: Theme.info) {
                onClose()
                DispatchQueue.main.async {
                    onOpenSnapshots?(task.nodeId)
                }
            }
            .accessibilityIdentifier("nodeinspect.action.snapshots")

            button("Close", icon: "xmark", color: Theme.textSecondary, action: onClose)
                .accessibilityIdentifier("nodeinspect.action.close")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .border(Theme.border, edges: [.bottom])
    }

    private var bodyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nodeCard
                stateCard
                timingCard
                runCard
            }
            .padding(16)
        }
    }

    private var nodeCard: some View {
        card(title: "Node") {
            detailRow("Label", label)
            detailRow("ID", task.nodeId)
        }
    }

    private var stateCard: some View {
        card(title: "State") {
            HStack(spacing: 8) {
                Image(systemName: runInspectorTaskStateIcon(task.state))
                    .font(.system(size: 12))
                    .foregroundColor(runInspectorTaskStateColor(task.state))
                Text(runInspectorTaskStateLabel(task.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(runInspectorTaskStateColor(task.state))
                Spacer()
            }
        }
    }

    private var timingCard: some View {
        card(title: "Execution") {
            detailRow("Iteration", task.iteration.map(String.init) ?? "-")
            detailRow("Attempt", task.lastAttempt.map { "#\($0)" } ?? "-")

            if let updatedAtMs = task.updatedAtMs {
                detailRow("Updated", runInspectorShortDate(updatedAtMs))
                detailRow("Relative", runInspectorRelativeDate(updatedAtMs))
            } else {
                detailRow("Updated", "-")
            }
        }
    }

    private var runCard: some View {
        card(title: "Run") {
            detailRow("Run ID", runId)
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textSecondary)

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
    }

    private func button(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(color.opacity(0.14))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
