import SwiftUI

struct SQLBrowserView: View {
    @ObservedObject var smithers: SmithersClient

    @State private var tables: [SQLTableInfo] = []
    @State private var selectedTableName: String?
    @State private var schemasByTable: [String: SQLTableSchema] = [:]
    @State private var schemaErrors: [String: String] = [:]

    @State private var queryText: String = ""
    @State private var result: SQLResult?
    @State private var queryError: String?

    @State private var isLoadingTables = true
    @State private var isLoadingSchema = false
    @State private var isExecuting = false
    @State private var tablesError: String?

    private var selectedTable: SQLTableInfo? {
        guard let selectedTableName else { return nil }
        return tables.first { $0.name == selectedTableName }
    }

    private var selectedSchema: SQLTableSchema? {
        guard let selectedTableName else { return nil }
        return schemasByTable[selectedTableName]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                tableSidebar
                    .frame(width: 300)

                Divider()
                    .background(Theme.border)

                editorAndResults
            }
        }
        .background(Theme.surface1)
        .task {
            await refreshTables()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("SQL Browser")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            if isLoadingTables {
                ProgressView()
                    .scaleEffect(0.5)
            }

            Spacer()

            Text("\(tables.count) tables")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)

            Button(action: { Task { await refreshTables() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh tables")
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private var tableSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tables")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if let tablesError, tables.isEmpty {
                sidebarMessage(icon: "exclamationmark.triangle", message: tablesError, color: Theme.warning)
            } else if isLoadingTables && tables.isEmpty {
                sidebarMessage(icon: "hourglass", message: "Loading tables…", color: Theme.textTertiary)
            } else if tables.isEmpty {
                sidebarMessage(icon: "tablecells", message: "No tables found.", color: Theme.textTertiary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(tables) { table in
                            tableRow(table)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Theme.base.opacity(0.35))
    }

    private var editorAndResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                queryCard

                schemaCard

                resultCard
            }
            .padding(16)
        }
    }

    private var queryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Query")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                Button(action: {
                    Task { await runQuery() }
                }) {
                    HStack(spacing: 6) {
                        if isExecuting {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                        Text(isExecuting ? "Running…" : "Run Query")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.25))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isExecuting || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $queryText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(8)
                .background(Theme.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )

            Text("Read-only SQLite fallback supports SELECT, PRAGMA, and EXPLAIN when HTTP is unavailable.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(14)
        .background(Theme.surface2.opacity(0.45))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var schemaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Schema")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if let selectedTable {
                    Text(selectedTable.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            if isLoadingSchema {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading schema…")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            } else if let selectedTableName, let message = schemaErrors[selectedTableName] {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
            } else if let schema = selectedSchema {
                VStack(spacing: 0) {
                    ForEach(schema.columns) { column in
                        HStack(spacing: 8) {
                            Text(column.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                                .frame(width: 180, alignment: .leading)

                            Text(column.type.isEmpty ? "?" : column.type)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .frame(width: 120, alignment: .leading)

                            if column.primaryKey {
                                badge("PK", color: Theme.accent)
                            }
                            if column.notNull {
                                badge("NOT NULL", color: Theme.warning)
                            }
                            if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
                                Text("default \(defaultValue)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)

                        Divider().background(Theme.border)
                    }
                }
            } else {
                Text("Select a table to inspect its schema.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(14)
        .background(Theme.surface2.opacity(0.45))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Results")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)

            if let queryError {
                Text(queryError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
            } else if isExecuting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5)
                    Text("Executing query…")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            } else if let result {
                resultTable(result)
            } else {
                Text("No results yet. Run a query to see output.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(14)
        .background(Theme.surface2.opacity(0.45))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func tableRow(_ table: SQLTableInfo) -> some View {
        let isSelected = table.name == selectedTableName

        return Button(action: {
            selectTable(table)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(table.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(isSelected ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Text(table.type)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    Text("\(table.rowCount) rows")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.sidebarSelected : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func sidebarMessage(icon: String, message: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func resultTable(_ result: SQLResult) -> some View {
        if result.columns.isEmpty {
            return AnyView(
                Text("Query executed (no rows returned).")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            )
        }

        let columnWidth: CGFloat = 180

        return AnyView(
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(result.columns.indices, id: \.self) { index in
                            Text(result.columns[index])
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: columnWidth, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(Theme.base.opacity(0.5))

                    Divider().background(Theme.border)

                    if result.rows.isEmpty {
                        Text("No rows")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        ForEach(result.rows.indices, id: \.self) { rowIndex in
                            HStack(spacing: 0) {
                                ForEach(result.columns.indices, id: \.self) { columnIndex in
                                    let value = columnIndex < result.rows[rowIndex].count
                                        ? result.rows[rowIndex][columnIndex]
                                        : ""
                                    Text(value)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: columnWidth, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                            }
                            .background(rowIndex % 2 == 0 ? Theme.surface2.opacity(0.45) : Color.clear)

                            Divider().background(Theme.border)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .frame(minHeight: 120)
        )
    }

    private func selectTable(_ table: SQLTableInfo) {
        selectedTableName = table.name
        if queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryText = "SELECT * FROM \(quoteSQLiteIdentifier(table.name)) LIMIT 100"
        }

        if schemasByTable[table.name] == nil {
            Task {
                await loadSchema(for: table.name)
            }
        }
    }

    private func refreshTables() async {
        isLoadingTables = true
        tablesError = nil

        do {
            let loaded = try await smithers.listSQLTables()
            tables = loaded
            isLoadingTables = false

            guard !loaded.isEmpty else {
                selectedTableName = nil
                return
            }

            if let selectedTableName, loaded.contains(where: { $0.name == selectedTableName }) {
                await loadSchema(for: selectedTableName)
                return
            }

            if let first = loaded.first {
                selectTable(first)
            }
        } catch {
            tablesError = error.localizedDescription
            isLoadingTables = false
            tables = []
        }
    }

    private func loadSchema(for tableName: String) async {
        guard !tableName.isEmpty else { return }

        isLoadingSchema = true
        schemaErrors[tableName] = nil

        do {
            let schema = try await smithers.getSQLTableSchema(tableName)
            schemasByTable[tableName] = schema
        } catch {
            schemaErrors[tableName] = error.localizedDescription
        }

        isLoadingSchema = false
    }

    private func runQuery() async {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isExecuting = true
        queryError = nil

        do {
            result = try await smithers.executeSQL(trimmed)
        } catch {
            result = nil
            queryError = error.localizedDescription
        }

        isExecuting = false
    }

    private func quoteSQLiteIdentifier(_ name: String) -> String {
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
