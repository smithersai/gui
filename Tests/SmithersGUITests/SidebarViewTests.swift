import SwiftUI
import ViewInspector
import XCTest
@testable import SmithersGUI

@MainActor
final class SidebarViewTests: XCTestCase {
    private func projectSource(_ filename: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SmithersGUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeSidebar(
        store: SessionStore,
        destination: Binding<NavDestination>,
        developerDebugAvailable: Bool = false
    ) -> SidebarView {
        SidebarView(
            store: store,
            destination: destination,
            developerDebugAvailable: developerDebugAvailable
        )
    }

    private func textStrings<V: View>(in view: V) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    func testSidebarShowsAppTitleAndSettingsEntry() throws {
        let store = SessionStore()
        var destination: NavDestination = .dashboard
        let sidebar = makeSidebar(
            store: store,
            destination: Binding(get: { destination }, set: { destination = $0 })
        )

        let labels = try textStrings(in: sidebar)
        XCTAssertTrue(labels.contains("Smithers"))
        XCTAssertTrue(labels.contains("Settings"))
    }

    func testSidebarRendersSessionTabsFromStore() throws {
        let store = SessionStore()
        store.sendMessage("Alpha thread")
        var destination: NavDestination = .chat
        let sidebar = makeSidebar(
            store: store,
            destination: Binding(get: { destination }, set: { destination = $0 })
        )

        let labels = try textStrings(in: sidebar)
        XCTAssertTrue(labels.contains("Alpha thread"))
    }

    func testSidebarRendersTerminalTabFromStore() throws {
        let store = SessionStore()
        _ = store.addTerminalTab(title: "Build Logs")

        var destination: NavDestination = .dashboard
        let sidebar = makeSidebar(
            store: store,
            destination: Binding(get: { destination }, set: { destination = $0 })
        )

        let labels = try textStrings(in: sidebar)
        XCTAssertTrue(labels.contains("Build Logs"))
    }

    func testSearchFieldExists() throws {
        let store = SessionStore()
        var destination: NavDestination = .dashboard
        let sidebar = makeSidebar(
            store: store,
            destination: Binding(get: { destination }, set: { destination = $0 })
        )

        let textFields = try sidebar.inspect().findAll(ViewType.TextField.self)
        XCTAssertGreaterThanOrEqual(textFields.count, 1)
    }

    func testDeveloperDebugEntryIsHiddenByDefault() throws {
        let store = SessionStore()
        var destination: NavDestination = .dashboard
        let sidebar = makeSidebar(
            store: store,
            destination: Binding(get: { destination }, set: { destination = $0 }),
            developerDebugAvailable: false
        )

        let labels = try textStrings(in: sidebar)
        XCTAssertFalse(labels.contains("Developer Debug"))
    }

    func testDeveloperDebugEntryIsVisibleWhenEnabled() throws {
        let store = SessionStore()
        var destination: NavDestination = .dashboard
        let sidebar = makeSidebar(
            store: store,
            destination: Binding(get: { destination }, set: { destination = $0 }),
            developerDebugAvailable: true
        )

        let labels = try textStrings(in: sidebar)
        XCTAssertTrue(labels.contains("Developer Debug"))
    }

    func testNewChatMenuIncludesChatAndTerminalActions() throws {
        let row = NewChatMenuRow(newChatAction: {}, terminalAction: {})
        let labels = try textStrings(in: row)

        XCTAssertTrue(labels.contains("New Chat"))
        XCTAssertTrue(labels.contains("Terminal"))
    }

    func testSessionRowHidesEmptyPreview() throws {
        let session = ChatSession(
            id: "id",
            title: "Thread",
            preview: "",
            timestamp: "just now",
            group: "Today"
        )
        let row = SessionRow(session: session, isSelected: false, action: {})

        let labels = try textStrings(in: row)
        XCTAssertTrue(labels.contains("Thread"))
        XCTAssertTrue(labels.contains("just now"))
        XCTAssertEqual(labels.count, 2)
    }

    func testTerminateTerminalActionUsesConfirmationDialog() throws {
        let source = try projectSource("SidebarView.swift")

        XCTAssertTrue(
            source.contains("confirmationDialog(\n            \"Terminate Terminal?\""),
            "Sidebar should present a confirmation dialog before terminal termination."
        )
        XCTAssertTrue(
            source.contains("Button(\"Terminate terminal\", role: .destructive) {\n                                    requestTerminateTerminal(terminalId: terminalId, title: tab.title)"),
            "Terminal context action should request confirmation instead of removing immediately."
        )
        XCTAssertTrue(
            source.contains("store.removeTerminalTab(terminalId)"),
            "Confirmed terminal termination should still remove the terminal tab."
        )
    }
}
