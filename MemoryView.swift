import SwiftUI

enum MemoryNamespaceFilterState {
    static func namespaces(from facts: [MemoryFact]) -> [String] {
        Array(Set(facts.map(\.namespace))).sorted()
    }

    static func validatedFilter(_ filter: String?, namespaces: [String]) -> String? {
        guard let filter else { return nil }
        return namespaces.contains(filter) ? filter : nil
    }
}

struct MemoryView: View {
    @ObservedObject var smithers: SmithersClient
    private let workflowPath: String?
    @State private var facts: [MemoryFact] = []
    @State private var allNamespaceFacts: [MemoryFact] = []
    @State private var recallResults: [MemoryRecallResult] = []
    @State private var isLoading = true
    @State private var listError: String?
    @State private var recallError: String?
    @State private var namespaceFilter: String?
    @State private var recallQuery = ""
    @State private var recallTopK = 10
    @State private var isRecalling = false
    @State private var hasAttemptedRecall = false
    @State private var recallGeneration = 0
    @State private var mode: ViewMode = .list
    @State private var selectedFact: MemoryFact?
    @State private var factsLoadID = 0

    private static let minRecallTopK = 1

    init(smithers: SmithersClient, workflowPath: String? = nil) {
        self._smithers = ObservedObject(wrappedValue: smithers)
        self.workflowPath = workflowPath
    }

    enum ViewMode {
        case list, recall
    }

    private var namespaces: [String] {
        MemoryNamespaceFilterState.namespaces(from: allNamespaceFacts)
    }

    private var filteredFacts: [MemoryFact] {
        if let ns = namespaceFilter {
            return facts.filter { $0.namespace == ns }
        }
        return facts
    }

    private var recallTopKBinding: Binding<Int> {
        Binding(
            get: { recallTopK },
            set: { recallTopK = Self.normalizedRecallTopK($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar

            switch mode {
                case .list:
                    if let err = listError {
                        errorView(err)
                    } else if let fact = selectedFact {
                        factDetail(fact)
                    } else {
                        factList
                    }
                case .recall:
                    recallView
            }
        }
        .background(Theme.surface1)
        .task { await loadFacts() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Memory")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if isLoading || isRecalling {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadFacts() } }) {
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Mode toggle
            Button(action: {
                mode = .list
                selectedFact = nil
                recallError = nil
            }) {
                Text("Facts")
                    .font(.system(size: 11, weight: mode == .list ? .semibold : .regular))
                    .foregroundColor(mode == .list ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .themedPill(fill: mode == .list ? Theme.pillActive : Theme.pillBg, cornerRadius: 6)
            }
            .buttonStyle(.plain)

            Button(action: {
                mode = .recall
                listError = nil
                recallError = nil
                recallQuery = ""
                recallResults = []
                hasAttemptedRecall = false
            }) {
                Text("Recall")
                    .font(.system(size: 11, weight: mode == .recall ? .semibold : .regular))
                    .foregroundColor(mode == .recall ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .themedPill(fill: mode == .recall ? Theme.pillActive : Theme.pillBg, cornerRadius: 6)
            }
            .buttonStyle(.plain)

            // Namespace filter
            Menu {
                    Button("All Namespaces") { namespaceFilter = nil }
                    Divider()
                    ForEach(namespaces, id: \.self) { ns in
                        Button(ns) { namespaceFilter = ns }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(namespaceFilter ?? "All Namespaces")
                            .font(.system(size: 11))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

            Spacer()

            Text("\(filteredFacts.count) facts")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - Fact List

    private var factList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if filteredFacts.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No memory facts")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    // Table header
                    HStack(spacing: 0) {
                        Text("Namespace")
                            .frame(width: 100, alignment: .leading)
                        Text("Key")
                            .frame(width: 120, alignment: .leading)
                        Text("Value")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Updated")
                            .frame(width: 100, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.surface2)
                    .border(Theme.border, edges: [.bottom])

                    ForEach(filteredFacts) { fact in
                        Button(action: { selectedFact = fact }) {
                            HStack(spacing: 0) {
                                Text(fact.namespace)
                                    .frame(width: 100, alignment: .leading)
                                    .foregroundColor(Theme.accent)
                                Text(fact.key)
                                    .frame(width: 120, alignment: .leading)
                                    .foregroundColor(Theme.textPrimary)
                                Text(factValuePreview(fact.valueJson, maxLen: 60))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                Text(factAge(fact.updatedAtMs))
                                    .frame(width: 100, alignment: .trailing)
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .refreshable { await loadFacts() }
    }

    // MARK: - Fact Detail

    private func factDetail(_ fact: MemoryFact) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: { selectedFact = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                        Text("Back to list")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    metaRow("Namespace", fact.namespace)
                    metaRow("Key", fact.key)
                    metaRow("Updated", detailTimestamp(fact.updatedAtMs, includeAge: true))
                    metaRow("Created", detailTimestamp(fact.createdAtMs))
                    if let ttl = fact.ttlMs {
                        metaRow("TTL", "\(ttl)ms")
                    }
                }

                Divider().background(Theme.border)

                Text("VALUE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)

                Text(formatFactValue(fact.valueJson))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.base)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            }
            .padding(20)
        }
    }

    // MARK: - Recall View

    private var recallView: some View {
        VStack(spacing: 0) {
            // Query input
            HStack(spacing: 8) {
                TextField("Semantic recall query...", text: $recallQuery)
                    .onSubmit { Task { await doRecall() } }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                topKControl

                Button(action: { Task { await doRecall() } }) {
                    Text("Search")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.accent.opacity(0.5) : Theme.accent)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)

            Text("Semantic recall in: \(namespaceFilter ?? "all namespaces")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            // Results
            ScrollView {
                VStack(spacing: 0) {
                    if let recallError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 24))
                                .foregroundColor(Theme.warning)
                            Text(recallError)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else if recallResults.isEmpty && !isRecalling {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundColor(Theme.textTertiary)
                            Text(hasAttemptedRecall ? "No results found." : "Enter a query to search memory")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(Array(recallResults.enumerated()), id: \.offset) { _, result in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "%.3f", result.score))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(scoreColor(result.score))
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.content)
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.textPrimary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider().background(Theme.border)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .refreshable { await doRecall() }
        }
    }

    // MARK: - Helpers

    private var topKControl: some View {
        HStack(spacing: 6) {
            Text("Top-K")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)

            TextField("Top-K", value: recallTopKBinding, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 8)
                .frame(width: 46, height: 32)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .accessibilityLabel("Top-K")
                .accessibilityIdentifier("memory.recall.topK")

            Stepper(
                "Top-K",
                onIncrement: { recallTopK = Self.normalizedRecallTopK(recallTopK + 1) },
                onDecrement: { recallTopK = Self.normalizedRecallTopK(recallTopK - 1) }
            )
                .labelsHidden()
                .accessibilityLabel("Top-K")
                .accessibilityIdentifier("memory.recall.topK.stepper")
        }
        .frame(height: 32)
    }

    private static func normalizedRecallTopK(_ value: Int) -> Int {
        max(value, minRecallTopK)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func scoreColor(_ value: Double) -> Color {
        ScoreColorScale.color(for: value)
    }

    private func factValuePreview(_ valueJSON: String, maxLen: Int) -> String {
        let maxLen = max(maxLen, 1)
        var value = valueJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        guard value.count > maxLen else { return value }
        if maxLen <= 3 {
            return String(value.prefix(maxLen))
        }
        return String(value.prefix(maxLen - 3)) + "..."
    }

    private func factAge(_ updatedAtMs: Int64) -> String {
        guard updatedAtMs > 0 else { return "" }
        let updatedAt = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000)
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private func detailTimestamp(_ timestampMs: Int64, includeAge: Bool = false) -> String {
        guard timestampMs > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let base = formatter.string(from: date)
        guard includeAge else { return base }
        let age = factAge(timestampMs)
        return age.isEmpty ? base : "\(base) (\(age))"
    }

    private func formatFactValue(_ valueJSON: String) -> String {
        let trimmed = valueJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(empty)" }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .fragmentsAllowed]),
            let output = String(data: pretty, encoding: .utf8)
        else {
            return trimmed
        }
        return output
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadFacts() } }
                .buttonStyle(.plain).foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFacts() async {
        factsLoadID += 1
        let loadID = factsLoadID
        isLoading = true
        listError = nil
        defer {
            if factsLoadID == loadID {
                isLoading = false
            }
        }

        do {
            let allFacts = try await smithers.listAllMemoryFacts(workflowPath: workflowPath)
            guard factsLoadID == loadID, !Task.isCancelled else { return }

            allNamespaceFacts = allFacts

            let availableNamespaces = MemoryNamespaceFilterState.namespaces(from: allFacts)
            let currentNamespace = namespaceFilter
            let validNamespace = MemoryNamespaceFilterState.validatedFilter(
                currentNamespace,
                namespaces: availableNamespaces
            )
            if validNamespace != currentNamespace {
                namespaceFilter = validNamespace
            }

            facts = allFacts
            let visibleFacts = validNamespace.map { namespace in
                allFacts.filter { $0.namespace == namespace }
            } ?? allFacts
            if let selectedFact, !visibleFacts.contains(where: { $0.id == selectedFact.id }) {
                self.selectedFact = nil
            }
        } catch {
            guard factsLoadID == loadID, !Task.isCancelled else { return }
            self.listError = error.localizedDescription
        }
    }

    private func doRecall() async {
        recallGeneration += 1
        let generation = recallGeneration
        let trimmedQuery = recallQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            recallError = nil
            recallResults = []
            isRecalling = false
            return
        }
        hasAttemptedRecall = true
        recallError = nil
        recallResults = []
        isRecalling = true
        defer {
            if generation == recallGeneration {
                isRecalling = false
            }
        }
        do {
            let fetched = try await smithers.recallMemory(
                query: trimmedQuery,
                namespace: namespaceFilter,
                workflowPath: workflowPath,
                topK: recallTopK
            )
            guard generation == recallGeneration else { return }
            recallResults = fetched
        } catch {
            guard generation == recallGeneration else { return }
            self.recallError = error.localizedDescription
        }
    }
}
