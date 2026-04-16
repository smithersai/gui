import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Inspectable Conformance

extension LiveRunChatView: @retroactive Inspectable {}

// MARK: - Test Helpers

private func makeRun(
    runId: String = "run-12345678",
    workflowName: String? = "test-workflow",
    workflowPath: String? = nil,
    status: RunStatus = .running,
    startedAtMs: Int64? = 1700000000000,
    finishedAtMs: Int64? = nil,
    summary: [String: Int]? = nil,
    errorJson: String? = nil
) -> RunSummary {
    RunSummary(
        runId: runId,
        workflowName: workflowName,
        workflowPath: workflowPath,
        status: status,
        startedAtMs: startedAtMs,
        finishedAtMs: finishedAtMs,
        summary: summary,
        errorJson: errorJson
    )
}

private func makeBlock(
    id: String? = nil,
    itemId: String? = nil,
    runId: String? = "run-1",
    nodeId: String? = nil,
    attempt: Int? = nil,
    role: String = "assistant",
    content: String = "Hello",
    timestampMs: Int64? = nil
) -> ChatBlock {
    ChatBlock(
        id: id,
        itemId: itemId,
        runId: runId,
        nodeId: nodeId,
        attempt: attempt,
        role: role,
        content: content,
        timestampMs: timestampMs
    )
}

private func makeTask(
    nodeId: String = "node-1",
    label: String? = nil,
    iteration: Int? = nil,
    state: String = "running",
    lastAttempt: Int? = nil,
    updatedAtMs: Int64? = nil
) -> RunTask {
    RunTask(
        nodeId: nodeId,
        label: label,
        iteration: iteration,
        state: state,
        lastAttempt: lastAttempt,
        updatedAtMs: updatedAtMs
    )
}

/// Mirrors the pure logic from LiveRunChatView for testability.
/// All functions here replicate the view's computed properties exactly.
private struct LiveRunChatLogic {
    let runId: String
    let nodeId: String?
    var run: RunSummary?
    var tasks: [RunTask] = []
    var allBlocks: [ChatBlock] = []
    var attempts: [Int: [ChatBlock]] = [:]
    var inFlightBlockIndexByLifecycleId: [String: Int] = [:]
    var currentAttempt = 0
    var maxAttempt = 0
    var newBlocksInLatest = 0
    var runError: String?
    var blocksError: String?
    var streamDone = false
    var follow = true

    var shortRunId: String {
        String(runId.prefix(8))
    }

    var runTitle: String {
        if let workflowName = run?.workflowName, !workflowName.isEmpty {
            return "\(workflowName) · \(shortRunId)"
        }
        return shortRunId
    }

    var nodeLabel: String? {
        guard let nodeId, !nodeId.isEmpty else { return nil }
        return nodeId
    }

    var statusLine: String {
        var parts: [String] = []
        if let nodeLabel {
            parts.append("Node: \(nodeLabel)")
        }
        if maxAttempt > 0 {
            parts.append("Attempt \(currentAttempt + 1) of \(maxAttempt + 1)")
        }
        if follow {
            parts.append("LIVE")
        }
        if newBlocksInLatest > 0 && currentAttempt < maxAttempt {
            parts.append("\(newBlocksInLatest) new in latest attempt")
        }
        return parts.joined(separator: " · ")
    }

    var bodyError: String? {
        if let runError { return "Error loading run: \(runError)" }
        if let blocksError { return "Error loading chat: \(blocksError)" }
        return nil
    }

    var isStreamingIndicatorVisible: Bool {
        guard let run else { return false }
        let isTerminal = run.status == .finished || run.status == .failed || run.status == .cancelled
        return !isTerminal && !streamDone
    }

    var displayBlocks: [ChatBlock] {
        let blocks = attempts.isEmpty ? allBlocks : attempts[currentAttempt] ?? []
        return deduplicatedChatBlocks(blocks)
    }

    var stateCounts: [(String, Int)] {
        if let summary = run?.summary, !summary.isEmpty {
            return summary
                .map { ($0.key, $0.value) }
                .sorted { $0.0 < $1.0 }
        }
        let grouped = Dictionary(grouping: tasks, by: { $0.state })
        return grouped
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 < $1.0 }
    }

    func formatDuration(deltaMs: Int64) -> String {
        let seconds = Int(deltaMs / 1000)
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m \(seconds % 60)s"
    }

    func timestampLabel(for block: ChatBlock) -> String {
        guard let blockTS = block.timestampMs else { return "" }
        if let runStart = run?.startedAtMs {
            let delta = max(0, blockTS - runStart)
            return "[\(formatDuration(deltaMs: delta))]"
        }
        let date = Date(timeIntervalSince1970: Double(blockTS) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "[\(formatter.string(from: date))]"
    }

    func matchesNodeFilter(_ block: ChatBlock) -> Bool {
        guard let nodeId, !nodeId.isEmpty else { return true }
        return block.nodeId == nodeId
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    mutating func previousAttempt() {
        guard currentAttempt > 0 else { return }
        currentAttempt -= 1
    }

    mutating func nextAttempt() {
        guard currentAttempt < maxAttempt else { return }
        currentAttempt += 1
        if currentAttempt == maxAttempt {
            newBlocksInLatest = 0
        }
    }

    mutating func appendStreamBlock(_ block: ChatBlock) {
        guard matchesNodeFilter(block) else { return }
        if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
            if replaceExistingStreamBlock(block, lifecycleId: lifecycleId) {
                return
            }
        }
        if replaceLastAssistantOverlapStreamBlock(block) {
            return
        }

        allBlocks.append(block)
        if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[lifecycleId] = allBlocks.count - 1
        }
        indexBlock(block)

        if block.attemptIndex > currentAttempt {
            newBlocksInLatest += 1
            return
        }
    }

    mutating func rebuildAttempts(with blocks: [ChatBlock]) {
        allBlocks = blocks
        attempts = [:]
        inFlightBlockIndexByLifecycleId = [:]
        maxAttempt = 0
        currentAttempt = 0

        for (index, block) in blocks.enumerated() {
            if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
                inFlightBlockIndexByLifecycleId[lifecycleId] = index
            }
            indexBlock(block)
        }

        currentAttempt = maxAttempt
        newBlocksInLatest = 0
    }

    mutating func indexBlock(_ block: ChatBlock) {
        let attempt = block.attemptIndex
        attempts[attempt, default: []].append(block)
        if attempt > maxAttempt {
            maxAttempt = attempt
        }
    }

    mutating func replaceExistingStreamBlock(_ block: ChatBlock, lifecycleId: String) -> Bool {
        let mappedIndex = inFlightBlockIndexByLifecycleId[lifecycleId]
            .flatMap { allBlocks.indices.contains($0) ? $0 : nil }
        let searchIndex = mappedIndex ?? allBlocks.lastIndex(where: { $0.lifecycleId == lifecycleId })
        guard let index = searchIndex else {
            return false
        }

        let existing = allBlocks[index]
        allBlocks[index] = existing.canMergeAssistantStream(with: block)
            ? existing.mergingAssistantStream(with: block)
            : block
        inFlightBlockIndexByLifecycleId[lifecycleId] = index
        rebuildAttemptIndexPreservingSelection()
        return true
    }

    mutating func replaceLastAssistantOverlapStreamBlock(_ block: ChatBlock) -> Bool {
        guard let index = allBlocks.indices.last else { return false }
        let existing = allBlocks[index]
        guard existing.canMergeAssistantStream(with: block),
              existing.hasStreamingContentOverlap(with: block) else {
            return false
        }

        allBlocks[index] = existing.mergingAssistantStream(with: block)
        if let existingLifecycleId = existing.lifecycleId, !existingLifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[existingLifecycleId] = index
        }
        if let incomingLifecycleId = block.lifecycleId, !incomingLifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[incomingLifecycleId] = index
        }
        if let mergedLifecycleId = allBlocks[index].lifecycleId, !mergedLifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[mergedLifecycleId] = index
        }
        rebuildAttemptIndexPreservingSelection()
        return true
    }

    mutating func rebuildAttemptIndexPreservingSelection() {
        let selectedAttempt = currentAttempt
        attempts = [:]
        maxAttempt = 0

        for block in allBlocks {
            indexBlock(block)
        }

        currentAttempt = min(selectedAttempt, maxAttempt)
    }
}

// MARK: - shortRunId Tests

final class LiveRunChatShortRunIdTests: XCTestCase {

    func testShortRunIdNormalLongId() {
        let logic = LiveRunChatLogic(runId: "abcdefghijklmnop", nodeId: nil)
        XCTAssertEqual(logic.shortRunId, "abcdefgh")
    }

    func testShortRunIdShortId() {
        let logic = LiveRunChatLogic(runId: "abc", nodeId: nil)
        XCTAssertEqual(logic.shortRunId, "abc")
    }

    func testShortRunIdEmpty() {
        let logic = LiveRunChatLogic(runId: "", nodeId: nil)
        XCTAssertEqual(logic.shortRunId, "")
    }

    func testShortRunIdExactly8Chars() {
        let logic = LiveRunChatLogic(runId: "12345678", nodeId: nil)
        XCTAssertEqual(logic.shortRunId, "12345678")
    }
}

// MARK: - runTitle Tests

final class LiveRunChatRunTitleTests: XCTestCase {

    func testRunTitleWithWorkflowName() {
        var logic = LiveRunChatLogic(runId: "abcdefghijklmnop", nodeId: nil)
        logic.run = makeRun(workflowName: "deploy-prod")
        XCTAssertEqual(logic.runTitle, "deploy-prod · abcdefgh")
    }

    func testRunTitleWithoutWorkflowName() {
        var logic = LiveRunChatLogic(runId: "abcdefghijklmnop", nodeId: nil)
        logic.run = makeRun(workflowName: nil)
        XCTAssertEqual(logic.runTitle, "abcdefgh")
    }

    func testRunTitleWithEmptyWorkflowName() {
        var logic = LiveRunChatLogic(runId: "abcdefghijklmnop", nodeId: nil)
        logic.run = makeRun(workflowName: "")
        XCTAssertEqual(logic.runTitle, "abcdefgh")
    }

    func testRunTitleNilRun() {
        let logic = LiveRunChatLogic(runId: "abcdefghijklmnop", nodeId: nil)
        XCTAssertEqual(logic.runTitle, "abcdefgh")
    }
}

// MARK: - nodeLabel Tests

final class LiveRunChatNodeLabelTests: XCTestCase {

    func testNodeLabelNilNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        XCTAssertNil(logic.nodeLabel)
    }

    func testNodeLabelEmptyNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "")
        XCTAssertNil(logic.nodeLabel)
    }

    func testNodeLabelValidNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "node-abc")
        XCTAssertEqual(logic.nodeLabel, "node-abc")
    }
}

// MARK: - statusLine Tests

final class LiveRunChatStatusLineTests: XCTestCase {

    func testStatusLineFollowOnly() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        XCTAssertEqual(logic.statusLine, "LIVE")
    }

    func testStatusLineNotFollowing() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.follow = false
        XCTAssertEqual(logic.statusLine, "")
    }

    func testStatusLineWithNodeLabel() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "node-x")
        XCTAssertEqual(logic.statusLine, "Node: node-x · LIVE")
    }

    func testStatusLineWithAttempts() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.maxAttempt = 2
        logic.currentAttempt = 1
        XCTAssertEqual(logic.statusLine, "Attempt 2 of 3 · LIVE")
    }

    func testStatusLineWithNewBlocksInLatest() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.maxAttempt = 2
        logic.currentAttempt = 0
        logic.newBlocksInLatest = 5
        XCTAssertEqual(logic.statusLine, "Attempt 1 of 3 · LIVE · 5 new in latest attempt")
    }

    func testStatusLineNewBlocksNotShownOnLatestAttempt() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.maxAttempt = 2
        logic.currentAttempt = 2
        logic.newBlocksInLatest = 5
        // currentAttempt == maxAttempt, so "new in latest" should NOT appear
        XCTAssertEqual(logic.statusLine, "Attempt 3 of 3 · LIVE")
    }

    func testStatusLineAllParts() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: "node-z")
        logic.maxAttempt = 3
        logic.currentAttempt = 1
        logic.newBlocksInLatest = 2
        XCTAssertEqual(logic.statusLine, "Node: node-z · Attempt 2 of 4 · LIVE · 2 new in latest attempt")
    }
}

// MARK: - bodyError Tests

final class LiveRunChatBodyErrorTests: XCTestCase {

    func testBodyErrorNone() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        XCTAssertNil(logic.bodyError)
    }

    func testBodyErrorRunError() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.runError = "network failure"
        XCTAssertEqual(logic.bodyError, "Error loading run: network failure")
    }

    func testBodyErrorBlocksError() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.blocksError = "timeout"
        XCTAssertEqual(logic.bodyError, "Error loading chat: timeout")
    }

    func testBodyErrorBothPresent_RunErrorWins() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.runError = "run err"
        logic.blocksError = "blocks err"
        XCTAssertEqual(logic.bodyError, "Error loading run: run err")
    }
}

// MARK: - isStreamingIndicatorVisible Tests

final class LiveRunChatStreamingIndicatorTests: XCTestCase {

    func testStreamingIndicatorNilRun() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        XCTAssertFalse(logic.isStreamingIndicatorVisible)
    }

    func testStreamingIndicatorRunningNotDone() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(status: .running)
        logic.streamDone = false
        XCTAssertTrue(logic.isStreamingIndicatorVisible)
    }

    func testStreamingIndicatorRunningStreamDone() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(status: .running)
        logic.streamDone = true
        XCTAssertFalse(logic.isStreamingIndicatorVisible)
    }

    func testStreamingIndicatorFinished() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(status: .finished)
        XCTAssertFalse(logic.isStreamingIndicatorVisible)
    }

    func testStreamingIndicatorFailed() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(status: .failed)
        XCTAssertFalse(logic.isStreamingIndicatorVisible)
    }

    func testStreamingIndicatorCancelled() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(status: .cancelled)
        XCTAssertFalse(logic.isStreamingIndicatorVisible)
    }

    func testStreamingIndicatorWaitingApproval() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(status: .waitingApproval)
        logic.streamDone = false
        XCTAssertTrue(logic.isStreamingIndicatorVisible)
    }
}

// MARK: - displayBlocks Tests

final class LiveRunChatDisplayBlocksTests: XCTestCase {

    func testDisplayBlocksEmptyAttempts() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.allBlocks = [makeBlock(content: "A"), makeBlock(content: "B")]
        // attempts is empty -> returns allBlocks
        XCTAssertEqual(logic.displayBlocks.count, 2)
        XCTAssertEqual(logic.displayBlocks[0].content, "A")
    }

    func testDisplayBlocksWithAttempts() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.allBlocks = [makeBlock(content: "A")]
        logic.attempts = [
            0: [makeBlock(content: "attempt-0-block")],
            1: [makeBlock(content: "attempt-1-a"), makeBlock(content: "attempt-1-b")]
        ]
        logic.currentAttempt = 1
        XCTAssertEqual(logic.displayBlocks.count, 2)
        XCTAssertEqual(logic.displayBlocks[0].content, "attempt-1-a")
    }

    func testDisplayBlocksMissingAttemptReturnsEmpty() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.attempts = [0: [makeBlock(content: "x")]]
        logic.currentAttempt = 5
        XCTAssertEqual(logic.displayBlocks.count, 0)
    }
}

// MARK: - stateCounts Tests

final class LiveRunChatStateCountsTests: XCTestCase {

    func testStateCountsFromRunSummary() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(summary: ["finished": 3, "failed": 1, "running": 2])
        let counts = logic.stateCounts
        XCTAssertEqual(counts.count, 3)
        // Sorted by key
        XCTAssertEqual(counts[0].0, "failed")
        XCTAssertEqual(counts[0].1, 1)
        XCTAssertEqual(counts[1].0, "finished")
        XCTAssertEqual(counts[1].1, 3)
        XCTAssertEqual(counts[2].0, "running")
        XCTAssertEqual(counts[2].1, 2)
    }

    func testStateCountsFromTasks() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(summary: nil)
        logic.tasks = [
            makeTask(nodeId: "n1", state: "running"),
            makeTask(nodeId: "n2", state: "running"),
            makeTask(nodeId: "n3", state: "finished"),
        ]
        let counts = logic.stateCounts
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[0].0, "finished")
        XCTAssertEqual(counts[0].1, 1)
        XCTAssertEqual(counts[1].0, "running")
        XCTAssertEqual(counts[1].1, 2)
    }

    func testStateCountsEmptySummaryFallsToTasks() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(summary: [:])
        logic.tasks = [makeTask(state: "pending")]
        let counts = logic.stateCounts
        // Empty summary -> falls through to tasks
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts[0].0, "pending")
    }

    func testStateCountsEmptyBoth() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(summary: nil)
        logic.tasks = []
        XCTAssertTrue(logic.stateCounts.isEmpty)
    }
}

// MARK: - formatDuration Tests

final class LiveRunChatFormatDurationTests: XCTestCase {

    private let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)

    func testFormatDurationZero() {
        XCTAssertEqual(logic.formatDuration(deltaMs: 0), "0s")
    }

    func testFormatDurationSubMinute() {
        XCTAssertEqual(logic.formatDuration(deltaMs: 45_000), "45s")
    }

    func testFormatDurationExactly60s() {
        XCTAssertEqual(logic.formatDuration(deltaMs: 60_000), "1m 0s")
    }

    func testFormatDurationMinutesRange() {
        XCTAssertEqual(logic.formatDuration(deltaMs: 125_000), "2m 5s")
    }

    func testFormatDurationExactly3600s() {
        XCTAssertEqual(logic.formatDuration(deltaMs: 3_600_000), "1h 0m 0s")
    }

    func testFormatDurationHoursRange() {
        XCTAssertEqual(logic.formatDuration(deltaMs: 3_661_000), "1h 1m 1s")
    }

    func testFormatDurationLargeValue() {
        // 2h 30m 15s = 9015s
        XCTAssertEqual(logic.formatDuration(deltaMs: 9_015_000), "2h 30m 15s")
    }

    func testFormatDurationSubSecond() {
        // 500ms -> 0s (integer division)
        XCTAssertEqual(logic.formatDuration(deltaMs: 500), "0s")
    }
}

// MARK: - timestampLabel Tests

final class LiveRunChatTimestampLabelTests: XCTestCase {

    func testTimestampLabelNilTimestamp() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block = makeBlock(timestampMs: nil)
        XCTAssertEqual(logic.timestampLabel(for: block), "")
    }

    func testTimestampLabelWithRunStartShowsDelta() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(startedAtMs: 1700000000000)
        let block = makeBlock(timestampMs: 1700000045000) // 45s after start
        XCTAssertEqual(logic.timestampLabel(for: block), "[45s]")
    }

    func testTimestampLabelWithRunStartZeroDelta() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(startedAtMs: 1700000000000)
        let block = makeBlock(timestampMs: 1700000000000)
        XCTAssertEqual(logic.timestampLabel(for: block), "[0s]")
    }

    func testTimestampLabelWithRunStartNegativeDeltaClamped() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(startedAtMs: 1700000050000)
        let block = makeBlock(timestampMs: 1700000000000) // before start
        // max(0, negative) = 0
        XCTAssertEqual(logic.timestampLabel(for: block), "[0s]")
    }

    func testTimestampLabelWithoutRunStartShowsAbsoluteTime() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.run = makeRun(startedAtMs: nil)
        // 1700000000 = 2023-11-14 22:13:20 UTC
        let block = makeBlock(timestampMs: 1700000000000)
        let label = logic.timestampLabel(for: block)
        // Should be in [HH:mm:ss] format
        XCTAssertTrue(label.hasPrefix("["), "Expected bracket prefix, got: \(label)")
        XCTAssertTrue(label.hasSuffix("]"), "Expected bracket suffix, got: \(label)")
        // Contains colons from time format
        XCTAssertTrue(label.contains(":"), "Expected time format with colons, got: \(label)")
    }

    func testTimestampLabelNoRunAtAll() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block = makeBlock(timestampMs: 1700000000000)
        let label = logic.timestampLabel(for: block)
        // run is nil, so startedAtMs is nil -> absolute time path
        XCTAssertTrue(label.hasPrefix("["))
        XCTAssertTrue(label.hasSuffix("]"))
    }
}

// MARK: - matchesNodeFilter Tests

final class LiveRunChatMatchesNodeFilterTests: XCTestCase {

    func testMatchesNodeFilterNilNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block = makeBlock(nodeId: "any-node")
        XCTAssertTrue(logic.matchesNodeFilter(block))
    }

    func testMatchesNodeFilterEmptyNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "")
        let block = makeBlock(nodeId: "any-node")
        XCTAssertTrue(logic.matchesNodeFilter(block))
    }

    func testMatchesNodeFilterMatchingNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "node-abc")
        let block = makeBlock(nodeId: "node-abc")
        XCTAssertTrue(logic.matchesNodeFilter(block))
    }

    func testMatchesNodeFilterNonMatchingNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "node-abc")
        let block = makeBlock(nodeId: "node-xyz")
        XCTAssertFalse(logic.matchesNodeFilter(block))
    }

    func testMatchesNodeFilterBlockWithNilNodeId() {
        let logic = LiveRunChatLogic(runId: "r1", nodeId: "node-abc")
        let block = makeBlock(nodeId: nil)
        XCTAssertFalse(logic.matchesNodeFilter(block))
    }
}

// MARK: - decodeStreamEvent Tests (via direct JSON decoding)

final class LiveRunChatDecodeStreamEventTests: XCTestCase {

    /// Mirrors decodeStreamEvent logic for testing
    private func decodeStreamEvent(_ event: SSEEvent) -> ChatBlock? {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }

        if let block = try? JSONDecoder().decode(ChatBlock.self, from: data) {
            return block
        }
        // StreamBlockEnvelope is private, so we decode the same structure inline
        struct Envelope: Decodable {
            let block: ChatBlock?
            let data: ChatBlock?
        }
        if let wrapped = try? JSONDecoder().decode(Envelope.self, from: data) {
            return wrapped.block ?? wrapped.data
        }
        return nil
    }

    func testDecodeValidChatBlockJSON() {
        let json = """
        {"role":"assistant","content":"Hello world","id":"b1"}
        """
        let event = SSEEvent(event: nil, data: json)
        let block = decodeStreamEvent(event)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.role, "assistant")
        XCTAssertEqual(block?.content, "Hello world")
        XCTAssertEqual(block?.id, "b1")
    }

    func testDecodeWrappedInEnvelopeWithBlock() {
        let json = """
        {"block":{"role":"user","content":"Hi","id":"b2"}}
        """
        let event = SSEEvent(event: nil, data: json)
        let block = decodeStreamEvent(event)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.role, "user")
        XCTAssertEqual(block?.content, "Hi")
    }

    func testDecodeWrappedInEnvelopeWithData() {
        let json = """
        {"data":{"role":"tool","content":"result","id":"b3"}}
        """
        let event = SSEEvent(event: nil, data: json)
        let block = decodeStreamEvent(event)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.role, "tool")
    }

    func testDecodeInvalidJSON() {
        let event = SSEEvent(event: nil, data: "not json at all{{{")
        let block = decodeStreamEvent(event)
        XCTAssertNil(block)
    }

    func testDecodeEmptyPayload() {
        let event = SSEEvent(event: nil, data: "")
        let block = decodeStreamEvent(event)
        XCTAssertNil(block)
    }

    func testDecodeWhitespaceOnlyPayload() {
        let event = SSEEvent(event: nil, data: "   \n  ")
        let block = decodeStreamEvent(event)
        XCTAssertNil(block)
    }

    func testDecodePayloadWithLeadingTrailingWhitespace() {
        let json = """
          {"role":"assistant","content":"trimmed","id":"b4"}
        """
        let event = SSEEvent(event: nil, data: json)
        let block = decodeStreamEvent(event)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.content, "trimmed")
    }
}

// MARK: - shellQuote Tests

final class LiveRunChatShellQuoteTests: XCTestCase {

    private let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)

    func testShellQuoteNormalString() {
        XCTAssertEqual(logic.shellQuote("hello"), "'hello'")
    }

    func testShellQuoteStringWithSingleQuotes() {
        XCTAssertEqual(logic.shellQuote("it's"), "'it'\"'\"'s'")
    }

    func testShellQuoteEmptyString() {
        XCTAssertEqual(logic.shellQuote(""), "''")
    }

    func testShellQuoteStringWithSpaces() {
        XCTAssertEqual(logic.shellQuote("hello world"), "'hello world'")
    }

    func testShellQuoteStringWithMultipleSingleQuotes() {
        XCTAssertEqual(logic.shellQuote("a'b'c"), "'a'\"'\"'b'\"'\"'c'")
    }
}

// MARK: - appleScriptString Tests

final class LiveRunChatAppleScriptStringTests: XCTestCase {

    private let logic = LiveRunChatLogic(runId: "r1", nodeId: nil)

    func testAppleScriptStringNormal() {
        XCTAssertEqual(logic.appleScriptString("hello"), "\"hello\"")
    }

    func testAppleScriptStringWithQuotes() {
        XCTAssertEqual(logic.appleScriptString("say \"hi\""), "\"say \\\"hi\\\"\"")
    }

    func testAppleScriptStringWithBackslashes() {
        XCTAssertEqual(logic.appleScriptString("path\\to\\file"), "\"path\\\\to\\\\file\"")
    }

    func testAppleScriptStringWithBothQuotesAndBackslashes() {
        XCTAssertEqual(logic.appleScriptString("a\\\"b"), "\"a\\\\\\\"b\"")
    }

    func testAppleScriptStringEmpty() {
        XCTAssertEqual(logic.appleScriptString(""), "\"\"")
    }
}

// MARK: - previousAttempt / nextAttempt Tests

final class LiveRunChatAttemptNavigationTests: XCTestCase {

    func testPreviousAttemptDecrementsWhenAboveZero() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 2
        logic.maxAttempt = 3
        logic.previousAttempt()
        XCTAssertEqual(logic.currentAttempt, 1)
    }

    func testPreviousAttemptNoOpAtZero() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 0
        logic.previousAttempt()
        XCTAssertEqual(logic.currentAttempt, 0)
    }

    func testNextAttemptIncrementsWhenBelowMax() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 1
        logic.maxAttempt = 3
        logic.nextAttempt()
        XCTAssertEqual(logic.currentAttempt, 2)
    }

    func testNextAttemptNoOpAtMax() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 3
        logic.maxAttempt = 3
        logic.nextAttempt()
        XCTAssertEqual(logic.currentAttempt, 3)
    }

    func testNextAttemptClearsNewBlocksWhenReachingMax() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 2
        logic.maxAttempt = 3
        logic.newBlocksInLatest = 5
        logic.nextAttempt()
        XCTAssertEqual(logic.currentAttempt, 3)
        XCTAssertEqual(logic.newBlocksInLatest, 0)
    }

    func testNextAttemptDoesNotClearNewBlocksBeforeMax() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 1
        logic.maxAttempt = 3
        logic.newBlocksInLatest = 5
        logic.nextAttempt()
        XCTAssertEqual(logic.currentAttempt, 2)
        XCTAssertEqual(logic.newBlocksInLatest, 5)
    }
}

// MARK: - appendStreamBlock Tests

final class LiveRunChatAppendStreamBlockTests: XCTestCase {

    func testAppendStreamBlockUpdatesExistingById() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "dup-id", content: "first")
        let block2 = makeBlock(id: "dup-id", content: "second")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "second")
    }

    func testAppendStreamBlockUpdatesExistingByItemId() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: nil, itemId: "cmd-1", content: "running")
        let block2 = makeBlock(id: nil, itemId: "cmd-1", content: "complete")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "complete")
    }

    func testAppendStreamBlockPrefersStableItemIdOverPerEventId() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let started = makeBlock(id: "evt-1", itemId: "cmd-1", role: "tool", content: "running")
        let progress = makeBlock(id: "evt-2", itemId: "cmd-1", role: "tool", content: "still running")
        let completed = makeBlock(id: "evt-3", itemId: "cmd-1", role: "tool", content: "complete")

        logic.appendStreamBlock(started)
        logic.appendStreamBlock(progress)
        logic.appendStreamBlock(completed)

        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].lifecycleId, "cmd-1")
        XCTAssertEqual(logic.allBlocks[0].content, "complete")
    }

    func testAppendStreamBlockMergesAssistantOverlapById() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "Hello wor")
        let block2 = makeBlock(id: "stream-1", content: "world")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world")
    }

    func testAppendStreamBlockAppendsTimestampedAssistantDeltaById() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "Hello ", timestampMs: 100)
        let block2 = makeBlock(id: "stream-1", content: "world", timestampMs: 101)
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world")
    }

    func testAppendStreamBlockMergesAnonymousAssistantOverlap() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: nil, content: "Hello wor")
        let block2 = makeBlock(id: nil, content: "world")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world")
    }

    func testAppendStreamBlockMergesAssistantOverlapAcrossChangingIds() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "Hello wor")
        let block2 = makeBlock(id: "stream-2", content: "world")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world")
        XCTAssertEqual(logic.inFlightBlockIndexByLifecycleId["stream-1"], 0)
        XCTAssertEqual(logic.inFlightBlockIndexByLifecycleId["stream-2"], 0)
    }

    func testAppendStreamBlockDoesNotMergeChangingIdsWithoutOverlap() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "First message")
        let block2 = makeBlock(id: "stream-2", content: "Second message")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 2)
    }

    func testAppendStreamBlockDoesNotMergeAnonymousAssistantAcrossInterveningBlock() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.appendStreamBlock(makeBlock(id: nil, content: "Hello wor"))
        logic.appendStreamBlock(makeBlock(id: nil, role: "user", content: "Next prompt"))
        logic.appendStreamBlock(makeBlock(id: nil, content: "world"))

        XCTAssertEqual(logic.allBlocks.count, 3)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello wor")
        XCTAssertEqual(logic.allBlocks[2].content, "world")
    }

    func testAppendStreamBlockMergesOutOfOrderCumulativeAssistantChunk() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "world")
        let block2 = makeBlock(id: "stream-1", content: "Hello world")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world")
    }

    func testAppendStreamBlockCollapsesRetransmittedCumulativeAssistantChunk() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "Hello world")
        let block2 = makeBlock(id: "stream-1", content: "Hello worldHello world!")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world!")
    }

    func testAppendStreamBlockMergesOutOfOrderInteriorOverlapChunk() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "stream-1", content: "Hello world, this is old")
        let block2 = makeBlock(id: "stream-1", content: "world, this is new")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "Hello world, this is new")
    }

    func testAppendStreamBlockNilIdNotDeduped() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: nil, content: "a")
        let block2 = makeBlock(id: nil, content: "b")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 2)
    }

    func testAppendStreamBlockEmptyIdNotDeduped() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let block1 = makeBlock(id: "", content: "a")
        let block2 = makeBlock(id: "", content: "b")
        logic.appendStreamBlock(block1)
        logic.appendStreamBlock(block2)
        XCTAssertEqual(logic.allBlocks.count, 2)
    }

    func testAppendStreamBlockNodeFiltering() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: "node-x")
        let matching = makeBlock(id: "b1", nodeId: "node-x", content: "match")
        let nonMatching = makeBlock(id: "b2", nodeId: "node-y", content: "skip")
        logic.appendStreamBlock(matching)
        logic.appendStreamBlock(nonMatching)
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.allBlocks[0].content, "match")
    }

    func testAppendStreamBlockTracksAttempts() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.appendStreamBlock(makeBlock(id: "b1", attempt: 0, content: "a0"))
        logic.appendStreamBlock(makeBlock(id: "b2", attempt: 1, content: "a1"))
        XCTAssertEqual(logic.attempts[0]?.count, 1)
        XCTAssertEqual(logic.attempts[1]?.count, 1)
        XCTAssertEqual(logic.maxAttempt, 1)
    }

    func testAppendStreamBlockHigherAttemptIncrementsNewBlocks() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 0
        logic.appendStreamBlock(makeBlock(id: "b1", attempt: 1, content: "future"))
        XCTAssertEqual(logic.newBlocksInLatest, 1)
    }

    func testAppendStreamBlockSameAttemptDoesNotIncrementNewBlocks() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.currentAttempt = 0
        logic.appendStreamBlock(makeBlock(id: "b1", attempt: 0, content: "current"))
        XCTAssertEqual(logic.newBlocksInLatest, 0)
    }
}

// MARK: - rebuildAttempts Tests

final class LiveRunChatRebuildAttemptsTests: XCTestCase {

    func testRebuildAttemptsEmptyBlocks() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.rebuildAttempts(with: [])
        XCTAssertEqual(logic.allBlocks.count, 0)
        XCTAssertTrue(logic.attempts.isEmpty)
        XCTAssertEqual(logic.maxAttempt, 0)
        XCTAssertEqual(logic.currentAttempt, 0)
        XCTAssertEqual(logic.newBlocksInLatest, 0)
    }

    func testRebuildAttemptsMultipleAttempts() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let blocks = [
            makeBlock(id: "b1", attempt: 0, content: "a0"),
            makeBlock(id: "b2", attempt: 0, content: "a0-b"),
            makeBlock(id: "b3", attempt: 1, content: "a1"),
            makeBlock(id: "b4", attempt: 2, content: "a2"),
        ]
        logic.rebuildAttempts(with: blocks)
        XCTAssertEqual(logic.allBlocks.count, 4)
        XCTAssertEqual(logic.attempts[0]?.count, 2)
        XCTAssertEqual(logic.attempts[1]?.count, 1)
        XCTAssertEqual(logic.attempts[2]?.count, 1)
        XCTAssertEqual(logic.maxAttempt, 2)
        XCTAssertEqual(logic.currentAttempt, 2, "Should jump to latest attempt")
        XCTAssertEqual(logic.newBlocksInLatest, 0)
    }

    func testRebuildAttemptsTracksLifecycleIndices() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let blocks = [
            makeBlock(id: "b1", content: "a"),
            makeBlock(id: nil, content: "b"),
            makeBlock(id: "", content: "c"),
            makeBlock(id: "b4", content: "d"),
        ]
        logic.rebuildAttempts(with: blocks)
        XCTAssertEqual(logic.inFlightBlockIndexByLifecycleId["b1"], 0)
        XCTAssertEqual(logic.inFlightBlockIndexByLifecycleId["b4"], 3)
        XCTAssertNil(logic.inFlightBlockIndexByLifecycleId[""])
        XCTAssertEqual(logic.inFlightBlockIndexByLifecycleId.count, 2)
    }

    func testRebuildAttemptsResetsState() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        logic.allBlocks = [makeBlock(content: "old")]
        logic.attempts = [0: [makeBlock(content: "old")]]
        logic.inFlightBlockIndexByLifecycleId = ["old-id": 0]
        logic.maxAttempt = 5
        logic.currentAttempt = 3
        logic.newBlocksInLatest = 10

        logic.rebuildAttempts(with: [makeBlock(id: "new", attempt: 0, content: "fresh")])
        XCTAssertEqual(logic.allBlocks.count, 1)
        XCTAssertEqual(logic.maxAttempt, 0)
        XCTAssertEqual(logic.currentAttempt, 0)
        XCTAssertEqual(logic.newBlocksInLatest, 0)
        XCTAssertEqual(logic.inFlightBlockIndexByLifecycleId["new"], 0)
    }

    func testRebuildAttemptsNilAttemptDefaultsToZero() {
        var logic = LiveRunChatLogic(runId: "r1", nodeId: nil)
        let blocks = [makeBlock(id: "b1", attempt: nil, content: "no attempt")]
        logic.rebuildAttempts(with: blocks)
        XCTAssertEqual(logic.attempts[0]?.count, 1)
        XCTAssertEqual(logic.maxAttempt, 0)
    }
}

// MARK: - HijackSession.resumeArgs Tests

final class HijackSessionResumeArgsTests: XCTestCase {

    func testResumeArgsCodex() {
        let session = HijackSession(
            runId: "r1", agentEngine: "codex", agentBinary: "",
            resumeToken: "tok-123", cwd: "/tmp", supportsResume: true
        )
        XCTAssertEqual(session.resumeArgs(), ["resume", "tok-123", "-C", "/tmp"])
    }

    func testResumeArgsGemini() {
        let session = HijackSession(
            runId: "r1", agentEngine: "gemini", agentBinary: "",
            resumeToken: "tok-456", cwd: "/tmp", supportsResume: true
        )
        XCTAssertEqual(session.resumeArgs(), ["--resume", "tok-456"])
    }

    func testResumeArgsDefault() {
        let session = HijackSession(
            runId: "r1", agentEngine: "claude", agentBinary: "",
            resumeToken: "tok-789", cwd: "/tmp", supportsResume: true
        )
        XCTAssertEqual(session.resumeArgs(), ["--resume", "tok-789"])
    }

    func testResumeArgsNotSupported() {
        let session = HijackSession(
            runId: "r1", agentEngine: "codex", agentBinary: "",
            resumeToken: "tok", cwd: "/tmp", supportsResume: false
        )
        XCTAssertEqual(session.resumeArgs(), [])
    }

    func testResumeArgsEmptyToken() {
        let session = HijackSession(
            runId: "r1", agentEngine: "codex", agentBinary: "",
            resumeToken: "", cwd: "/tmp", supportsResume: true
        )
        XCTAssertEqual(session.resumeArgs(), [])
    }

    func testLaunchInvocationFallsBackToEngineBinary() {
        let session = HijackSession(
            runId: "r1", agentEngine: "codex", agentBinary: "",
            resumeToken: "tok", cwd: "/repo", supportsResume: true
        )

        XCTAssertEqual(
            session.launchInvocation(defaultWorkingDirectory: "/fallback"),
            HijackLaunchInvocation(
                executable: "codex",
                arguments: ["resume", "tok", "-C", "/repo"],
                workingDirectory: "/repo"
            )
        )
    }

    func testDecodesCurrentSmithersCLIHijackLaunchSpec() throws {
        let json = """
        {
          "runId": "run-1",
          "engine": "codex",
          "mode": "native-cli",
          "nodeId": "plan",
          "attempt": 1,
          "iteration": 0,
          "resume": "session-123",
          "cwd": "/repo",
          "launch": {
            "command": "codex",
            "args": ["resume", "session-123", "-C", "/repo"],
            "cwd": "/repo"
          },
          "resumeCommand": "smithers up workflow.tsx --resume --run-id run-1"
        }
        """
        let session = try JSONDecoder().decode(HijackSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.runId, "run-1")
        XCTAssertEqual(session.agentEngine, "codex")
        XCTAssertEqual(session.agentBinary, "codex")
        XCTAssertEqual(session.resumeToken, "session-123")
        XCTAssertTrue(session.supportsResume)
        XCTAssertEqual(
            session.launchInvocation(defaultWorkingDirectory: "/fallback"),
            HijackLaunchInvocation(
                executable: "codex",
                arguments: ["resume", "session-123", "-C", "/repo"],
                workingDirectory: "/repo"
            )
        )
    }

    func testConversationModeHijackDoesNotCreateNativeLaunchInvocation() throws {
        let json = """
        {
          "runId": "run-1",
          "engine": "openai-sdk",
          "mode": "conversation",
          "resume": null,
          "messageCount": 2,
          "cwd": "/repo",
          "launch": null
        }
        """
        let session = try JSONDecoder().decode(HijackSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.agentEngine, "openai-sdk")
        XCTAssertFalse(session.supportsResume)
        XCTAssertNil(session.launchInvocation(defaultWorkingDirectory: "/fallback"))
    }

    func testWrappedHijackSessionDoesNotDecodeAsEmptyDirectSession() throws {
        let json = """
        {
          "ok": true,
          "data": {
            "runId": "run-1",
            "agentEngine": "claude-code",
            "agentBinary": "claude",
            "resumeToken": "session-123",
            "cwd": "/repo",
            "supportsResume": true
          }
        }
        """
        let data = Data(json.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(HijackSession.self, from: data))
        let envelope = try JSONDecoder().decode(APIEnvelope<HijackSession>.self, from: data)
        XCTAssertEqual(envelope.data?.launchInvocation(defaultWorkingDirectory: "/fallback")?.executable, "claude")
    }
}

// MARK: - ChatBlock Model Tests

final class LiveRunChatBlockModelTests: XCTestCase {

    func testAttemptIndexDefaultsToZero() {
        let block = makeBlock(attempt: nil)
        XCTAssertEqual(block.attemptIndex, 0)
    }

    func testAttemptIndexNegativeClamped() {
        let block = makeBlock(attempt: -1)
        XCTAssertEqual(block.attemptIndex, 0)
    }

    func testAttemptIndexPositive() {
        let block = makeBlock(attempt: 3)
        XCTAssertEqual(block.attemptIndex, 3)
    }

    func testStableIdUsesIdWhenPresent() {
        let block = makeBlock(id: "real-id")
        XCTAssertEqual(block.stableId, "real-id")
    }

    func testStableIdUsesFallbackWhenNil() {
        let block = makeBlock(id: nil)
        XCTAssertFalse(block.stableId.isEmpty, "Fallback ID should be non-empty")
        XCTAssertTrue(block.stableId.hasPrefix("chatblock-"))
    }

    func testChatBlockDecodingFromJSON() throws {
        let json = """
        {"role":"assistant","content":"test msg","id":"x1","attempt":2,"timestampMs":1700000000000}
        """
        let block = try JSONDecoder().decode(ChatBlock.self, from: Data(json.utf8))
        XCTAssertEqual(block.id, "x1")
        XCTAssertEqual(block.role, "assistant")
        XCTAssertEqual(block.content, "test msg")
        XCTAssertEqual(block.attempt, 2)
        XCTAssertEqual(block.timestampMs, 1700000000000)
    }

    func testChatBlockDecodingMinimalJSON() throws {
        let json = """
        {"role":"user","content":"hi"}
        """
        let block = try JSONDecoder().decode(ChatBlock.self, from: Data(json.utf8))
        XCTAssertEqual(block.role, "user")
        XCTAssertEqual(block.content, "hi")
        XCTAssertNil(block.id)
        XCTAssertNil(block.attempt)
        XCTAssertNil(block.timestampMs)
        XCTAssertNil(block.nodeId)
    }
}
