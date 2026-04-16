import XCTest

class SmithersGUIUITestCase: XCTestCase {
    var app: XCUIApplication!
    var launchArguments: [String] { ["--uitesting"] }
    var launchEnvironmentOverrides: [String: String] { [:] }

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Clear saved application state to prevent crash-recovery dialogs
        let savedStateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.smithers.SmithersGUI.savedState")
        try? FileManager.default.removeItem(at: savedStateDir)

        app = XCUIApplication()
        app.launchArguments = launchArguments
        var launchEnvironment: [String: String] = [
            "SMITHERS_GUI_UITEST": "1",
            "SMITHERS_GUI_DISABLE_ANIMATIONS": "1",
        ]
        launchEnvironment.merge(launchEnvironmentOverrides) { _, new in new }
        app.launchEnvironment = launchEnvironment
        app.launch()

        if !app.wait(for: .runningForeground, timeout: 40) {
            app.terminate()
            app.launch()
        }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 40))
        XCTAssertTrue(element("sidebar").waitForExistence(timeout: 30))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func waitForElement(_ identifier: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(identifier)
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "Missing element: \(identifier)", file: file, line: line)
        return found
    }

    func navigate(to label: String, expectedViewIdentifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let navIdentifier = "nav.\(label.replacingOccurrences(of: " ", with: ""))"
        var nav = app.buttons[navIdentifier]
        if !nav.waitForExistence(timeout: 1.5) {
            expandSidebarSectionIfNeeded(for: label)
            nav = app.buttons[navIdentifier]
            if !nav.waitForExistence(timeout: 1.5) {
                // Section toggles can land in the opposite state under UI-test timing.
                // Try one more toggle before failing.
                expandSidebarSectionIfNeeded(for: label)
                nav = app.buttons[navIdentifier]
            }
        }
        XCTAssertTrue(nav.waitForExistence(timeout: 8), "Missing nav row for \(label)", file: file, line: line)
        nav.click()
        XCTAssertTrue(element(expectedViewIdentifier).waitForExistence(timeout: 8), "Missing view after navigating to \(label): \(expectedViewIdentifier)", file: file, line: line)
    }

    func expandSidebarSectionIfNeeded(for label: String) {
        let smithersLabels: Set<String> = [
            "Dashboard", "Agents", "Runs", "Snapshots", "Workflows", "Triggers", "Approvals",
            "Prompts", "Scores", "Memory", "Search", "SQL Browser", "Workspaces",
            "Logs",
        ]
        let vcsLabels: Set<String> = [
            "Changes", "JJHub Workflows", "Landings", "Tickets", "Issues",
        ]

        if smithersLabels.contains(label) {
            let section = app.buttons["sidebar.section.SMITHERS"]
            if section.waitForExistence(timeout: 2) {
                section.click()
            }
        } else if vcsLabels.contains(label) {
            let section = app.buttons["sidebar.section.VCS"]
            if section.waitForExistence(timeout: 2) {
                section.click()
            }
        }
    }

    func chooseSmithersChatTargetIfNeeded(file: StaticString = #filePath, line: UInt = #line) {
        let picker = element("chat.targetPicker")
        if picker.waitForExistence(timeout: 1.5) {
            let smithersTarget = waitForElement("chat.target.smithers", timeout: 5, file: file, line: line)
            smithersTarget.click()
        }

        XCTAssertTrue(
            element("chat.surface").waitForExistence(timeout: 5),
            "Chat surface should be visible after selecting Smithers target",
            file: file,
            line: line
        )
    }

    func typeInto(_ identifier: String, _ text: String, submit: Bool = false) {
        let field = waitForElement(identifier)
        field.click()
        field.typeText(text)
        if submit {
            app.typeKey(.return, modifierFlags: [])
        }
    }

    func sessionButtonCount() -> Int {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "tab.chat:")
        return app.buttons.matching(predicate).count
    }
}
