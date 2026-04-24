import SwiftUI

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    @Published private(set) var content: ShareExtensionContent?
    @Published private(set) var workspaces: [ShareWorkspace] = []
    @Published var selectedWorkspaceID: String?
    @Published var comment: String = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?

    private let contentLoader: ShareExtensionContentLoader
    private let client: ShareExtensionAPIClient
    private var didStart = false

    init(
        contentLoader: ShareExtensionContentLoader,
        client: ShareExtensionAPIClient
    ) {
        self.contentLoader = contentLoader
        self.client = client
    }

    var selectedWorkspace: ShareWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var canSend: Bool {
        content?.text.shareTrimmedNonEmpty != nil &&
            selectedWorkspace?.canPostAgentMessage == true &&
            !isLoading &&
            !isSending
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedContent = try await contentLoader.load()
            let loadedWorkspaces = try await client.fetchWorkspaces()
            content = loadedContent
            workspaces = loadedWorkspaces
            selectedWorkspaceID = selectedWorkspaceID
                ?? loadedWorkspaces.first(where: \.canPostAgentMessage)?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async -> Bool {
        guard let content, let workspace = selectedWorkspace else {
            errorMessage = "Choose a workspace before sending."
            return false
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            try await client.handoff(content: content, comment: comment, workspace: workspace)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct SmithersShareExtensionView: View {
    @StateObject private var model: ShareExtensionViewModel
    private let onCancel: () -> Void
    private let onComplete: () -> Void

    init(
        model: ShareExtensionViewModel,
        onCancel: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Loading workspaces...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("smithers-share.loading")
                } else if model.content == nil || model.workspaces.isEmpty {
                    unavailableView
                } else {
                    shareForm
                }
            }
            .navigationTitle("Share to Smithers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(model.isSending)
                        .accessibilityIdentifier("smithers-share.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await model.send() {
                                onComplete()
                            }
                        }
                    } label: {
                        if model.isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("smithers-share.send")
                }
            }
        }
        .task { await model.start() }
        .interactiveDismissDisabled(model.isSending)
    }

    private var shareForm: some View {
        Form {
            if let content = model.content {
                Section("Shared Content") {
                    Text(content.previewText)
                        .font(.callout)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("smithers-share.content-preview")
                }
            }

            Section("Comment") {
                TextField("Optional comment", text: $model.comment, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("smithers-share.comment")
            }

            Section("Workspace") {
                ForEach(model.workspaces) { workspace in
                    workspaceRow(workspace)
                }
            }
            .accessibilityIdentifier("smithers-share.workspace-picker")

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("smithers-share.error")
                }
            }
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Unable to Share",
                systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                description: Text(model.errorMessage ?? "No shareable text or workspace was found.")
            )

            Button("Retry") {
                Task { await model.reload() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("smithers-share.retry")
        }
        .padding()
    }

    private func workspaceRow(_ workspace: ShareWorkspace) -> some View {
        Button {
            model.selectedWorkspaceID = workspace.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: workspace.canPostAgentMessage ? "rectangle.stack" : "exclamationmark.triangle")
                    .frame(width: 22)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.title)
                        .font(.body)
                        .lineLimit(1)
                    if !workspace.repoLabel.isEmpty {
                        Text(workspace.repoLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if model.selectedWorkspaceID == workspace.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!workspace.canPostAgentMessage || model.isSending)
        .accessibilityIdentifier("smithers-share.workspace.\(workspace.id.shareAccessibilityKey)")
    }
}

private extension String {
    var shareAccessibilityKey: String {
        map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        .reduce(into: "") { $0.append($1) }
    }
}
