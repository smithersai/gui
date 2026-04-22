import XCTest

class SmithersGUIUITestCase: XCTestCase {
    private static let defaultWorkspacePath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }()

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
            "SMITHERS_OPEN_WORKSPACE": Self.defaultWorkspacePath,
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
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func waitForElement(_ identifier: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(identifier)
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "Missing element: \(identifier)", file: file, line: line)
        return found
    }

    func navigate(to label: String, expectedViewIdentifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let navButton = app.buttons[navigationButtonIdentifier(for: label)]
        if navButton.waitForExistence(timeout: 5) {
            navButton.click()
            XCTAssertTrue(
                element(expectedViewIdentifier).waitForExistence(timeout: 8),
                "Missing view after navigating to \(label): \(expectedViewIdentifier)",
                file: file,
                line: line
            )
            return
        }

        let route = paletteRoute(for: label)
        navigateViaPalette(
            query: route.query,
            itemIdentifier: route.itemIdentifier,
            preferredLabel: route.displayLabel,
            expectedViewIdentifier: expectedViewIdentifier,
            file: file,
            line: line
        )
    }

    func navigateViaPalette(
        query: String,
        itemIdentifier: String? = nil,
        preferredLabel: String? = nil,
        expectedViewIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openCommandPalette(file: file, line: line)

        let input = waitForElement("commandPalette.input", timeout: 5, file: file, line: line)
        input.click()
        input.typeText(query)
        Thread.sleep(forTimeInterval: 0.4)

        var activated = false
        if let itemIdentifier {
            let item = app.buttons.matching(identifier: itemIdentifier).firstMatch
            if item.waitForExistence(timeout: 2) {
                item.click()
                activated = true
            }
        }

        if !activated, let preferredLabel {
            let labelMatch = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", preferredLabel)).firstMatch
            if labelMatch.waitForExistence(timeout: 2) {
                labelMatch.click()
                activated = true
            }
        }

        if !activated {
            Thread.sleep(forTimeInterval: 0.3)
            app.typeKey(.return, modifierFlags: [])
        }

        XCTAssertTrue(
            element(expectedViewIdentifier).waitForExistence(timeout: 8),
            "Missing view after navigating via palette to \(query): \(expectedViewIdentifier)",
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

    private func paletteRoute(for label: String) -> (query: String, displayLabel: String, itemIdentifier: String) {
        let displayLabel: String
        switch label {
        case "Smithers":
            displayLabel = "Dashboard"
        case "VCSDashboard":
            displayLabel = "VCS Dashboard"
        default:
            displayLabel = label
        }

        let query = displayLabel
        let token = displayLabel
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeToken = token
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        return (query, displayLabel, "commandPalette.item.route-\(safeToken)")
    }

    private func navigationButtonIdentifier(for label: String) -> String {
        let navLabel: String
        switch label {
        case "Smithers":
            navLabel = "Dashboard"
        default:
            navLabel = label
        }

        return "nav.\(navLabel.replacingOccurrences(of: " ", with: ""))"
    }

    private func openCommandPalette(file: StaticString = #filePath, line: UInt = #line) {
        if element("commandPalette.root").exists {
            return
        }

        let openLauncherButton = element("shortcut.openLauncher")
        for attempt in 0..<3 {
            if attempt == 0 {
                app.typeKey("p", modifierFlags: .command)
            } else if openLauncherButton.waitForExistence(timeout: 1) {
                openLauncherButton.click()
            } else {
                app.typeKey("p", modifierFlags: .command)
            }

            if element("commandPalette.root").waitForExistence(timeout: 2) {
                return
            }
        }

        XCTAssertTrue(
            element("commandPalette.root").waitForExistence(timeout: 1),
            "Command palette did not open",
            file: file,
            line: line
        )
    }
}
