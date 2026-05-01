import Foundation

enum InspectorTab: String, CaseIterable, Hashable, Sendable {
    case output = "Output"
    case diff = "Diff"
    case logs = "Logs"
}

enum DefaultTabPicker {
    static func pickDefault(
        nodeType: SmithersNodeType,
        state: String?,
        hasOutput: Bool,
        hasDiff: Bool,
        hasLogs: Bool
    ) -> InspectorTab? {
        guard nodeType == .task else { return nil }

        let resolvedState = state ?? "pending"

        switch resolvedState {
        case "finished":
            if hasOutput { return .output }
            if hasDiff { return .diff }
            return .logs
        case "running":
            return .logs
        case "failed":
            if hasOutput { return .output }
            return .logs
        default:
            return .logs
        }
    }
}
