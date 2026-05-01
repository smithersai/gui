import Foundation
import os

enum HeartbeatColor: String, Sendable, Equatable {
    case green
    case amber
    case red
}

enum HeartbeatState {
    /// Pure function: (now, lastEventAt, heartbeatMs) -> HeartbeatColor
    /// Boundaries: <= 2x green, < 5x amber, >= 5x red
    static func color(now: Date, lastEventAt: Date?, heartbeatMs: Int) -> HeartbeatColor {
        guard heartbeatMs > 0 else {
            AppLogger.ui.warning("HeartbeatState: degenerate heartbeatMs", metadata: [
                "heartbeatMs": String(heartbeatMs),
            ])
            return .red
        }

        guard let lastEventAt else {
            return .red
        }

        let elapsedSeconds = now.timeIntervalSince(lastEventAt)

        if elapsedSeconds < 0 {
            AppLogger.ui.warning("HeartbeatState: clock skew detected", metadata: [
                "elapsed_ms": String(Int(elapsedSeconds * 1000)),
            ])
            return .green
        }

        let interval = TimeInterval(heartbeatMs) / 1000.0
        let greenThreshold = interval * 2
        let amberThreshold = interval * 5

        if elapsedSeconds <= greenThreshold {
            return .green
        } else if elapsedSeconds < amberThreshold {
            return .amber
        } else {
            return .red
        }
    }
}
