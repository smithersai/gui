import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct LiveRunChatView: View {
    @ObservedObject var smithers: SmithersClient
    let runId: String
    let nodeId: String?
    var onClose: () -> Void = {}

    @State private var run: RunSummary?
    @State private var tasks: [RunTask] = []

    @State private var allBlocks: [ChatBlock] = []
    @State private var attempts: [Int: [ChatBlock]] = [:]
    @State private var inFlightBlockIndexByLifecycleId: [String: Int] = [:]
    @State private var currentAttempt = 0
    @State private var maxAttempt = 0
    @State private var newBlocksInLatest = 0

    @State private var loadingRun = true
    @State private var loadingBlocks = true
    @State private var runError: String?
    @State private var blocksError: String?

    @State private var streamTask: Task<Void, Never>?
    @State private var streamGeneration = UUID()
    @State private var streamDone = false
    @State private var bufferingInitialStream = false
    @State private var initialStreamBuffer: [ChatBlock] = []

    @State private var follow = true
    @State private var showContextPane = false
    @State private var scrollRequest = UUID()

    @State private var hijacking = false
    @State private var hijackError: String?
    @State private var replayFallback = false
    @State private var promptResumeAutomation = false
    @State private var hijackReturnError: String?
    @State private var hijackReturned = false

    private let bottomAnchor = "live-run-chat-bottom"

    private var displayBlocks: [ChatBlock] {
        let blocks = attempts.isEmpty ? allBlocks : attempts[currentAttempt] ?? []
        return deduplicatedChatBlocks(blocks)
    }

    private var shortRunId: String {
        String(runId.prefix(8))
    }

    private var runTitle: String {
        if let workflowName = run?.workflowName, !workflowName.isEmpty {
            return "\(workflowName) · \(shortRunId)"
        }
        return shortRunId
    }

    private var nodeLabel: String? {
        guard let nodeId, !nodeId.isEmpty else { return nil }
        return nodeId
    }

    private var statusLine: String {
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

    private var bodyError: String? {
        if let runError { return "Error loading run: \(runError)" }
        if let blocksError { return "Error loading chat: \(blocksError)" }
        return nil
    }

    private var isStreamingIndicatorVisible: Bool {
        guard let run else { return false }
        let isTerminal = run.status == .finished || run.status == .failed || run.status == .cancelled
        return !isTerminal && !streamDone
    }

    private var stateCounts: [(String, Int)] {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            hijackBanner

            HStack(spacing: 0) {
                transcriptPane
                if showContextPane {
                    Divider().background(Theme.border)
                    contextPane
                        .frame(width: 280)
                        .background(Theme.surface2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surface1)
        .task {
            await loadAll()
        }
        .onDisappear {
            stopStreaming()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Run Chat")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(runTitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            if loadingRun || loadingBlocks {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .border(Theme.border, edges: [.bottom])
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: previousAttempt) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.inputBg)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(currentAttempt <= 0)
                .opacity(currentAttempt <= 0 ? 0.45 : 1)

                Button(action: nextAttempt) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.inputBg)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(currentAttempt >= maxAttempt)
                .opacity(currentAttempt >= maxAttempt ? 0.45 : 1)

                if maxAttempt > 0 {
                    Text("Attempt \(currentAttempt + 1) / \(maxAttempt + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(currentAttempt == maxAttempt ? Theme.success : Theme.textSecondary)
                }

                if newBlocksInLatest > 0 && currentAttempt < maxAttempt {
                    Button("\(newBlocksInLatest) new in latest") {
                        currentAttempt = maxAttempt
                        newBlocksInLatest = 0
                        follow = true
                        scrollRequest = UUID()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.warning)
                }

                Spacer()

                pillButton(follow ? "Following" : "Follow", icon: "dot.radiowaves.left.and.right") {
                    follow.toggle()
                    if follow {
                        scrollRequest = UUID()
                    }
                }

                pillButton(showContextPane ? "Hide Context" : "Context", icon: "sidebar.right") {
                    showContextPane.toggle()
                }

                pillButton("Refresh", icon: "arrow.clockwise") {
                    Task { await refresh() }
                }

                pillButton(hijacking ? "Hijacking..." : "Hijack", icon: "arrow.trianglehead.branch") {
                    startHijack()
                }
                .disabled(hijacking)
                .opacity(hijacking ? 0.6 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if !statusLine.isEmpty {
                HStack {
                    Text(statusLine)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .border(Theme.border, edges: [.bottom])
    }

    private func pillButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var hijackBanner: some View {
        if hijacking {
            banner(text: "Hijacking session...", color: Theme.accent)
        } else if let hijackError {
            banner(text: "Hijack error: \(hijackError)", color: Theme.danger)
        } else if replayFallback {
            banner(text: "Resume not supported by this agent. Conversation history is still available.", color: Theme.warning)
        } else if promptResumeAutomation {
            HStack(spacing: 10) {
                Text("Hijack session launched\(hijackReturnError.map { " (\($0))" } ?? "").")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("Resume automation", action: resumeAutomation)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.success)
                Button("Dismiss", action: dismissHijackPrompt)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.surface2)
            .border(Theme.border, edges: [.bottom])
        } else if hijackReturned {
            banner(text: "Returned from hijack session.", color: Theme.textTertiary)
        }
    }

    private func banner(text: String, color: Color) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface2)
        .border(Theme.border, edges: [.bottom])
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !displayBlocks.isEmpty {
                        ForEach(displayBlocks, id: \.stableId) { block in
                            transcriptBlockRow(block)
                        }
                    } else if loadingRun || loadingBlocks {
                        loadingBody
                    } else if let bodyError {
                        errorBody(bodyError)
                    } else {
                        emptyBody
                    }

                    if isStreamingIndicatorVisible {
                        Text("(streaming...)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(16)
            }
            .refreshable { await refresh() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2).onChanged { _ in
                    if follow {
                        follow = false
                    }
                }
            )
            .onChange(of: displayBlocks.count) { _, _ in
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: scrollRequest) { _, _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6)
            Text("Loading chat...")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func errorBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
            Button("Retry") {
                Task { await refresh() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private var emptyBody: some View {
        Text("No messages yet.")
            .font(.system(size: 12))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func transcriptBlockRow(_ block: ChatBlock) -> some View {
        let role = block.role.lowercased()
        let roleText = role.isEmpty ? "status" : role
        let timestamp = timestampLabel(for: block)
        let headerColor: Color = {
            switch role {
            case "assistant": return Theme.accent
            case "user": return Theme.success
            case "tool": return Theme.warning
            default: return Theme.textTertiary
            }
        }()

        let background: Color = {
            switch role {
            case "assistant": return Theme.bubbleAssistant
            case "user": return Theme.bubbleUser
            case "tool": return Theme.warning.opacity(0.10)
            default: return Theme.surface2.opacity(0.45)
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !timestamp.isEmpty {
                    Text(timestamp)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
                Text(roleText.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(headerColor)
                if let node = block.nodeId, !node.isEmpty, node != nodeId {
                    Text(node)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
            }

            Text(block.content)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(background)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private var contextPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Context")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                contextRow("Run", shortRunId)
                if let workflow = run?.workflowName {
                    contextRow("Workflow", workflow)
                }
                if let status = run?.status.rawValue {
                    contextRow("Status", status)
                }
                if let nodeLabel {
                    contextRow("Node", nodeLabel)
                }
                contextRow("Attempt", "\(currentAttempt + 1) / \(maxAttempt + 1)")
                contextRow("Blocks", "\(displayBlocks.count)")

                if let elapsed = run?.elapsedString, !elapsed.isEmpty {
                    contextRow("Elapsed", elapsed)
                }

                if !stateCounts.isEmpty {
                    Divider().background(Theme.border)
                    Text("Nodes")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                    ForEach(stateCounts, id: \.0) { state, count in
                        HStack {
                            Text(state)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                            Spacer()
                            Text("\(count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }

                if let errorJson = run?.errorJson, !errorJson.isEmpty {
                    Divider().background(Theme.border)
                    Text("Error")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.danger)
                    Text(errorJson)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private func contextRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
    }

    private func timestampLabel(for block: ChatBlock) -> String {
        guard let blockTS = block.timestampMs else { return "" }
        if let runStart = run?.startedAtMs {
            let delta = max(0, blockTS - runStart)
            return "[\(formatDuration(deltaMs: delta))]"
        }
        let date = Date(timeIntervalSince1970: Double(blockTS) / 1000.0)
        return "[\(DateFormatters.hourMinuteSecond.string(from: date))]"
    }

    private func formatDuration(deltaMs: Int64) -> String {
        let seconds = Int(deltaMs / 1000)
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m \(seconds % 60)s"
    }

    private func previousAttempt() {
        guard currentAttempt > 0 else { return }
        currentAttempt -= 1
        scrollRequest = UUID()
    }

    private func nextAttempt() {
        guard currentAttempt < maxAttempt else { return }
        currentAttempt += 1
        if currentAttempt == maxAttempt {
            newBlocksInLatest = 0
        }
        scrollRequest = UUID()
    }

    private func refresh() async {
        stopStreaming()
        await loadAll()
    }

    private func loadAll() async {
        async let runResult: () = loadRun()
        async let blocksResult: () = loadBlocks()
        _ = await (runResult, blocksResult)
    }

    private func loadRun() async {
        loadingRun = true
        runError = nil
        do {
            let inspection = try await smithers.inspectRun(runId)
            run = inspection.run
            tasks = inspection.tasks
        } catch {
            runError = error.localizedDescription
        }
        loadingRun = false
    }

    private func loadBlocks() async {
        loadingBlocks = true
        blocksError = nil
        streamDone = false
        bufferingInitialStream = true
        initialStreamBuffer = []

        // Start streaming immediately so messages appear while initial load is in progress
        startStreaming()

        do {
            var blocks = try await smithers.getChatOutput(runId)
            blocks = blocks.filter(matchesNodeFilter)
            let bufferedBlocks = initialStreamBuffer
            bufferingInitialStream = false
            initialStreamBuffer = []
            rebuildAttempts(with: blocks)
            for block in bufferedBlocks {
                appendStreamBlock(block)
            }
        } catch {
            bufferingInitialStream = false
            initialStreamBuffer = []
            // Only show error if we also have no streamed blocks
            if allBlocks.isEmpty {
                blocksError = error.localizedDescription
            }
        }

        loadingBlocks = false
    }

    private func startStreaming() {
        streamTask?.cancel()
        streamTask = nil
        let generation = UUID()
        streamGeneration = generation
        streamDone = false
        streamTask = Task {
            for await event in smithers.streamChat(runId) {
                if Task.isCancelled { break }
                guard let block = decodeStreamEvent(event) else { continue }
                await MainActor.run {
                    guard streamGeneration == generation, !Task.isCancelled else { return }
                    appendStreamBlock(block)
                }
            }
            await MainActor.run {
                guard streamGeneration == generation, !Task.isCancelled else { return }
                streamDone = true
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        streamGeneration = UUID()
        bufferingInitialStream = false
        initialStreamBuffer = []
    }

    private func decodeStreamEvent(_ event: SSEEvent) -> ChatBlock? {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }

        if let block = try? JSONDecoder().decode(ChatBlock.self, from: data) {
            return block
        }
        if let wrapped = try? JSONDecoder().decode(StreamBlockEnvelope.self, from: data) {
            return wrapped.block ?? wrapped.data
        }
        return nil
    }

    private func appendStreamBlock(_ block: ChatBlock) {
        guard matchesNodeFilter(block) else { return }
        if bufferingInitialStream {
            initialStreamBuffer.append(block)
        }

        if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
            if replaceExistingStreamBlock(block, lifecycleId: lifecycleId) {
                if follow {
                    scrollRequest = UUID()
                }
                return
            }
        } else if replaceLastAnonymousAssistantStreamBlock(block) {
            if follow {
                scrollRequest = UUID()
            }
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

        if follow {
            scrollRequest = UUID()
        }
    }

    private func rebuildAttempts(with blocks: [ChatBlock]) {
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
        if follow {
            scrollRequest = UUID()
        }
    }

    private func indexBlock(_ block: ChatBlock) {
        let attempt = block.attemptIndex
        attempts[attempt, default: []].append(block)
        if attempt > maxAttempt {
            maxAttempt = attempt
        }
    }

    private func replaceExistingStreamBlock(_ block: ChatBlock, lifecycleId: String) -> Bool {
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

    private func replaceLastAnonymousAssistantStreamBlock(_ block: ChatBlock) -> Bool {
        guard block.lifecycleId == nil else { return false }
        guard let index = allBlocks.indices.last else { return false }
        let existing = allBlocks[index]
        guard existing.lifecycleId == nil,
              existing.canMergeAssistantStream(with: block),
              existing.hasStreamingContentOverlap(with: block) else {
            return false
        }

        allBlocks[index] = existing.mergingAssistantStream(with: block)
        rebuildAttemptIndexPreservingSelection()
        return true
    }

    private func rebuildAttemptIndexPreservingSelection() {
        let selectedAttempt = currentAttempt
        attempts = [:]
        maxAttempt = 0

        for block in allBlocks {
            indexBlock(block)
        }

        currentAttempt = min(selectedAttempt, maxAttempt)
    }

    private func matchesNodeFilter(_ block: ChatBlock) -> Bool {
        guard let nodeId, !nodeId.isEmpty else { return true }
        return block.nodeId == nodeId
    }

    private func startHijack() {
        guard !hijacking else { return }

        hijacking = true
        hijackError = nil
        replayFallback = false

        Task { @MainActor in
            do {
                let session = try await smithers.hijackRun(runId)
                hijacking = false

                if !session.supportsResume {
                    replayFallback = true
                    appendStatusBlock("Agent does not support native resume. Conversation history remains available here.")
                    return
                }

                do {
                    try await launchHijackSession(session)
                    hijackReturned = true
                    promptResumeAutomation = true
                    appendStatusBlock("--------- HIJACK SESSION LAUNCHED ---------")
                    await loadRun()
                } catch {
                    hijackError = error.localizedDescription
                }
            } catch {
                hijacking = false
                hijackError = error.localizedDescription
            }
        }
    }

    private func resumeAutomation() {
        promptResumeAutomation = false
        hijackReturned = false
        appendStatusBlock("Resuming automation...")
        Task { await refresh() }
    }

    private func dismissHijackPrompt() {
        promptResumeAutomation = false
        hijackReturned = false
    }

    private func appendStatusBlock(_ message: String) {
        let block = ChatBlock(
            id: UUID().uuidString,
            runId: runId,
            nodeId: nodeId,
            attempt: maxAttempt,
            role: "system",
            content: message,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        allBlocks.append(block)
        indexBlock(block)
        if follow {
            scrollRequest = UUID()
        }
    }

    private func launchHijackSession(_ session: HijackSession) async throws {
        guard let invocation = session.launchInvocation() else {
            throw SmithersError.api("Hijack session is missing resume details")
        }

        #if os(macOS)
        let quotedArgs = invocation.arguments.map(shellQuote).joined(separator: " ")
        let command = "cd \(shellQuote(invocation.workingDirectory)); \(shellQuote(invocation.executable)) \(quotedArgs)"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(command))
        end tell
        """

        try await Self.runHijackLaunchScript(script)
        #else
        throw SmithersError.notAvailable("Hijack handoff is only available on macOS")
        #endif
    }

    #if os(macOS)
    private nonisolated static func runHijackLaunchScript(_ script: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutCollector = HijackProcessOutputBuffer()
            let stderrCollector = HijackProcessOutputBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutCollector.append(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrCollector.append(handle.availableData)
            }
            defer {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
            }

            try process.run()
            process.waitUntilExit()

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())

            guard process.terminationStatus == 0 else {
                let errText = String(decoding: stderrCollector.snapshot(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let outText = String(decoding: stdoutCollector.snapshot(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = errText.isEmpty ? outText : errText
                throw SmithersError.cli(message.isEmpty ? "Failed to launch hijack terminal session" : message)
            }
        }.value
    }
    #endif

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

#if os(macOS)
private final class HijackProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}
#endif

private struct StreamBlockEnvelope: Decodable {
    let block: ChatBlock?
    let data: ChatBlock?
}
