import Darwin
import Foundation

public struct PTYSessionID: Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SessionInfo: Codable {
    public let id: String
    public let title: String?
    public let state: String
    public let pid: Int32?
    public let cwd: String?
    public let rows: UInt16?
    public let cols: UInt16?

    public init(
        id: String,
        title: String? = nil,
        state: String,
        pid: Int32? = nil,
        cwd: String? = nil,
        rows: UInt16? = nil,
        cols: UInt16? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.pid = pid
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, state, pid, cwd, rows, cols
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.rows = try c.decodeIfPresent(UInt16.self, forKey: .rows)
        self.cols = try c.decodeIfPresent(UInt16.self, forKey: .cols)
    }
}

public enum SessionControllerError: Error {
    case daemonUnavailable
    case rpcError(code: Int, message: String)
    case decodingFailed(String)
    case attachMissingFd
}

public actor SessionController {
    public static let shared = SessionController()
    private static let binarySearchAncestorLimit = 8

    private let socketPathOverride: String?
    private var nextId: Int = 0

    public init() {
        self.socketPathOverride = nil
    }

    internal init(socketPathOverride: String?) {
        self.socketPathOverride = socketPathOverride
    }

    // MARK: - Public API

    public func ensureDaemon() async throws {
        if (try? await ping()) != nil { return }

        guard let binary = Self.locateDaemonBinary() else {
            throw SessionControllerError.daemonUnavailable
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--socket", socketPath()]
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try proc.run()
        } catch {
            throw SessionControllerError.daemonUnavailable
        }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if (try? await ping()) != nil { return }
        }
        throw SessionControllerError.daemonUnavailable
    }

    public func ping() async throws -> (version: String, pid: Int32, sessions: Int) {
        struct Result: Codable {
            let version: String?
            let pid: Int32?
            let sessions: Int?
        }
        let result: Result = try await call(method: "daemon.ping", params: [String: SessionRPCValue]())
        return (
            version: result.version ?? "",
            pid: result.pid ?? 0,
            sessions: result.sessions ?? 0
        )
    }

    public func createSession(
        title: String?,
        shell: String?,
        command: String?,
        cwd: String?,
        env: [String: String]?,
        rows: UInt16,
        cols: UInt16
    ) async throws -> SessionInfo {
        var params: [String: SessionRPCValue] = [
            "rows": .int(Int(rows)),
            "cols": .int(Int(cols)),
        ]
        if let title = title { params["title"] = .string(title) }
        if let shell = shell { params["shell"] = .string(shell) }
        if let command = command { params["command"] = .string(command) }
        if let cwd = cwd { params["cwd"] = .string(cwd) }
        if let env = env {
            var envObj: [String: SessionRPCValue] = [:]
            for (k, v) in env { envObj[k] = .string(v) }
            params["env"] = .object(envObj)
        }
        return try await call(method: "session.create", params: params)
    }

    public func attach(sessionId: PTYSessionID) async throws -> (info: SessionInfo, ptyFd: Int32) {
        try await ensureDaemon()
        let id = nextRequestID()
        let request = encodeRequest(id: id, method: "session.attach", params: [
            "sessionId": .string(sessionId.rawValue),
        ])

        let path = socketPath()
        let fd = try connectSocket(path: path)
        defer { Darwin.close(fd) }

        try writeAll(fd: fd, bytes: request)
        let (payload, ptyFd) = try recvJSONWithFd(fd: fd, maxPayload: 1024 * 1024)
        guard let ptyFd = ptyFd else {
            throw SessionControllerError.attachMissingFd
        }

        do {
            let info: SessionInfo = try decodeResult(payload)
            return (info: info, ptyFd: ptyFd)
        } catch {
            Darwin.close(ptyFd)
            throw error
        }
    }

    public func detach(sessionId: PTYSessionID) async throws {
        let _: EmptyResult = try await call(method: "session.detach", params: [
            "sessionId": .string(sessionId.rawValue),
        ])
    }

    public func terminate(sessionId: PTYSessionID) async throws {
        let _: EmptyResult = try await call(method: "session.terminate", params: [
            "sessionId": .string(sessionId.rawValue),
        ])
    }

    public func list() async throws -> [SessionInfo] {
        return try await call(method: "session.list", params: [String: SessionRPCValue]())
    }

    public func info(sessionId: PTYSessionID) async throws -> SessionInfo {
        return try await call(method: "session.info", params: [
            "sessionId": .string(sessionId.rawValue),
        ])
    }

    public func resize(sessionId: PTYSessionID, cols: UInt16, rows: UInt16) async throws {
        let _: EmptyResult = try await call(method: "session.resize", params: [
            "sessionId": .string(sessionId.rawValue),
            "cols": .int(Int(cols)),
            "rows": .int(Int(rows)),
        ])
    }

    public func capture(sessionId: PTYSessionID, lines: Int) async throws -> String {
        struct Result: Codable {
            let text: String?
        }
        let r: Result = try await call(method: "session.capture", params: [
            "sessionId": .string(sessionId.rawValue),
            "lines": .int(lines),
        ])
        return r.text ?? ""
    }

    public func send(sessionId: PTYSessionID, text: String, enter: Bool) async throws {
        let _: EmptyResult = try await call(method: "session.send", params: [
            "sessionId": .string(sessionId.rawValue),
            "text": .string(text),
            "enter": .bool(enter),
        ])
    }

    public func sendKey(sessionId: PTYSessionID, key: String) async throws {
        let _: EmptyResult = try await call(method: "session.sendKey", params: [
            "sessionId": .string(sessionId.rawValue),
            "key": .string(key),
        ])
    }

    // MARK: - Internals

    internal func socketPath() -> String {
        Self.resolvedSocketPath(socketPathOverride: socketPathOverride)
    }

    private func nextRequestID() -> Int {
        nextId &+= 1
        return nextId
    }

    internal nonisolated static func resolvedSocketPath(socketPathOverride: String? = nil) -> String {
        if let override = socketPathOverride, !override.isEmpty { return override }
        if let env = currentEnvironmentValue("SMITHERS_SESSION_SOCKET"), !env.isEmpty {
            return env
        }
        if let xdg = currentEnvironmentValue("XDG_RUNTIME_DIR"), !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("smithers-sessions.sock")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".smithers/sessions.sock").path
    }

    internal nonisolated static func locateDaemonBinary(referenceFilePath: String = #filePath) -> String? {
        locateHelperBinary(
            named: "smithers-session-daemon",
            environmentKey: "SMITHERS_SESSION_DAEMON",
            referenceFilePath: referenceFilePath
        )
    }

    internal nonisolated static func locateSessionConnectBinary(referenceFilePath: String = #filePath) -> String? {
        locateHelperBinary(
            named: "smithers-session-connect",
            environmentKey: "SMITHERS_SESSION_CONNECT",
            referenceFilePath: referenceFilePath
        )
    }

    private nonisolated static func locateHelperBinary(
        named binaryName: String,
        environmentKey: String,
        referenceFilePath: String = #filePath
    ) -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(binaryName)")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }

        if let env = currentEnvironmentValue(environmentKey),
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }

        if let devBinary = locateRepoBuildBinary(named: binaryName, referenceFilePath: referenceFilePath) {
            return devBinary
        }

        if let path = currentEnvironmentValue("PATH") {
            for dir in path.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent(binaryName)
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    private nonisolated static func locateRepoBuildBinary(
        named binaryName: String,
        referenceFilePath: String
    ) -> String? {
        var dir = URL(fileURLWithPath: referenceFilePath).deletingLastPathComponent()
        for _ in 0..<binarySearchAncestorLimit {
            let candidate = dir
                .appendingPathComponent("libsmithers/zig-out/bin/\(binaryName)")
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func currentEnvironmentValue(_ key: String) -> String? {
        if let value = getenv(key) {
            let string = String(cString: value)
            return string.isEmpty ? nil : string
        }
        return ProcessInfo.processInfo.environment[key]
    }

    // MARK: - RPC call

    private struct EmptyResult: Codable {}

    private func call<R: Decodable>(method: String, params: [String: SessionRPCValue]) async throws -> R {
        let id = nextRequestID()
        let request = encodeRequest(id: id, method: method, params: params)

        let path = socketPath()
        let fd = try connectSocket(path: path)
        defer { Darwin.close(fd) }

        try writeAll(fd: fd, bytes: request)
        let line = try readLine(fd: fd, maxLen: 8 * 1024 * 1024)
        return try decodeResult(line)
    }

    private func encodeRequest(id: Int, method: String, params: [String: SessionRPCValue]) -> Data {
        let body: [String: SessionRPCValue] = [
            "id": .int(id),
            "method": .string(method),
            "params": .object(params),
        ]
        var data = (try? JSONEncoder().encode(SessionRPCValue.object(body))) ?? Data()
        data.append(0x0A) // newline
        return data
    }

    private func decodeResult<R: Decodable>(_ data: Data) throws -> R {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionControllerError.decodingFailed("invalid JSON response")
        }
        if let errObj = root["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? -1
            let message = (errObj["message"] as? String) ?? "unknown error"
            throw SessionControllerError.rpcError(code: code, message: message)
        }
        if R.self == EmptyResult.self {
            // No-op: presence of result is sufficient.
            return EmptyResult() as! R
        }
        guard let resultAny = root["result"] else {
            throw SessionControllerError.decodingFailed("missing result")
        }
        let resultData: Data
        do {
            resultData = try JSONSerialization.data(withJSONObject: resultAny, options: [.fragmentsAllowed])
        } catch {
            throw SessionControllerError.decodingFailed("re-serialize: \(error)")
        }
        do {
            return try JSONDecoder().decode(R.self, from: resultData)
        } catch {
            throw SessionControllerError.decodingFailed(String(describing: error))
        }
    }

    // MARK: - Socket syscalls

    private func connectSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw SessionControllerError.daemonUnavailable
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count >= capacity {
            Darwin.close(fd)
            throw SessionControllerError.daemonUnavailable
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { cptr in
                for i in 0..<pathBytes.count { cptr[i] = CChar(bitPattern: pathBytes[i]) }
                cptr[pathBytes.count] = 0
            }
        }
        // sun_len on Darwin (BSD)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            throw SessionControllerError.daemonUnavailable
        }
        return fd
    }

    private func writeAll(fd: Int32, bytes: Data) throws {
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && (errno == EINTR) { continue }
                throw SessionControllerError.daemonUnavailable
            }
        }
    }

    private func readLine(fd: Int32, maxLen: Int) throws -> Data {
        var buf = Data()
        var byte: UInt8 = 0
        while buf.count < maxLen {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A { return buf }
                buf.append(byte)
                continue
            }
            if n == 0 {
                if buf.isEmpty { throw SessionControllerError.daemonUnavailable }
                return buf
            }
            if errno == EINTR { continue }
            throw SessionControllerError.daemonUnavailable
        }
        throw SessionControllerError.decodingFailed("response too large")
    }

    // recvmsg with ancillary data to pick up a single SCM_RIGHTS fd.
    // Layout mirrors libsmithers/src/session/fd_passing.zig sender:
    //   cmsghdr { cmsg_len: socklen_t, cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS }
    //   followed by one Int32 fd, with CMSG_ALIGN padding.
    // On Darwin SOL_SOCKET == 0xFFFF, SCM_RIGHTS == 0x01, and cmsg_len uses socklen_t.
    private func recvJSONWithFd(fd: Int32, maxPayload: Int) throws -> (Data, Int32?) {
        let payloadBuf = UnsafeMutableRawPointer.allocate(byteCount: maxPayload, alignment: 8)
        defer { payloadBuf.deallocate() }

        var iov = iovec(iov_base: payloadBuf, iov_len: maxPayload)

        // Space for one fd via SCM_RIGHTS. Keep it generous but fixed.
        let controlLen = 64
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLen, alignment: 8)
        defer { control.deallocate() }
        memset(control, 0, controlLen)

        return try withUnsafeMutablePointer(to: &iov) { iovPtr -> (Data, Int32?) in
            var msg = msghdr(
                msg_name: nil,
                msg_namelen: 0,
                msg_iov: iovPtr,
                msg_iovlen: 1,
                msg_control: control,
                msg_controllen: socklen_t(controlLen),
                msg_flags: 0
            )

            var n: Int
            while true {
                n = Darwin.recvmsg(fd, &msg, 0)
                if n >= 0 { break }
                if errno == EINTR { continue }
                throw SessionControllerError.daemonUnavailable
            }
            if n == 0 { throw SessionControllerError.daemonUnavailable }

            // Trim payload to first newline (line-delimited JSON).
            let data = Data(bytes: payloadBuf, count: n)
            let line: Data
            if let nl = data.firstIndex(of: 0x0A) {
                line = data.prefix(upTo: nl)
            } else {
                line = data
            }

            var extractedFd: Int32? = nil
            let cmsgLen = Int(msg.msg_controllen)
            if cmsgLen >= MemoryLayout<cmsghdr>.size {
                let hdr = control.assumingMemoryBound(to: cmsghdr.self).pointee
                // SOL_SOCKET on Darwin is 0xFFFF, SCM_RIGHTS is 0x01.
                if hdr.cmsg_level == SOL_SOCKET && hdr.cmsg_type == SCM_RIGHTS {
                    // CMSG_DATA: align(sizeof(cmsghdr)) from base.
                    let dataOffset = cmsgAlign(MemoryLayout<cmsghdr>.size)
                    if Int(hdr.cmsg_len) >= dataOffset + MemoryLayout<Int32>.size {
                        let fdPtr = control.advanced(by: dataOffset).assumingMemoryBound(to: Int32.self)
                        extractedFd = fdPtr.pointee
                    }
                }
            }

            return (Data(line), extractedFd)
        }
    }

    private nonisolated func cmsgAlign(_ len: Int) -> Int {
        let a = MemoryLayout<socklen_t>.size
        return (len + a - 1) & ~(a - 1)
    }
}

// MARK: - SessionRPCValue for request encoding

private enum SessionRPCValue: Encodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case object([String: SessionRPCValue])
    case array([SessionRPCValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        }
    }
}
