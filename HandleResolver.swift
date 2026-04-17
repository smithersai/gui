import Foundation

enum HandleKind: String, CaseIterable, Codable, Hashable, Sendable {
    case window
    case workspace
    case pane
    case surface
}

private enum HandleIDCodec {
    static func uuid(from value: String) -> UUID {
        if let uuid = UUID(uuidString: value) {
            return uuid
        }

        return deterministicUUID(from: value)
    }

    private static func deterministicUUID(from value: String) -> UUID {
        var state: UInt64 = 14695981039346656037
        var bytes: [UInt8] = []

        func append(_ byte: UInt8) {
            state ^= UInt64(byte)
            state = state &* 1099511628211
            bytes.append(UInt8(truncatingIfNeeded: state >> 56))
            bytes.append(UInt8(truncatingIfNeeded: state >> 48))
        }

        for byte in value.utf8 {
            append(byte)
        }

        while bytes.count < 16 {
            append(UInt8(bytes.count))
        }

        bytes = Array(bytes.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}

protocol UUIDHandleID:
    Hashable,
    Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral,
    Sendable
{
    static var handleKind: HandleKind { get }
    var uuid: UUID { get }
    init(uuid: UUID)
    init(_ rawValue: String)
}

extension UUIDHandleID {
    init() {
        self.init(uuid: UUID())
    }

    init(_ rawValue: String) {
        self.init(uuid: HandleIDCodec.uuid(from: rawValue))
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    var rawValue: String {
        uuid.uuidString
    }

    var description: String {
        rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct WindowID: UUIDHandleID {
    static let handleKind: HandleKind = .window
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }
}

struct WorkspaceID: UUIDHandleID {
    static let handleKind: HandleKind = .workspace
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }
}

struct PaneID: UUIDHandleID {
    static let handleKind: HandleKind = .pane
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }
}

struct SurfaceID: UUIDHandleID {
    static let handleKind: HandleKind = .surface
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }
}

typealias TabID = SurfaceID
typealias PanelID = SurfaceID
typealias TerminalSurfaceID = SurfaceID
typealias SessionID = WorkspaceID
typealias TerminalID = WorkspaceID
typealias TerminalTabID = WorkspaceID
typealias RunTabID = WorkspaceID

struct HandleRef: Hashable, Codable, CustomStringConvertible, Sendable {
    let kind: HandleKind
    let number: Int

    init(kind: HandleKind, number: Int) {
        self.kind = kind
        self.number = number
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let kind = HandleKind(rawValue: parts[0]),
              let number = Int(parts[1]),
              number > 0
        else {
            return nil
        }

        self.kind = kind
        self.number = number
    }

    var rawValue: String {
        "\(kind.rawValue):\(number)"
    }

    var description: String {
        rawValue
    }
}

struct HandleResolution: Hashable, Sendable {
    let kind: HandleKind
    let uuid: UUID
    let ref: HandleRef
}

final class HandleResolver {
    static let shared = HandleResolver()

    private struct Key: Hashable {
        let kind: HandleKind
        let uuid: UUID
    }

    private var nextNumber = 1
    private var refsByKey: [Key: HandleRef] = [:]
    private var keysByRef: [HandleRef: Key] = [:]

    init() {}

    @discardableResult
    func ref(for id: WindowID) -> HandleRef {
        ref(kind: .window, uuid: id.uuid)
    }

    @discardableResult
    func ref(for id: WorkspaceID) -> HandleRef {
        ref(kind: .workspace, uuid: id.uuid)
    }

    @discardableResult
    func ref(for id: PaneID) -> HandleRef {
        ref(kind: .pane, uuid: id.uuid)
    }

    @discardableResult
    func ref(for id: SurfaceID) -> HandleRef {
        ref(kind: .surface, uuid: id.uuid)
    }

    func resolveWindow(_ ref: HandleRef) -> WindowID? {
        resolve(ref, as: .window).map(WindowID.init(uuid:))
    }

    func resolveWorkspace(_ ref: HandleRef) -> WorkspaceID? {
        resolve(ref, as: .workspace).map(WorkspaceID.init(uuid:))
    }

    func resolvePane(_ ref: HandleRef) -> PaneID? {
        resolve(ref, as: .pane).map(PaneID.init(uuid:))
    }

    func resolveSurface(_ ref: HandleRef) -> SurfaceID? {
        resolve(ref, as: .surface).map(SurfaceID.init(uuid:))
    }

    func resolveWindow(_ rawRef: String) -> WindowID? {
        HandleRef(rawValue: rawRef).flatMap(resolveWindow)
    }

    func resolveWorkspace(_ rawRef: String) -> WorkspaceID? {
        HandleRef(rawValue: rawRef).flatMap(resolveWorkspace)
    }

    func resolvePane(_ rawRef: String) -> PaneID? {
        HandleRef(rawValue: rawRef).flatMap(resolvePane)
    }

    func resolveSurface(_ rawRef: String) -> SurfaceID? {
        HandleRef(rawValue: rawRef).flatMap(resolveSurface)
    }

    func resolution(for ref: HandleRef) -> HandleResolution? {
        guard let key = keysByRef[ref] else { return nil }
        return HandleResolution(kind: key.kind, uuid: key.uuid, ref: ref)
    }

    func ref(kind: HandleKind, uuid: UUID) -> HandleRef {
        let key = Key(kind: kind, uuid: uuid)
        if let existing = refsByKey[key] {
            return existing
        }

        let next = HandleRef(kind: kind, number: nextNumber)
        nextNumber += 1
        refsByKey[key] = next
        keysByRef[next] = key
        return next
    }

    private func resolve(_ ref: HandleRef, as expectedKind: HandleKind) -> UUID? {
        guard ref.kind == expectedKind,
              let key = keysByRef[ref],
              key.kind == expectedKind
        else {
            return nil
        }
        return key.uuid
    }
}
