import Foundation
import CSmithersKit

enum SmithersError: LocalizedError {
    case unauthorized
    case notFound
    case httpError(Int)
    case api(String)
    case cli(String)
    case noWorkspace
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Unauthorized - check your API token"
        case .notFound: return "Resource not found"
        case .httpError(let code): return "HTTP error \(code)"
        case .api(let message): return message
        case .cli(let message): return message
        case .noWorkspace: return "No workspace ID configured"
        case .notAvailable(let message): return message
        }
    }
}

extension Smithers {
    static func string(from value: smithers_string_s, free: Bool = true) -> String {
        defer {
            if free {
                #if !SMITHERS_STUB
                smithers_string_free(value)
                #endif
            }
        }
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
            count: Int(value.len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }

    static func message(from error: smithers_error_s) -> String? {
        defer {
            #if !SMITHERS_STUB
            smithers_error_free(error)
            #endif
        }
        guard error.code != 0 else { return nil }
        guard let msg = error.msg else { return "libsmithers error \(error.code)" }
        return String(cString: msg)
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        guard let self else { return body(nil) }
        return self.withCString(body)
    }
}
