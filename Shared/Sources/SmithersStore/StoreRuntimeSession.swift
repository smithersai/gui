import Foundation
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

internal protocol StoreRuntimeSession: AnyObject {
    func onEvent(_ handler: @escaping (RuntimeEvent) -> Void)
    func subscribe(shape: String, paramsJSON: String) throws -> UInt64
    func unsubscribe(_ handle: UInt64)
    func pin(_ handle: UInt64)
    func unpin(_ handle: UInt64)
    func cacheQuery(table: String, whereSQL: String?, limit: Int32, offset: Int32) throws -> String
    func write(action: String, payloadJSON: String) throws -> UInt64
    func wipeCache() throws
}

internal extension StoreRuntimeSession {
    func subscribe(shape: String) throws -> UInt64 {
        try subscribe(shape: shape, paramsJSON: "{}")
    }
}

extension RuntimeSession: StoreRuntimeSession {}
