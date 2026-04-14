import SwiftUI

struct MemoryView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var facts: [MemoryFact] = []
    @State private var recallResults: [MemoryRecallResult] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var namespaceFilter: String?
    @State private var recallQuery = ""
    @State private var isRecalling = false
    @State private var mode: ViewMode = .list
    @State private var selectedFact: MemoryFact?

    enum ViewMode {
        case list, recall
    }

    private var namespaces: [String] {
        Array(Set(facts.map(\.namespace))).sorted()
    }

    private var filteredFacts: [MemoryFact] {
        if let ns = namespaceFilter {
            return facts.filter { $0.namespace == ns }
        }
        return facts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar

            if let error {
                errorView(error)
            } else {
                switch mode {
                case .list:
                    if let fact = selectedFact {
                        factDetail(fact)
                    } else {
                        factList
                    }
                case .recall:
                    recallView
                }
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
            Button(action: { mode = .list; selectedFact = nil }) {
                Text("Facts")
                    .font(.system(size: 11, weight: mode == .list ? .semibold : .regular))
                    .foregroundColor(mode == .list ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(mode == .list ? Theme.pillActive : Theme.pillBg)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button(action: { mode = .recall }) {
                Text("Recall")
                    .font(.system(size: 11, weight: mode == .recall ? .semibold : .regular))
                    .foregroundColor(mode == .recall ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(mode == .recall ? Theme.pillActive : Theme.pillBg)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Namespace filter
            if mode == .list {
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
            }

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
                                Text(fact.valueJson)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                Text(shortDate(fact.updatedAt))
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
                    metaRow("Created", formatDate(fact.createdAt))
                    metaRow("Updated", formatDate(fact.updatedAt))
                    if let ttl = fact.ttlMs {
                        metaRow("TTL", "\(ttl / 1000)s")
                    }
                }

                Divider().background(Theme.border)

                Text("VALUE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)

                Text(prettyJSON(fact.valueJson))
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
                TextField("Semantic recall query...", text: $recallQuery, onCommit: { Task { await doRecall() } })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                Button(action: { Task { await doRecall() } }) {
                    Text("Search")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(recallQuery.isEmpty ? Theme.accent.opacity(0.5) : Theme.accent)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(recallQuery.isEmpty)
            }
            .padding(20)

            // Results
            ScrollView {
                VStack(spacing: 0) {
                    if recallResults.isEmpty && !isRecalling {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundColor(Theme.textTertiary)
                            Text("Enter a query to search memory")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(recallResults) { result in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "%.2f", result.score))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(scoreColor(result.score))
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.content)
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.textPrimary)
                                        .textSelection(.enabled)
                                    if let meta = result.metadata {
                                        Text(meta)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                    }
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
        }
    }

    // MARK: - Helpers

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
        if value >= 0.8 { return Theme.success }
        if value >= 0.5 { return Theme.warning }
        return Theme.danger
    }

    private func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        return fmt.string(from: date)
    }

    private func prettyJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return str
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
        isLoading = true
        error = nil
        do {
            facts = try await smithers.listMemoryFacts()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func doRecall() async {
        guard !recallQuery.isEmpty else { return }
        isRecalling = true
        do {
            recallResults = try await smithers.recallMemory(query: recallQuery)
        } catch {
            self.error = error.localizedDescription
        }
        isRecalling = false
    }
}
