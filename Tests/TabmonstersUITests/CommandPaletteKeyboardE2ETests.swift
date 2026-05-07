import XCTest

final class CommandPaletteKeyboardE2ETests: SmithersGUIUITestCase {
    func testCommandPOpensAndEscapeClosesLauncher() {
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(element("commandPalette.root").waitForExistence(timeout: 3))

        app.typeKey(.escape, modifierFlags: [])

        let disappears = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element("commandPalette.root")
        )
        wait(for: [disappears], timeout: 3)
    }

    func testCommandShiftPOpensCommandMode() {
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("commandPalette.root").waitForExistence(timeout: 3))
        XCTAssertTrue(element("commandPalette.mode").waitForExistence(timeout: 3))
        XCTAssertEqual(element("commandPalette.mode").label, "Command Mode")
    }

    func testCommandKOpensAskAIMode() {
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element("commandPalette.root").waitForExistence(timeout: 3))
        XCTAssertTrue(element("commandPalette.mode").waitForExistence(timeout: 3))
        XCTAssertEqual(element("commandPalette.mode").label, "Ask AI")
    }

    func testCommandTCreatesTerminalTabAndNavigates() {
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(element("view.terminal").waitForExistence(timeout: 5))
    }
}
