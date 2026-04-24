// SmithersRuntime — Swift wrapper around the 0120 libsmithers-core FFI.
//
// This target is intentionally thin: it converts the C ABI declared in
// libsmithers/include/smithers.h into a type-safe Swift interface, and
// nothing more. Business logic lives in Zig; persistence lives in Zig;
// transport lives in Zig. SwiftUI views consume this module; the
// existing macos/Sources/Smithers/*.swift adapters will become thin
// shims over this layer (see Smithers.Runtime.swift in that directory).
//
// Credential injection: Core NEVER reads tokens from disk. Platform code
// (the 0109 SmithersAuth module) hands its TokenManager to a
// Runtime.CredentialsProvider; the provider's closure is invoked on
// every connect / 401-recovery by the Zig side via a C function pointer.

#if canImport(CSmithersKit)
import CSmithersKit
#endif
import Foundation

/// Thrown when a Core / Session operation fails or the feature flag is off.
public struct SmithersRuntimeError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SmithersRuntimeError(code=\(code)): \(message)" }
}

/// The credentials the runtime needs for every connection.
public struct SmithersCredentials: Sendable {
    public var bearer: String
    public var expiresAt: Date?
    public var refreshToken: String?

    public init(bearer: String, expiresAt: Date? = nil, refreshToken: String? = nil) {
        self.bearer = bearer
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
    }
}

/// A closure the platform implements to hand tokens to the runtime.
/// Returning nil fires AUTH_EXPIRED on the session and the host must
/// refresh / re-present sign-in before retrying.
public typealias CredentialsProvider = @Sendable () -> SmithersCredentials?

/// Engine-connection configuration. `cacheMaxMB = 0` means unbounded
/// (LRU eviction is a 0120-followup).
public struct EngineConfig: Sendable {
    public var engineID: String
    public var baseURL: String
    public var shapeProxyURL: String?
    public var wsPtyURL: String?
    public var cacheDir: String?
    public var cacheMaxMB: UInt32

    public init(
        engineID: String,
        baseURL: String,
        shapeProxyURL: String? = nil,
        wsPtyURL: String? = nil,
        cacheDir: String? = nil,
        cacheMaxMB: UInt32 = 0
    ) {
        self.engineID = engineID
        self.baseURL = baseURL
        self.shapeProxyURL = shapeProxyURL
        self.wsPtyURL = wsPtyURL
        self.cacheDir = cacheDir
        self.cacheMaxMB = cacheMaxMB
    }
}

public enum RuntimeEvent: Sendable {
    case stateChanged(String?)
    case authExpired
    case reconnect
    case shapeDelta(String?)
    case writeAck(String?)
    case ptyData(String?)
    case ptyClosed(String?)
}

/// The process-lifetime runtime root. One per app.
public final class SmithersRuntime {
    #if canImport(CSmithersKit)
    fileprivate var handle: OpaquePointer?
    fileprivate let providerBox: ProviderBox
    #endif

    public init(credentials: @escaping CredentialsProvider) throws {
        #if canImport(CSmithersKit)
        self.providerBox = ProviderBox(provider: credentials)
        var err = smithers_error_s(code: 0, msg: nil)
        let ud = Unmanaged.passUnretained(self.providerBox).toOpaque()
        let raw = smithers_core_new(credentialsTrampoline, ud, &err)
        if raw == nil {
            let msg = err.msg.map { String(cString: $0) } ?? "smithers_core_new failed"
            smithers_error_free(err)
            throw SmithersRuntimeError(code: err.code, message: msg)
        }
        self.handle = OpaquePointer(raw)
        #else
        _ = credentials
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available on this platform")
        #endif
    }

    deinit {
        #if canImport(CSmithersKit)
        if let h = handle { smithers_core_free(UnsafeMutableRawPointer(h)) }
        #endif
    }

    public func connect(_ config: EngineConfig) throws -> RuntimeSession {
        #if canImport(CSmithersKit)
        guard let h = handle else {
            throw SmithersRuntimeError(code: -1, message: "core closed")
        }
        return try config.engineID.withCString { engineID in
            try config.baseURL.withCString { base in
                try withOptionalCString(config.shapeProxyURL) { shape in
                    try withOptionalCString(config.wsPtyURL) { ws in
                        try withOptionalCString(config.cacheDir) { cache in
                            var cfg = smithers_core_engine_config_s(
                                engine_id: engineID,
                                base_url: base,
                                shape_proxy_url: shape,
                                ws_pty_url: ws,
                                cache_dir: cache,
                                cache_max_mb: config.cacheMaxMB
                            )
                            var err = smithers_error_s(code: 0, msg: nil)
                            let raw = smithers_core_connect(UnsafeMutableRawPointer(h), &cfg, &err)
                            if raw == nil {
                                let msg = err.msg.map { String(cString: $0) } ?? "connect failed"
                                smithers_error_free(err)
                                throw SmithersRuntimeError(code: err.code, message: msg)
                            }
                            return RuntimeSession(raw: raw!)
                        }
                    }
                }
            }
        }
        #else
        _ = config
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }
}

/// A single engine connection. Owns the transport + bounded cache in Zig.
public final class RuntimePTY {
    public private(set) var handle: UInt64?

    #if canImport(CSmithersKit)
    fileprivate var raw: UnsafeMutableRawPointer?
    #endif

    #if canImport(CSmithersKit)
    fileprivate init(raw: UnsafeMutableRawPointer) {
        self.raw = raw
        self.handle = smithers_core_pty_public_handle(raw)
    }
    #endif

    deinit {
        detach()
    }

    public func write(_ bytes: Data) throws {
        #if canImport(CSmithersKit)
        guard let raw else { return }
        guard !bytes.isEmpty else { return }

        let err: smithers_error_s = bytes.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return smithers_core_pty_write(raw, base, rawBuffer.count)
        }
        if err.code != 0 {
            let msg = err.msg.map { String(cString: $0) } ?? "pty_write failed"
            smithers_error_free(err)
            throw SmithersRuntimeError(code: err.code, message: msg)
        }
        #else
        _ = bytes
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }

    public func resize(cols: UInt16, rows: UInt16) throws {
        #if canImport(CSmithersKit)
        guard let raw else { return }
        let err = smithers_core_pty_resize(raw, cols, rows)
        if err.code != 0 {
            let msg = err.msg.map { String(cString: $0) } ?? "pty_resize failed"
            smithers_error_free(err)
            throw SmithersRuntimeError(code: err.code, message: msg)
        }
        #else
        _ = (cols, rows)
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }

    public func detach() {
        #if canImport(CSmithersKit)
        guard let raw else { return }
        smithers_core_detach_pty(raw)
        self.raw = nil
        #endif
    }
}

public final class RuntimeSession {
    #if canImport(CSmithersKit)
    fileprivate let raw: UnsafeMutableRawPointer
    fileprivate let eventBox: EventBox
    #endif

    #if canImport(CSmithersKit)
    fileprivate init(raw: UnsafeMutableRawPointer) {
        self.raw = raw
        self.eventBox = EventBox()
    }
    #endif

    deinit {
        #if canImport(CSmithersKit)
        smithers_core_disconnect(raw)
        #endif
    }

    /// Install (or replace) the primary event callback. Dispatched on
    /// the Zig event-loop thread — hop to your actor before touching UI
    /// state.
    public func onEvent(_ handler: @escaping (RuntimeEvent) -> Void) {
        #if canImport(CSmithersKit)
        self.eventBox.setPrimaryHandler(handler)
        let ud = Unmanaged.passUnretained(self.eventBox).toOpaque()
        smithers_core_register_callback(raw, eventTrampoline, ud)
        #else
        _ = handler
        #endif
    }

    @discardableResult
    public func addEventListener(_ handler: @escaping (RuntimeEvent) -> Void) -> UUID {
        #if canImport(CSmithersKit)
        let token = self.eventBox.addHandler(handler)
        let ud = Unmanaged.passUnretained(self.eventBox).toOpaque()
        smithers_core_register_callback(raw, eventTrampoline, ud)
        return token
        #else
        _ = handler
        return UUID()
        #endif
    }

    public func removeEventListener(_ token: UUID) {
        #if canImport(CSmithersKit)
        self.eventBox.removeHandler(token)
        #endif
    }

    public func subscribe(shape: String, paramsJSON: String = "{}") throws -> UInt64 {
        #if canImport(CSmithersKit)
        return try shape.withCString { s in
            try paramsJSON.withCString { p in
                var err = smithers_error_s(code: 0, msg: nil)
                let id = smithers_core_subscribe(raw, s, p, &err)
                if id == 0 {
                    let msg = err.msg.map { String(cString: $0) } ?? "subscribe failed"
                    smithers_error_free(err)
                    throw SmithersRuntimeError(code: err.code, message: msg)
                }
                return id
            }
        }
        #else
        _ = shape; _ = paramsJSON
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }

    public func unsubscribe(_ handle: UInt64) {
        #if canImport(CSmithersKit)
        smithers_core_unsubscribe(raw, handle)
        #endif
    }

    public func pin(_ handle: UInt64) {
        #if canImport(CSmithersKit)
        smithers_core_pin(raw, handle)
        #endif
    }

    public func unpin(_ handle: UInt64) {
        #if canImport(CSmithersKit)
        smithers_core_unpin(raw, handle)
        #endif
    }

    public func cacheQuery(table: String, whereSQL: String? = nil, limit: Int32 = 0, offset: Int32 = 0) throws -> String {
        #if canImport(CSmithersKit)
        return try table.withCString { t in
            try withOptionalCString(whereSQL) { w in
                var err = smithers_error_s(code: 0, msg: nil)
                let s = smithers_core_cache_query(raw, t, w, limit, offset, &err)
                if err.code != 0 {
                    let msg = err.msg.map { String(cString: $0) } ?? "query failed"
                    smithers_error_free(err)
                    smithers_string_free(s)
                    throw SmithersRuntimeError(code: err.code, message: msg)
                }
                let out = s.ptr.map { String(cString: $0) } ?? "[]"
                smithers_string_free(s)
                return out
            }
        }
        #else
        _ = table; _ = whereSQL; _ = limit; _ = offset
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }

    public func write(action: String, payloadJSON: String) throws -> UInt64 {
        #if canImport(CSmithersKit)
        return try action.withCString { a in
            try payloadJSON.withCString { p in
                var err = smithers_error_s(code: 0, msg: nil)
                let fut = smithers_core_write(raw, a, p, &err)
                if fut == 0 {
                    let msg = err.msg.map { String(cString: $0) } ?? "write failed"
                    smithers_error_free(err)
                    throw SmithersRuntimeError(code: err.code, message: msg)
                }
                return fut
            }
        }
        #else
        _ = action; _ = payloadJSON
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }

    public func attachPTY(sessionID: String) throws -> RuntimePTY {
        #if canImport(CSmithersKit)
        return try sessionID.withCString { sid in
            var err = smithers_error_s(code: 0, msg: nil)
            let handle = smithers_core_attach_pty(raw, sid, &err)
            if handle == nil {
                let msg = err.msg.map { String(cString: $0) } ?? "attach_pty failed"
                smithers_error_free(err)
                throw SmithersRuntimeError(code: err.code, message: msg)
            }
            return RuntimePTY(raw: handle!)
        }
        #else
        _ = sessionID
        throw SmithersRuntimeError(code: -1, message: "CSmithersKit not available")
        #endif
    }

    public func wipeCache() throws {
        #if canImport(CSmithersKit)
        let e = smithers_core_cache_wipe(raw)
        if e.code != 0 {
            let msg = e.msg.map { String(cString: $0) } ?? "cache_wipe failed"
            smithers_error_free(e)
            throw SmithersRuntimeError(code: e.code, message: msg)
        }
        #endif
    }

    // Test-only hook so SmithersRuntimeTests can drive the pump.
    internal func _tickForTest() {
        #if canImport(CSmithersKit)
        smithers_core_tick_for_test(raw)
        #endif
    }
}

// ---- Internal plumbing -----------------------------------------------

#if canImport(CSmithersKit)

fileprivate final class EventBox {
    private let lock = NSLock()
    private var primaryHandler: ((RuntimeEvent) -> Void)? = nil
    private var handlers: [UUID: (RuntimeEvent) -> Void] = [:]

    func setPrimaryHandler(_ handler: @escaping (RuntimeEvent) -> Void) {
        lock.lock()
        primaryHandler = handler
        lock.unlock()
    }

    func addHandler(_ handler: @escaping (RuntimeEvent) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        handlers[token] = handler
        lock.unlock()
        return token
    }

    func removeHandler(_ token: UUID) {
        lock.lock()
        handlers.removeValue(forKey: token)
        lock.unlock()
    }

    func dispatch(_ event: RuntimeEvent) {
        lock.lock()
        let primary = primaryHandler
        let callbacks = Array(handlers.values)
        lock.unlock()
        primary?(event)
        for callback in callbacks {
            callback(event)
        }
    }
}

fileprivate final class ProviderBox {
    let provider: CredentialsProvider
    // Keep Swift-owned C string buffers alive while the callback runs.
    var bearerCStr: ContiguousArray<CChar> = []
    var refreshCStr: ContiguousArray<CChar>? = nil

    init(provider: @escaping CredentialsProvider) {
        self.provider = provider
    }
}

fileprivate let credentialsTrampoline: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<smithers_credentials_s>?) -> Bool) = { ud, out in
    guard let ud, let out else { return false }
    let box = Unmanaged<ProviderBox>.fromOpaque(ud).takeUnretainedValue()
    guard let creds = box.provider() else { return false }

    box.bearerCStr = creds.bearer.utf8CString
    let bearerPtr = box.bearerCStr.withUnsafeBufferPointer { $0.baseAddress }
    var refreshPtr: UnsafePointer<CChar>? = nil
    if let rt = creds.refreshToken {
        box.refreshCStr = rt.utf8CString
        refreshPtr = box.refreshCStr!.withUnsafeBufferPointer { $0.baseAddress }
    } else {
        box.refreshCStr = nil
    }
    out.pointee = smithers_credentials_s(
        bearer: bearerPtr,
        expires_unix_ms: Int64((creds.expiresAt?.timeIntervalSince1970 ?? 0) * 1000),
        refresh_token: refreshPtr
    )
    return true
}

fileprivate let eventTrampoline: (@convention(c) (UnsafeMutableRawPointer?, smithers_core_event_tag_e, UnsafePointer<CChar>?) -> Void) = { ud, tag, payload in
    guard let ud else { return }
    let box = Unmanaged<EventBox>.fromOpaque(ud).takeUnretainedValue()
    let payloadStr: String? = payload.map { String(cString: $0) }
    let evt: RuntimeEvent
    switch tag {
    case SMITHERS_CORE_EVENT_AUTH_EXPIRED: evt = .authExpired
    case SMITHERS_CORE_EVENT_RECONNECT: evt = .reconnect
    case SMITHERS_CORE_EVENT_SHAPE_DELTA: evt = .shapeDelta(payloadStr)
    case SMITHERS_CORE_EVENT_WRITE_ACK: evt = .writeAck(payloadStr)
    case SMITHERS_CORE_EVENT_PTY_DATA: evt = .ptyData(payloadStr)
    case SMITHERS_CORE_EVENT_PTY_CLOSED: evt = .ptyClosed(payloadStr)
    default: evt = .stateChanged(payloadStr)
    }
    box.dispatch(evt)
}

fileprivate func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
    if let value = value {
        return try value.withCString { try body($0) }
    } else {
        return try body(nil)
    }
}
#endif
