import Foundation
import CSmithersKit

/// Thread-safe facade over the libsmithers obs FFI. Use from any thread; the
/// underlying ring buffer + counters are guarded by the Zig-side mutex.
///
/// Prefer this over touching `DevTelemetryStore` from background contexts —
/// the store is `@MainActor` and exists for UI binding only.
enum DevTelemetryRecorder {
    /// Record an FFI client.call observation. Mirrors the Zig-side per-method
    /// histogram so latency from the host's perspective (queue + dispatch +
    /// FFI + decode) is captured separately from the pure FFI timing the
    /// libsmithers wrapper records.
    static func recordClientCall(
        method: String,
        durationMs: Int64,
        isError: Bool,
        errorMessage: String? = nil
    ) {
        let methodKey = "swift.client.call.\(method)"
        method.withCString { mptr in
            methodKey.withCString { kptr in
                smithers_obs_record_method(kptr, durationMs, isError)
                let level: Int32 = isError ? 3 : 1 // warn vs debug
                let subsystem = "swift.smithers_client"
                let name = "client_call"
                if let errorMessage {
                    let escaped = errorMessage.escapingForJSONString
                    let fields = "{\"method\":\"\(method.escapingForJSONString)\",\"err\":true,\"message\":\"\(escaped)\"}"
                    fields.withCString { fptr in
                        subsystem.withCString { sptr in
                            name.withCString { nptr in
                                smithers_obs_emit(level, sptr, nptr, durationMs, fptr)
                            }
                        }
                    }
                } else {
                    let fields = "{\"method\":\"\(method.escapingForJSONString)\",\"err\":false}"
                    fields.withCString { fptr in
                        subsystem.withCString { sptr in
                            name.withCString { nptr in
                                smithers_obs_emit(level, sptr, nptr, durationMs, fptr)
                            }
                        }
                    }
                }
                _ = mptr
                _ = kptr
            }
        }
    }

    /// Generic helper for instrumenting any Swift code path.
    static func emit(
        level: LogLevel = .info,
        subsystem: String,
        name: String,
        durationMs: Int64? = nil,
        fields: [String: String]? = nil
    ) {
        let fieldsJSON = fields.flatMap(Self.encodeFields)
        subsystem.withCString { sptr in
            name.withCString { nptr in
                if let fieldsJSON {
                    fieldsJSON.withCString { fptr in
                        smithers_obs_emit(Int32(level.obsLevel), sptr, nptr, durationMs ?? -1, fptr)
                    }
                } else {
                    smithers_obs_emit(Int32(level.obsLevel), sptr, nptr, durationMs ?? -1, nil)
                }
            }
        }
    }

    static func incrementCounter(_ key: String, by delta: UInt64 = 1) {
        key.withCString { ptr in
            smithers_obs_increment_counter(ptr, delta)
        }
    }

    static func setMinLevel(_ level: LogLevel) {
        smithers_obs_set_min_level(Int32(level.obsLevel))
    }

    private static func encodeFields(_ fields: [String: String]) -> String? {
        guard !fields.isEmpty else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(fields.count)
        for key in fields.keys.sorted() {
            let value = fields[key] ?? ""
            parts.append("\"\(key.escapingForJSONString)\":\"\(value.escapingForJSONString)\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

private extension String {
    var escapingForJSONString: String {
        var out = ""
        out.reserveCapacity(count)
        for char in unicodeScalars {
            switch char {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if char.value < 0x20 {
                    out += String(format: "\\u%04x", char.value)
                } else {
                    out.unicodeScalars.append(char)
                }
            }
        }
        return out
    }
}
