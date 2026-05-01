import Foundation
import SwiftUI

/// Tracks the most recent non-noise chat block content per task `nodeId` for a
/// single run, so the live tree can preview what each running task is
/// currently producing without opening the Logs inspector.
@MainActor
final class LastLogPerNodeStore: ObservableObject {
    @Published private(set) var lastContent: [String: String] = [:]

    private let streamProvider: ChatStreamProviding
    private let historyProvider: ChatHistoryProviding
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private(set) var activeRunId: String?

    init(
        streamProvider: ChatStreamProviding,
        historyProvider: ChatHistoryProviding = EmptyChatHistoryProvider.shared
    ) {
        self.streamProvider = streamProvider
        self.historyProvider = historyProvider
    }

    func connect(runId: String) {
        guard !runId.isEmpty else { return }
        if activeRunId == runId, streamTask != nil { return }
        disconnect()
        activeRunId = runId

        // Prime with the recorded transcript so tasks that last produced output
        // before the tree was opened still show a preview. The live stream
        // overwrites entries as new blocks arrive.
        historyTask = Task { @MainActor [weak self, historyProvider] in
            guard let self else { return }
            do {
                let blocks = try await historyProvider.getChatOutput(runId: runId)
                guard !Task.isCancelled, self.activeRunId == runId else { return }
                for block in blocks {
                    self.ingest(block, runId: runId)
                }
            } catch {
                AppLogger.network.debug("LastLog history prime failed", metadata: [
                    "run_id": runId,
                    "error": String(describing: error),
                ])
            }
        }

        let stream = streamProvider.streamChat(runId: runId)
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    self.ingest(event, runId: runId)
                }
            } catch {
                AppLogger.network.warning("LastLog stream error", metadata: [
                    "run_id": runId,
                    "error": String(describing: error),
                ])
            }
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        historyTask?.cancel()
        historyTask = nil
        activeRunId = nil
        lastContent = [:]
    }

    /// Look up the most recent preview line for a tree node's task id. Falls
    /// back to iteration-suffixed children (`"<id>:<n>"`) when the tree node's
    /// id is a prefix of the block's id, mirroring LogsTab's match semantics.
    func lastLog(forTaskNodeId nodeId: String) -> String? {
        if let exact = lastContent[nodeId] { return exact }

        let prefix = nodeId + ":"
        var best: (key: String, value: String)?
        for (key, value) in lastContent where key.hasPrefix(prefix) {
            if best == nil || key > best!.key {
                best = (key, value)
            }
        }
        return best?.value
    }

    private func ingest(_ event: SSEEvent, runId: String) {
        if let eventRunId = event.runId,
           !SSEEvent.runId(eventRunId, matches: runId) {
            return
        }
        guard let block = LogsTabModel.decodeStreamEvent(event) else { return }
        ingest(block, runId: runId)
    }

    private func ingest(_ block: ChatBlock, runId: String) {
        if let blockRunId = block.runId,
           !SSEEvent.runId(blockRunId, matches: runId) {
            return
        }
        if ChatBlockFilter.shouldHide(block, enabled: true) { return }
        guard let nodeId = block.nodeId, !nodeId.isEmpty else { return }

        let trimmed = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastContent[nodeId] = Self.singleLinePreview(from: trimmed)
    }

    static func singleLinePreview(from content: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(content.count)
        var lastWasSpace = false
        for scalar in content.unicodeScalars {
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isWhitespace {
                if !lastWasSpace, !collapsed.isEmpty {
                    collapsed.append(" ")
                    lastWasSpace = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        if collapsed.hasSuffix(" ") { collapsed.removeLast() }
        return collapsed
    }
}
