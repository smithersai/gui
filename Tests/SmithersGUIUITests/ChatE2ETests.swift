import XCTest

final class ChatE2ETests: SmithersGUIUITestCase {
    func testWelcomeStateMessageSendSlashPaletteAndSendStopToggle() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")

        XCTAssertTrue(element("chat.emptyState").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What can I help you build?"].exists)

        typeInto("chat.input", "Hello from XCUITest")
        waitForElement("chat.sendButton").click()

        XCTAssertTrue(app.staticTexts["Hello from XCUITest"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("chat.stopButton").waitForExistence(timeout: 2), "Send button should toggle to stop while the simulated turn is running")
        XCTAssertTrue(app.staticTexts["UI test response for: Hello from XCUITest"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("chat.sendButton").waitForExistence(timeout: 5), "Stop button should toggle back to send after the simulated turn completes")

        typeInto("chat.input", "/")
        XCTAssertTrue(element("chat.slashPalette").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["/help"].exists || app.staticTexts["/dashboard"].exists)
    }
}
