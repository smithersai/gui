import XCTest
@testable import SmithersGUI

@MainActor
final class RunNotificationTrackerTests: XCTestCase {
    func testShouldToastRunStatusFirstCall() {
        var tracker = RunNotificationTracker()
        XCTAssertTrue(tracker.shouldToastRunStatus(runId: "run-1", status: .running))
    }

    func testShouldToastRunStatusDeduplicatesDuplicateStatus() {
        var tracker = RunNotificationTracker()
        XCTAssertTrue(tracker.shouldToastRunStatus(runId: "run-1", status: .running))
        XCTAssertFalse(tracker.shouldToastRunStatus(runId: "run-1", status: .running))
    }

    func testForgetRunAllowsRetoast() {
        var tracker = RunNotificationTracker()
        XCTAssertTrue(tracker.shouldToastRunStatus(runId: "run-1", status: .failed))
        tracker.forgetRun("run-1")
        XCTAssertTrue(tracker.shouldToastRunStatus(runId: "run-1", status: .failed))
    }

    func testShouldToastApprovalDeduplicatesByApprovalID() {
        var tracker = RunNotificationTracker()
        XCTAssertTrue(tracker.shouldToastApproval("approval-1"))
        XCTAssertFalse(tracker.shouldToastApproval("approval-1"))
        XCTAssertTrue(tracker.shouldToastApproval("approval-2"))
    }
}

@MainActor
final class AppNotificationsTests: XCTestCase {
    private final class NativeSenderMock: NativeNotificationSending {
        private(set) var notifications: [(title: String, message: String)] = []

        func send(title: String, message: String) {
            notifications.append((title: title, message: message))
        }
    }

    func testPostAndDismiss() {
        let native = NativeSenderMock()
        let notifications = AppNotifications(nativeNotifications: native)

        notifications.post(title: "Hello", message: "World", level: .info, duration: 30)
        XCTAssertEqual(notifications.toasts.count, 1)

        let toast = try? XCTUnwrap(notifications.toasts.first)
        XCTAssertNotNil(toast)
        if let toast {
            notifications.dismiss(toast.id)
        }

        XCTAssertEqual(notifications.toasts.count, 0)
    }

    func testAutoDismissAfterDuration() async {
        let native = NativeSenderMock()
        let notifications = AppNotifications(nativeNotifications: native)

        notifications.post(title: "Short", message: "Timer", level: .info, duration: 0.05)
        XCTAssertEqual(notifications.toasts.count, 1)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(notifications.toasts.count, 0)
    }

    func testMaxVisibleToastsEvictsOldest() {
        let native = NativeSenderMock()
        let notifications = AppNotifications(nativeNotifications: native)

        notifications.post(title: "1", message: "", level: .info, duration: 30)
        notifications.post(title: "2", message: "", level: .info, duration: 30)
        notifications.post(title: "3", message: "", level: .info, duration: 30)
        notifications.post(title: "4", message: "", level: .info, duration: 30)

        XCTAssertEqual(notifications.toasts.count, AppNotifications.maxVisibleToasts)
        XCTAssertEqual(notifications.toasts.map(\.title), ["2", "3", "4"])
    }

    func testNativeNotificationWhenInactive() {
        let native = NativeSenderMock()
        let notifications = AppNotifications(nativeNotifications: native)
        notifications.setAppActiveForTesting(false)

        notifications.post(
            title: "Background completion",
            message: "Run finished",
            level: .completion,
            duration: 30,
            nativeWhenInactive: true
        )

        XCTAssertEqual(native.notifications.count, 1)
        XCTAssertEqual(native.notifications.first?.title, "Background completion")
    }
}
