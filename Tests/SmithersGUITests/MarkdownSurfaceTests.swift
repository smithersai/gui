import XCTest
@testable import SmithersGUI

@MainActor
final class MarkdownSurfaceModelTests: XCTestCase {
    private let retryPolicy = MarkdownFileWatcherRetryPolicy(
        maxAttempts: 3,
        interval: .milliseconds(50),
        pollInterval: .milliseconds(75)
    )

    func testOpeningMarkdownFileLoadsContent() throws {
        let fileURL = try makeMarkdownFile(contents: "# Plan\n\nInitial")
        let model = MarkdownSurfaceModel(
            surfaceId: UUID().uuidString,
            filePath: fileURL.path,
            retryPolicy: retryPolicy
        )
        defer { model.stop() }

        XCTAssertEqual(model.content, "# Plan\n\nInitial")
        XCTAssertEqual(model.availability, .available)
    }

    func testSimpleWriteReloadsContent() async throws {
        let fileURL = try makeMarkdownFile(contents: "Before")
        let model = MarkdownSurfaceModel(
            surfaceId: UUID().uuidString,
            filePath: fileURL.path,
            retryPolicy: retryPolicy
        )
        defer { model.stop() }

        await assertEventually { model.watcherState == .watchingFile }
        try "After".write(to: fileURL, atomically: false, encoding: .utf8)

        await assertEventually { model.content == "After" }
        XCTAssertEqual(model.availability, .available)
    }

    func testAtomicRenameReattachesToNewInode() async throws {
        let fileURL = try makeMarkdownFile(contents: "Before")
        let model = MarkdownSurfaceModel(
            surfaceId: UUID().uuidString,
            filePath: fileURL.path,
            retryPolicy: retryPolicy
        )
        defer { model.stop() }

        await assertEventually { model.watcherState == .watchingFile }
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
        try "After atomic rename".write(to: tempURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(rename(tempURL.path, fileURL.path), 0)

        await assertEventually { model.content == "After atomic rename" }
        XCTAssertEqual(model.availability, .available)
        await assertEventually { model.watcherState == .watchingFile }
    }

    func testDeleteThenRecreateWithinRetryWindowReconnects() async throws {
        let fileURL = try makeMarkdownFile(contents: "Before")
        let model = MarkdownSurfaceModel(
            surfaceId: UUID().uuidString,
            filePath: fileURL.path,
            retryPolicy: retryPolicy
        )
        defer { model.stop() }

        await assertEventually { model.watcherState == .watchingFile }
        try FileManager.default.removeItem(at: fileURL)
        try await Task.sleep(nanoseconds: 80_000_000)
        try "Back quickly".write(to: fileURL, atomically: true, encoding: .utf8)

        await assertEventually { model.content == "Back quickly" }
        XCTAssertEqual(model.availability, .available)
    }

    func testDeletedAndStaysDeletedShowsUnavailableThenPollsForReappearance() async throws {
        let fileURL = try makeMarkdownFile(contents: "Before")
        let shortRetryPolicy = MarkdownFileWatcherRetryPolicy(
            maxAttempts: 2,
            interval: .milliseconds(40),
            pollInterval: .milliseconds(60)
        )
        let model = MarkdownSurfaceModel(
            surfaceId: UUID().uuidString,
            filePath: fileURL.path,
            retryPolicy: shortRetryPolicy
        )
        defer { model.stop() }

        await assertEventually { model.watcherState == .watchingFile }
        try FileManager.default.removeItem(at: fileURL)

        await assertEventually(timeout: 1.5) {
            if case .unavailable = model.availability {
                return true
            }
            return false
        }
        await assertEventually { model.watcherState == .watchingDirectory }

        try "Back later".write(to: fileURL, atomically: true, encoding: .utf8)

        await assertEventually(timeout: 1.5) { model.content == "Back later" }
        XCTAssertEqual(model.availability, .available)
    }

    private func makeMarkdownFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smithers-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("plan.md", isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    private func assertEventually(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await waitUntil(timeout: timeout, condition: condition)
        XCTAssertTrue(result, file: file, line: line)
    }
}

final class MarkdownShellTests: XCTestCase {
    func testShellLoadsMarkedMermaidHighlightAndSystemThemeBridge() throws {
        let html = try String(contentsOf: sourceRoot()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("MarkdownShell", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false))

        XCTAssertTrue(html.contains("marked.min.js"))
        XCTAssertTrue(html.contains("mermaid.min.js"))
        XCTAssertTrue(html.contains("highlight.min.js"))
        XCTAssertTrue(html.contains("window.matchMedia"))
        XCTAssertTrue(html.contains("window.smithersMarkdown"))
        XCTAssertTrue(html.contains("setContent"))
        XCTAssertTrue(html.contains("mermaid.run"))
        XCTAssertTrue(html.contains("highlightElement"))
        XCTAssertTrue(html.contains("language-mermaid"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
    }

    func testSetContentScriptJSONEscapesMarkdown() {
        let markdown = "Title \"quoted\"\n</script>"
        let script = MarkdownWebViewRepresentable.setContentScript(for: markdown)

        XCTAssertTrue(script.hasPrefix("window.smithersMarkdown.setContent("))
        XCTAssertTrue(script.hasSuffix(");"))
        XCTAssertFalse(script.contains("\n</script>"))
        XCTAssertTrue(script.contains(#"\"quoted\""#))
    }

    func testExternalLinksUseDefaultExternalOpenPolicy() {
        XCTAssertTrue(MarkdownExternalLinkPolicy.shouldOpenExternally(
            url: URL(string: "https://smithers.sh/docs"),
            navigationType: .linkActivated,
            targetFrameIsMainFrame: true
        ))
        XCTAssertFalse(MarkdownExternalLinkPolicy.shouldOpenExternally(
            url: URL(string: "file:///tmp/index.html#section"),
            navigationType: .linkActivated,
            targetFrameIsMainFrame: true
        ))
        XCTAssertFalse(MarkdownExternalLinkPolicy.shouldOpenExternally(
            url: URL(string: "https://smithers.sh/docs"),
            navigationType: .other,
            targetFrameIsMainFrame: true
        ))
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
final class MarkdownWorkspaceSurfaceTests: XCTestCase {
    func testMarkdownSurfaceUsesWorkspaceIdentityAndCleansNotificationsOnClose() {
        let store = SessionStore()
        let terminalId = store.addTerminalTab(title: "Docs")
        let workspace = store.ensureTerminalWorkspace(terminalId)
        let filePath = "/tmp/smithers-plan.md"

        let surfaceId = workspace.addMarkdown(filePath: filePath)
        let surface = workspace.surfaces[surfaceId]

        XCTAssertEqual(surface?.kind, .markdown)
        XCTAssertEqual(surface?.markdownFilePath, filePath)
        XCTAssertEqual(surface?.title, "smithers-plan.md")
        XCTAssertEqual(workspace.focusedSurfaceId, surfaceId)
        XCTAssertEqual(SurfaceNotificationStore.shared.surfaceWorkspaceIds[surfaceId.rawValue], terminalId)
        XCTAssertTrue(workspace.displayPreview.contains("markdown"))

        store.removeTerminalTab(terminalId)

        XCTAssertNil(SurfaceNotificationStore.shared.surfaceWorkspaceIds[surfaceId.rawValue])
    }
}
