import XCTest

final class ChatE2ETests: SmithersGUIUITestCase {
    func testChatTargetPickerShowsSmithersAndExternalAgentOptions() {
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))

        XCTAssertTrue(element("chat.targetPicker").waitForExistence(timeout: 5))
        XCTAssertTrue(element("chat.target.smithers").exists)
        XCTAssertTrue(element("chat.target.codex").waitForExistence(timeout: 5))

        chooseSmithersChatTargetIfNeeded()
    }

    func testWelcomeStateMessageSendSlashPaletteAndSendStopToggle() {
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))
        chooseSmithersChatTargetIfNeeded()

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
