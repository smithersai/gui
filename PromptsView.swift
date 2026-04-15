import SwiftUI

struct PromptSourceLoadSnapshot: Equatable {
    let promptId: String
    let loadGeneration: Int
    let editGeneration: Int

    func canApply(
        selectedId: String?,
        activeLoadGeneration: Int,
        currentEditGeneration: Int
    ) -> Bool {
        selectedId == promptId
            && activeLoadGeneration == loadGeneration
            && currentEditGeneration == editGeneration
    }
}

struct PromptsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var prompts: [SmithersPrompt] = []
    @State private var selectedId: String?
    @State private var source: String = ""
    @State private var originalSource: String = ""
    @State private var sourceEditGeneration = 0
    @State private var sourceLoadGeneration = 0
    @State private var inputs: [PromptInput] = []
    @State private var inputValues: [String: String] = [:]
    @State private var originalInputValues: [String: String] = [:]
    @State private var previewText: String?
    @State private var previewRequestGeneration = 0
    @State private var isLoading = true
    @State private var savingPromptId: String?
    @State private var isPreviewing = false
    @State private var error: String?
    @State private var saveError: String?
    @State private var showUnsavedAlert = false
    @State private var pendingPrompt: SmithersPrompt?
    @State private var tab: DetailTab = .source
    private let previewDebounceNanoseconds: UInt64 = 300_000_000

    enum DetailTab: String, CaseIterable {
        case source = "Source"
        case inputs = "Inputs"
        case preview = "Preview"
    }

    init(smithers: SmithersClient) {
        self.smithers = smithers
    }

    init(
        smithers: SmithersClient,
        initialPrompts: [SmithersPrompt],
        isLoading: Bool = false,
        selectedId: String? = nil,
        source: String? = nil,
        originalSource: String? = nil,
        inputs: [PromptInput] = [],
        inputValues: [String: String] = [:],
        previewText: String? = nil,
        tab: DetailTab = .source
    ) {
        self.smithers = smithers
        let selectedSource = source
            ?? initialPrompts.first { $0.id == selectedId }?.source
            ?? ""
        let initialInputs = inputs.isEmpty
            ? Self.inputs(for: selectedSource, preferredInputs: [])
            : inputs
        let initialInputValues = inputValues.isEmpty
            ? Self.defaultInputValues(for: initialInputs)
            : inputValues
        _prompts = State(initialValue: initialPrompts)
        _isLoading = State(initialValue: isLoading)
        _selectedId = State(initialValue: selectedId)
        _source = State(initialValue: selectedSource)
        _originalSource = State(initialValue: originalSource ?? selectedSource)
        _inputs = State(initialValue: initialInputs)
        _inputValues = State(initialValue: initialInputValues)
        _originalInputValues = State(initialValue: initialInputValues)
        _previewText = State(initialValue: previewText)
        _tab = State(initialValue: tab)
    }

    private var selectedPrompt: SmithersPrompt? {
        prompts.first { $0.id == selectedId }
    }

    private var hasSourceChanges: Bool {
        source != originalSource
    }

    private var hasInputValueChanges: Bool {
        Self.normalizedInputValues(inputValues, for: inputs)
            != Self.normalizedInputValues(originalInputValues, for: inputs)
    }

    private var hasChanges: Bool {
        hasSourceChanges
    }

    private var isSavingSelectedPrompt: Bool {
        savingPromptId == selectedId
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { source },
            set: { newValue in
                guard source != newValue else { return }
                source = newValue
                sourceEditGeneration += 1
                syncInputsWithSource(newValue)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                HStack(spacing: 0) {
                    promptList
                        .frame(width: 240)
                    Divider().background(Theme.border)
                    detailPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadPrompts() }
        .task(id: sourceEditGeneration) {
            await renderPreviewAfterDebounce(
                promptId: selectedId,
                sourceSnapshot: source,
                editGeneration: sourceEditGeneration
            )
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Discard", role: .destructive) {
                if let p = pendingPrompt {
                    pendingPrompt = nil
                    saveError = nil
                    applySelection(p)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPrompt = nil
            }
        } message: {
            Text("You have unsaved changes. Discard them?")
        }
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
                            .themedSidebarRowBackground(isSelected: selectedId == prompt.id)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await loadPrompts() }
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
                                HStack(spacing: 5) {
                                    Text(t.rawValue)
                                    if t == .inputs && hasInputValueChanges {
                                        Circle()
                                            .fill(Theme.warning)
                                            .frame(width: 6, height: 6)
                                            .accessibilityLabel("Unsaved input values")
                                    }
                                }
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

                        if let saveError {
                            Text(saveError)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.danger)
                                .lineLimit(1)
                                .padding(.trailing, 4)
                        }

                        if hasSourceChanges {
                            Button(action: { Task { await savePrompt() } }) {
                                HStack(spacing: 4) {
                                    if isSavingSelectedPrompt {
                                        ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                                    }
                                    Text("Save")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(Theme.accent)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSavingSelectedPrompt)
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
        SyntaxHighlightedTextEditor(
            text: sourceBinding,
            language: SourceCodeLanguage(fileName: selectedPrompt?.entryFile ?? "\(selectedId ?? "prompt").mdx"),
            accessibilityIdentifier: "prompts.sourceEditor"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    HStack(spacing: 8) {
                        Text("DISCOVERED INPUTS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textTertiary)
                        if hasInputValueChanges {
                            Text("UNSAVED VALUES")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.warning)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .themedPill(cornerRadius: 3)
                        }
                    }

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
                                        .themedPill(cornerRadius: 3)
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
        if hasChanges {
            pendingPrompt = prompt
            showUnsavedAlert = true
            return
        }
        applySelection(prompt)
    }

    private func applySelection(_ prompt: SmithersPrompt) {
        let promptId = prompt.id
        selectedId = prompt.id
        source = prompt.source ?? ""
        originalSource = source
        let selectedInputs = Self.inputs(for: source, preferredInputs: prompt.inputs ?? [])
        applyInputs(selectedInputs, resetValues: true)
        previewText = nil
        isPreviewing = false
        savingPromptId = nil
        tab = .source
        sourceLoadGeneration += 1
        let loadSnapshot = PromptSourceLoadSnapshot(
            promptId: promptId,
            loadGeneration: sourceLoadGeneration,
            editGeneration: sourceEditGeneration
        )

        // Load full details + props
        Task {
            do {
                let full = try await smithers.getPrompt(promptId)
                guard loadSnapshot.canApply(
                    selectedId: selectedId,
                    activeLoadGeneration: sourceLoadGeneration,
                    currentEditGeneration: sourceEditGeneration
                ) else { return }
                source = full.source ?? ""
                originalSource = source

                let props = try await smithers.discoverPromptProps(promptId)
                guard loadSnapshot.canApply(
                    selectedId: selectedId,
                    activeLoadGeneration: sourceLoadGeneration,
                    currentEditGeneration: sourceEditGeneration
                ) else { return }
                applyInputs(Self.inputs(for: source, preferredInputs: props), resetValues: true)
            } catch {
                // Use what we have from the list
            }
        }
    }

    private func savePrompt() async {
        guard let id = selectedId else {
            savingPromptId = nil
            return
        }
        let capturedId = id
        let sourceToSave = source
        savingPromptId = capturedId
        defer {
            if savingPromptId == capturedId {
                savingPromptId = nil
            }
        }
        do {
            try await smithers.updatePrompt(capturedId, source: sourceToSave)
            // Only apply if the same prompt is still selected.
            guard selectedId == capturedId else { return }
            originalSource = sourceToSave
            saveError = nil
        } catch {
            guard selectedId == capturedId else { return }
            saveError = error.localizedDescription
        }
    }

    private func renderPreviewAfterDebounce(
        promptId: String?,
        sourceSnapshot: String,
        editGeneration: Int
    ) async {
        guard editGeneration > 0, promptId != nil else { return }
        do {
            try await Task.sleep(nanoseconds: previewDebounceNanoseconds)
        } catch {
            return
        }
        guard selectedId == promptId,
              source == sourceSnapshot,
              sourceEditGeneration == editGeneration else { return }
        await renderPreview(switchToPreview: false)
    }

    private func renderPreview(switchToPreview: Bool = true) async {
        guard let id = selectedId else { return }
        let selectedValues = inputValues
        let selectedSource = source
        let editGeneration = sourceEditGeneration
        previewRequestGeneration += 1
        let requestGeneration = previewRequestGeneration
        isPreviewing = true
        if switchToPreview {
            tab = .preview
        }
        defer {
            if selectedId == id && previewRequestGeneration == requestGeneration {
                isPreviewing = false
            }
        }
        do {
            let preview = try await smithers.previewPrompt(id, source: selectedSource, input: selectedValues)
            guard selectedId == id,
                  source == selectedSource,
                  inputValues == selectedValues,
                  sourceEditGeneration == editGeneration,
                  previewRequestGeneration == requestGeneration else { return }
            previewText = preview
        } catch {
            guard selectedId == id,
                  source == selectedSource,
                  inputValues == selectedValues,
                  sourceEditGeneration == editGeneration,
                  previewRequestGeneration == requestGeneration else { return }
            previewText = "Error: \(error.localizedDescription)"
        }
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
