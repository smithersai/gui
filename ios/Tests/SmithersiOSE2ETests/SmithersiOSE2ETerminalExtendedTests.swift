// SmithersiOSE2ETerminalExtendedTests.swift — extended terminal / PTY E2E
// scenarios against the real plue backend.
//
// Scope:
//   - Keep the existing SmithersiOSE2ETerminalTests.swift untouched.
//   - Add 10 complementary scenarios covering mount, write, resize,
//     detach/reattach, reconnect, websocket validation, rate limiting,
//     and session tombstoning.
//
// Current app reality:
//   - The iOS workspace detail currently mounts TerminalSurface with
//     `transport: nil`, so scenarios that require live PTY byte flow are
//     intentionally strict and will surface that gap until the real
//     transport is wired.
//   - The terminal detail shell is gated by
//     `PLUE_E2E_WORKSPACE_SESSION_ID` in ProcessInfo today, not by a live
//     session lookup, so the tombstone scenario is also intentionally
//     strict and will catch that mismatch.

#if os(iOS)
import XCTest
import Foundation
import Darwin

final class SmithersiOSE2ETerminalExtendedTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_terminal_mounts_when_workspace_session_seeded() throws {
        guard let ctx = requireTerminalContext() else { return }

        let app = launchSignedInApp()
        XCTAssertFalse(
            terminalSurface(in: app).exists,
            "terminal surface must not leak onto the root shell before a workspace is opened"
        )

        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)

        XCTAssertTrue(
            terminalSurface(in: app).waitForExistence(timeout: 10),
            "seeded workspace session must mount the iOS terminal surface"
        )
        XCTAssertTrue(
            app.textFields["terminal.ios.input"].waitForExistence(timeout: 5),
            "terminal input field must render once the surface mounts"
        )
        XCTAssertFalse(
            app.otherElements["terminal.placeholder"].exists,
            "E2E must render the iOS terminal surface, not the UITest placeholder"
        )
    }

    func test_terminal_input_echoes() throws {
        guard let ctx = requireTerminalContext() else { return }

        let app = launchSignedInApp()
        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)

        let input = app.textFields["terminal.ios.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "terminal input must exist")

        let marker = "e2e-echo-\(UUID().uuidString.prefix(8))"
        XCTAssertFalse(
            renderedTerminalText(in: app).contains(marker),
            "terminal scrollback must not already contain the unique marker before input is sent"
        )

        input.tap()
        input.typeText(marker)
        app.buttons["terminal.ios.send"].tap()

        XCTAssertTrue(
            waitForTerminalText(marker, in: app, timeout: 10),
            "typed marker must echo back into the terminal text view within 10 seconds"
        )
    }

    func test_terminal_resize_on_rotation() throws {
        guard let ctx = requireTerminalContext() else { return }

        let app = launchSignedInApp()
        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)
        XCTAssertTrue(
            terminalSurface(in: app).waitForExistence(timeout: 10),
            "terminal surface must exist before rotation"
        )

        let device = XCUIDevice.shared
        let original = device.orientation
        defer {
            device.orientation = original == .unknown ? .portrait : original
        }

        device.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.workspaceDetailShell(in: app).exists &&
                    self.terminalSurface(in: app).exists &&
                    self.appBackButton(in: app).exists
            },
            "rotating to landscape must keep the workspace detail and terminal mounted"
        )

        device.orientation = .portrait
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                self.workspaceDetailShell(in: app).exists &&
                    self.terminalSurface(in: app).exists &&
                    self.appBackButton(in: app).exists
            },
            "rotating back to portrait must not crash or unmount the terminal"
        )
        XCTAssertFalse(
            app.otherElements["terminal.placeholder"].exists,
            "rotation must keep the real iOS terminal renderer mounted"
        )
    }

    func test_terminal_detach_reattach_preserves_scrollback() throws {
        guard let ctx = requireTerminalContext() else { return }

        let app = launchSignedInApp()
        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)

        let input = app.textFields["terminal.ios.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "terminal input must exist")

        let marker = "e2e-scrollback-\(UUID().uuidString.prefix(8))"
        XCTAssertFalse(
            renderedTerminalText(in: app).contains(marker),
            "marker must not already exist before we write it"
        )

        input.tap()
        input.typeText(marker)
        app.buttons["terminal.ios.send"].tap()

        XCTAssertTrue(
            waitForTerminalText(marker, in: app, timeout: 10),
            "marker must be visible before we detach from the workspace detail"
        )

        appBackButton(in: app).tap()
        XCTAssertFalse(
            terminalSurface(in: app).exists,
            "leaving the workspace detail must unmount the terminal surface from the root shell"
        )

        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)
        XCTAssertTrue(
            waitForTerminalText(marker, in: app, timeout: 5),
            "reattaching to the same workspace must preserve prior terminal scrollback"
        )
    }

    func test_terminal_reconnect_after_ws_pause() throws {
        guard let ctx = requireTerminalContext() else { return }
        guard !ctx.dockerAPIContainer.isEmpty else {
            throw XCTSkip("PLUE_E2E_DOCKER_API_CONTAINER not set")
        }

        let app = launchSignedInApp()
        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)
        XCTAssertTrue(
            terminalSurface(in: app).waitForExistence(timeout: 10),
            "terminal surface must mount before the docker pause sequence"
        )

        let pauseStatus = try runHostCommand(["docker", "pause", ctx.dockerAPIContainer])
        XCTAssertEqual(
            pauseStatus, 0,
            "docker pause must succeed for reconnect coverage"
        )
        var didUnpause = false
        defer {
            if !didUnpause {
                _ = try? runHostCommand(["docker", "unpause", ctx.dockerAPIContainer])
            }
        }

        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(
            isBackendHealthy(baseURL: ctx.baseURL, timeout: 2),
            "paused plue api container must make the backend temporarily unreachable"
        )

        let unpauseStatus = try runHostCommand(["docker", "unpause", ctx.dockerAPIContainer])
        didUnpause = true
        XCTAssertEqual(
            unpauseStatus, 0,
            "docker unpause must succeed for reconnect coverage"
        )

        XCTAssertTrue(
            waitUntil(timeout: 20, pollInterval: 0.5) {
                self.isBackendHealthy(baseURL: ctx.baseURL, timeout: 2)
            },
            "plue api must recover after docker unpause"
        )
        XCTAssertTrue(
            waitUntil(timeout: 10, pollInterval: 0.25) {
                self.workspaceDetailShell(in: app).exists &&
                    self.terminalSurface(in: app).exists
            },
            "terminal detail must recover after the websocket pause window"
        )
    }

    func test_terminal_origin_header_enforced() throws {
        guard let ctx = requireTerminalContext() else { return }

        let attempt = attemptWebSocket(
            url: ctx.terminalWebSocketURL,
            origin: "http://evil.example:9999",
            bearer: ctx.bearer,
            protocols: ["terminal"],
            timeout: 5
        )

        assertRejected(
            attempt,
            reason: "terminal websocket must reject a bad Origin header"
        )
        XCTAssertNotEqual(
            attempt.negotiatedProtocol,
            "terminal",
            "bad-origin websocket must not negotiate the terminal subprotocol"
        )
    }

    func test_terminal_bearer_required() throws {
        guard let ctx = requireTerminalContext() else { return }

        let attempt = attemptWebSocket(
            url: ctx.terminalWebSocketURL,
            origin: ctx.allowedOrigin,
            bearer: nil,
            protocols: ["terminal"],
            timeout: 5
        )

        assertRejected(
            attempt,
            reason: "terminal websocket must reject requests with no bearer token"
        )
        XCTAssertFalse(
            attempt.didOpen,
            "missing-bearer websocket must not open"
        )
    }

    func test_terminal_subprotocol_must_be_terminal() throws {
        guard let ctx = requireTerminalContext() else { return }

        let attempt = attemptWebSocket(
            url: ctx.terminalWebSocketURL,
            origin: ctx.allowedOrigin,
            bearer: ctx.bearer,
            protocols: ["not-terminal"],
            timeout: 5
        )

        assertRejected(
            attempt,
            reason: "terminal websocket must reject a non-terminal subprotocol"
        )
        XCTAssertNotEqual(
            attempt.negotiatedProtocol,
            "terminal",
            "wrong-subprotocol websocket must not negotiate the terminal protocol"
        )
    }

    func test_terminal_rate_limit_on_open() throws {
        guard let ctx = requireTerminalContext() else { return }

        try resetAuthRateLimits(baseURL: ctx.baseURL)
        defer { try? resetAuthRateLimits(baseURL: ctx.baseURL) }

        let warmupURL = ctx.terminalHTTPURL
        for index in 0..<45 {
            let request = websocketUpgradeRequest(
                url: warmupURL,
                origin: ctx.allowedOrigin,
                bearer: nil,
                subprotocol: "terminal"
            )
            let (_, status) = try syncRequest(request, timeout: 5)
            XCTAssertNotEqual(
                status, 429,
                "warm-up request \(index + 1) must not hit the global API rate limit yet"
            )
        }

        let statuses = try burstStatuses(count: 20, timeout: 10) {
            self.websocketUpgradeRequest(
                url: warmupURL,
                origin: ctx.allowedOrigin,
                bearer: nil,
                subprotocol: "terminal"
            )
        }

        XCTAssertTrue(
            statuses.contains(429),
            "rapid terminal open attempts must produce at least one HTTP 429 after crossing the anonymous API limit"
        )
        XCTAssertTrue(
            statuses.contains { $0 != 429 },
            "burst must straddle the threshold; if every request is 429 the test started already rate-limited"
        )
    }

    func test_terminal_unmounts_when_workspace_session_tombstoned() throws {
        guard let ctx = requireTerminalContext() else { return }

        let app = launchSignedInApp()
        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)
        XCTAssertTrue(
            terminalSurface(in: app).waitForExistence(timeout: 10),
            "terminal surface must be mounted before we tombstone the seeded workspace session"
        )

        let destroyRequest = authorizedRequest(
            url: ctx.destroySessionURL,
            bearer: ctx.bearer,
            method: "POST"
        )
        let (_, destroyStatus) = try syncRequest(destroyRequest, timeout: 10)
        XCTAssertEqual(
            destroyStatus, 204,
            "workspace session destroy route must accept the seeded session id"
        )

        appBackButton(in: app).tap()
        XCTAssertFalse(
            terminalSurface(in: app).exists,
            "after leaving detail, the terminal must no longer be visible on the root shell"
        )

        openSeededWorkspace(in: app, workspaceID: ctx.workspaceID)
        let terminalEmptyState = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail.terminal-empty").firstMatch
        XCTAssertFalse(
            terminalSurface(in: app).waitForExistence(timeout: 5),
            "after the workspace session is tombstoned, reopening the workspace must not render the terminal surface"
        )
        XCTAssertTrue(
            terminalEmptyState.waitForExistence(timeout: 5),
            "after the workspace session is tombstoned, reopening the workspace must show the terminal-empty state"
        )
    }

    // MARK: - App helpers

    private func launchSignedInApp() -> XCUIApplication {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in iOS shell must mount in E2E mode"
        )
        return app
    }

    private func openSeededWorkspace(in app: XCUIApplication, workspaceID: String) {
        let switcherButton = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(
            switcherButton.waitForExistence(timeout: 10),
            "root shell must expose the workspace switcher trigger"
        )
        switcherButton.tap()

        let switcherRoot = app.descendants(matching: .any)
            .matching(identifier: "switcher.ios.root").firstMatch
        XCTAssertTrue(
            switcherRoot.waitForExistence(timeout: 10),
            "workspace switcher must present before selecting the seeded row"
        )

        let exactRow = app.buttons["switcher.row.\(workspaceID)"]
        let row = exactRow.waitForExistence(timeout: 10)
            ? exactRow
            : app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
            ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "seeded workspace switcher row must exist"
        )
        row.tap()

        XCTAssertTrue(
            workspaceDetailShell(in: app).waitForExistence(timeout: 10),
            "workspace detail shell must render after selecting the seeded row"
        )
    }

    private func workspaceDetailShell(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail").firstMatch
    }

    private func terminalSurface(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "terminal.ios.surface").firstMatch
    }

    private func appBackButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["content.ios.workspace-detail.back"]
    }

    private func renderedTerminalText(in app: XCUIApplication) -> String {
        let textView = app.textViews["terminal.ios.text"]
        guard textView.exists else { return "" }

        if let value = textView.value as? String, !value.isEmpty {
            return value
        }
        if !textView.label.isEmpty {
            return textView.label
        }

        let fragments = textView.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .filter { !$0.isEmpty }
        return fragments.joined(separator: "\n")
    }

    private func waitForTerminalText(
        _ needle: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout, pollInterval: 0.2) {
            self.renderedTerminalText(in: app).contains(needle)
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return condition()
    }

    // MARK: - Environment

    private func requireTerminalContext(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TerminalE2EContext? {
        let env = ProcessInfo.processInfo.environment

        guard env[E2ELaunchKey.seededData] == "1" else {
            XCTFail("terminal extended scenarios require PLUE_E2E_SEEDED=1", file: file, line: line)
            return nil
        }
        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            XCTFail("terminal extended scenarios require SMITHERS_E2E_BEARER", file: file, line: line)
            return nil
        }
        guard let baseURLString = env[E2ELaunchKey.baseURL],
              let baseURL = URL(string: baseURLString) else {
            XCTFail("terminal extended scenarios require PLUE_BASE_URL", file: file, line: line)
            return nil
        }
        guard let workspaceID = env[E2ELaunchKey.seededWorkspaceID], !workspaceID.isEmpty else {
            XCTFail("terminal extended scenarios require PLUE_E2E_WORKSPACE_ID", file: file, line: line)
            return nil
        }
        guard let workspaceSessionID = env[E2ELaunchKey.seededWorkspaceSessionID],
              !workspaceSessionID.isEmpty else {
            XCTFail("terminal extended scenarios require PLUE_E2E_WORKSPACE_SESSION_ID", file: file, line: line)
            return nil
        }
        guard let owner = env[E2ELaunchKey.seededRepoOwner], !owner.isEmpty,
              let repoName = env[E2ELaunchKey.seededRepoName], !repoName.isEmpty else {
            XCTFail("terminal extended scenarios require PLUE_E2E_REPO_OWNER + PLUE_E2E_REPO_NAME", file: file, line: line)
            return nil
        }

        return TerminalE2EContext(
            baseURL: baseURL,
            bearer: bearer,
            workspaceID: workspaceID,
            workspaceSessionID: workspaceSessionID,
            repoOwner: owner,
            repoName: repoName,
            dockerAPIContainer: env[E2ELaunchKey.dockerAPIContainer] ?? ""
        )
    }

    // MARK: - HTTP / WS helpers

    private func isBackendHealthy(baseURL: URL, timeout: TimeInterval) -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, status) = try syncRequest(request, timeout: timeout)
            return status == 200
        } catch {
            return false
        }
    }

    private func resetAuthRateLimits(baseURL: URL) throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/_test/auth-rate-limits"))
        request.httpMethod = "DELETE"
        let (_, status) = try syncRequest(request, timeout: 10)
        XCTAssertEqual(status, 204, "DELETE /api/_test/auth-rate-limits must succeed in the docker E2E stack")
    }

    private func authorizedRequest(
        url: URL,
        bearer: String,
        method: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func websocketUpgradeRequest(
        url: URL,
        origin: String,
        bearer: String?,
        subprotocol: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue(webSocketKey(), forHTTPHeaderField: "Sec-WebSocket-Key")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let subprotocol {
            request.setValue(subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return request
    }

    private func syncRequest(
        _ request: URLRequest,
        timeout: TimeInterval
    ) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        let session = URLSession(configuration: config)

        var output: (Data, Int)?
        var outputError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                outputError = error
            } else if let http = response as? HTTPURLResponse {
                output = (data ?? Data(), http.statusCode)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        session.invalidateAndCancel()

        if let outputError {
            throw outputError
        }
        guard let output else {
            throw NSError(
                domain: "terminal-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "timed out waiting for \(request.url?.absoluteString ?? "<nil>")"]
            )
        }
        return output
    }

    private func burstStatuses(
        count: Int,
        timeout: TimeInterval,
        requestFactory: @escaping () -> URLRequest
    ) throws -> [Int] {
        let group = DispatchGroup()
        let lock = NSLock()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = max(20, count)
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        let session = URLSession(configuration: config)

        var statuses: [Int] = []
        for _ in 0..<count {
            group.enter()
            let task = session.dataTask(with: requestFactory()) { _, response, error in
                lock.lock()
                defer {
                    lock.unlock()
                    group.leave()
                }
                if let http = response as? HTTPURLResponse {
                    statuses.append(http.statusCode)
                } else if error != nil {
                    statuses.append(-1)
                } else {
                    statuses.append(-2)
                }
            }
            task.resume()
        }

        let waitResult = group.wait(timeout: .now() + timeout + 5)
        session.invalidateAndCancel()
        guard waitResult == .success else {
            throw NSError(
                domain: "terminal-e2e",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey:
                    "timed out waiting for burst request completion"]
            )
        }
        return statuses
    }

    private func attemptWebSocket(
        url: URL,
        origin: String,
        bearer: String?,
        protocols: [String],
        timeout: TimeInterval
    ) -> WebSocketAttempt {
        let observer = WebSocketTaskObserver()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        let session = URLSession(
            configuration: config,
            delegate: observer,
            delegateQueue: nil
        )

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        let task = session.webSocketTask(with: request)
        task.resume()
        task.receive { result in
            observer.recordReceive(result)
        }

        let waiter = XCTWaiter()
        let waitResult = waiter.wait(for: [observer.stateChange], timeout: timeout)
        let outcome = observer.snapshot(waitResult: waitResult)

        task.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
        session.invalidateAndCancel()
        return outcome
    }

    private func assertRejected(
        _ attempt: WebSocketAttempt,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(attempt.didOpen, reason, file: file, line: line)
        XCTAssertTrue(
            attempt.completionError != nil ||
                attempt.receiveError != nil ||
                attempt.waitResult == .timedOut,
            "\(reason) (expected completion/receive error, got waitResult=\(String(describing: attempt.waitResult)))",
            file: file,
            line: line
        )
    }

    private func webSocketKey() -> String {
        Data(UUID().uuidString.utf8).base64EncodedString()
    }

    // MARK: - Host command helper

    private func runHostCommand(_ arguments: [String]) throws -> Int32 {
        // `Foundation.Process` is unavailable in an iOS UI-test target, so
        // we use `posix_spawn` directly to launch `/usr/bin/env docker ...`.
        try withCStringArray(["/usr/bin/env"] + arguments) { argv in
            try withCStringArray(
                ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            ) { envp in
                var pid = pid_t()
                let spawnStatus = posix_spawn(&pid, "/usr/bin/env", nil, nil, argv, envp)
                guard spawnStatus == 0 else {
                    throw NSError(
                        domain: "terminal-e2e",
                        code: Int(spawnStatus),
                        userInfo: [NSLocalizedDescriptionKey:
                            "posix_spawn failed for /usr/bin/env \(arguments.joined(separator: " "))"]
                    )
                }

                var waitStatus: Int32 = 0
                guard waitpid(pid, &waitStatus, 0) == pid else {
                    throw NSError(
                        domain: "terminal-e2e",
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey:
                            "waitpid failed for /usr/bin/env \(arguments.joined(separator: " "))"]
                    )
                }
                return waitStatus
            }
        }
    }

    private func withCStringArray<R>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
    ) throws -> R {
        var cStrings = strings.map { strdup($0) }
        defer {
            for ptr in cStrings {
                if let ptr {
                    free(ptr)
                }
            }
        }
        cStrings.append(nil)
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private struct TerminalE2EContext {
    let baseURL: URL
    let bearer: String
    let workspaceID: String
    let workspaceSessionID: String
    let repoOwner: String
    let repoName: String
    let dockerAPIContainer: String

    var allowedOrigin: String {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.string ?? baseURL.absoluteString
    }

    var terminalHTTPURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(repoOwner)
            .appendingPathComponent(repoName)
            .appendingPathComponent("workspace")
            .appendingPathComponent("sessions")
            .appendingPathComponent(workspaceSessionID)
            .appendingPathComponent("terminal")
    }

    var terminalWebSocketURL: URL {
        var components = URLComponents(url: terminalHTTPURL, resolvingAgainstBaseURL: false)!
        components.scheme = terminalHTTPURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    var destroySessionURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(repoOwner)
            .appendingPathComponent(repoName)
            .appendingPathComponent("workspace")
            .appendingPathComponent("sessions")
            .appendingPathComponent(workspaceSessionID)
            .appendingPathComponent("destroy")
    }
}

private struct WebSocketAttempt {
    let didOpen: Bool
    let negotiatedProtocol: String?
    let completionError: Error?
    let receiveError: Error?
    let waitResult: XCTWaiter.Result
}

private final class WebSocketTaskObserver: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    let stateChange = XCTestExpectation(description: "websocket state change")

    private let lock = NSLock()
    private var fulfilled = false
    private var opened = false
    private var protocolName: String?
    private var taskError: Error?
    private var readError: Error?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        opened = true
        protocolName = `protocol`
        fulfillIfNeeded()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        taskError = error
        fulfillIfNeeded()
        lock.unlock()
    }

    func recordReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard case .failure(let error) = result else { return }
        lock.lock()
        readError = error
        fulfillIfNeeded()
        lock.unlock()
    }

    func snapshot(waitResult: XCTWaiter.Result) -> WebSocketAttempt {
        lock.lock()
        defer { lock.unlock() }
        return WebSocketAttempt(
            didOpen: opened,
            negotiatedProtocol: protocolName,
            completionError: taskError,
            receiveError: readError,
            waitResult: waitResult
        )
    }

    private func fulfillIfNeeded() {
        guard !fulfilled else { return }
        fulfilled = true
        stateChange.fulfill()
    }
}
#endif
