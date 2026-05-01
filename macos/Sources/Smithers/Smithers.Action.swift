import Foundation

extension Smithers {
    struct Action {
        enum Kind {
            case none
            case toast
            case desktopNotification
            case clipboardWrite
            case openURL
            case newSession
        }

        let kind: Kind
        let title: String?
        let body: String?
        let value: String?
        let sessionKind: Session.Kind?

        init(
            kind: Kind = .none,
            title: String? = nil,
            body: String? = nil,
            value: String? = nil,
            sessionKind: Session.Kind? = nil
        ) {
            self.kind = kind
            self.title = title
            self.body = body
            self.value = value
            self.sessionKind = sessionKind
        }
    }
}
