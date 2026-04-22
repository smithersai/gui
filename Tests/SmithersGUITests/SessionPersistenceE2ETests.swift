import Darwin
import Foundation
import XCTest
@testable import SmithersGUI

/// End-to-end test for native terminal session persistence across "app
/// restarts". Boots the real `smithers-session-daemon` on an isolated
/// socket, creates a real PTY session, round-trips a
/// `TerminalWorkspaceRecord` through JSON (simulating app quit + relaunch),
/// and verifies the daemon still reports the session as live via
/// `session.info` — which is what gates the reattach path in
/// `SessionStore.verifyNativeSessionOrRespawn`.
final class SessionPersistenceE2ETests: XCTestCase {

    private var daemonProcess: Process?
    private var socketPath: String = ""

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smt-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.socketPath = tmp.appendingPathComponent("sessions.sock").path

        let binary = try Self.locateDaemonBinary()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--socket", socketPath, "--idle-seconds", "0"]
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try proc.run()
        self.daemonProcess = proc

        try await waitForSocket(path: socketPath, timeout: 3.0)
    }

    override func tearDown() async throws {
        if let proc = daemonProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        )
    }

    // MARK: - The test

    func testSessionSurvivesSimulatedAppRestart() async throws {
        let controller = SessionController(socketPathOverride: socketPath)

        // 1. Create a real PTY session running a shell loop so it stays alive.
        let created = try await controller.createSession(
            title: "persistence-probe",
            shell: "/bin/sh",
            command: "while :; do sleep 1; done",
            cwd: "/tmp",
            env: nil,
            rows: 24,
            cols: 80
        )
        XCTAssertFalse(created.id.isEmpty, "daemon returned empty session id")

        // 2. Persist a tab carrying that sessionId, and round-trip through
        //    JSON — this is exactly what happens when the app quits and
        //    relaunches.
        let originalTab = TerminalWorkspaceRecord(
            terminalId: "t-1",
            title: "Claude",
            preview: "claude",
            timestamp: Date(),
            createdAt: Date(),
            workingDirectory: "/tmp",
            command: "claude",
            backend: .native,
            rootSurfaceId: "surface-1",
            sessionId: created.id,
            runId: nil,
            isPinned: false,
            rootKind: .terminal
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(originalTab)

        // Sanity: the encoded JSON must contain the sessionId. This is the
        // regression test for the "sessionId was dropped on encode" bug.
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(
            encodedString.contains("\"sessionId\""),
            "encoded tab JSON is missing sessionId field: \(encodedString)"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let restoredTab = try decoder.decode(TerminalWorkspaceRecord.self, from: encoded)
        XCTAssertEqual(
            restoredTab.sessionId,
            created.id,
            "sessionId did not survive JSON round-trip — reattach would always miss"
        )

        // 3. Simulate the GUI's reattach-liveness check. The daemon is still
        //    up (it would be across a real app restart too, because
        //    server.zig refuses idle-exit while sessions exist), so the
        //    session must still be reported as live.
        let restoredId = try XCTUnwrap(restoredTab.sessionId)
        let info = try await controller.info(sessionId: PTYSessionID(restoredId))
        XCTAssertEqual(info.id, created.id)
        // The daemon reports "running" when a client is attached and
        // "detached" otherwise. Both mean the PTY is alive and reattachable.
        XCTAssertTrue(
            info.state == "running" || info.state == "detached",
            "unexpected state after restart: \(info.state)"
        )

        // 4. Negative case: terminate the session and confirm the liveness
        //    check throws, so the GUI would fall through to respawn instead
        //    of handing ghostty a dead sessionId.
        try await controller.terminate(sessionId: PTYSessionID(restoredId))

        do {
            _ = try await controller.info(sessionId: PTYSessionID(restoredId))
            XCTFail("info() should have thrown after terminate()")
        } catch SessionControllerError.rpcError {
            // Expected: daemon reports the session is gone.
        } catch SessionControllerError.daemonUnavailable {
            // Also acceptable: daemon exited because session count hit zero
            // (we launched it with --idle-seconds 0).
        } catch {
            XCTFail("unexpected error from info() after terminate: \(error)")
        }
    }

    func testSessionConnectHelperCanReattachAfterClientProcessDies() async throws {
        guard let connectBinary = SessionController.locateSessionConnectBinary(
            referenceFilePath: #filePath
        ) else {
            throw XCTSkip(
                "smithers-session-connect binary not found in bundle, env, PATH, or local checkout"
            )
        }

        let controller = SessionController(socketPathOverride: socketPath)
        let created = try await controller.createSession(
            title: "reattach-probe",
            shell: "/bin/sh",
            command: "printf 'REATTACH_READY\\n'; exec cat",
            cwd: "/tmp",
            env: nil,
            rows: 24,
            cols: 80
        )

        _ = try await waitForCapture(
            controller: controller,
            sessionId: created.id,
            contains: "REATTACH_READY"
        )

        let first = try SessionConnectProcess(
            binary: connectBinary,
            sessionId: created.id,
            socketPath: socketPath
        )
        defer { first.terminateIfNeeded() }

        let firstReplay = try await first.waitForStdout(containing: "REATTACH_READY")
        XCTAssertTrue(firstReplay.contains("REATTACH_READY"))

        first.send("alpha-from-first-attach\n")
        let firstEcho = try await first.waitForStdout(containing: "alpha-from-first-attach")
        XCTAssertTrue(firstEcho.contains("alpha-from-first-attach"))

        first.process.terminate()
        try await first.waitForExit()
        XCTAssertFalse(
            first.stderrString.contains("MissingFileDescriptor"),
            "first helper should not fail to attach: \(first.stderrString)"
        )

        try await waitForSessionState(
            controller: controller,
            sessionId: created.id,
            expectedState: "detached"
        )

        let second = try SessionConnectProcess(
            binary: connectBinary,
            sessionId: created.id,
            socketPath: socketPath
        )
        defer { second.terminateIfNeeded() }

        let secondReplay = try await second.waitForStdout(containing: "REATTACH_READY")
        XCTAssertTrue(secondReplay.contains("REATTACH_READY"))

        second.send("beta-after-reattach\n")
        let secondEcho = try await second.waitForStdout(containing: "beta-after-reattach")
        XCTAssertTrue(secondEcho.contains("beta-after-reattach"))
        XCTAssertFalse(
            second.stderrString.contains("MissingFileDescriptor"),
            "second helper reported fd passing failure: \(second.stderrString)"
        )
    }

    // MARK: - Helpers

    private static func locateDaemonBinary() throws -> String {
        if let env = ProcessInfo.processInfo.environment["SMITHERS_SESSION_DAEMON"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }

        // Walk up from the test source file to the repo root, then append
        // the zig-out location. This keeps the test independent of the
        // Xcode scheme's working directory.
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

    private func waitForSocket(path: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                // Also confirm the daemon is actually accepting connections.
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
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "SessionPersistenceE2ETests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "daemon socket never appeared at \(path)"]
        )
    }

    private func waitForCapture(
        controller: SessionController,
        sessionId: String,
        contains needle: String,
        timeout: TimeInterval = 5
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = try await controller.capture(sessionId: PTYSessionID(sessionId), lines: 200)
            if text.contains(needle) {
                return text
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "SessionPersistenceE2ETests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for capture containing \(needle)"]
        )
    }

    private func waitForSessionState(
        controller: SessionController,
        sessionId: String,
        expectedState: String,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let info = try await controller.info(sessionId: PTYSessionID(sessionId))
            if info.state == expectedState {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "SessionPersistenceE2ETests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for state \(expectedState)"]
        )
    }
}

private final class SessionConnectProcess {
    let process = Process()

    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutBuffer = LockedDataBuffer()
    private let stderrBuffer = LockedDataBuffer()

    init(binary: String, sessionId: String, socketPath: String) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [sessionId, "--socket", socketPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutBuffer] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stdoutBuffer.append(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
        }

        try process.run()
    }

    deinit {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    func send(_ text: String) {
        stdinPipe.fileHandleForWriting.write(Data(text.utf8))
    }

    func waitForStdout(containing needle: String, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let output = stdoutString
            if output.contains(needle) {
                return output
            }
            if !process.isRunning {
                throw NSError(
                    domain: "SessionPersistenceE2ETests",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "session-connect exited before producing \(needle). stdout=\(output) stderr=\(stderrString)"
                    ]
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "SessionPersistenceE2ETests",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "timed out waiting for stdout containing \(needle). stdout=\(stdoutString) stderr=\(stderrString)"
            ]
        )
    }

    func waitForExit(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "SessionPersistenceE2ETests",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for session-connect to exit"]
        )
    }

    func terminateIfNeeded() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    var stdoutString: String { stdoutBuffer.stringValue }
    var stderrString: String { stderrBuffer.stringValue }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
