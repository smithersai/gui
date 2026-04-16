import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Abstracts chat stream transport so LogsTab can be exercised deterministically in tests.
@MainActor
protocol ChatStreamProviding: AnyObject {
    func streamChat(runId: String) -> AsyncThrowingStream<SSEEvent, Error>
}

@MainActor
final class EmptyChatStreamProvider: ChatStreamProviding {
    static let shared = EmptyChatStreamProvider()

    func streamChat(runId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

extension SmithersClient: ChatStreamProviding {
    func streamChat(runId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let stream = self.streamChat(runId)
            let task = Task {
                for await event in stream {
                    continuation.yield(event)
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

/// Wraps transcript copy plumbing so tests can validate copied text without touching system pasteboard.
protocol TranscriptPasteboarding {
    func write(_ text: String)
}

struct SystemTranscriptPasteboard: TranscriptPasteboarding {
    func write(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

@MainActor
final class LogsTabModel: ObservableObject {
    @Published private(set) var blocks: [ChatBlock] = []
    @Published var followToBottom = true
    @Published var hideNoise = true
    @Published private(set) var isStreaming = false
    @Published private(set) var streamError: String?
    @Published private(set) var scrollRequestToken = UUID()

    private(set) var activeRunId: String?
    private(set) var activeNodeId: String?

    private let streamProvider: ChatStreamProviding
    private let pasteboard: TranscriptPasteboarding

    private var streamTask: Task<Void, Never>?
    private var merger = ChatBlockMerger()
    private var subscribedAt: Date?

    init(
        streamProvider: ChatStreamProviding,
        pasteboard: TranscriptPasteboarding = SystemTranscriptPasteboard(),
        hideNoiseByDefault: Bool = true
    ) {
        self.streamProvider = streamProvider
        self.pasteboard = pasteboard
        hideNoise = hideNoiseByDefault
    }

    var visibleBlocks: [ChatBlock] {
        blocks.filter {
            !ChatBlockFilter.shouldHide(
                $0,
                enabled: hideNoise
            )
        }
    }

    func activate(runId: String, nodeId: String) {
        guard !runId.isEmpty, !nodeId.isEmpty else {
            deactivate(reason: "invalid_context")
            return
        }

        if activeRunId == runId,
           activeNodeId == nodeId,
           streamTask != nil {
            return
        }

        deactivate(reason: "switch_context")

        activeRunId = runId
        activeNodeId = nodeId
        streamError = nil
        merger.reset()
        blocks = []

        AppLogger.ui.debug("Logs subscribe", metadata: [
            "run_id": runId,
            "node_id": nodeId,
        ])

        subscribedAt = Date()
        isStreaming = true
        let stream = streamProvider.streamChat(runId: runId)

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    self.processEvent(event, runId: runId, nodeId: nodeId)
                }

                guard !Task.isCancelled else { return }
                if self.activeRunId == runId,
                   self.activeNodeId == nodeId {
                    self.isStreaming = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isStreaming = false
                self.streamError = "Stream error. Try reconnecting."
                AppLogger.network.warning("Logs stream error", metadata: [
                    "run_id": runId,
                    "node_id": nodeId,
                    "error": String(describing: error),
                ])
            }
        }
    }

    func deactivate(reason: String) {
        if let runId = activeRunId,
           let nodeId = activeNodeId {
            let durationMs = Int((Date().timeIntervalSince(subscribedAt ?? Date())) * 1000)
            AppLogger.ui.debug("Logs unsubscribe", metadata: [
                "run_id": runId,
                "node_id": nodeId,
                "duration_ms": String(max(0, durationMs)),
                "reason": reason,
            ])
        }

        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        subscribedAt = nil
        activeRunId = nil
        activeNodeId = nil
    }

    func retryCurrentSubscription() {
        guard let runId = activeRunId,
              let nodeId = activeNodeId else {
            return
        }
        activate(runId: runId, nodeId: nodeId)
    }

    func userScrolledAwayFromBottom() {
        if followToBottom {
            followToBottom = false
        }
    }

    func userReachedBottom(autoResume: Bool) {
        guard autoResume else { return }
        if !followToBottom {
            followToBottom = true
        }
    }

    @discardableResult
    func copyVisibleTranscript(timestampProvider: (ChatBlock) -> String?) -> String {
        let transcript = ChatBlockRenderer.plainTextTranscript(
            blocks: visibleBlocks,
            timestampProvider: timestampProvider
        )
        pasteboard.write(transcript)
        return transcript
    }

    private func processEvent(_ event: SSEEvent, runId: String, nodeId: String) {
        if let eventRunId = event.runId,
           !SSEEvent.runId(eventRunId, matches: runId) {
            AppLogger.network.warning("Logs stream event dropped due to run mismatch", metadata: [
                "expected_run_id": runId,
                "event_run_id": eventRunId,
            ])
            return
        }

        guard let block = Self.decodeStreamEvent(event) else {
            AppLogger.network.warning("Logs stream event dropped due to malformed payload", metadata: [
                "run_id": runId,
                "node_id": nodeId,
            ])
            return
        }

        if let blockRunId = block.runId,
           !SSEEvent.runId(blockRunId, matches: runId) {
            AppLogger.network.warning("Logs block dropped due to run mismatch", metadata: [
                "expected_run_id": runId,
                "block_run_id": blockRunId,
            ])
            return
        }

        guard Self.blockMatchesNode(block, nodeId: nodeId) else {
            return
        }

        let stats = merger.append(block)
        blocks = merger.blocks

        AppLogger.ui.debug("Logs merge", metadata: [
            "run_id": runId,
            "node_id": nodeId,
            "appended": String(stats.appended),
            "replaced": String(stats.replaced),
            "merged": String(stats.merged),
            "total": String(blocks.count),
        ])

        if followToBottom {
            requestScrollToBottom()
        }
    }

    func requestScrollToBottom() {
        scrollRequestToken = UUID()
    }

    static func decodeStreamEvent(_ event: SSEEvent) -> ChatBlock? {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8) else {
            return nil
        }

        if let block = try? JSONDecoder().decode(ChatBlock.self, from: data) {
            return block
        }
        if let wrapped = try? JSONDecoder().decode(LogsStreamBlockEnvelope.self, from: data) {
            return wrapped.block ?? wrapped.data
        }
        return nil
    }

    static func blockMatchesNode(_ block: ChatBlock, nodeId: String) -> Bool {
        guard let blockNodeId = block.nodeId,
              !blockNodeId.isEmpty else {
            return false
        }

        if blockNodeId == nodeId {
            return true
        }

        let prefix = nodeId + ":"
        return blockNodeId.hasPrefix(prefix)
    }
}

private struct LogsStreamBlockEnvelope: Decodable {
    let block: ChatBlock?
    let data: ChatBlock?
}

private struct LogsBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct LogsTab: View {
    @ObservedObject var store: LiveRunDevToolsStore

    @StateObject private var model: LogsTabModel
    @AppStorage("liverun.logs.autoResumeAtBottom") private var autoResumeAtBottom = true
    @State private var suppressBottomTrackingUntil = Date.distantPast

    private let bottomAnchor = "logs.tab.bottom"

    @MainActor
    init(
        store: LiveRunDevToolsStore,
        streamProvider: ChatStreamProviding = EmptyChatStreamProvider.shared,
        pasteboard: TranscriptPasteboarding = SystemTranscriptPasteboard()
    ) {
        self.store = store
        _model = StateObject(
            wrappedValue: LogsTabModel(
                streamProvider: streamProvider,
                pasteboard: pasteboard
            )
        )
    }

    private var currentRunId: String? {
        store.runId
    }

    private var currentNodeId: String? {
        store.selectedNode?.task?.nodeId
    }

    var body: some View {
        VStack(spacing: 0) {
            controls

            if let streamError = model.streamError {
                errorBanner(streamError)
            }

            transcriptBody
        }
        .background(Theme.surface1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.logs")
        .onAppear {
            activateSubscriptionIfPossible()
        }
        .onDisappear {
            model.deactivate(reason: "tab_hidden")
        }
        .onChange(of: store.selectedNodeId) { _, _ in
            activateSubscriptionIfPossible()
        }
        .onChange(of: store.runId) { _, _ in
            activateSubscriptionIfPossible()
        }
        .onChange(of: model.followToBottom) { _, enabled in
            if enabled {
                model.requestScrollToBottom()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("Follow", isOn: $model.followToBottom)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .accessibilityIdentifier("logs.followToggle")

            Toggle("Hide noise", isOn: $model.hideNoise)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .accessibilityIdentifier("logs.noiseToggle")

            Spacer()

            if model.isStreaming {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                    Text("Live")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
                .accessibilityIdentifier("logs.streamingIndicator")
            }

            Button("Copy transcript") {
                _ = model.copyVisibleTranscript { block in
                    timestampLabel(for: block)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .accessibilityIdentifier("logs.copyTranscript")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface2.opacity(0.5))
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var transcriptBody: some View {
        Group {
            if model.visibleBlocks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.textTertiary)
                    Text("No transcript yet.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("logs.empty")
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geo in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.visibleBlocks, id: \.stableId) { block in
                                    ChatBlockRenderer(
                                        block: block,
                                        timestamp: timestampLabel(for: block)
                                    )
                                    .id(block.stableId)
                                    .accessibilityIdentifier(blockAccessibilityIdentifier(block))
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .background(
                                        GeometryReader { markerGeo in
                                            Color.clear.preference(
                                                key: LogsBottomOffsetPreferenceKey.self,
                                                value: markerGeo.frame(in: .named("logs.scroll")).maxY
                                            )
                                        }
                                    )
                                    .id(bottomAnchor)
                            }
                            .padding(12)
                        }
                        .coordinateSpace(name: "logs.scroll")
                        .onPreferenceChange(LogsBottomOffsetPreferenceKey.self) { markerBottom in
                            handleBottomOffset(markerBottom, viewportHeight: geo.size.height)
                        }
                        .onChange(of: model.scrollRequestToken) { _, _ in
                            suppressBottomTrackingUntil = Date().addingTimeInterval(0.20)
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Button("Retry") {
                model.retryCurrentSubscription()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.accent)
            .accessibilityIdentifier("logs.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.warning.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityIdentifier("logs.error")
    }

    private func activateSubscriptionIfPossible() {
        guard let runId = currentRunId,
              let nodeId = currentNodeId,
              !runId.isEmpty,
              !nodeId.isEmpty else {
            model.deactivate(reason: "missing_context")
            return
        }

        model.activate(runId: runId, nodeId: nodeId)
    }

    private func handleBottomOffset(_ markerBottom: CGFloat, viewportHeight: CGFloat) {
        guard Date() >= suppressBottomTrackingUntil else { return }

        let threshold: CGFloat = 14
        let isAtBottom = markerBottom <= viewportHeight + threshold

        if isAtBottom {
            model.userReachedBottom(autoResume: autoResumeAtBottom)
        } else {
            model.userScrolledAwayFromBottom()
        }
    }

    private func timestampLabel(for block: ChatBlock) -> String? {
        guard let ts = block.timestampMs else { return nil }
        let date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
        return DateFormatters.hourMinuteSecond.string(from: date)
    }

    private func blockAccessibilityIdentifier(_ block: ChatBlock) -> String {
        let raw = block.stableId
        let sanitized = raw.map { char -> Character in
            if char.isLetter || char.isNumber || char == "_" || char == "-" || char == "." {
                return char
            }
            return "-"
        }
        return "logs.block.\(String(sanitized))"
    }
}
