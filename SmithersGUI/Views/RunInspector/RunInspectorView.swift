import SwiftUI

struct RunInspectorView: View {
    @ObservedObject var smithers: SmithersClient
    let runId: String
    let nodeId: String?
    var onOpenTerminalCommand: ((String, String, String) -> Void)? = nil
    var onOpenWorkflow: ((String) -> Void)? = nil
    var onOpenPrompt: (() -> Void)? = nil
    var onRunSummaryRefreshed: ((RunSummary) -> Void)? = nil
    var onOpenAuditHistory: ((String) -> Void)? = nil
    var onClose: () -> Void = {}

    var body: some View {
        LiveRunView(
            smithers: smithers,
            runId: runId,
            nodeId: nodeId,
            onOpenTerminalCommand: onOpenTerminalCommand,
            onOpenWorkflow: onOpenWorkflow,
            onOpenPrompt: onOpenPrompt,
            onRunSummaryRefreshed: onRunSummaryRefreshed,
            onOpenAuditHistory: onOpenAuditHistory,
            onClose: onClose
        )
    }
}
