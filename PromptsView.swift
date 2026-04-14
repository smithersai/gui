import SwiftUI

struct PromptsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var prompts: [SmithersPrompt] = []
    @State private var selectedId: String?
    @State private var source: String = ""
    @State private var originalSource: String = ""
    @State private var inputs: [PromptInput] = []
    @State private var inputValues: [String: String] = [:]
    @State private var previewText: String?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isPreviewing = false
    @State private var error: String?
    @State private var tab: DetailTab = .source

    enum DetailTab: String, CaseIterable {
        case source = "Source"
        case inputs = "Inputs"
        case preview = "Preview"
    }

    private var selectedPrompt: SmithersPrompt? {
        prompts.first { $0.id == selectedId }
    }

    private var hasChanges: Bool {
        source != originalSource
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                HSplitView {
                    promptList
                        .frame(minWidth: 220)
                    detailPane
                        .frame(minWidth: 400)
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadPrompts() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Prompts")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadPrompts() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - List

    private var promptList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if prompts.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No prompts found")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(prompts) { prompt in
                        Button(action: { selectPrompt(prompt) }) {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundColor(selectedId == prompt.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prompt.id)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    if let entry = prompt.entryFile {
                                        Text(entry)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(selectedId == prompt.id ? Theme.sidebarSelected : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .background(Theme.surface2)
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if selectedPrompt != nil {
                VStack(spacing: 0) {
                    // Tabs + save button
                    HStack(spacing: 0) {
                        ForEach(DetailTab.allCases, id: \.self) { t in
                            Button(action: { tab = t }) {
                                Text(t.rawValue)
                                    .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                                    .foregroundColor(tab == t ? Theme.accent : Theme.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if tab == t {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                }
                            }
                        }
                        Spacer()

                        if hasChanges {
                            Button(action: { Task { await savePrompt() } }) {
                                HStack(spacing: 4) {
                                    if isSaving {
                                        ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                                    }
                                    Text("Save")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(Theme.accent)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                            .padding(.trailing, 12)
                        }
                    }
                    .border(Theme.border, edges: [.bottom])

                    // Content
                    switch tab {
                    case .source:
                        sourceEditor
                    case .inputs:
                        inputsView
                    case .preview:
                        previewView
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a prompt")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface1)
    }

    private var sourceEditor: some View {
        TextEditor(text: $source)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Theme.base)
            .padding(1)
    }

    private var inputsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if inputs.isEmpty {
                    Text("No inputs discovered")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .padding(20)
                } else {
                    Text("DISCOVERED INPUTS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textTertiary)

                    ForEach(inputs) { input in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(input.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                if let type = input.type {
                                    Text(type)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Theme.pillBg)
                                        .cornerRadius(3)
                                }
                            }
                            TextField(
                                input.defaultValue ?? "Value...",
                                text: Binding(
                                    get: { inputValues[input.name] ?? "" },
                                    set: { inputValues[input.name] = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Theme.inputBg)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                        }
                    }

                    Button(action: { Task { await renderPreview() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                            Text("Preview with values")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(20)
        }
    }

    private var previewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isPreviewing {
                    HStack {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        Text("Rendering...")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(20)
                } else if let preview = previewText {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(20)
                } else {
                    VStack(spacing: 8) {
                        Text("No preview available")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                        Button(action: { Task { await renderPreview() } }) {
                            Text("Generate Preview")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }

    // MARK: - Actions

    private func selectPrompt(_ prompt: SmithersPrompt) {
        selectedId = prompt.id
        source = prompt.source ?? ""
        originalSource = source
        inputs = prompt.inputs ?? []
        inputValues = [:]
        previewText = nil
        tab = .source

        // Load full details + props
        Task {
            do {
                let full = try await smithers.getPrompt(prompt.id)
                source = full.source ?? ""
                originalSource = source
                let props = try await smithers.discoverPromptProps(prompt.id)
                inputs = props
                for prop in props {
                    if let def = prop.defaultValue {
                        inputValues[prop.name] = def
                    }
                }
            } catch {
                // Use what we have from the list
            }
        }
    }

    private func savePrompt() async {
        guard let id = selectedId else { return }
        isSaving = true
        do {
            try await smithers.updatePrompt(id, source: source)
            originalSource = source
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    private func renderPreview() async {
        guard let id = selectedId else { return }
        isPreviewing = true
        tab = .preview
        do {
            previewText = try await smithers.previewPrompt(id, input: inputValues)
        } catch {
            previewText = "Error: \(error.localizedDescription)"
        }
        isPreviewing = false
    }

    private func loadPrompts() async {
        isLoading = true
        error = nil
        do {
            prompts = try await smithers.listPrompts()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadPrompts() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
