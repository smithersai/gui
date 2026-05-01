import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum DeveloperDebugMode {
    static let environmentKey = "SMITHERS_GUI_DEBUG"
    private static let enableArguments = ["--developer-debug", "--dev-debug", "--debug-mode"]
    private static let disableArguments = ["--no-developer-debug", "--no-dev-debug"]
    private static let truthyValues = ["1", "true", "yes", "on", "enabled"]
    private static let falseyValues = ["0", "false", "no", "off", "disabled"]

    static var isEnabled: Bool {
        isEnabled(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            isDebugBuild: _isDebugAssertConfiguration()
        )
    }

    static func isEnabled(
        environment: [String: String],
        arguments: [String],
        isDebugBuild: Bool
    ) -> Bool {
        if arguments.contains(where: { disableArguments.contains($0) }) {
            return false
        }

        if let rawValue = environment[environmentKey] {
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if truthyValues.contains(normalized) { return true }
            if falseyValues.contains(normalized) { return false }
        }

        if arguments.contains(where: { enableArguments.contains($0) }) {
            return true
        }

        return isDebugBuild
    }
}

enum DeveloperDebugTone: Equatable {
    case normal
    case good
    case warning
    case danger

    var color: Color {
        switch self {
        case .normal: return Theme.textSecondary
        case .good: return Theme.success
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        }
    }
}

struct DeveloperDebugStateRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let tone: DeveloperDebugTone

    init(label: String, value: String, tone: DeveloperDebugTone = .normal) {
        self.id = label
        self.label = label
        self.value = value
        self.tone = tone
    }
}

struct DeveloperDebugSessionSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let isActive: Bool
    let isRunning: Bool
    let messageCount: Int
    let model: String
}

struct DeveloperDebugRunTabSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
}

struct DeveloperDebugMessageSummary: Identifiable, Equatable {
    let id: String
    let type: String
    let timestamp: String
    let preview: String
}

struct DeveloperDebugSnapshot: Equatable {
    let capturedAt: Date
    let destinationLabel: String
    let destinationDetails: String
    let appRows: [DeveloperDebugStateRow]
    let sessionRows: [DeveloperDebugStateRow]
    let logRows: [DeveloperDebugStateRow]
    let sessions: [DeveloperDebugSessionSummary]
    let runTabs: [DeveloperDebugRunTabSummary]
    let recentMessages: [DeveloperDebugMessageSummary]

    @MainActor
    static func capture(
        store: SessionStore,
        smithers: SmithersClient,
        destination: NavDestination,
        logStats: LogFileStats?,
        now: Date = Date()
    ) -> DeveloperDebugSnapshot {
        let appRows = [
            DeveloperDebugStateRow(label: "Destination", value: destination.label),
            DeveloperDebugStateRow(label: "Route", value: destination.debugRouteDescription),
            DeveloperDebugStateRow(
                label: "Smithers CLI",
                value: smithers.cliAvailable ? "available" : "missing",
                tone: smithers.cliAvailable ? .good : .warning
            ),
            DeveloperDebugStateRow(
                label: "Smithers connection",
                value: smithers.isConnected ? "connected" : "offline",
                tone: smithers.isConnected ? .good : .warning
            ),
            DeveloperDebugStateRow(label: "Smithers transport", value: smithers.connectionTransport.rawValue),
            DeveloperDebugStateRow(
                label: "Server reachable",
                value: smithers.serverReachable ? "yes" : "no",
                tone: smithers.serverReachable ? .good : .normal
            ),
            DeveloperDebugStateRow(label: "Working directory", value: smithers.workingDirectory),
            DeveloperDebugStateRow(label: "Server URL", value: smithers.serverURL?.nilIfBlank ?? "not configured"),
            DeveloperDebugStateRow(
                label: "Debug gate",
                value: DeveloperDebugMode.isEnabled ? "enabled" : "disabled",
                tone: DeveloperDebugMode.isEnabled ? .good : .warning
            ),
        ]

        let sessionRows = [
            DeveloperDebugStateRow(label: "Run tabs", value: "\(store.runTabs.count)"),
            DeveloperDebugStateRow(label: "Terminal tabs", value: "\(store.terminalTabs.count)"),
        ]

        let logRows = [
            DeveloperDebugStateRow(label: "Log file", value: logStats?.fileURL.path ?? "loading"),
            DeveloperDebugStateRow(label: "Entries", value: logStats.map { "\($0.entryCount)" } ?? "loading"),
            DeveloperDebugStateRow(label: "Size", value: logStats.map { formattedBytes($0.sizeBytes) } ?? "loading"),
            DeveloperDebugStateRow(
                label: "Dropped writes",
                value: logStats.map { "\($0.droppedWriteCount)" } ?? "loading",
                tone: (logStats?.droppedWriteCount ?? 0) > 0 ? .danger : .normal
            ),
            DeveloperDebugStateRow(
                label: "Last write error",
                value: logStats?.lastWriteError?.nilIfBlank ?? "none",
                tone: logStats?.lastWriteError == nil ? .normal : .danger
            ),
        ]

        let sessions: [DeveloperDebugSessionSummary] = []

        let runTabs = store.runTabs.map { tab in
            DeveloperDebugRunTabSummary(
                id: tab.runId,
                title: tab.title.nilIfBlank ?? "Run \(idPrefix(tab.runId))",
                preview: trimmedPreview(tab.preview, limit: 140)
            )
        }

        let recentMessages: [DeveloperDebugMessageSummary] = []

        return DeveloperDebugSnapshot(
            capturedAt: now,
            destinationLabel: destination.label,
            destinationDetails: destination.debugRouteDescription,
            appRows: appRows,
            sessionRows: sessionRows,
            logRows: logRows,
            sessions: sessions,
            runTabs: runTabs,
            recentMessages: recentMessages
        )
    }

    private static func idPrefix(_ value: String) -> String {
        String(value.prefix(8))
    }

    private static func trimmedPreview(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "empty" }
        guard normalized.count > limit else { return normalized }
        return "\(String(normalized.prefix(limit)))..."
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}

private enum DeveloperDebugTab: String, CaseIterable, Identifiable {
    case state = "State"
    case telemetry = "Metrics"
    case events = "Events"
    case logs = "Logs"
    case actions = "Actions"

    var id: String { rawValue }
}

@MainActor
struct DeveloperDebugPanel: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var smithers: SmithersClient
    @ObservedObject private var telemetry = DevTelemetryStore.shared
    let destination: NavDestination
    let onClose: () -> Void
    let onOpenLogs: () -> Void

    @State private var selectedTab: DeveloperDebugTab = .state
    @State private var logStats: LogFileStats?
    @State private var logEntries: [LogEntry] = []
    @State private var logLevelFilter: LogLevel?
    @State private var logSearchText = ""
    @State private var eventLevelFilter: LogLevel?
    @State private var eventSearchText = ""
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer?
    @State private var actionFeedback: String?

    private var snapshot: DeveloperDebugSnapshot {
        DeveloperDebugSnapshot.capture(
            store: store,
            smithers: smithers,
            destination: destination,
            logStats: logStats
        )
    }

    private var filteredLogEntries: [LogEntry] {
        logEntries.filter { entry in
            if let logLevelFilter, entry.level != logLevelFilter { return false }
            let query = logSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return true }
            return entry.message.lowercased().contains(query) ||
                entry.category.rawValue.lowercased().contains(query) ||
                entry.level.rawValue.lowercased().contains(query) ||
                (entry.formattedMetadata?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Debug View", selection: $selectedTab) {
                ForEach(DeveloperDebugTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .accessibilityIdentifier("developerDebug.tabPicker")

            Divider()
                .overlay(Theme.border)

            Group {
                switch selectedTab {
                case .state:
                    stateTab(snapshot)
                case .telemetry:
                    telemetryTab()
                case .events:
                    eventsTab()
                case .logs:
                    logsTab(snapshot)
                case .actions:
                    actionsTab()
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 640, maxHeight: .infinity)
        .background(Theme.surface1)
        .border(Theme.border, edges: [.leading])
        .task { await refreshDiagnostics() }
        .onAppear {
            startAutoRefresh()
            telemetry.start()
        }
        .onDisappear {
            stopAutoRefresh()
            telemetry.stop()
        }
        .onChange(of: autoRefresh) { _, newValue in
            if newValue { startAutoRefresh() } else { stopAutoRefresh() }
        }
        .accessibilityIdentifier("developerDebug.panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer Debug")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(snapshot.destinationDetails)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("Auto", isOn: $autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Auto refresh diagnostics")
                .accessibilityIdentifier("developerDebug.autoRefresh")

            Button {
                Task { await refreshDiagnostics() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh diagnostics")
            .accessibilityIdentifier("developerDebug.refresh")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close developer debug")
            .accessibilityIdentifier("developerDebug.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.titlebarBg)
        .border(Theme.border, edges: [.bottom])
    }

    private func stateTab(_ snapshot: DeveloperDebugSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DeveloperDebugSection(title: "Runtime") {
                    DeveloperDebugRows(rows: snapshot.appRows)
                }

                DeveloperDebugSection(title: "Store") {
                    DeveloperDebugRows(rows: snapshot.sessionRows)
                }

                DeveloperDebugSection(title: "Sessions") {
                    if snapshot.sessions.isEmpty {
                        DeveloperDebugEmptyRow(text: "No sessions")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(snapshot.sessions) { session in
                                DeveloperDebugSessionRow(session: session)
                            }
                        }
                    }
                }

                DeveloperDebugSection(title: "Run Tabs") {
                    if snapshot.runTabs.isEmpty {
                        DeveloperDebugEmptyRow(text: "No run tabs")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(snapshot.runTabs) { tab in
                                DeveloperDebugRunTabRow(tab: tab)
                            }
                        }
                    }
                }

                DeveloperDebugSection(title: "Recent Messages") {
                    if snapshot.recentMessages.isEmpty {
                        DeveloperDebugEmptyRow(text: "No active messages")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(snapshot.recentMessages) { message in
                                DeveloperDebugMessageRow(message: message)
                            }
                        }
                    }
                }

                DeveloperDebugSection(title: "Libsmithers obs") {
                    DeveloperDebugRows(rows: telemetryStateRows())
                }
            }
            .padding(12)
        }
    }

    private func telemetryStateRows() -> [DeveloperDebugStateRow] {
        let snap = telemetry.snapshot
        let topMethods = snap.methods
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { "\($0.key.suffix(28)) n=\($0.count) avg=\(Int($0.avgMs))ms" }
            .joined(separator: "; ")
        let topLine = topMethods.isEmpty ? "no calls yet" : topMethods
        let totalErrors = snap.methods.reduce(0) { $0 + $1.errors }
        return [
            DeveloperDebugStateRow(label: "Polling", value: telemetry.isPolling ? "on" : "off",
                                   tone: telemetry.isPolling ? .good : .warning),
            DeveloperDebugStateRow(label: "Total events", value: "\(snap.totalEventSeq)"),
            DeveloperDebugStateRow(label: "Dropped", value: "\(snap.droppedEvents)",
                                   tone: snap.droppedEvents > 0 ? .warning : .normal),
            DeveloperDebugStateRow(label: "Tracked methods", value: "\(snap.methods.count)"),
            DeveloperDebugStateRow(label: "Method errors", value: "\(totalErrors)",
                                   tone: totalErrors > 0 ? .danger : .normal),
            DeveloperDebugStateRow(label: "Top methods", value: topLine),
        ]
    }

    private func logsTab(_ snapshot: DeveloperDebugSnapshot) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                DeveloperDebugRows(rows: snapshot.logRows)

                HStack(spacing: 8) {
                    Picker("Level", selection: $logLevelFilter) {
                        Text("All").tag(LogLevel?.none)
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(LogLevel?.some(level))
                        }
                    }
                    .frame(width: 110)
                    .accessibilityIdentifier("developerDebug.logs.levelFilter")

                    TextField("Search logs", text: $logSearchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("developerDebug.logs.search")

                    Button(action: onOpenLogs) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open full log viewer")
                    .accessibilityIdentifier("developerDebug.logs.openFull")
                }
            }
            .padding(12)

            Divider()
                .overlay(Theme.border)

            if filteredLogEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.textTertiary)
                    Text(logEntries.isEmpty ? "No log entries yet" : "No entries match filters")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(filteredLogEntries) { entry in
                                DeveloperLogEntryRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: logEntries.count) { _, _ in
                        if let last = filteredLogEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func telemetryTab() -> some View {
        let snap = telemetry.snapshot
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DeveloperDebugSection(title: "Runtime") {
                    DeveloperDebugRows(rows: telemetryRuntimeRows(snap))
                }

                DeveloperDebugSection(title: "Counters") {
                    if snap.counters.isEmpty {
                        DeveloperDebugEmptyRow(text: "No counters recorded yet")
                    } else {
                        DeveloperDebugRows(rows: snap.counters.map {
                            DeveloperDebugStateRow(label: $0.0, value: "\($0.1)")
                        })
                    }
                }

                DeveloperDebugSection(title: "Method latency") {
                    if snap.methods.isEmpty {
                        DeveloperDebugEmptyRow(text: "No method calls observed yet")
                    } else {
                        VStack(spacing: 6) {
                            ForEach(snap.methods) { method in
                                DeveloperMethodLatencyRow(method: method)
                            }
                        }
                    }
                }

                if let err = telemetry.lastPollError {
                    DeveloperDebugSection(title: "Telemetry health") {
                        DeveloperDebugRows(rows: [
                            DeveloperDebugStateRow(label: "Last poll error", value: err, tone: .danger)
                        ])
                    }
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("developerDebug.telemetry.scroll")
    }

    private func telemetryRuntimeRows(_ snap: DevTelemetrySnapshot) -> [DeveloperDebugStateRow] {
        let uptime = max(0, snap.nowMs - snap.startedAtMs)
        return [
            DeveloperDebugStateRow(label: "Polling", value: telemetry.isPolling ? "on (2s)" : "off",
                                   tone: telemetry.isPolling ? .good : .warning),
            DeveloperDebugStateRow(label: "Uptime", value: "\(uptime / 1000)s"),
            DeveloperDebugStateRow(label: "Events emitted", value: "\(snap.totalEventSeq)"),
            DeveloperDebugStateRow(label: "Events dropped",
                                   value: "\(snap.droppedEvents)",
                                   tone: snap.droppedEvents > 0 ? .warning : .normal),
            DeveloperDebugStateRow(label: "Ring capacity", value: "\(snap.ringCapacity)"),
            DeveloperDebugStateRow(label: "Min level (Zig)", value: levelName(snap.minLevel)),
            DeveloperDebugStateRow(label: "UI buffer", value: "\(telemetry.events.count)/1000"),
        ]
    }

    private func levelName(_ raw: Int) -> String {
        switch raw {
        case 0: return "trace"
        case 1: return "debug"
        case 2: return "info"
        case 3: return "warn"
        default: return "error"
        }
    }

    private var filteredTelemetryEvents: [DevTelemetryEvent] {
        let query = eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return telemetry.events.reversed().filter { event in
            if let eventLevelFilter, event.level != eventLevelFilter { return false }
            guard !query.isEmpty else { return true }
            return event.subsystem.lowercased().contains(query)
                || event.name.lowercased().contains(query)
                || (event.fieldsJSON?.lowercased().contains(query) ?? false)
        }
    }

    private func eventsTab() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Level", selection: $eventLevelFilter) {
                    Text("All").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(LogLevel?.some(level))
                    }
                }
                .frame(width: 110)
                .accessibilityIdentifier("developerDebug.events.levelFilter")

                TextField("Filter events", text: $eventSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("developerDebug.events.search")

                Button {
                    telemetry.poll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Force telemetry poll")

                Button {
                    telemetry.clearLocalBuffer()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear local event buffer")
                .accessibilityIdentifier("developerDebug.events.clear")
            }
            .padding(12)

            Divider().overlay(Theme.border)

            let visible = filteredTelemetryEvents
            if visible.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.textTertiary)
                    Text(telemetry.events.isEmpty ? "No events yet — interact with the app" : "No events match filters")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visible) { event in
                            DeveloperTelemetryEventRow(event: event)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func actionsTab() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DeveloperDebugSection(title: "Telemetry") {
                    VStack(alignment: .leading, spacing: 6) {
                        actionButton(title: "Force poll now", system: "arrow.clockwise") {
                            telemetry.poll()
                            actionFeedback = "Polled libsmithers obs ring"
                        }
                        actionButton(title: "Clear local event buffer", system: "trash") {
                            telemetry.clearLocalBuffer()
                            actionFeedback = "Cleared \(telemetry.events.count) events"
                        }
                        actionButton(title: "Emit test event", system: "bolt") {
                            DevTelemetryRecorder.emit(
                                level: .info,
                                subsystem: "swift.devtools",
                                name: "user_test_event",
                                fields: ["source": "DeveloperDebugPanel"]
                            )
                            actionFeedback = "Emitted swift.devtools.user_test_event"
                        }
                        actionButton(title: "Increment test counter", system: "plus.circle") {
                            DevTelemetryRecorder.incrementCounter("test.dev_panel.clicks")
                            actionFeedback = "test.dev_panel.clicks++"
                        }
                    }
                }

                DeveloperDebugSection(title: "Levels") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(LogLevel.allCases, id: \.self) { level in
                                Button(level.rawValue.capitalized) {
                                    DevTelemetryRecorder.setMinLevel(level)
                                    actionFeedback = "Set Zig obs min level to \(level.rawValue)"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                DeveloperDebugSection(title: "Diagnostics") {
                    VStack(alignment: .leading, spacing: 6) {
                        actionButton(title: "Copy diagnostics JSON", system: "doc.on.doc") {
                            copyDiagnosticsToPasteboard()
                            actionFeedback = "Diagnostics JSON copied to clipboard"
                        }
                        actionButton(title: "Open full log viewer", system: "arrow.up.right.square") {
                            onOpenLogs()
                        }
                    }
                }

                if let actionFeedback {
                    Text(actionFeedback)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.success)
                        .padding(.top, 4)
                        .accessibilityIdentifier("developerDebug.actions.feedback")
                }
            }
            .padding(12)
        }
    }

    private func actionButton(title: String, system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Theme.surface2.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func copyDiagnosticsToPasteboard() {
        let snap = snapshot
        let tel = telemetry.snapshot
        let payload: [String: Any] = [
            "captured_at": ISO8601DateFormatter().string(from: snap.capturedAt),
            "destination": snap.destinationLabel,
            "destination_details": snap.destinationDetails,
            "app_rows": snap.appRows.map { ["label": $0.label, "value": $0.value, "tone": String(describing: $0.tone)] },
            "session_rows": snap.sessionRows.map { ["label": $0.label, "value": $0.value] },
            "log_rows": snap.logRows.map { ["label": $0.label, "value": $0.value] },
            "telemetry": [
                "started_at_ms": tel.startedAtMs,
                "now_ms": tel.nowMs,
                "events_seq": tel.totalEventSeq,
                "events_dropped": tel.droppedEvents,
                "counters": Dictionary(uniqueKeysWithValues: tel.counters.map { ($0.0, $0.1) }),
                "methods": tel.methods.map { method -> [String: Any] in
                    [
                        "key": method.key,
                        "count": method.count,
                        "errors": method.errors,
                        "max_ms": method.maxMs,
                        "last_ms": method.lastMs,
                        "avg_ms": method.avgMs,
                    ]
                }
            ]
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    @MainActor
    private func refreshDiagnostics() async {
        async let entries = AppLogger.fileWriter.readEntries(limit: 300)
        async let stats = AppLogger.fileWriter.stats()
        logEntries = await entries
        logStats = await stats
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        guard autoRefresh else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await refreshDiagnostics() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

private struct DeveloperDebugSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
            content
        }
    }
}

private struct DeveloperDebugRows: View {
    let rows: [DeveloperDebugStateRow]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 128, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(row.tone.color)
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(Theme.surface2.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct DeveloperDebugEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.surface2.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DeveloperDebugSessionRow: View {
    let session: DeveloperDebugSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if session.isActive {
                    DeveloperDebugBadge(text: "ACTIVE", color: Theme.accent)
                }
                if session.isRunning {
                    DeveloperDebugBadge(text: "RUNNING", color: Theme.success)
                }
                Spacer()
                Text(String(session.id.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }

            HStack(spacing: 10) {
                Text("\(session.messageCount) messages")
                Text(session.model)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.textTertiary)

            Text(session.preview)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
        }
        .textSelection(.enabled)
        .padding(10)
        .background(Theme.surface2.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(session.isActive ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        )
    }
}

private struct DeveloperDebugRunTabRow: View {
    let tab: DeveloperDebugRunTabSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(String(tab.id.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
            Text(tab.preview)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
        }
        .textSelection(.enabled)
        .padding(10)
        .background(Theme.surface2.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DeveloperDebugMessageRow: View {
    let message: DeveloperDebugMessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                DeveloperDebugBadge(text: message.type.uppercased(), color: Theme.info)
                Text(message.timestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Text(message.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
            Text(message.preview)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(3)
        }
        .textSelection(.enabled)
        .padding(10)
        .background(Theme.surface2.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DeveloperDebugBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct DeveloperMethodLatencyRow: View {
    let method: DevTelemetryMethodStat

    private var p99Index: Int? {
        guard method.count > 0 else { return nil }
        let total = method.buckets.reduce(0, +)
        guard total > 0 else { return nil }
        let target = Double(total) * 0.99
        var running: UInt64 = 0
        for (idx, bucket) in method.buckets.enumerated() {
            running += bucket
            if Double(running) >= target { return idx }
        }
        return method.buckets.count - 1
    }

    private var maxBucket: UInt64 { method.buckets.max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(method.key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if method.errors > 0 {
                    Text("\(method.errors) err")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.danger)
                }
                Text("n=\(method.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
            HStack(spacing: 10) {
                Text("avg \(Int(method.avgMs))ms")
                Text("last \(method.lastMs)ms")
                Text("max \(method.maxMs)ms")
                if let p99Index, p99Index < method.bucketUpperMs.count {
                    let upper = method.bucketUpperMs[p99Index]
                    Text("p99 ≤ \(upper < 0 ? "∞" : "\(upper)")ms")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.textTertiary)
            histogramBar
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Theme.surface2.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(method.errors > 0 ? Theme.danger.opacity(0.4) : Theme.border, lineWidth: 1)
        )
    }

    private var histogramBar: some View {
        GeometryReader { geo in
            let total = max(1, method.buckets.reduce(0, +))
            let widths = method.buckets.map { CGFloat($0) / CGFloat(total) }
            HStack(spacing: 1) {
                ForEach(Array(method.buckets.enumerated()), id: \.offset) { idx, bucket in
                    let intensity = Double(bucket) / Double(max(1, maxBucket))
                    Rectangle()
                        .fill(Theme.accent.opacity(0.25 + 0.55 * intensity))
                        .frame(width: max(1, geo.size.width * widths[idx]))
                        .help("≤\(method.bucketUpperMs[idx] < 0 ? "∞" : "\(method.bucketUpperMs[idx])")ms: \(bucket)")
                }
            }
        }
        .frame(height: 6)
    }
}

private struct DeveloperTelemetryEventRow: View {
    let event: DevTelemetryEvent

    private var levelColor: Color {
        switch event.level {
        case .debug: return Theme.textTertiary
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }

    private var sourceBadgeColor: Color {
        event.source == .zig ? Theme.accent : Theme.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(DateFormatters.hourMinuteSecondMillisecond.string(from: event.timestamp))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Text(event.source.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(sourceBadgeColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(sourceBadgeColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(event.level.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(levelColor)
                Text(event.subsystem)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                Spacer()
                if let durationMs = event.durationMs {
                    Text("\(durationMs)ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            Text(event.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
            if let fields = event.fieldsJSON {
                Text(fields)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.surface2.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct DeveloperLogEntryRow: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.level {
        case .debug: return Theme.textTertiary
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(DateFormatters.hourMinuteSecondMillisecond.string(from: entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Text(entry.level.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(levelColor)
                Text(entry.category.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(4)

            if let formattedMetadata = entry.formattedMetadata {
                Text(formattedMetadata)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(3)
            }
        }
        .textSelection(.enabled)
        .padding(8)
        .background(Theme.surface2.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension NavDestination {
    var debugRouteDescription: String {
        switch self {
        case .home:
            return "home"
        case .dashboard:
            return "dashboard"
        case .vcsDashboard:
            return "vcsDashboard"
        case .agents:
            return "agents"
        case .changes:
            return "changes"
        case .runs:
            return "runs"
        case .snapshots:
            return "snapshots"
        case .workflows:
            return "workflows"
        case .triggers:
            return "triggers"
        case .jjhubWorkflows:
            return "jjhubWorkflows"
        case .approvals:
            return "approvals"
        case .prompts:
            return "prompts"
        case .scores:
            return "scores"
        case .memory:
            return "memory"
        case .search:
            return "search"
        case .sql:
            return "sql"
        case .landings:
            return "landings"
        case .tickets:
            return "tickets"
        case .issues:
            return "issues"
        case .settings:
            return "settings"
        case .workspaces:
            return "workspaces"
        case .logs:
            return "logs"
        case .terminal(let id):
            return "terminal id=\(id)"
        case .terminalCommand(let binary, let workingDirectory, let name):
            return "terminalCommand name=\(name) binary=\(binary) cwd=\(workingDirectory)"
        case .liveRun(let runId, let nodeId):
            return "liveRun run=\(runId) node=\(nodeId ?? "all")"
        case .runInspect(let runId, let workflowName):
            return "runInspect run=\(runId) workflow=\(workflowName ?? "unknown")"
        }
    }
}
