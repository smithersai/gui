import Foundation
import CSmithersKit

extension Smithers {
    struct Action {
        let tag: smithers_action_tag_e
        let title: String?
        let body: String?
        let value: String?
        let sessionKind: Session.Kind?

        init(cValue: smithers_action_s) {
            tag = cValue.tag
            switch cValue.tag {
            case SMITHERS_ACTION_OPEN_WORKSPACE:
                title = nil
                body = nil
                value = cValue.u.open_workspace.path.map(String.init(cString:))
                sessionKind = nil
            case SMITHERS_ACTION_NEW_SESSION:
                title = nil
                body = nil
                value = nil
                sessionKind = Session.Kind(cValue: cValue.u.new_session.kind)
            case SMITHERS_ACTION_SHOW_TOAST:
                title = cValue.u.toast.title.map(String.init(cString:))
                body = cValue.u.toast.body.map(String.init(cString:))
                value = nil
                sessionKind = nil
            case SMITHERS_ACTION_DESKTOP_NOTIFY:
                title = cValue.u.desktop_notify.title.map(String.init(cString:))
                body = cValue.u.desktop_notify.body.map(String.init(cString:))
                value = nil
                sessionKind = nil
            case SMITHERS_ACTION_OPEN_URL:
                title = nil
                body = nil
                value = cValue.u.open_url.url.map(String.init(cString:))
                sessionKind = nil
            case SMITHERS_ACTION_CLIPBOARD_WRITE:
                title = nil
                body = nil
                value = cValue.u.clipboard_write.text.map(String.init(cString:))
                sessionKind = nil
            case SMITHERS_ACTION_RUN_STARTED,
                 SMITHERS_ACTION_RUN_FINISHED,
                 SMITHERS_ACTION_RUN_STATE_CHANGED,
                 SMITHERS_ACTION_APPROVAL_REQUESTED:
                title = nil
                body = nil
                value = cValue.u.run_event.run_id.map(String.init(cString:))
                sessionKind = nil
            default:
                title = nil
                body = nil
                value = nil
                sessionKind = nil
            }
        }
    }
}
