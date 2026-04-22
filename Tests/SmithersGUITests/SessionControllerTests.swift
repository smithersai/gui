import Darwin
import Foundation
import XCTest
@testable import SmithersGUI

/// Tests for `SessionController`, the Swift client for the native session
/// daemon. These use a real UNIX-domain listening socket on a tmp path as a
/// fake daemon — the test accepts exactly one connection, reads one line of
/// JSON-RPC, and writes back a canned response line.
final class SessionControllerTests: XCTestCase {

    // MARK: - Fake daemon server

    /// A minimal AF_UNIX server that accepts one connection, reads a single
    /// newline-terminated JSON request, hands it to a handler, and writes
    /// back the handler's response (already newline-terminated).
    ///
    /// The server runs on a detached thread. Tests can await the captured
    /// request via `requestExpectation`.
    private final class FakeDaemon {
        let socketPath: String
        private let listenFd: Int32
        private let queue = DispatchQueue(label: "SessionControllerTests.FakeDaemon", qos: .userInitiated)
        private let handler: (Data) -> FakeDaemonResponse
        private let lock = NSLock()
        private var _capturedRequest: Data?

        /// The LAST request received from a client, without the trailing newline.
        /// The fake daemon serves connections in a loop, so ping probes made by
        /// the controller do not consume the primary test connection.
        var capturedRequest: Data? {
            lock.lock(); defer { lock.unlock() }
            return _capturedRequest
        }
        /// Fulfilled once per accepted connection. The default controller
        /// flow is one request per call, so tests usually wait for exactly
        /// one fulfillment, but `attach` also pings the daemon first, so
        /// tests for attach should not rely on this expectation.
        let requestReceived: XCTestExpectation = {
            let e = XCTestExpectation(description: "fake daemon received request")
            e.assertForOverFulfill = false
            return e
        }()

        init(handler: @escaping (Data) -> FakeDaemonResponse) throws {
            self.handler = handler

            let tmp = FileManager.default.temporaryDirectory
            let name = "smt-fake-\(UUID().uuidString.prefix(8)).sock"
            self.socketPath = tmp.appendingPathComponent(String(name)).path

            _ = unlink(socketPath)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(domain: "FakeDaemon", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket failed"])
            }
            self.listenFd = fd

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(socketPath.utf8)
            precondition(bytes.count < capacity, "socket path too long for sockaddr_un")
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { c in
                    for i in 0..<bytes.count { c[i] = CChar(bitPattern: bytes[i]) }
                    c[bytes.count] = 0
                }
            }
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

            let bindRc = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindRc == 0 else {
                Darwin.close(fd)
                throw NSError(domain: "FakeDaemon", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind failed errno=\(errno)"])
            }

            guard listen(fd, 8) == 0 else {
                Darwin.close(fd)
                throw NSError(domain: "FakeDaemon", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen failed errno=\(errno)"])
            }
        }

        deinit {
            Darwin.close(listenFd)
            _ = unlink(socketPath)
        }

        /// Start accepting connections in a loop on a background thread.
        /// Each accepted connection serves exactly one request/response then
        /// closes, which matches how SessionController uses the socket.
        func start() {
            queue.async { self.acceptLoop() }
        }

        private func acceptLoop() {
            while true {
                let client = accept(listenFd, nil, nil)
                if client < 0 {
                    // Listener was closed (deinit) or a transient error —
                    // either way, stop the loop.
                    return
                }
                serve(client: client)
            }
        }

        private func serve(client: Int32) {
            defer { Darwin.close(client) }
            let requestLine = readLine(fd: client)

            self.lock.lock()
            self._capturedRequest = requestLine
            self.lock.unlock()
            self.requestReceived.fulfill()

            let response = self.handler(requestLine)
            writeResponse(fd: client, response: response)
        }

        private func readLine(fd: Int32) -> Data {
            var buf = Data()
            var byte: UInt8 = 0
            while buf.count < 1 << 20 {
                let n = Darwin.read(fd, &byte, 1)
                if n == 1 {
                    if byte == 0x0A { return buf }
                    buf.append(byte)
                    continue
                }
                if n == 0 { return buf }
                if errno == EINTR { continue }
                return buf
            }
            return buf
        }

        private func writeResponse(fd: Int32, response: FakeDaemonResponse) {
            var data = response.jsonLine
            if data.last != 0x0A {
                data.append(0x0A)
            }

            if let ptyFd = response.scmRightsFd {
                sendWithFd(fd: fd, fdToSend: ptyFd, payload: data)
            } else {
                _ = data.withUnsafeBytes { raw -> Int in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if n > 0 { offset += n; continue }
                        if n < 0 && errno == EINTR { continue }
                        return -1
                    }
                    return 0
                }
            }
        }

        /// Send a single fd alongside `payload` using SCM_RIGHTS. Layout
        /// mirrors libsmithers/src/session/fd_passing.zig.
        private func sendWithFd(fd: Int32, fdToSend: Int32, payload: Data) {
            let controlLen = cmsgAlign(MemoryLayout<cmsghdr>.size) + cmsgAlign(MemoryLayout<Int32>.size)
            let control = UnsafeMutableRawPointer.allocate(byteCount: controlLen, alignment: 8)
            defer { control.deallocate() }
            memset(control, 0, controlLen)

            let hdr = control.assumingMemoryBound(to: cmsghdr.self)
            hdr.pointee.cmsg_len = socklen_t(cmsgAlign(MemoryLayout<cmsghdr>.size) + MemoryLayout<Int32>.size)
            hdr.pointee.cmsg_level = SOL_SOCKET
            hdr.pointee.cmsg_type = SCM_RIGHTS

            let dataOffset = cmsgAlign(MemoryLayout<cmsghdr>.size)
            let fdPtr = control.advanced(by: dataOffset).assumingMemoryBound(to: Int32.self)
            fdPtr.pointee = fdToSend

            payload.withUnsafeBytes { raw -> Void in
                guard let base = raw.baseAddress else { return }
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: base),
                    iov_len: raw.count
                )
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: iovPtr,
                        msg_iovlen: 1,
                        msg_control: control,
                        msg_controllen: socklen_t(controlLen),
                        msg_flags: 0
                    )
                    _ = sendmsg(fd, &msg, 0)
                }
            }
        }

        private func cmsgAlign(_ len: Int) -> Int {
            let a = MemoryLayout<socklen_t>.size
            return (len + a - 1) & ~(a - 1)
        }
    }

    private struct FakeDaemonResponse {
        var jsonLine: Data
        /// If non-nil, the response is sent via sendmsg + SCM_RIGHTS with
        /// this extra file descriptor attached.
        var scmRightsFd: Int32?
    }

    // MARK: - Helpers

    /// Decode the JSON-RPC request line the fake daemon captured.
    private func decodeRequest(_ data: Data?) throws -> [String: Any] {
        guard let data = data else {
            throw XCTSkip("no request captured")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "decode", code: 0, userInfo: [NSLocalizedDescriptionKey: "non-object request"])
        }
        return obj
    }

    private func makeExecutableFixture(named binaryName: String) throws -> (root: URL, referenceFilePath: String, binaryPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionControllerTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("nested/a/b", isDirectory: true)
        let binaryURL = root
            .appendingPathComponent("libsmithers/zig-out/bin", isDirectory: true)
            .appendingPathComponent(binaryName, isDirectory: false)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        let referenceFilePath = sourceDir.appendingPathComponent("Fixture.swift").path
        return (root, referenceFilePath, binaryURL.path)
    }

    private func makeBundledExecutableFixture(named binaryName: String) throws -> (root: URL, bundleURL: URL, binaryPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionControllerTests-Bundle-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("SmithersGUI.app", isDirectory: true)
        let binaryURL = bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(binaryName, isDirectory: false)
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        return (root, bundleURL, binaryURL.path)
    }

    private func makeBundleRelativeExecutableFixture(named binaryName: String) throws -> (root: URL, bundleURL: URL, binaryPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionControllerTests-AppBundle-\(UUID().uuidString)", isDirectory: true)
        let exportDir = root.appendingPathComponent("build/export", isDirectory: true)
        let bundleURL = exportDir.appendingPathComponent("SmithersGUI.app", isDirectory: true)
        let binaryURL = root
            .appendingPathComponent("libsmithers/zig-out/bin", isDirectory: true)
            .appendingPathComponent(binaryName, isDirectory: false)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        return (root, bundleURL, binaryURL.path)
    }

    private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "SessionControllerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for process \(pid) to exit"]
        )
    }

    // MARK: - Tests

    func testPingReturnsVersion() async throws {
        let daemon = try FakeDaemon { _ in
            FakeDaemonResponse(
                jsonLine: Data(#"{"id":1,"result":{"version":"0.1.0","pid":123,"sessions":0}}"#.utf8)
            )
        }
        daemon.start()

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let result = try await controller.ping()

        XCTAssertEqual(result.version, "0.1.0")
        XCTAssertEqual(result.pid, 123)
        XCTAssertEqual(result.sessions, 0)

        await fulfillment(of: [daemon.requestReceived], timeout: 2.0)
    }

    func testCreateSessionSendsParams() async throws {
        let daemon = try FakeDaemon { _ in
            FakeDaemonResponse(
                jsonLine: Data(#"{"id":1,"result":{"id":"sess-1","title":"demo","state":"running","rows":24,"cols":80,"cwd":"/tmp"}}"#.utf8)
            )
        }
        daemon.start()

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let info = try await controller.createSession(
            title: "demo",
            shell: "/bin/sh",
            command: nil,
            cwd: "/tmp",
            env: nil,
            rows: 24,
            cols: 80
        )

        await fulfillment(of: [daemon.requestReceived], timeout: 2.0)

        XCTAssertEqual(info.id, "sess-1")
        XCTAssertEqual(info.title, "demo")
        XCTAssertEqual(info.state, "running")

        let req = try decodeRequest(daemon.capturedRequest)
        XCTAssertEqual(req["method"] as? String, "session.create")

        guard let params = req["params"] as? [String: Any] else {
            return XCTFail("params missing")
        }
        XCTAssertEqual(params["title"] as? String, "demo")
        XCTAssertEqual(params["shell"] as? String, "/bin/sh")
        XCTAssertEqual(params["cwd"] as? String, "/tmp")
        XCTAssertEqual(params["rows"] as? Int, 24)
        XCTAssertEqual(params["cols"] as? Int, 80)
    }

    func testListReturnsInfos() async throws {
        let daemon = try FakeDaemon { _ in
            FakeDaemonResponse(
                jsonLine: Data(#"""
                {"id":1,"result":[{"id":"sess-a","title":"A","state":"running","rows":24,"cols":80},{"id":"sess-b","title":"B","state":"detached","rows":30,"cols":100}]}
                """#.utf8)
            )
        }
        daemon.start()

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let list = try await controller.list()

        await fulfillment(of: [daemon.requestReceived], timeout: 2.0)

        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].id, "sess-a")
        XCTAssertEqual(list[0].state, "running")
        XCTAssertEqual(list[0].title, "A")
        XCTAssertEqual(list[1].id, "sess-b")
        XCTAssertEqual(list[1].state, "detached")
        XCTAssertEqual(list[1].rows, 30)
    }

    func testErrorResponseThrowsRpcError() async throws {
        let daemon = try FakeDaemon { _ in
            FakeDaemonResponse(
                jsonLine: Data(#"{"id":1,"error":{"code":-32000,"message":"nope"}}"#.utf8)
            )
        }
        daemon.start()

        let controller = SessionController(socketPathOverride: daemon.socketPath)

        do {
            _ = try await controller.list()
            XCTFail("expected rpcError")
        } catch let SessionControllerError.rpcError(code, message) {
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "nope")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await fulfillment(of: [daemon.requestReceived], timeout: 2.0)
    }

    func testAttachReceivesFd() async throws {
        // Create a pipe. The daemon sends the read-end fd to the client via
        // SCM_RIGHTS. The daemon writes a known payload to the write-end so
        // the test can verify the client received a usable fd by reading it.
        var pipeFds: [Int32] = [0, 0]
        let pipeRc = pipeFds.withUnsafeMutableBufferPointer { buf -> Int32 in
            pipe(buf.baseAddress)
        }
        XCTAssertEqual(pipeRc, 0, "pipe() failed")

        let readEnd = pipeFds[0]
        let writeEnd = pipeFds[1]

        // Write a sentinel into the pipe so the client can read it from the
        // received fd.
        let sentinel = "smt-fd-ok"
        _ = sentinel.withCString { Darwin.write(writeEnd, $0, strlen($0)) }
        Darwin.close(writeEnd)

        let daemon = try FakeDaemon { request in
            // Only the attach request gets the fd; the ping done by
            // ensureDaemon() gets a plain ping response.
            let isAttach = (try? JSONSerialization.jsonObject(with: request))
                .flatMap { ($0 as? [String: Any])?["method"] as? String } == "session.attach"
            if isAttach {
                return FakeDaemonResponse(
                    jsonLine: Data(#"{"id":1,"result":{"id":"sess-1","title":"t","state":"running","rows":24,"cols":80}}"#.utf8),
                    scmRightsFd: readEnd
                )
            }
            return FakeDaemonResponse(
                jsonLine: Data(#"{"id":1,"result":{"version":"0.1.0","pid":1,"sessions":0}}"#.utf8)
            )
        }
        daemon.start()

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let (info, ptyFd) = try await controller.attach(sessionId: PTYSessionID("sess-1"))

        await fulfillment(of: [daemon.requestReceived], timeout: 2.0)

        // Close the daemon's copy of the read-end so the client's fd is the
        // only live reference.
        Darwin.close(readEnd)

        XCTAssertEqual(info.id, "sess-1")
        XCTAssertGreaterThanOrEqual(ptyFd, 0, "expected a valid fd from attach")

        defer { Darwin.close(ptyFd) }

        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
            Darwin.read(ptyFd, bp.baseAddress, bp.count)
        }
        XCTAssertGreaterThan(n, 0, "expected to read the sentinel from the received fd")
        let got = String(bytes: buf.prefix(max(n, 0)), encoding: .utf8) ?? ""
        XCTAssertEqual(got, sentinel)
    }

    func testCaptureReturnsScrollback() async throws {
        let daemon = try FakeDaemon { _ in
            FakeDaemonResponse(
                jsonLine: Data(#"{"id":1,"result":{"sessionId":"sess-1","text":"hello\n"}}"#.utf8)
            )
        }
        daemon.start()

        let controller = SessionController(socketPathOverride: daemon.socketPath)
        let text = try await controller.capture(sessionId: PTYSessionID("sess-1"), lines: 100)

        await fulfillment(of: [daemon.requestReceived], timeout: 2.0)

        XCTAssertEqual(text, "hello\n")

        let req = try decodeRequest(daemon.capturedRequest)
        XCTAssertEqual(req["method"] as? String, "session.capture")
        if let params = req["params"] as? [String: Any] {
            XCTAssertEqual(params["sessionId"] as? String, "sess-1")
            XCTAssertEqual(params["lines"] as? Int, 100)
        } else {
            XCTFail("missing params")
        }
    }

    func testLocateDaemonBinaryFindsRepoArtifactRelativeToReferenceFile() throws {
        let fixture = try makeExecutableFixture(named: "smithers-session-daemon")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = SessionController.locateDaemonBinary(
            referenceFilePath: fixture.referenceFilePath,
            bundleURL: fixture.root.appendingPathComponent("NoBundle.app", isDirectory: true)
        )

        XCTAssertEqual(resolved, fixture.binaryPath)
    }

    func testLocateSessionConnectBinaryFindsRepoArtifactRelativeToReferenceFile() throws {
        let fixture = try makeExecutableFixture(named: "smithers-session-connect")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = SessionController.locateSessionConnectBinary(
            referenceFilePath: fixture.referenceFilePath,
            bundleURL: fixture.root.appendingPathComponent("NoBundle.app", isDirectory: true)
        )

        XCTAssertEqual(resolved, fixture.binaryPath)
    }

    func testLocateSessionConnectBinaryPrefersBundledResource() throws {
        let fixture = try makeBundledExecutableFixture(named: "smithers-session-connect")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = SessionController.locateSessionConnectBinary(
            referenceFilePath: "/tmp/SessionControllerTests/Nowhere.swift",
            bundleURL: fixture.bundleURL
        )

        XCTAssertEqual(resolved, fixture.binaryPath)
    }

    func testLocateSessionConnectBinaryFindsRepoArtifactRelativeToBundleURL() throws {
        let fixture = try makeBundleRelativeExecutableFixture(named: "smithers-session-connect")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = SessionController.locateSessionConnectBinary(
            referenceFilePath: "/tmp/SessionControllerTests/Nowhere.swift",
            bundleURL: fixture.bundleURL
        )

        XCTAssertEqual(resolved, fixture.binaryPath)
    }

    func testBuildNativeAttachCommandIncludesResolvedSocket() {
        let command = SessionStore.buildNativeAttachCommand(
            for: "sess-123",
            sessionConnectBinaryOverride: "/tmp/smithers-session-connect",
            socketPathOverride: "/tmp/smithers.sock"
        )

        XCTAssertEqual(
            command,
            "'/tmp/smithers-session-connect' 'sess-123' --socket '/tmp/smithers.sock'"
        )
    }

    func testEnsureDaemonLaunchesOnSocketOverride() async throws {
        guard SessionController.locateDaemonBinary() != nil else {
            throw XCTSkip("smithers-session-daemon binary not found in bundle, env, PATH, or local checkout")
        }

        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("smt-launch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("sessions.sock").path
        let controller = SessionController(socketPathOverride: socketPath)

        try await controller.ensureDaemon()
        let ping = try await controller.ping()

        XCTAssertGreaterThan(ping.pid, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        XCTAssertEqual(Darwin.kill(ping.pid, SIGTERM), 0)
        try await waitForProcessExit(pid: ping.pid)
    }
}
