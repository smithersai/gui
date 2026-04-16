import SwiftUI

struct LiveRunHeaderView: View {
    let status: RunStatus
    let workflowName: String
    let runId: String
    let startedAt: Date?
    let heartbeatMs: Int
    let lastEventAt: Date?
    let lastSeq: Int

    var onCancel: (() -> Void)?
    var onHijack: (() -> Void)?
    var onOpenLogs: (() -> Void)?
    var onRefresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            RunStatusPill(
                status: status,
                runId: runId,
                onCancel: onCancel,
                onHijack: onHijack,
                onOpenLogs: onOpenLogs
            )

            HStack(spacing: 4) {
                Text(workflowName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(runId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .onTapGesture {
                        RunStatusPill.copyRunId(runId)
                    }
                    .help("Click to copy run ID")
            }

            Spacer()

            if let startedAt {
                ElapsedTimeView(startedAt: startedAt)
            } else {
                Text("--:--")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            HeartbeatIndicator(
                lastEventAt: lastEventAt,
                heartbeatMs: heartbeatMs,
                lastSeq: lastSeq
            )

            overflowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live run header")
    }

    private var overflowMenu: some View {
        Menu {
            Button("Refresh") { onRefresh?() }
            if onHijack != nil {
                Button("Hijack") { onHijack?() }
            }
            if onOpenLogs != nil {
                Button("Open Logs") { onOpenLogs?() }
            }
            Divider()
            if onCancel != nil {
                Button("Cancel Run", role: .destructive) { onCancel?() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
        .accessibilityLabel("More actions")
    }
}
