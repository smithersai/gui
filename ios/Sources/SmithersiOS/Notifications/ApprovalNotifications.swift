#if os(iOS)
import Foundation
import UserNotifications

enum ApprovalNotificationIdentifier {
    static let category = "APPROVAL"
    static let approveAction = "APPROVE"
    static let denyAction = "DENY"
}

struct NotificationPayload: Equatable {
    enum Action: Equatable {
        case open
        case approve
        case deny

        init?(identifier: String) {
            switch identifier {
            case UNNotificationDefaultActionIdentifier:
                self = .open
            case ApprovalNotificationIdentifier.approveAction:
                self = .approve
            case ApprovalNotificationIdentifier.denyAction:
                self = .deny
            default:
                return nil
            }
        }

        var decisionValue: String? {
            switch self {
            case .open:
                return nil
            case .approve:
                return "approve"
            case .deny:
                return "deny"
            }
        }
    }

    let approvalID: String
    let repoOwner: String?
    let repoName: String?
    let action: Action

    static func parse(
        _ userInfo: [AnyHashable: Any],
        actionIdentifier: String = UNNotificationDefaultActionIdentifier
    ) -> NotificationPayload? {
        guard let action = Action(identifier: actionIdentifier) else {
            return nil
        }

        let dictionaries = dictionariesToSearch(in: userInfo)
        guard let approvalID = firstString(
            for: ["approval_id", "approvalID", "approvalId"],
            in: dictionaries
        ) else {
            return nil
        }

        let repo = repoRef(in: dictionaries)
        return NotificationPayload(
            approvalID: approvalID,
            repoOwner: repo.owner,
            repoName: repo.name,
            action: action
        )
    }

    private static func dictionariesToSearch(in userInfo: [AnyHashable: Any]) -> [[String: Any]] {
        var dictionaries: [[String: Any]] = [stringDictionary(from: userInfo)]
        for key in ["payload", "data", "approval"] {
            if let dictionary = dictionaryValue(for: key, in: dictionaries[0]) {
                dictionaries.append(dictionary)
            }
        }
        return dictionaries
    }

    private static func repoRef(in dictionaries: [[String: Any]]) -> (owner: String?, name: String?) {
        let owner = firstString(
            for: ["repo_owner", "repoOwner", "repository_owner", "owner", "o"],
            in: dictionaries
        )
        let explicitName = firstString(
            for: ["repo_name", "repoName", "repository_name", "name", "r"],
            in: dictionaries
        )
        if owner != nil, explicitName != nil {
            return (owner, explicitName)
        }

        if let owner,
           let repoValue = firstString(for: ["repo", "repository"], in: dictionaries) {
            if repoValue.contains("/") {
                let split = splitRepoFullName(repoValue)
                return (split.owner ?? owner, split.name)
            }
            return (owner, repoValue)
        }

        for key in ["repo", "repository"] {
            if let dictionary = firstDictionary(for: key, in: dictionaries) {
                let owner = firstString(
                    for: ["owner", "repo_owner", "repoOwner", "repository_owner", "o"],
                    in: [dictionary]
                )
                let name = firstString(
                    for: ["name", "repo_name", "repoName", "repository_name", "r"],
                    in: [dictionary]
                )
                if owner != nil || name != nil {
                    return (owner, name)
                }
            }
        }

        if let fullName = firstString(
            for: ["repo_full_name", "repository_full_name", "full_name", "repo", "repository"],
            in: dictionaries
        ) {
            return splitRepoFullName(fullName)
        }

        return (owner, explicitName)
    }

    private static func firstString(for keys: [String], in dictionaries: [[String: Any]]) -> String? {
        for dictionary in dictionaries {
            for key in keys {
                guard let value = dictionary[key] else { continue }
                if let string = normalizedString(value) {
                    return string
                }
            }
        }
        return nil
    }

    private static func firstDictionary(
        for key: String,
        in dictionaries: [[String: Any]]
    ) -> [String: Any]? {
        for dictionary in dictionaries {
            if let value = dictionaryValue(for: key, in: dictionary) {
                return value
            }
        }
        return nil
    }

    private static func dictionaryValue(for key: String, in dictionary: [String: Any]) -> [String: Any]? {
        if let value = dictionary[key] as? [String: Any] {
            return value
        }
        guard let hashableValue = dictionary[key] as? [AnyHashable: Any] else {
            return nil
        }
        return stringDictionary(from: hashableValue)
    }

    private static func stringDictionary(from dictionary: [AnyHashable: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
    }

    private static func normalizedString(_ value: Any) -> String? {
        let string: String?
        switch value {
        case let value as String:
            string = value
        case let value as NSString:
            string = value as String
        case let value as NSNumber:
            string = value.stringValue
        default:
            string = nil
        }

        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func splitRepoFullName(_ fullName: String) -> (owner: String?, name: String?) {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return (nil, nil)
        }
        return (parts[0], parts[1])
    }
}

enum ApprovalNotificationCategory {
    static func make() -> UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: ApprovalNotificationIdentifier.approveAction,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: ApprovalNotificationIdentifier.denyAction,
            title: "Deny",
            options: [.authenticationRequired, .destructive]
        )

        return UNNotificationCategory(
            identifier: ApprovalNotificationIdentifier.category,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
    }
}

final class ApprovalNotificationHandler {
    static let shared = ApprovalNotificationHandler()

    private let lock = NSLock()
    private var configuration: Configuration?

    private init() {}

    func configure(
        baseURL: URL,
        bearerProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared
    ) {
        lock.lock()
        configuration = Configuration(
            baseURL: baseURL,
            bearerProvider: bearerProvider,
            session: session
        )
        lock.unlock()
    }

    func handle(_ payload: NotificationPayload) async {
        switch payload.action {
        case .open:
            await openApproval(payload.approvalID)
        case .approve, .deny:
            do {
                try await decide(payload)
            } catch {
                NSLog("Smithers approval notification action failed: \(error.localizedDescription)")
            }
        }
    }

    private func openApproval(_ approvalID: String) async {
        guard let url = URL(string: "smithers://approvals/\(approvalID)") else {
            return
        }
        await MainActor.run {
            DeepLinkRouter.shared.handle(url)
        }
    }

    private func decide(_ payload: NotificationPayload) async throws {
        guard let decision = payload.action.decisionValue else {
            return
        }
        guard let repoOwner = payload.repoOwner,
              let repoName = payload.repoName
        else {
            throw ApprovalNotificationError.missingRepo
        }

        let configuration = try currentConfiguration()
        guard let bearer = configuration.bearerProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bearer.isEmpty
        else {
            throw ApprovalNotificationError.missingBearer
        }

        var request = URLRequest(
            url: configuration.baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("repos")
                .appendingPathComponent(repoOwner)
                .appendingPathComponent(repoName)
                .appendingPathComponent("approvals")
                .appendingPathComponent(payload.approvalID)
                .appendingPathComponent("decide")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(DecisionRequest(decision: decision))

        let (_, response) = try await configuration.session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ApprovalNotificationError.invalidResponse
        }
    }

    private func currentConfiguration() throws -> Configuration {
        lock.lock()
        let current = configuration
        lock.unlock()

        guard let current else {
            throw ApprovalNotificationError.notConfigured
        }
        return current
    }
}

private struct Configuration {
    let baseURL: URL
    let bearerProvider: @Sendable () -> String?
    let session: URLSession
}

private struct DecisionRequest: Encodable {
    let decision: String
}

private enum ApprovalNotificationError: LocalizedError {
    case notConfigured
    case missingBearer
    case missingRepo
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Notification handler is not configured."
        case .missingBearer:
            return "Missing bearer token."
        case .missingRepo:
            return "Missing repository owner or name in notification payload."
        case .invalidResponse:
            return "Approval decision request failed."
        }
    }
}
#endif
