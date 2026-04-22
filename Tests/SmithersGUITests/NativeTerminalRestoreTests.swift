import Darwin
import Foundation
import XCTest
@testable import SmithersGUI

#if os(macOS)
import AppKit
#endif

@MainActor
final class NativeTerminalRestoreTests: XCTestCase {
    func testTerminalWorkspaceRecordRoundTripPreservesSnapshot() throws {
        let rootId = SurfaceID()
        let splitId = SurfaceID()
        let root = WorkspaceSurface.terminal(
            id: rootId,
            workingDirectory: "/tmp/project",
            command: "codex",
            backend: .native,
            sessionId: "sess-root"
        )
        let split = WorkspaceSurface.terminal(
            id: splitId,
            workingDirectory: "/tmp/project",
            command: "claude",
            backend: .native,
            sessionId: "sess-split"
        )
        let snapshot = TerminalWorkspaceSnapshot(
            title: "Codex",
            surfaces: [root, split],
            layout: .makeSplit(axis: .horizontal, first: .leaf(root.id), second: .leaf(split.id)),
            focusedSurfaceId: split.id,
            hasCustomTitle: true
        )
        let record = TerminalWorkspaceRecord(
            terminalId: "terminal-1",
            title: "Codex",
            preview: "2 terminals",
            timestamp: Date(timeIntervalSince1970: 1_735_171_200),
            createdAt: Date(timeIntervalSince1970: 1_735_171_200),
            workingDirectory: "/tmp/project",
            command: "codex",
            backend: .native,
            rootSurfaceId: root.id.rawValue,
            sessionId: "sess-root",
            rootKind: .terminal,
            snapshot: snapshot
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(TerminalWorkspaceRecord.self, from: data)

        let restored = try XCTUnwrap(decoded.snapshot)
        XCTAssertEqual(restored.surfaces.count, 2)
        XCTAssertEqual(restored.layout.surfaceIds, [root.id, split.id])
        XCTAssertEqual(restored.focusedSurfaceId, split.id)
        XCTAssertEqual(restored.surfaces.first(where: { $0.id == root.id })?.sessionId, "sess-root")
        XCTAssertEqual(restored.surfaces.first(where: { $0.id == split.id })?.sessionId, "sess-split")
        XCTAssertEqual(restored.surfaces.first(where: { $0.id == root.id })?.nativeAttachmentState, .ready)
        XCTAssertEqual(restored.surfaces.first(where: { $0.id == split.id })?.nativeAttachmentState, .ready)
    }

    #if os(macOS)
    func testSessionStoreReloadRestoresWorkspaceSnapshot() async throws {
        let context = try makeStoreContext(name: "snapshot")
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.addTerminalTab(
            title: "Codex",
            workingDirectory: context.workspacePath,
            command: "codex"
        )
        let workspace = store.ensureTerminalWorkspace(terminalId)
        let rootId = try XCTUnwrap(workspace.layout.firstSurfaceId)
        workspace.markNativeTerminalReady(surfaceId: rootId, sessionId: "sess-root")
        let splitId = workspace.splitFocused(axis: .horizontal, kind: .terminal)
        workspace.markNativeTerminalReady(surfaceId: splitId, sessionId: "sess-split")

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        let reloaded = context.makeStore()
        let restoredTab = try XCTUnwrap(reloaded.terminalTabs.first { $0.terminalId == terminalId })
        let restoredSnapshot = try XCTUnwrap(restoredTab.snapshot)
        XCTAssertEqual(restoredSnapshot.surfaces.count, 2)
        XCTAssertEqual(Set(restoredSnapshot.layout.surfaceIds), Set([rootId, splitId]))

        let restoredWorkspace = reloaded.ensureTerminalWorkspace(terminalId)
        XCTAssertEqual(restoredWorkspace.orderedSurfaces.count, 2)
        XCTAssertEqual(restoredWorkspace.surfaces[rootId]?.sessionId, "sess-root")
        XCTAssertEqual(restoredWorkspace.surfaces[splitId]?.sessionId, "sess-split")
    }

    func testStoreRestoresLiveNativeSessionWithoutRestartingIt() async throws {
        let daemon = try IsolatedSessionDaemon()
        try daemon.start()
        defer { daemon.cleanup() }

        let context = try makeStoreContext(name: "live")
        defer { context.cleanup() }

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let created = try await controller.createSession(
            title: "Codex",
            shell: "/bin/sh",
            command: "while :; do sleep 1; done",
            cwd: context.workspacePath,
            env: nil,
            rows: 24,
            cols: 80
        )
        let rootId = SurfaceID()
        let terminalId = WorkspaceID().rawValue
        let snapshot = TerminalWorkspaceSnapshot(
            title: "Codex",
            surfaces: [
                .terminal(
                    id: rootId,
                    workingDirectory: context.workspacePath,
                    command: "codex",
                    backend: .native,
                    sessionId: created.id
                )
            ],
            layout: .leaf(rootId),
            focusedSurfaceId: rootId,
            hasCustomTitle: false
        )

        let store = context.makeStore()
        store.terminalTabs = [
            TerminalWorkspaceRecord(
                terminalId: terminalId,
                title: "Codex",
                preview: "codex",
                timestamp: Date(),
                createdAt: Date(),
                workingDirectory: context.workspacePath,
                command: "codex",
                backend: .native,
                rootSurfaceId: rootId.rawValue,
                sessionId: created.id,
                rootKind: .terminal,
                snapshot: snapshot
            )
        ]
        _ = store.ensureTerminalWorkspace(terminalId)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        let reloaded = context.makeStore()
        let restoredWorkspace = reloaded.ensureTerminalWorkspace(terminalId)
        let sharedInfo = try await SessionController.shared.info(sessionId: PTYSessionID(created.id))
        XCTAssertEqual(sharedInfo.id, created.id)
        let restoredSessionId = try await waitForReadyNativeSession(in: restoredWorkspace, surfaceId: rootId)

        XCTAssertEqual(restoredSessionId, created.id)

        let info = try await controller.info(sessionId: PTYSessionID(restoredSessionId))
        XCTAssertEqual(info.id, created.id)
    }

    func testStoreLeavesMissingRestoredSessionUnavailableInsteadOfRespawning() async throws {
        let daemon = try IsolatedSessionDaemon()
        try daemon.start()
        defer { daemon.cleanup() }

        let context = try makeStoreContext(name: "stale")
        defer { context.cleanup() }

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let created = try await controller.createSession(
            title: "Codex",
            shell: "/bin/sh",
            command: "while :; do sleep 1; done",
            cwd: context.workspacePath,
            env: nil,
            rows: 24,
            cols: 80
        )
        let rootId = SurfaceID()
        let terminalId = WorkspaceID().rawValue
        let snapshot = TerminalWorkspaceSnapshot(
            title: "Codex",
            surfaces: [
                .terminal(
                    id: rootId,
                    workingDirectory: context.workspacePath,
                    command: "codex",
                    backend: .native,
                    sessionId: created.id
                )
            ],
            layout: .leaf(rootId),
            focusedSurfaceId: rootId,
            hasCustomTitle: false
        )

        let store = context.makeStore()
        store.terminalTabs = [
            TerminalWorkspaceRecord(
                terminalId: terminalId,
                title: "Codex",
                preview: "codex",
                timestamp: Date(),
                createdAt: Date(),
                workingDirectory: context.workspacePath,
                command: "codex",
                backend: .native,
                rootSurfaceId: rootId.rawValue,
                sessionId: created.id,
                rootKind: .terminal,
                snapshot: snapshot
            )
        ]
        _ = store.ensureTerminalWorkspace(terminalId)

        try await controller.terminate(sessionId: PTYSessionID(created.id))

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        let reloaded = context.makeStore()
        let restoredWorkspace = reloaded.ensureTerminalWorkspace(terminalId)
        do {
            _ = try await SessionController.shared.info(sessionId: PTYSessionID(created.id))
            XCTFail("stale session should not be visible through shared controller")
        } catch {
            // Expected: the restored tab should observe the missing session.
        }
        try await waitForUnavailableNativeSession(in: restoredWorkspace, surfaceId: rootId)

        XCTAssertNil(restoredWorkspace.surfaces[rootId]?.sessionId)
        XCTAssertNil(reloaded.terminalTabs.first(where: { $0.terminalId == terminalId })?.sessionId)
        if let sessions = try? await controller.list() {
            XCTAssertTrue(sessions.isEmpty)
        }
    }
    #endif

    private func makeStoreContext(name: String) throws -> StoreContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeTerminalRestoreTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        return StoreContext(
            root: root,
            workspacePath: workspaceURL.path,
            databasePath: root.appendingPathComponent("app.sqlite").path
        )
    }

    private func waitForReadyNativeSession(
        in workspace: TerminalWorkspace,
        surfaceId: SurfaceID,
        timeout: TimeInterval = 5
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch workspace.nativeTerminalState(surfaceId: surfaceId) {
            case .ready:
                if let sessionId = workspace.surfaces[surfaceId]?.sessionId {
                    return sessionId
                }
            case .unavailable(let message):
                throw NSError(
                    domain: "NativeTerminalRestoreTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "native terminal became unavailable"]
                )
            case .pending:
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "NativeTerminalRestoreTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for ready native session"]
        )
    }

    private func waitForUnavailableNativeSession(
        in workspace: TerminalWorkspace,
        surfaceId: SurfaceID,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = workspace.nativeTerminalState(surfaceId: surfaceId)
            if case .unavailable = state {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "NativeTerminalRestoreTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for unavailable native session"]
        )
    }
}

private struct StoreContext {
    let root: URL
    let workspacePath: String
    let databasePath: String

    @MainActor
    func makeStore() -> SessionStore {
        SessionStore(
            workingDirectory: workspacePath,
            app: Smithers.App(databasePath: databasePath)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class IsolatedSessionDaemon {
    let socketPath: String
    private let previousSocketEnv: String?
    private var process: Process?

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smt-native-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.socketPath = tmp.appendingPathComponent("sessions.sock").path
        self.previousSocketEnv = ProcessInfo.processInfo.environment["SMITHERS_SESSION_SOCKET"]
    }

    func start() throws {
        let binary = try Self.locateDaemonBinary()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--socket", socketPath, "--idle-seconds", "0"]
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try proc.run()
        process = proc

        setenv("SMITHERS_SESSION_SOCKET", socketPath, 1)
        try waitForSocket(path: socketPath, timeout: 3.0)
    }

    func cleanup() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        if let previousSocketEnv {
            setenv("SMITHERS_SESSION_SOCKET", previousSocketEnv, 1)
        } else {
            unsetenv("SMITHERS_SESSION_SOCKET")
        }
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        )
    }

    private static func locateDaemonBinary() throws -> String {
        if let env = ProcessInfo.processInfo.environment["SMITHERS_SESSION_DAEMON"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }

        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("libsmithers/zig-out/bin/smithers-session-daemon")
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }

        throw XCTSkip(
            "smithers-session-daemon binary not found; build it via `zig build` in libsmithers/ or set SMITHERS_SESSION_DAEMON"
        )
    }

    private func waitForSocket(path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                if fd >= 0 {
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    let bytes = Array(path.utf8)
                    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
                    if bytes.count < capacity {
                        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { c in
                                for i in 0..<bytes.count { c[i] = CChar(bitPattern: bytes[i]) }
                                c[bytes.count] = 0
                            }
                        }
                        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
                            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                            }
                        }
                        Darwin.close(fd)
                        if rc == 0 { return }
                    } else {
                        Darwin.close(fd)
                    }
                }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        throw NSError(
            domain: "NativeTerminalRestoreTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "daemon socket never appeared at \(path)"]
        )
    }
}
