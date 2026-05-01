import Foundation

extension Smithers {
    struct Event {
        enum Tag {
            case none
            case json
            case end
            case error
        }

        let tag: Tag
        let payload: String
    }

    final class EventStream {
        private var events: [Event]
        private var index = 0

        init(events: [Event]) {
            self.events = events
        }

        func next() -> Event {
            guard index < events.count else {
                return Event(tag: .end, payload: "")
            }
            defer { index += 1 }
            return events[index]
        }
    }
}

extension Smithers.EventStream: @unchecked Sendable {}
