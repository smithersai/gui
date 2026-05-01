import XCTest
import AppKit

final class OutputTabE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH": "1",
        ]
    }

    func testFinishedTaskRendersOutput() {
        openOutputTab(forTreeRow: 3)
        XCTAssertTrue(element("output.copy.status").waitForExistence(timeout: 10))
    }

    func testPendingTaskAutoRefreshesToProduced() {
        openOutputTab(forTreeRow: 5)
        XCTAssertTrue(element("output.copy.rating").waitForExistence(timeout: 8))
    }

    func testFailedTaskShowsPartialOutput() {
        openOutputTab(forTreeRow: 6)
        XCTAssertTrue(element("output.failed.partial.toggle").waitForExistence(timeout: 10))
        XCTAssertTrue(element("output.failed.partial.value").waitForExistence(timeout: 5))
    }

    func testCopyFieldValueWritesPasteboard() {
        openOutputTab(forTreeRow: 3)
        XCTAssertTrue(element("output.copy.status").waitForExistence(timeout: 10))

        waitForElement("output.copy.status").click()

        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(copied, "ready")
    }

    func testExpandAndCollapseNestedObject() {
        openOutputTab(forTreeRow: 5)
        XCTAssertTrue(element("output.copy.rating").waitForExistence(timeout: 8))

        let expandButton = app.buttons["Expand object with 2 keys"]
        XCTAssertTrue(expandButton.waitForExistence(timeout: 3))
        expandButton.click()

        XCTAssertTrue(app.staticTexts["summary:"].waitForExistence(timeout: 3))

        let collapseButton = app.buttons["Collapse object with 2 keys"]
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 3))
        collapseButton.click()

        XCTAssertFalse(app.staticTexts["summary:"].waitForExistence(timeout: 1.5))
    }

    private func openLiveRunTreeHarness() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 5))
    }

    private func openOutputTab(forTreeRow rowId: Int) {
        openLiveRunTreeHarness()

        let expectedNodeId = expectedInspectorNodeId(forTreeRow: rowId)
        let outputTab = waitForElement("inspector.tab.output", timeout: 10)

        for _ in 0..<4 {
            guard safeClick("tree.row.\(rowId)", timeout: 8) else { continue }
            if let expectedNodeId, !waitForInspectorNodeId(expectedNodeId, timeout: 3) {
                continue
            }

            for _ in 0..<3 {
                guard outputTab.isHittable else { continue }
                outputTab.click()
                if element("inspector.tab.content.output").waitForExistence(timeout: 2) {
                    if let expectedNodeId {
                        if waitForInspectorNodeId(expectedNodeId, timeout: 2) {
                            return
                        }
                    } else {
                        return
                    }
                }
            }
        }

        XCTFail("Failed to open output tab for tree.row.\(rowId)")
    }

    private func expectedInspectorNodeId(forTreeRow rowId: Int) -> String? {
        switch rowId {
        case 3:
            return "task:fetch"
        case 5:
            return "task:review:0"
        case 6:
            return "task:review:1"
        default:
            return nil
        }
    }

    private func waitForInspectorNodeId(_ expectedNodeId: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentInspectorNodeId() == expectedNodeId {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return false
    }

    private func currentInspectorNodeId() -> String? {
        let copyNodeId = element("inspector.header.copyNodeId")
        guard copyNodeId.waitForExistence(timeout: 1), copyNodeId.isHittable else {
            return nil
        }
        copyNodeId.click()
        return NSPasteboard.general.string(forType: .string)
    }

    private func safeClick(_ identifier: String, timeout: TimeInterval) -> Bool {
        let target = waitForElement(identifier, timeout: timeout)
        guard target.isHittable else {
            return false
        }
        target.click()
        return true
    }
}
