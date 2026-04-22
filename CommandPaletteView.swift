import SwiftUI

struct CommandPaletteView: View {
    let initialQuery: String
    let itemsRevision: Int
    let isInline: Bool
    let itemsProvider: (String) -> [CommandPaletteItem]
    let onExecute: (CommandPaletteItem, String) -> Void
    let onDismiss: () -> Void

    @State private var query: String
    @State private var selectedIndex = 0
    @State private var items: [CommandPaletteItem] = []
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool

    private static let debounceNanoseconds: UInt64 = 80_000_000

    init(
        initialQuery: String,
        itemsRevision: Int = 0,
        isInline: Bool = false,
        itemsProvider: @escaping (String) -> [CommandPaletteItem],
        onExecute: @escaping (CommandPaletteItem, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialQuery = initialQuery
        self.itemsRevision = itemsRevision
        self.isInline = isInline
        self.itemsProvider = itemsProvider
        self.onExecute = onExecute
        self.onDismiss = onDismiss
        _query = State(initialValue: initialQuery)
    }

    private var parsedQuery: ParsedCommandPaletteQuery {
        CommandPaletteQueryParser.parse(query)
    }

    private var selectedItem: CommandPaletteItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var body: some View {
        Group {
            if isInline {
                VStack(spacing: 0) {
                    header
                    Divider().background(Theme.border)
                    resultList
                }
                .frame(minWidth: 560, maxWidth: 760)
            } else {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture(perform: onDismiss)

                    VStack(spacing: 0) {
                        header
                        Divider().background(Theme.border)
                        resultList
                    }
                    .frame(minWidth: 560, maxWidth: 760)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 88)
                    .padding(.horizontal, 24)
                    .background(Color.clear)
                }
            }
        }
        .onAppear {
            refreshItems(for: query, resetSelection: true)
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
        .onChange(of: query) { _, newQuery in
            selectedIndex = ContentViewCommandPaletteModel.preferredSelectionIndex(for: newQuery)
            scheduleItemsRefresh(for: newQuery)
        }
        .onChange(of: initialQuery) { _, newQuery in
            query = newQuery
            refreshItems(for: newQuery, resetSelection: true)
        }
        .onChange(of: itemsRevision) { _, _ in
            refreshItems(for: query, resetSelection: false)
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !items.isEmpty else { return .ignored }
            selectedIndex = min(selectedIndex + 1, items.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !items.isEmpty else { return .ignored }
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            executeSelectedItem()
            return .handled
        }
        .onKeyPress(.tab) {
            applyTabCompletion()
            return .handled
        }
        .accessibilityIdentifier("commandPalette.root")
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)

                TextField("Type a command or search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .focused($isInputFocused)
                    .accessibilityIdentifier("commandPalette.input")

                if let prefix = parsedQuery.prefix {
                    Text(String(prefix))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.14))
                        .cornerRadius(5)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            HStack {
                Text(parsedQuery.mode.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityIdentifier("commandPalette.mode")
                Spacer()
                Text("Esc to close")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .background(Theme.surface2)
    }

    @ViewBuilder
    private var resultList: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.textTertiary)
                Text("No matching results")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if !parsedQuery.searchText.isEmpty {
                    Button("Ask AI: \(parsedQuery.searchText)") {
                        onExecute(
                            CommandPaletteItem(
                                id: "commandPalette.empty.ask",
                                title: "Ask AI",
                                subtitle: parsedQuery.searchText,
                                icon: "sparkles",
                                section: "AI",
                                keywords: [parsedQuery.searchText],
                                shortcut: "Cmd+K",
                                action: .askAI(parsedQuery.searchText),
                                isEnabled: true
                            ),
                            query
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(Theme.surface1)
            .accessibilityIdentifier("commandPalette.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if shouldShowSectionHeader(at: index, items: items) {
                            Text(item.section.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, index == 0 ? 8 : 12)
                                .padding(.bottom, 4)
                        }
                        row(item: item, index: index)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(minHeight: 220, maxHeight: 460)
            .background(Theme.surface1)
        }
    }

    private func row(item: CommandPaletteItem, index: Int) -> some View {
        let selected = index == selectedIndex
        return Button {
            selectedIndex = index
            execute(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(item.isEnabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.7))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(item.isEnabled ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.inputBg)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.accent.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("commandPalette.item.\(safeID(item.id))")
    }

    private func shouldShowSectionHeader(at index: Int, items: [CommandPaletteItem]) -> Bool {
        guard items.indices.contains(index) else { return false }
        if index == 0 { return true }
        return items[index].section != items[index - 1].section
    }

    private func scheduleItemsRefresh(for newQuery: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            if Task.isCancelled { return }
            refreshItems(for: newQuery, resetSelection: true)
        }
    }

    private func refreshItems(for currentQuery: String, resetSelection: Bool) {
        let refreshed = itemsProvider(currentQuery)
        items = refreshed

        let preferredIndex = ContentViewCommandPaletteModel.preferredSelectionIndex(for: currentQuery)
        if refreshed.isEmpty {
            selectedIndex = preferredIndex
            return
        }
        if preferredIndex < 0 {
            selectedIndex = preferredIndex
            return
        }
        if resetSelection || selectedIndex < 0 {
            selectedIndex = preferredIndex
            return
        }
        if selectedIndex >= refreshed.count {
            selectedIndex = max(0, refreshed.count - 1)
        }
    }

    private func executeSelectedItem() {
        guard let item = selectedItem else { return }
        execute(item)
    }

    private func execute(_ item: CommandPaletteItem) {
        guard item.isEnabled else { return }
        onExecute(item, query)
    }

    private func applyTabCompletion() {
        guard let item = selectedItem else { return }

        switch item.action {
        case .askAI:
            query = "?"
        case .slashCommand(let name):
            query = "/\(name) "
        case .runWorkflow:
            query = "\(item.title) "
        case .openFile(let path):
            query = "@\(path)"
        default:
            if parsedQuery.mode == .openAnything {
                query = ">\(item.title.lowercased())"
            } else {
                query = item.title
            }
        }
    }

    private func safeID(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
