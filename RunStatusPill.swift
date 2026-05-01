import AppKit
import SwiftUI

extension RunStatus {
    var statusColor: Color {
        switch self {
        case .running: return Theme.accent
        case .finished: return Theme.success
        case .waitingApproval, .waitingEvent, .waitingTimer: return Theme.warning
        case .failed: return Theme.danger
        case .stale, .orphaned: return Theme.warning
        case .cancelled: return Theme.textTertiary
        case .unknown: return Theme.textSecondary
        }
    }
}

struct RunStatusPill: View {
    let status: RunStatus
    let runId: String
    var onCancel: (() -> Void)?
    var onHijack: (() -> Void)?
    var onOpenLogs: (() -> Void)?

    var body: some View {
        Menu {
            Button("Cancel Run") { onCancel?() }
            Button("Hijack") { onHijack?() }
            Button("Copy Run ID") { Self.copyRunId(runId) }
            Button("Open Logs") { onOpenLogs?() }
        } label: {
            Text(status.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(status.statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(status.statusColor.opacity(0.15))
                .cornerRadius(Theme.Metrics.pillCornerRadius)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Run status: \(status.label)")
        .accessibilityHint("Click for run actions")
    }

    static func copyRunId(_ runId: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(runId, forType: .string)
    }
}
