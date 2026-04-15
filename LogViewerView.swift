import SwiftUI
import AppKit

enum LogViewerFiltering {
    static func filteredEntries(
        _ entries: [LogEntry],
        levelFilter: LogLevel?,
        categoryFilter: LogCategory?,
        searchText: String
    ) -> [LogEntry] {
        entries.filter {
            matches(
                $0,
                levelFilter: levelFilter,
                categoryFilter: categoryFilter,
                searchText: searchText
            )
        }
    }

    static func matches(
        _ entry: LogEntry,
        levelFilter: LogLevel?,
        categoryFilter: LogCategory?,
        searchText: String
    ) -> Bool {
        if let levelFilter, entry.level != levelFilter { return false }
        if let categoryFilter, entry.category != categoryFilter { return false }

        guard !searchText.isEmpty else { return true }
        let text = searchText.lowercased()
        let matchesMessage = entry.message.lowercased().contains(text)
        let matchesLevel = entry.level.rawValue.lowercased().contains(text)
        let matchesCategory = entry.category.rawValue.lowercased().contains(text)
        let matchesMeta = entry.metadata?.contains { key, value in
            key.lowercased().contains(text) || value.lowercased().contains(text)
        } ?? false

        return matchesMessage || matchesLevel || matchesCategory || matchesMeta
    }
}

enum LogViewerFormatting {
    static func fileSizeString(_ sizeBytes: Int) -> String {
        if sizeBytes < 1024 { return "\(sizeBytes) B" }
        if sizeBytes < 1_048_576 { return "\(sizeBytes / 1024) KB" }
        return String(format: "%.1f MB", Double(sizeBytes) / 1_048_576.0)
    }
}

struct LogViewerView: View {
    @State private var entries: [LogEntry] = []
    @State private var levelFilter: LogLevel? = nil
    @State private var categoryFilter: LogCategory? = nil
    @State private var searchText = ""
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer?
    @State private var logFileSize: Int = 0
    @State private var totalEntryCount: Int = 0
    @State private var logFileURL: URL?
    @State private var droppedWriteCount: Int = 0
    @State private var lastWriteError: String?
    @State private var showClearLogsConfirmation = false

    private var filteredEntries: [LogEntry] {
        LogViewerFiltering.filteredEntries(
            entries,
            levelFilter: levelFilter,
            categoryFilter: categoryFilter,
            searchText: searchText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text("Logs")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Picker("Level", selection: $levelFilter) {
                    Text("All Levels").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(LogLevel?.some(level))
                    }
                }
                .frame(width: 120)

                Picker("Category", selection: $categoryFilter) {
                    Text("All Categories").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(LogCategory?.some(cat))
                    }
                }
                .frame(width: 140)

                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Toggle("Auto", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Button(action: { showClearLogsConfirmation = true }) {
                    Image(systemName: "trash")
                }
                .help("Clear logs")

                Button(action: exportLogs) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export logs")

                Button(action: revealLogs) {
                    Image(systemName: "folder")
                }
                .help("Reveal log file")

                Button(action: loadEntries) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface1)
            .border(Theme.border, edges: [.bottom])

            // Stats bar
            HStack(spacing: 16) {
                Text("\(filteredEntries.count) of \(totalEntryCount) entries")
                    .foregroundColor(Theme.textTertiary)

                Text(formattedFileSize)
                    .foregroundColor(Theme.textTertiary)

                if let logFileURL {
                    Text(logFileURL.path)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(logFileURL.path)
                }

                let errorCount = entries.filter { $0.level == .error }.count
                if errorCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.danger).frame(width: 6, height: 6)
                        Text("\(errorCount) errors")
                            .foregroundColor(Theme.danger)
                    }
                }

                let warningCount = entries.filter { $0.level == .warning }.count
                if warningCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.warning).frame(width: 6, height: 6)
                        Text("\(warningCount) warnings")
                            .foregroundColor(Theme.warning)
                    }
                }

                // Category breakdown
                let categoryCounts = Dictionary(grouping: entries, by: \.category).mapValues(\.count)
                if !categoryCounts.isEmpty {
                    let breakdown = categoryCounts
                        .sorted { $0.value > $1.value }
                        .prefix(4)
                        .map { "\($0.key.rawValue):\($0.value)" }
                        .joined(separator: " ")
                    Text(breakdown)
                        .foregroundColor(Theme.textTertiary)
                }

                if droppedWriteCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.danger).frame(width: 6, height: 6)
                        Text("\(droppedWriteCount) dropped")
                            .foregroundColor(Theme.danger)
                    }
                    .help(lastWriteError ?? "Log writer dropped entries")
                } else if let lastWriteError {
                    Text(lastWriteError)
                        .foregroundColor(Theme.warning)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(lastWriteError)
                }

                Spacer()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Theme.surface1)
            .border(Theme.border, edges: [.bottom])

            // Log entries
            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.textTertiary)
                    Text(entries.isEmpty ? "No log entries yet" : "No entries match filters")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    }
                    .listStyle(.plain)
                    .onChange(of: entries.count) { _, _ in
                        if let last = filteredEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Theme.base)
        .task { loadEntries() }
        .onAppear { startAutoRefresh() }
        .onDisappear { stopAutoRefresh() }
        .onChange(of: autoRefresh) { _, newValue in
            if newValue { startAutoRefresh() } else { stopAutoRefresh() }
        }
        .confirmationDialog(
            "Clear Logs",
            isPresented: $showClearLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) {
                clearLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clear all local log entries? This action cannot be undone.")
        }
        .accessibilityIdentifier("view.logs")
    }

    private var formattedFileSize: String {
        LogViewerFormatting.fileSizeString(logFileSize)
    }

    private func loadEntries() {
        Task {
            entries = await AppLogger.fileWriter.readEntries(limit: 1000)
            let stats = await AppLogger.fileWriter.stats()
            totalEntryCount = stats.entryCount
            logFileSize = stats.sizeBytes
            logFileURL = stats.fileURL
            droppedWriteCount = stats.droppedWriteCount
            lastWriteError = stats.lastWriteError
        }
    }

    private func clearLogs() {
        Task {
            await AppLogger.fileWriter.clearLog()
            AppLogger.lifecycle.info("Log file cleared from viewer")
            entries = []
            let stats = await AppLogger.fileWriter.stats()
            totalEntryCount = stats.entryCount
            logFileSize = stats.sizeBytes
            logFileURL = stats.fileURL
            droppedWriteCount = stats.droppedWriteCount
            lastWriteError = stats.lastWriteError
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        guard autoRefresh else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            loadEntries()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func exportLogs() {
        Task { @MainActor in
            guard let logURL = await AppLogger.fileWriter.exportLog() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "smithers-gui-logs-\(Self.exportDateString()).log"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                // Guard against deleting the source if dest resolves to the same file.
                if logURL.standardized == dest.standardized {
                    // Source and destination are the same file — nothing to do.
                    return
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: logURL, to: dest)
                AppLogger.lifecycle.info("Log file exported", metadata: ["destination": dest.path])
            } catch {
                AppLogger.error.error("Log export failed", metadata: [
                    "destination": dest.path,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func revealLogs() {
        Task { @MainActor in
            guard let logURL = await AppLogger.fileWriter.exportLog() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    private static func exportDateString() -> String {
        DateFormatters.fileYearMonthDayHourMinuteSecond.string(from: Date())
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(DateFormatters.hourMinuteSecondMillisecond.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)

            LevelBadge(level: entry.level)

            Text(entry.category.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                if let metadata = entry.metadata, !metadata.isEmpty {
                    Text(entry.formattedMetadata ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }
}

// MARK: - Level Badge

private struct LevelBadge: View {
    let level: LogLevel

    private var color: Color {
        switch level {
        case .debug: return Theme.textTertiary
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }

    var body: some View {
        Text(level.rawValue.prefix(3).uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(3)
            .frame(width: 36)
    }
}
