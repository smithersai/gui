import Foundation
import SwiftUI

struct OutputRequestContext: Equatable {
    let runId: String
    let nodeId: String
    let iteration: Int?
}

@MainActor
final class OutputTabController: ObservableObject {
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var response: NodeOutputResponse?
    @Published private(set) var error: DevToolsClientError?
    @Published var selectedIteration: Int?

    private(set) var context: OutputRequestContext?
    private(set) var lastObservedRuntimeState: String?

    private let outputProvider: NodeOutputProvider
    private var fetchTask: Task<Void, Never>?

    init(outputProvider: NodeOutputProvider) {
        self.outputProvider = outputProvider
    }

    deinit {
        fetchTask?.cancel()
    }

    func activate(context: OutputRequestContext?, runtimeState: String?) {
        if self.context == context {
            return
        }

        cancelInFlight()
        self.context = context
        self.lastObservedRuntimeState = runtimeState
        self.response = nil
        self.error = nil
        self.selectedIteration = context?.iteration

        guard context != nil else {
            return
        }

        fetch(reason: "mount")
    }

    func observeRuntimeState(_ runtimeState: String?) {
        let previousState = lastObservedRuntimeState
        lastObservedRuntimeState = runtimeState

        guard response?.status == .pending else {
            return
        }
        guard previousState != runtimeState else {
            return
        }

        guard let runtimeState else {
            return
        }
        if runtimeState == "finished" || runtimeState == "failed" {
            fetch(reason: "state_transition")
        }
    }

    func retry() {
        fetch(reason: "retry")
    }

    func retry(using iteration: Int?) {
        guard let context else {
            return
        }
        self.context = OutputRequestContext(
            runId: context.runId,
            nodeId: context.nodeId,
            iteration: iteration
        )
        selectedIteration = iteration
        fetch(reason: "retry_iteration")
    }

    func cancelInFlight() {
        fetchTask?.cancel()
        fetchTask = nil
        isLoading = false
    }

    private func fetch(reason: String) {
        guard let context else {
            return
        }

        cancelInFlight()
        isLoading = true
        error = nil

        let startedAt = CFAbsoluteTimeGetCurrent()
        fetchTask = Task { [weak self] in
            guard let self else { return }

            do {
                let output = try await outputProvider.getNodeOutput(
                    runId: context.runId,
                    nodeId: context.nodeId,
                    iteration: context.iteration
                )

                guard !Task.isCancelled else { return }

                let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let rowBytes = output.row.flatMap { JSONValue.object($0).compactJSONString?.utf8.count } ?? 0
                AppLogger.network.debug("OutputTab fetch complete", metadata: [
                    "run_id": context.runId,
                    "node_id": context.nodeId,
                    "iteration": context.iteration.map(String.init) ?? "nil",
                    "status": output.status.rawValue,
                    "duration_ms": String(durationMs),
                    "row_bytes": String(rowBytes),
                    "reason": reason,
                ])

                response = output
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                let mapped = error as? DevToolsClientError ?? .unknown(String(describing: error))
                self.error = mapped
                self.isLoading = false

                AppLogger.network.debug("OutputTab fetch failed", metadata: [
                    "run_id": context.runId,
                    "node_id": context.nodeId,
                    "iteration": context.iteration.map(String.init) ?? "nil",
                    "error": mapped.displayMessage,
                    "reason": reason,
                ])
            }
        }
    }
}

struct OutputTab: View {
    @ObservedObject var store: LiveRunDevToolsStore

    @StateObject private var controller: OutputTabController

    init(store: LiveRunDevToolsStore, outputProvider: NodeOutputProvider) {
        self.store = store
        _controller = StateObject(wrappedValue: OutputTabController(outputProvider: outputProvider))
    }

    private var context: OutputRequestContext? {
        guard let runId = store.runId,
              let selectedNode = store.selectedNode,
              selectedNode.type == .task,
              let nodeId = selectedNode.task?.nodeId else {
            return nil
        }

        return OutputRequestContext(
            runId: runId,
            nodeId: nodeId,
            iteration: selectedNode.task?.iteration
        )
    }

    private var runtimeState: String? {
        guard let selectedNode = store.selectedNode,
              case .string(let state)? = selectedNode.props["state"] else {
            return nil
        }
        return state
    }

    private var suggestedIteration: Int? {
        context?.iteration
    }

    var body: some View {
        Group {
            if context == nil {
                Text("Output is available for task nodes only.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("output.unavailable")
            } else {
                tabBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
        .accessibilityIdentifier("inspector.tab.content.output")
        .onAppear {
            controller.activate(context: context, runtimeState: runtimeState)
        }
        .onChange(of: store.selectedNodeId) { _ in
            controller.activate(context: context, runtimeState: runtimeState)
        }
        .onChange(of: store.seq) { _ in
            controller.activate(context: context, runtimeState: runtimeState)
            controller.observeRuntimeState(runtimeState)
        }
        .onDisappear {
            controller.cancelInFlight()
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        if controller.isLoading && controller.response == nil {
            loadingView
        } else if let error = controller.error {
            switch error {
            case .nodeHasNoOutput:
                noOutputTableView
            case .iterationNotFound(let iteration):
                iterationNotFoundView(iteration)
            default:
                errorView(error)
            }
        } else if let response = controller.response {
            responseView(response)
                .overlay(alignment: .topTrailing) {
                    if controller.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .padding(8)
                    }
                }
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading output…")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("output.loading")
    }

    private var noOutputTableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 16))
                .foregroundColor(Theme.textTertiary)
            Text("This node has no output table.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityIdentifier("output.noOutputTable")
    }

    @ViewBuilder
    private func responseView(_ response: NodeOutputResponse) -> some View {
        switch response.status {
        case .produced:
            OutputRenderer(row: response.row ?? [:], schema: response.schema)
                .accessibilityIdentifier("output.produced")
        case .pending:
            OutputPendingView()
        case .failed:
            OutputFailedView(partial: response.partial)
        }
    }

    @ViewBuilder
    private func errorView(_ error: DevToolsClientError) -> some View {
        VStack(spacing: 8) {
            Text(error.displayMessage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.danger)
                .multilineTextAlignment(.center)

            if let hint = error.hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }

            Button("Retry") {
                controller.retry()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface2)
            .cornerRadius(6)
            .accessibilityIdentifier("output.error.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityIdentifier("output.error")
    }

    private func iterationNotFoundView(_ iteration: Int) -> some View {
        let options = iterationOptions(missingIteration: iteration)

        return VStack(spacing: 10) {
            Text(iteration >= 0 ? "Iteration \(iteration) was not found." : "Selected iteration was not found.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.warning)
                .multilineTextAlignment(.center)

            if !options.isEmpty {
                Picker("Iteration", selection: $controller.selectedIteration) {
                    ForEach(options, id: \.self) { option in
                        Text("Iteration \(option)").tag(Optional(option))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("output.iteration.selector")
            }

            if let suggestedIteration {
                Text("Latest valid iteration: \(suggestedIteration)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }

            HStack(spacing: 8) {
                Button("Retry") {
                    controller.retry(using: controller.selectedIteration)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surface2)
                .cornerRadius(6)
                .accessibilityIdentifier("output.iteration.retry")

                if let suggestedIteration {
                    Button("Use latest") {
                        controller.retry(using: suggestedIteration)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surface2)
                    .cornerRadius(6)
                    .accessibilityIdentifier("output.iteration.useLatest")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityIdentifier("output.iterationNotFound")
    }

    private func iterationOptions(missingIteration: Int) -> [Int] {
        var values: [Int] = []
        if missingIteration >= 0 {
            values.append(missingIteration)
        }
        if let current = context?.iteration, current >= 0, !values.contains(current) {
            values.append(current)
        }
        if let selected = controller.selectedIteration, selected >= 0, !values.contains(selected) {
            values.append(selected)
        }
        return values.sorted()
    }
}
