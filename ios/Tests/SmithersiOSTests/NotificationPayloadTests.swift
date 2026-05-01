#if os(iOS)
import UserNotifications
import XCTest
@testable import SmithersiOS

final class NotificationPayloadTests: XCTestCase {
    func testParseNestedAPNSPayloadForApproveAction() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": [
                    "title": "Approval requested",
                    "body": "Deploy production",
                ],
                "category": ApprovalNotificationIdentifier.category,
            ] as [String: Any],
            "payload": [
                "approval_id": "approval-123",
                "repo_owner": "acme",
                "repo_name": "widgets",
            ] as [String: Any],
        ]

        let payload = try XCTUnwrap(NotificationPayload.parse(
            userInfo,
            actionIdentifier: ApprovalNotificationIdentifier.approveAction
        ))

        XCTAssertEqual(payload.approvalID, "approval-123")
        XCTAssertEqual(payload.repoOwner, "acme")
        XCTAssertEqual(payload.repoName, "widgets")
        XCTAssertEqual(payload.action, .approve)
    }

    func testParseDefaultTapFromTopLevelPayload() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": ApprovalNotificationIdentifier.category],
            "approval_id": "approval-456",
            "repo_full_name": "smithers/gui",
        ]

        let payload = try XCTUnwrap(NotificationPayload.parse(userInfo))

        XCTAssertEqual(payload.approvalID, "approval-456")
        XCTAssertEqual(payload.repoOwner, "smithers")
        XCTAssertEqual(payload.repoName, "gui")
        XCTAssertEqual(payload.action, .open)
    }

    func testParseDenyActionFromNestedRepoDictionary() throws {
        let userInfo: [AnyHashable: Any] = [
            "payload": [
                "approval_id": "approval-789",
                "repo": [
                    "owner": "octo",
                    "name": "frontend",
                ],
            ] as [String: Any],
        ]

        let payload = try XCTUnwrap(NotificationPayload.parse(
            userInfo,
            actionIdentifier: ApprovalNotificationIdentifier.denyAction
        ))

        XCTAssertEqual(payload.approvalID, "approval-789")
        XCTAssertEqual(payload.repoOwner, "octo")
        XCTAssertEqual(payload.repoName, "frontend")
        XCTAssertEqual(payload.action, .deny)
    }

    func testParseRejectsUnknownAction() {
        let userInfo: [AnyHashable: Any] = [
            "payload": ["approval_id": "approval-123"],
        ]

        XCTAssertNil(NotificationPayload.parse(userInfo, actionIdentifier: "ARCHIVE"))
    }

    func testParseRejectsMissingApprovalID() {
        let userInfo: [AnyHashable: Any] = [
            "payload": [
                "repo_owner": "acme",
                "repo_name": "widgets",
            ] as [String: Any],
        ]

        XCTAssertNil(NotificationPayload.parse(
            userInfo,
            actionIdentifier: ApprovalNotificationIdentifier.approveAction
        ))
    }
}
#endif
