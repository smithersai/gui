import SwiftUI

struct HeartbeatIndicator: View {
    let lastEventAt: Date?
    let heartbeatMs: Int
    let lastSeq: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var enginePulse = false

    var body: some View {
        HStack(spacing: 4) {
            engineDot
            UIHeartbeatDot()
        }
        .onChange(of: lastEventAt) { _, _ in
            guard !reduceMotion else { return }
            enginePulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                enginePulse = false
            }
        }
    }

    private var engineDot: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = HeartbeatState.color(
                now: context.date,
                lastEventAt: lastEventAt,
                heartbeatMs: heartbeatMs
            )
            Circle()
                .fill(state.swiftUIColor)
                .frame(width: 8, height: 8)
                .scaleEffect(enginePulse ? 1.4 : 1.0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: enginePulse)
                .accessibilityLabel(engineAccessibilityLabel(state))
                .accessibilityRemoveTraits(.isImage)
                .help(engineTooltip)
        }
    }

    private var engineTooltip: String {
        var parts: [String] = []
        if let lastEventAt {
            let formatter = ISO8601DateFormatter()
            parts.append("Last: \(formatter.string(from: lastEventAt))")
        } else {
            parts.append("Last: none")
        }
        parts.append("Interval: \(heartbeatMs)ms")
        parts.append("Seq: \(lastSeq)")
        return parts.joined(separator: "\n")
    }

    private func engineAccessibilityLabel(_ color: HeartbeatColor) -> String {
        let stateWord: String
        switch color {
        case .green: stateWord = "healthy"
        case .amber: stateWord = "stale"
        case .red: stateWord = "unresponsive"
        }
        if let lastEventAt {
            let ago = max(0, Int(Date().timeIntervalSince(lastEventAt)))
            return "Engine heartbeat \u{2014} last event \(ago) seconds ago, \(stateWord)."
        }
        return "Engine heartbeat \u{2014} no events received, \(stateWord)."
    }
}

extension HeartbeatColor {
    var swiftUIColor: Color {
        switch self {
        case .green: return Theme.success
        case .amber: return Theme.warning
        case .red: return Theme.danger
        }
    }
}

struct UIHeartbeatDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = Int(context.date.timeIntervalSince1970) % 2 == 0
            Circle()
                .fill(Theme.success.opacity(0.7))
                .frame(width: 6, height: 6)
                .scaleEffect(phase && !reduceMotion ? 1.3 : 1.0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: phase)
                .accessibilityLabel("UI heartbeat \u{2014} responding")
                .accessibilityRemoveTraits(.isImage)
                .help("UI heartbeat \u{2014} SwiftUI main thread responsive")
        }
    }
}
