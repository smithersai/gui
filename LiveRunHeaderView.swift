import SwiftUI

struct LiveRunHeaderView: View {
    let status: RunStatus
    let workflowName: String
    let runId: String
    let startedAt: Date?
    let heartbeatMs: Int
    let lastEventAt: Date?
    let lastSeq: Int
    let viewersLastEventAt: Date?
    let viewersHeartbeatMs: Int?
    let runStateLabel: String?
    let runStateReason: String?
    let connectionState: DevToolsConnectionState
    let staleSince: Date?

    var onCancel: (() -> Void)?
    var onHijack: (() -> Void)?
    var onOpenLogs: (() -> Void)?
    var onResume: (() -> Void)? = nil
    var onRewind: (() -> Void)? = nil
    var onRefresh: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onOpenWorkflow: (() -> Void)?
    var smithersVersion: String?

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
                if let onOpenWorkflow {
                    Button(action: onOpenWorkflow) {
                        Text(workflowName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .underline()
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open workflow")
                    .accessibilityIdentifier("liveRun.header.openWorkflow")
                } else {
                    Text(workflowName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }

                Text(runId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .onTapGesture {
                        RunStatusPill.copyRunId(runId)
                    }
                    .help("Click to copy run ID")

                if let runStateLabel, !runStateLabel.isEmpty {
                    Text("· \(runStateLabel)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let runStateReason, !runStateReason.isEmpty {
                    Text("· \(runStateReason)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
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
                lastSeq: lastSeq,
                viewersLastEventAt: viewersLastEventAt,
                viewersHeartbeatMs: viewersHeartbeatMs
            )

            connectionIndicator

            overflowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live run header")
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch connectionState {
        case .connecting:
            if staleSince != nil {
                indicatorLabel(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Reconnecting",
                    color: Theme.warning
                )
            }
        case .error:
            if staleSince != nil {
                indicatorLabel(
                    icon: "wifi.exclamationmark",
                    text: "Connection unstable",
                    color: Theme.warning
                )
            }
        case .disconnected:
            if staleSince != nil {
                indicatorLabel(
                    icon: "wifi.slash",
                    text: "Offline",
                    color: Theme.warning
                )
            }
        case .streaming:
            EmptyView()
        }
    }

    private func indicatorLabel(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityIdentifier("liveRun.header.connectionIndicator")
    }

    private var overflowMenu: some View {
        Menu {
            Button("Refresh") { onRefresh?() }
            if onClearHistory != nil {
                Button("Clear History") { onClearHistory?() }
            }
            if onResume != nil {
                Button("Resume Run") { onResume?() }
            }
            if onRewind != nil {
                Button("Rewind") { onRewind?() }
            }
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
            if let smithersVersion {
                Divider()
                Text("Smithers \(smithersVersion)")
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
