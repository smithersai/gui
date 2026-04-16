import AppKit
import XCTest
@testable import SmithersGUI

final class RunStatusPillTests: XCTestCase {

    // MARK: - Label mapping

    func testAllStatusesHaveNonEmptyLabels() {
        for status in RunStatus.allCases {
            XCTAssertFalse(status.label.isEmpty, "\(status) should have a non-empty label")
        }
    }

    func testRunningLabel() {
        XCTAssertEqual(RunStatus.running.label, "RUNNING")
    }

    func testFinishedLabel() {
        XCTAssertEqual(RunStatus.finished.label, "FINISHED")
    }

    func testFailedLabel() {
        XCTAssertEqual(RunStatus.failed.label, "FAILED")
    }

    func testWaitingApprovalLabel() {
        XCTAssertEqual(RunStatus.waitingApproval.label, "APPROVAL")
    }

    func testCancelledLabel() {
        XCTAssertEqual(RunStatus.cancelled.label, "CANCELLED")
    }

    func testUnknownLabel() {
        XCTAssertEqual(RunStatus.unknown.label, "UNKNOWN")
    }

    // MARK: - Color mapping (every status maps to a documented color)

    func testRunningColorIsAccent() {
        XCTAssertEqual(RunStatus.running.statusColor, Theme.accent)
    }

    func testFinishedColorIsSuccess() {
        XCTAssertEqual(RunStatus.finished.statusColor, Theme.success)
    }

    func testWaitingApprovalColorIsWarning() {
        XCTAssertEqual(RunStatus.waitingApproval.statusColor, Theme.warning)
    }

    func testFailedColorIsDanger() {
        XCTAssertEqual(RunStatus.failed.statusColor, Theme.danger)
    }

    func testCancelledColorIsMuted() {
        XCTAssertEqual(RunStatus.cancelled.statusColor, Theme.textTertiary)
    }

    func testUnknownColorIsSecondary() {
        XCTAssertEqual(RunStatus.unknown.statusColor, Theme.textSecondary)
    }

    // MARK: - Copy run ID action

    func testCopyRunIdPutsStringOnPasteboard() {
        let runId = "run_test_abc123"
        RunStatusPill.copyRunId(runId)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, runId)
    }

    func testCopyRunIdOverwritesPreviousPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("old_value", forType: .string)
        RunStatusPill.copyRunId("new_run_id")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "new_run_id")
    }

    func testCopyEmptyRunId() {
        RunStatusPill.copyRunId("")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "")
    }
}
