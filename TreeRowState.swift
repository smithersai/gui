import SwiftUI

enum TaskExecutionState: String, CaseIterable, Sendable {
    case pending
    case running
    case finished
    case failed
    case blocked
    case waitingApproval
    case cancelled
    case unknown

    var color: Color {
        switch self {
        case .pending: return Theme.textTertiary
        case .running: return Theme.accent
        case .finished: return Theme.textPrimary
        case .failed: return Theme.danger
        case .blocked, .waitingApproval: return Theme.warning
        case .cancelled: return Theme.textTertiary
        case .unknown: return Theme.textTertiary
        }
    }

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .blocked: return "pause.circle.fill"
        case .waitingApproval: return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .waitingApproval: return "Waiting Approval"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    var isFailed: Bool { self == .failed }
    var isStrikethrough: Bool { self == .cancelled }
    var shouldPulse: Bool { self == .running }

    var rowBackground: Color {
        switch self {
        case .failed: return Theme.danger.opacity(0.08)
        default: return Color.clear
        }
    }

    var tagForeground: Color {
        switch self {
        case .pending, .cancelled: return Theme.textTertiary
        case .running: return Theme.accent
        case .finished: return Theme.textPrimary
        case .failed: return Theme.danger
        case .blocked, .waitingApproval: return Theme.warning
        case .unknown: return Theme.textTertiary
        }
    }
}

func extractState(from node: DevToolsNode) -> TaskExecutionState {
    if let stateValue = node.props["state"] {
        switch stateValue {
        case .string(let s):
            return TaskExecutionState(rawValue: s) ?? .unknown
        default:
            break
        }
    }
    return .unknown
}

func keyPropsSummary(for node: DevToolsNode, maxLength: Int = 120) -> String {
    var parts: [String] = []

    if let task = node.task {
        if let label = task.label { parts.append(label) }
        if let agent = task.agent { parts.append("agent=\(agent)") }
        if let iteration = task.iteration, iteration > 0 { parts.append("iter=\(iteration)") }
    }

    if let name = node.props["name"] {
        if case .string(let s) = name, !s.isEmpty {
            parts.insert("name=\"\(s)\"", at: 0)
        }
    }

    if let id = node.props["id"] {
        if case .string(let s) = id, !s.isEmpty {
            parts.insert("id=\"\(s)\"", at: 0)
        }
    }

    let joined = parts.joined(separator: " ")
    if joined.count > maxLength {
        return String(joined.prefix(maxLength - 1)) + "…"
    }
    return joined
}

func elapsedText(from node: DevToolsNode) -> String? {
    if let startMs = node.props["startedAtMs"], case .number(let start) = startMs {
        if let endMs = node.props["finishedAtMs"], case .number(let end) = endMs {
            return formatDuration(ms: end - start)
        }
        let elapsed = Date().timeIntervalSince1970 * 1000 - start
        if elapsed > 0 {
            return formatDuration(ms: elapsed)
        }
    }
    return nil
}

private func formatDuration(ms: Double) -> String {
    let totalSeconds = Int(ms / 1000)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if minutes > 0 {
        return String(format: "%d:%02d", minutes, seconds)
    }
    return "\(seconds)s"
}
