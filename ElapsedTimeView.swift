import SwiftUI

enum ElapsedTimeFormatter {
    static func format(seconds: Int) -> String {
        if seconds < 0 {
            AppLogger.ui.warning("ElapsedTimeFormatter: negative elapsed time", metadata: [
                "seconds": String(seconds),
            ])
            return "00:00"
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

struct ElapsedTimeView: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(ElapsedTimeFormatter.format(seconds: seconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Elapsed time: \(ElapsedTimeFormatter.format(seconds: seconds))")
        }
    }
}
