import Foundation
import CSmithersKit

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

        init(cValue: smithers_event_s) {
            switch cValue.tag {
            case SMITHERS_EVENT_JSON: tag = .json
            case SMITHERS_EVENT_END: tag = .end
            case SMITHERS_EVENT_ERROR: tag = .error
            default: tag = .none
            }
            payload = Smithers.string(from: cValue.payload, free: false)
        }
    }
}

extension Smithers {
    final class EventStream {
        private var stream: smithers_event_stream_t?

        init(_ stream: smithers_event_stream_t?) {
            self.stream = stream
        }

        deinit {
            if let stream {
                smithers_event_stream_free(stream)
            }
        }

        func next() -> Event {
            guard let stream else {
                return Event(cValue: smithers_event_s(tag: SMITHERS_EVENT_END, payload: smithers_string_s(ptr: nil, len: 0)))
            }
            let event = smithers_event_stream_next(stream)
            defer { smithers_event_free(event) }
            return Event(cValue: event)
        }
    }
}

extension Smithers.EventStream: @unchecked Sendable {}
