import SwiftUI
import os

protocol NodeDiffFetching: Sendable {
    func getNodeDiff(runId: String, nodeId: String, iteration: Int) async throws -> NodeDiffBundle
}

extension SmithersClient: @preconcurrency NodeDiffFetching {}

final class EmptyNodeDiffFetcher: NodeDiffFetching, @unchecked Sendable {
    static let shared = EmptyNodeDiffFetcher()

    func getNodeDiff(runId: String, nodeId: String, iteration: Int) async throws -> NodeDiffBundle {
        NodeDiffBundle(seq: 0, baseRef: "", patches: [])
    }
}

struct DiffTabRequest: Equatable, Sendable {
    let runId: String
    let nodeId: String
    let iteration: Int

    var cacheKey: String {
        "\(runId)|\(nodeId)|\(iteration)"
    }
}

@MainActor
final class DiffTabModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: DevToolsClientError?
    @Published private(set) var files: [UnifiedDiffFile] = []
    @Published private(set) var showLargeDiffWarning = false
    @Published private(set) var expandedFileIDs: Set<String> = []
    @Published private(set) var totalBytes: Int = 0

    private var loadTask: Task<Void, Never>?
    private var activeRequestToken = UUID()
    private(set) var lastRequest: DiffTabRequest?

    private let client: any NodeDiffFetching

    init(client: any NodeDiffFetching = EmptyNodeDiffFetcher.shared) {
        self.client = client
    }

    func load(_ request: DiffTabRequest) {
        lastRequest = request
        cancel()

        isLoading = true
        lastError = nil

        let token = UUID()
        activeRequestToken = token

        let signpostState = AppLogger.performance.beginInterval("diffTabLoad")
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let bundle = try await client.getNodeDiff(
                    runId: request.runId,
                    nodeId: request.nodeId,
                    iteration: request.iteration
                )
                try Task.checkCancellation()
                guard await MainActor.run(body: { self.activeRequestToken == token }) else { return }

                await MainActor.run {
                    self.apply(bundle: bundle, request: request)
                    self.isLoading = false
                    AppLogger.performance.endInterval("diffTabLoad", signpostState)
                    AppLogger.network.debug("Node diff loaded", metadata: [
                        "run_id": request.runId,
                        "node_id": request.nodeId,
                        "iteration": String(request.iteration),
                        "duration_ms": String(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)),
                        "bytes": String(self.totalBytes),
                        "file_count": String(self.files.count),
                    ])
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.activeRequestToken == token {
                        self.isLoading = false
                    }
                    AppLogger.performance.endInterval("diffTabLoad", signpostState)
                }
            } catch {
                let mapped: DevToolsClientError
                if let devError = error as? DevToolsClientError {
                    mapped = devError
                } else if let urlError = error as? URLError {
                    mapped = .from(urlError: urlError)
                } else if let localized = (error as? LocalizedError)?.errorDescription,
                          let parsed = DevToolsClientError.from(libsmithersMessage: localized) {
                    mapped = parsed
                } else {
                    mapped = .unknown(String(describing: error))
                }

                await MainActor.run {
                    guard self.activeRequestToken == token else { return }
                    self.lastError = mapped
                    self.files = []
                    self.expandedFileIDs = []
                    self.totalBytes = 0
                    self.showLargeDiffWarning = false
                    self.isLoading = false
                    AppLogger.performance.endInterval("diffTabLoad", signpostState)
                    if case .diffTooLarge = mapped {
                        AppLogger.network.warning("Node diff too large", metadata: [
                            "run_id": request.runId,
                            "node_id": request.nodeId,
                            "iteration": String(request.iteration),
                        ])
                    }
                }
            }
        }
    }

    func retry() {
        guard let lastRequest else { return }
        load(lastRequest)
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    func setFileExpanded(_ fileID: String, expanded: Bool) {
        if expanded {
            expandedFileIDs.insert(fileID)
        } else {
            expandedFileIDs.remove(fileID)
        }
    }

    func isFileExpanded(_ fileID: String) -> Bool {
        expandedFileIDs.contains(fileID)
    }

    private func apply(bundle: NodeDiffBundle, request: DiffTabRequest) {
        var parsedFiles: [UnifiedDiffFile] = []
        var warnings: [UnifiedDiffParseWarning] = []

        for patch in bundle.patches {
            do {
                let parsed = try UnifiedDiffParser.parse(patch: patch, strict: false)
                parsedFiles.append(parsed.file)
                warnings.append(contentsOf: parsed.warnings)
            } catch let parseError as DiffParseError {
                switch parseError {
                case .malformedHunkHeader(let line, _):
                    AppLogger.ui.warning("Unified diff parse error", metadata: [
                        "run_id": request.runId,
                        "node_id": request.nodeId,
                        "iteration": String(request.iteration),
                        "line": String(line),
                    ])
                }
            } catch {
                AppLogger.ui.warning("Unified diff parse error", metadata: [
                    "run_id": request.runId,
                    "node_id": request.nodeId,
                    "iteration": String(request.iteration),
                ])
            }
        }

        for warning in warnings {
            AppLogger.ui.warning("Unified diff parse warning", metadata: [
                "run_id": request.runId,
                "node_id": request.nodeId,
                "iteration": String(request.iteration),
                "line": String(warning.line),
            ])
        }

        files = parsedFiles
        totalBytes = bundle.patches.reduce(0) { partial, patch in
            partial + patch.diff.utf8.count + (patch.binaryContent?.utf8.count ?? 0)
        }

        showLargeDiffWarning = files.count > 50 || totalBytes > 1_048_576

        if showLargeDiffWarning {
            expandedFileIDs = []
        } else if files.count > 3 {
            expandedFileIDs = Set(files.prefix(3).map(\.id))
        } else {
            expandedFileIDs = Set(files.map(\.id))
        }
    }
}

struct DiffTab: View {
    let runId: String?
    let selectedNode: DevToolsNode?
    var isExpanded: Bool = false

    @StateObject private var model: DiffTabModel
    @State private var modalPresented = false

    init(
        runId: String?,
        selectedNode: DevToolsNode?,
        client: any NodeDiffFetching = EmptyNodeDiffFetcher.shared,
        isExpanded: Bool = false
    ) {
        self.runId = runId
        self.selectedNode = selectedNode
        self.isExpanded = isExpanded
        _model = StateObject(wrappedValue: DiffTabModel(client: client))
    }

    private var request: DiffTabRequest? {
        guard let runId, let task = selectedNode?.task else {
            return nil
        }
        return DiffTabRequest(
            runId: runId,
            nodeId: task.nodeId,
            iteration: max(0, task.iteration ?? 0)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isExpanded, request != nil, !model.files.isEmpty {
                expandToolbar
            }
            if let request {
                content(request: request)
            } else {
                unavailableState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("diffTab.root")
        }
        .onAppear {
            if let request {
                model.load(request)
            }
        }
        .onChange(of: request?.cacheKey) { _ in
            guard let request else { return }
            model.load(request)
        }
        .onDisappear {
            model.cancel()
        }
        .sheet(isPresented: $modalPresented) {
            DiffModalView(model: model) {
                modalPresented = false
            }
            .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 800)
        }
    }

    private var expandToolbar: some View {
        HStack(spacing: 6) {
            Spacer()
            Button {
                modalPresented = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                    Text("Expand")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.inputBg)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Open diff in a larger window")
            .accessibilityIdentifier("diffTab.expand")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface2.opacity(0.5))
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func content(request: DiffTabRequest) -> some View {
        if model.isLoading {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading diff…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("diffTab.loading")
        } else if let error = model.lastError {
            VStack(alignment: .leading, spacing: 10) {
                Text(error.displayMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.danger)
                if let hint = error.hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Button("Retry") {
                    model.retry()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("diffTab.retry")
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("diffTab.error")
        } else if model.files.isEmpty {
            Text("No file changes.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("diffTab.empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.showLargeDiffWarning {
                            Text("Large diff — expand files individually.")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.warning)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.warning.opacity(0.12))
                                .cornerRadius(6)
                                .accessibilityIdentifier("diffTab.largeWarning")
                        }

                        fileList(proxy: proxy)

                        ForEach(model.files) { file in
                            DiffFileView(
                                file: file,
                                isExpanded: Binding(
                                    get: { model.isFileExpanded(file.id) },
                                    set: { model.setFileExpanded(file.id, expanded: $0) }
                                )
                            )
                            .id(file.id)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func fileList(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
                .textCase(.uppercase)

            ForEach(model.files) { file in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(file.id, anchor: .top)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(file.status.rawValue)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(color(for: file.status))
                            .frame(width: 16)

                        Text(file.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if file.additions > 0 {
                            Text("+\(file.additions)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.diffAddFg)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.diffDelFg)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("diffTab.fileButton.\(safeAccessibilityID(file.id))")
            }
        }
        .padding(10)
        .background(Theme.surface2)
        .cornerRadius(6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diffTab.fileList")
    }

    private var unavailableState: some View {
        Text("Diff unavailable for this node.")
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("diffTab.unavailable")
    }

    private func color(for status: UnifiedDiffFileStatus) -> Color {
        switch status {
        case .added: return Theme.diffAddFg
        case .modified: return Theme.diffHunkFg
        case .deleted: return Theme.diffDelFg
        case .renamed: return Theme.warning
        case .unknown: return Theme.textTertiary
        }
    }

    private func safeAccessibilityID(_ raw: String) -> String {
        String(raw.map { character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "_"
        })
    }
}

struct DiffModalView: View {
    @ObservedObject var model: DiffTabModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diff")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if !model.files.isEmpty {
                    Text("\(model.files.count) files")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("diffTab.modal.close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface2)
            .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)

            if model.files.isEmpty {
                Text("No file changes.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.files) { file in
                            DiffFileView(
                                file: file,
                                isExpanded: Binding(
                                    get: { model.isFileExpanded(file.id) },
                                    set: { model.setFileExpanded(file.id, expanded: $0) }
                                )
                            )
                            .id(file.id)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
        .accessibilityIdentifier("diffTab.modal")
    }
}
