import SwiftUI

struct SearchView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var query = ""
    @State private var tab: SearchTab = .code
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var issueState: String? = nil

    enum SearchTab: String, CaseIterable {
        case code = "Code"
        case issues = "Issues"
        case repos = "Repos"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Search")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .border(Theme.border, edges: [.bottom])

            // Search input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                TextField("Search...", text: $query)
                    .onSubmit { Task { await search() } }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if isSearching {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Theme.inputBg)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Tabs
            HStack(spacing: 0) {
                ForEach(SearchTab.allCases, id: \.self) { t in
                    Button(action: { tab = t; if !query.isEmpty { Task { await search() } } }) {
                        Text(t.rawValue)
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .foregroundColor(tab == t ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if tab == t {
                            Rectangle().fill(Theme.accent).frame(height: 2)
                        }
                    }
                }

                if tab == .issues {
                    Menu {
                        Button("All") { issueState = nil; Task { await search() } }
                        Button("Open") { issueState = "open"; Task { await search() } }
                        Button("Closed") { issueState = "closed"; Task { await search() } }
                    } label: {
                        HStack(spacing: 4) {
                            Text(issueState ?? "All")
                                .font(.system(size: 11))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Theme.pillBg)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }

                Spacer()

                Text("\(results.count) results")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 12)
            .border(Theme.border, edges: [.bottom])

            // Results
            ScrollView {
                VStack(spacing: 0) {
                    if results.isEmpty && !isSearching {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundColor(Theme.textTertiary)
                            Text(query.isEmpty ? "Enter a search query" : "No results found")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        ForEach(results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(result.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let line = result.lineNumber {
                                        Text("L\(line)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }

                                if let path = result.filePath {
                                    Text(path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Theme.accent)
                                        .lineLimit(1)
                                }

                                if let snippet = result.snippet {
                                    Text(snippet)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(3)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.base)
                                        .cornerRadius(6)
                                }

                                if let desc = result.description {
                                    Text(desc)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider().background(Theme.border)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .background(Theme.surface1)
    }

    private func search() async {
        guard !query.isEmpty else { return }
        isSearching = true
        do {
            switch tab {
            case .code:
                results = try await smithers.searchCode(query: query)
            case .issues:
                results = try await smithers.searchIssues(query: query, state: issueState)
            case .repos:
                results = try await smithers.searchRepos(query: query)
            }
        } catch {
            results = []
        }
        isSearching = false
    }
}
