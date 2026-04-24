#if os(iOS)
import Foundation
import XCTest

private enum DevtoolsEnvKey {
    static let repoID = "PLUE_E2E_REPO_ID"
    static let workspaceID = "PLUE_E2E_WORKSPACE_ID"
    static let repoOwner = "PLUE_E2E_REPO_OWNER"
    static let repoName = "PLUE_E2E_REPO_NAME"
}

private enum DevtoolsAuthMode {
    case bearer
    case none
}

private enum DevtoolsLogicalKind {
    case console
    case network

    // Ticket 0107's reference implementation uses a closed enum
    // (`command_output`, `tool_state`, etc.), while the GUI ticket asks
    // for logical "console" / "network" coverage. Try the user-facing
    // kind first, then fall back to the plue-side enum when the backend
    // rejects the logical name.
    var candidateAPIKinds: [String] {
        switch self {
        case .console:
            return ["console", "command_output"]
        case .network:
            return ["network", "tool_state"]
        }
    }
}

private struct DevtoolsE2EContext {
    let baseURL: URL
    let bearer: String
    let repoID: Int64
    let repoOwner: String?
    let repoName: String?
    let sessionID: String
    let workspaceID: String?
}

private struct HTTPResult {
    let statusCode: Int
    let data: Data
    let body: String
    let headers: [AnyHashable: Any]
}

private struct SnapshotWriteResult {
    let path: String
    let apiKind: String
    let statusCode: Int
    let body: String
    let snapshotID: String
}

private struct SnapshotReadView {
    let source: String
    let statusCode: Int
    let body: String
}

private enum DevtoolsTestError: LocalizedError {
    case missingEnvironment(String)
    case badEnvironment(String)
    case missingWriteEndpoint([String])
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let key):
            return "missing required E2E environment key: \(key)"
        case .badEnvironment(let message):
            return message
        case .missingWriteEndpoint(let attempts):
            let detail = attempts.isEmpty ? "no candidate paths were tried" : attempts.joined(separator: ", ")
            return "bug candidate: no devtools snapshot write endpoint reachable with a signed-in bearer (\(detail))"
        case .timedOut(let message):
            return message
        }
    }
}

private final class ShapeStreamRecorder: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var completionError: Error?

    var statusCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return response?.statusCode
    }

    var bodyString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? "<non-utf8>"
    }

    var errorDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return completionError?.localizedDescription
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        completionError = error
        lock.unlock()
    }
}

private final class ShapeStreamProbe {
    private let session: URLSession
    private let task: URLSessionDataTask
    private let recorder: ShapeStreamRecorder

    init(request: URLRequest) {
        let recorder = ShapeStreamRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        self.recorder = recorder
        self.session = URLSession(configuration: config, delegate: recorder, delegateQueue: nil)
        self.task = session.dataTask(with: request)
        task.resume()
    }

    deinit {
        close()
    }

    func currentBody() -> String {
        recorder.bodyString
    }

    func waitForAnyData(timeout: TimeInterval) -> SnapshotReadView {
        wait(timeout: timeout, matcher: { !$0.isEmpty })
    }

    func waitForContains(_ needle: String, timeout: TimeInterval) -> SnapshotReadView {
        wait(timeout: timeout, matcher: { $0.contains(needle) })
    }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }

    private func wait(timeout: TimeInterval, matcher: (String) -> Bool) -> SnapshotReadView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = recorder.statusCode
            let body = recorder.bodyString
            if let status, !(200...299).contains(status) {
                return SnapshotReadView(source: "shape", statusCode: status, body: body)
            }
            if matcher(body) {
                return SnapshotReadView(source: "shape", statusCode: status ?? 200, body: body)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        var finalBody = recorder.bodyString
        if finalBody.isEmpty, let error = recorder.errorDescription {
            finalBody = "<stream-error> \(error)"
        }
        return SnapshotReadView(
            source: "shape",
            statusCode: recorder.statusCode ?? -1,
            body: finalBody
        )
    }
}

private final class DevtoolsTestClient {
    let context: DevtoolsE2EContext
    private var featureFlagsCache: [String: Bool]?

    init(context: DevtoolsE2EContext) {
        self.context = context
    }

    static func fromEnvironment() throws -> DevtoolsTestClient {
        let env = ProcessInfo.processInfo.environment

        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            throw DevtoolsTestError.missingEnvironment(E2ELaunchKey.bearer)
        }
        guard let baseURLString = env[E2ELaunchKey.baseURL], !baseURLString.isEmpty else {
            throw DevtoolsTestError.missingEnvironment(E2ELaunchKey.baseURL)
        }
        guard let baseURL = URL(string: baseURLString) else {
            throw DevtoolsTestError.badEnvironment("invalid \(E2ELaunchKey.baseURL): \(baseURLString)")
        }
        guard let repoIDString = env[DevtoolsEnvKey.repoID], let repoID = Int64(repoIDString) else {
            throw DevtoolsTestError.missingEnvironment(DevtoolsEnvKey.repoID)
        }
        guard let sessionID = env[E2ELaunchKey.seededAgentSessionID], !sessionID.isEmpty else {
            throw DevtoolsTestError.missingEnvironment(E2ELaunchKey.seededAgentSessionID)
        }

        return DevtoolsTestClient(
            context: DevtoolsE2EContext(
                baseURL: baseURL,
                bearer: bearer,
                repoID: repoID,
                repoOwner: env[DevtoolsEnvKey.repoOwner],
                repoName: env[DevtoolsEnvKey.repoName],
                sessionID: sessionID,
                workspaceID: env[DevtoolsEnvKey.workspaceID]
            )
        )
    }

    func skipPositiveScenariosIfFlagExplicitlyDisabled() throws {
        guard let state = try featureFlagState(named: "devtools_snapshot_enabled"),
              state == false else {
            return
        }
        throw XCTSkip("devtools_snapshot_enabled=false on this backend; positive devtools snapshot scenarios are unavailable by design")
    }

    func featureFlagState(named name: String) throws -> Bool? {
        let flags = try fetchFeatureFlags()
        guard flags.keys.contains(name) else { return nil }
        return flags[name]
    }

    func fetchFeatureFlags() throws -> [String: Bool] {
        if let featureFlagsCache {
            return featureFlagsCache
        }
        let result = try send(
            method: "GET",
            path: "api/feature-flags",
            authMode: .bearer
        )
        guard result.statusCode == 200 else {
            throw DevtoolsTestError.badEnvironment(
                "GET /api/feature-flags returned \(result.statusCode): \(result.body)"
            )
        }

        let flags: [String: Bool]
        if let envelope = try? JSONDecoder().decode(FeatureFlagsEnvelope.self, from: result.data) {
            flags = envelope.flags
        } else if let direct = try? JSONDecoder().decode([String: Bool].self, from: result.data) {
            flags = direct
        } else {
            throw DevtoolsTestError.badEnvironment("feature-flags response was not decodable JSON")
        }
        featureFlagsCache = flags
        return flags
    }

    func uniqueMarker(_ prefix: String) -> String {
        "devtools-\(prefix)-\(UUID().uuidString.lowercased())"
    }

    func postSnapshot(
        logicalKind: DevtoolsLogicalKind,
        payload: [String: Any],
        authMode: DevtoolsAuthMode = .bearer
    ) throws -> SnapshotWriteResult {
        var lastKindFailure: SnapshotWriteResult?

        for apiKind in logicalKind.candidateAPIKinds {
            let result = try postSnapshot(
                apiKind: apiKind,
                payload: payload,
                authMode: authMode
            )

            if isKindValidationFailure(result) {
                lastKindFailure = result
                continue
            }
            return result
        }

        if let lastKindFailure {
            return lastKindFailure
        }
        throw DevtoolsTestError.badEnvironment("no candidate kind was attempted for \(logicalKind)")
    }

    func postSnapshot(
        path: String,
        apiKind: String,
        payload: [String: Any],
        authMode: DevtoolsAuthMode = .bearer
    ) throws -> SnapshotWriteResult {
        let result = try send(
            method: "POST",
            path: path,
            jsonObject: snapshotBody(apiKind: apiKind, payload: payload),
            authMode: authMode
        )
        return SnapshotWriteResult(
            path: path,
            apiKind: apiKind,
            statusCode: result.statusCode,
            body: result.body,
            snapshotID: extractSnapshotID(from: result.data)
        )
    }

    func fetchLatestView(
        sessionID: String? = nil,
        repoID: Int64? = nil,
        workspaceID: String? = nil,
        waitFor marker: String? = nil,
        timeout: TimeInterval = 5
    ) throws -> SnapshotReadView {
        let sessionID = sessionID ?? context.sessionID
        let repoID = repoID ?? context.repoID
        let workspaceID = workspaceID ?? context.workspaceID
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let view = try fetchLatestHTTPView(
                sessionID: sessionID,
                repoID: repoID,
                workspaceID: workspaceID
            ) {
                if view.statusCode >= 400 || marker == nil || view.body.contains(marker!) {
                    return view
                }
            } else {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let probe = try openShapeProbe(sessionID: sessionID, repoID: repoID)
        defer { probe.close() }
        let remaining = max(1, deadline.timeIntervalSinceNow)
        if let marker {
            return probe.waitForContains(marker, timeout: remaining)
        }
        return probe.waitForAnyData(timeout: remaining)
    }

    func openShapeProbe(sessionID: String? = nil, repoID: Int64? = nil) throws -> ShapeStreamProbe {
        let sessionID = sessionID ?? context.sessionID
        let repoID = repoID ?? context.repoID
        let whereClause = "repository_id IN (\(repoID)) AND session_id IN ('\(sessionID)')"

        var request = URLRequest(url: try endpointURL(
            path: "v1/shape",
            queryItems: [
                URLQueryItem(name: "table", value: "devtools_snapshots"),
                URLQueryItem(name: "where", value: whereClause),
            ]
        ))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(context.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return ShapeStreamProbe(request: request)
    }

    func regexCount(pattern: String, in body: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(
            in: body,
            options: [],
            range: NSRange(body.startIndex..., in: body)
        )
    }

    private func postSnapshot(
        apiKind: String,
        payload: [String: Any],
        authMode: DevtoolsAuthMode
    ) throws -> SnapshotWriteResult {
        var misses: [String] = []
        for path in writePathCandidates() {
            let result = try send(
                method: "POST",
                path: path,
                jsonObject: snapshotBody(apiKind: apiKind, payload: payload),
                authMode: authMode
            )
            switch result.statusCode {
            case 404, 405, 501:
                misses.append("\(path) -> \(result.statusCode)")
                continue
            default:
                return SnapshotWriteResult(
                    path: path,
                    apiKind: apiKind,
                    statusCode: result.statusCode,
                    body: result.body,
                    snapshotID: extractSnapshotID(from: result.data)
                )
            }
        }
        throw DevtoolsTestError.missingWriteEndpoint(misses)
    }

    private func fetchLatestHTTPView(
        sessionID: String,
        repoID: Int64,
        workspaceID: String?
    ) throws -> SnapshotReadView? {
        let queryItems = [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "repository_id", value: String(repoID)),
            URLQueryItem(name: "workspace_id", value: workspaceID),
            URLQueryItem(name: "latest", value: "1"),
        ].compactMap { (item: URLQueryItem) -> URLQueryItem? in
            guard let value = item.value, !value.isEmpty else { return nil }
            return item
        }

        for path in readPathCandidates(sessionID: sessionID) {
            let result = try send(
                method: "GET",
                path: path,
                queryItems: queryItems,
                authMode: .bearer
            )
            switch result.statusCode {
            case 404, 405, 501:
                continue
            default:
                return SnapshotReadView(
                    source: path,
                    statusCode: result.statusCode,
                    body: result.body
                )
            }
        }
        return nil
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let rawURL = context.baseURL.appendingPathComponent(trimmed)
        guard var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
            throw DevtoolsTestError.badEnvironment("failed to build URL for path \(path)")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let finalURL = components.url else {
            throw DevtoolsTestError.badEnvironment("failed to resolve URL components for \(path)")
        }
        return finalURL
    }

    private func send(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonObject: [String: Any]? = nil,
        authMode: DevtoolsAuthMode,
        timeout: TimeInterval = 15
    ) throws -> HTTPResult {
        var request = URLRequest(url: try endpointURL(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if jsonObject != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        switch authMode {
        case .bearer:
            request.setValue("Bearer \(context.bearer)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }
        if let jsonObject {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        }
        return try syncRequest(request)
    }

    private func syncRequest(_ request: URLRequest) throws -> HTTPResult {
        var output: HTTPResult?
        var outputError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outputError = error
                return
            }
            guard let response = response as? HTTPURLResponse else {
                outputError = DevtoolsTestError.badEnvironment("non-HTTP response for \(request.url?.absoluteString ?? "<nil>")")
                return
            }
            let data = data ?? Data()
            output = HTTPResult(
                statusCode: response.statusCode,
                data: data,
                body: String(data: data, encoding: .utf8) ?? "<non-utf8>",
                headers: response.allHeaderFields
            )
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + request.timeoutInterval)
        if waitResult == .timedOut {
            task.cancel()
            throw DevtoolsTestError.timedOut("timed out waiting for \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")")
        }
        if let outputError {
            throw outputError
        }
        guard let output else {
            throw DevtoolsTestError.badEnvironment("request finished without output for \(request.url?.absoluteString ?? "<nil>")")
        }
        return output
    }

    private func snapshotBody(apiKind: String, payload: [String: Any]) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": context.sessionID,
            "repository_id": context.repoID,
            "kind": apiKind,
            "payload": payload,
        ]
        if let workspaceID = context.workspaceID, !workspaceID.isEmpty {
            body["workspace_id"] = workspaceID
        }
        return body
    }

    private func writePathCandidates() -> [String] {
        var paths: [String] = []
        if let prefix = repoPrefix() {
            let sessionPrefix = "\(prefix)/agent/sessions/\(escapedPathComponent(context.sessionID))"
            paths.append(contentsOf: [
                "\(sessionPrefix)/devtools_snapshots",
                "\(sessionPrefix)/devtools-snapshots",
                "\(sessionPrefix)/devtools/snapshots",
                "\(prefix)/devtools_snapshots",
                "\(prefix)/devtools-snapshots",
                "\(prefix)/devtools/snapshots",
            ])
        }
        paths.append(contentsOf: [
            "api/agent/sessions/\(escapedPathComponent(context.sessionID))/devtools_snapshots",
            "api/agent/sessions/\(escapedPathComponent(context.sessionID))/devtools-snapshots",
            "api/agent/sessions/\(escapedPathComponent(context.sessionID))/devtools/snapshots",
            "api/devtools_snapshots",
            "api/devtools-snapshots",
            "api/devtools/snapshots",
        ])
        return paths
    }

    private func readPathCandidates(sessionID: String) -> [String] {
        var paths: [String] = []
        if let prefix = repoPrefix() {
            let sessionPrefix = "\(prefix)/agent/sessions/\(escapedPathComponent(sessionID))"
            paths.append(contentsOf: [
                "\(sessionPrefix)/devtools_snapshots/latest",
                "\(sessionPrefix)/devtools-snapshots/latest",
                "\(sessionPrefix)/devtools/snapshots/latest",
                "\(sessionPrefix)/devtools_snapshots",
                "\(sessionPrefix)/devtools-snapshots",
                "\(sessionPrefix)/devtools/snapshots",
                "\(prefix)/devtools_snapshots/latest",
                "\(prefix)/devtools-snapshots/latest",
                "\(prefix)/devtools/snapshots/latest",
                "\(prefix)/devtools_snapshots",
                "\(prefix)/devtools-snapshots",
                "\(prefix)/devtools/snapshots",
            ])
        }
        paths.append(contentsOf: [
            "api/agent/sessions/\(escapedPathComponent(sessionID))/devtools_snapshots/latest",
            "api/agent/sessions/\(escapedPathComponent(sessionID))/devtools-snapshots/latest",
            "api/agent/sessions/\(escapedPathComponent(sessionID))/devtools/snapshots/latest",
            "api/agent/sessions/\(escapedPathComponent(sessionID))/devtools_snapshots",
            "api/agent/sessions/\(escapedPathComponent(sessionID))/devtools-snapshots",
            "api/agent/sessions/\(escapedPathComponent(sessionID))/devtools/snapshots",
            "api/devtools_snapshots/latest",
            "api/devtools-snapshots/latest",
            "api/devtools/snapshots/latest",
            "api/devtools_snapshots",
            "api/devtools-snapshots",
            "api/devtools/snapshots",
        ])
        return paths
    }

    private func repoPrefix() -> String? {
        guard let owner = context.repoOwner, !owner.isEmpty,
              let repoName = context.repoName, !repoName.isEmpty else {
            return nil
        }
        return "api/repos/\(escapedPathComponent(owner))/\(escapedPathComponent(repoName))"
    }

    private func escapedPathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    private func isKindValidationFailure(_ result: SnapshotWriteResult) -> Bool {
        guard result.statusCode == 400 || result.statusCode == 422 else { return false }
        let lowered = result.body.lowercased()
        return lowered.contains("kind") &&
            (lowered.contains("enum") ||
             lowered.contains("allowed") ||
             lowered.contains("invalid"))
    }

    private func extractSnapshotID(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return ""
        }

        let candidateDicts: [[String: Any]] = {
            var dicts: [[String: Any]] = []
            if let top = object as? [String: Any] {
                dicts.append(top)
                if let snapshot = top["snapshot"] as? [String: Any] {
                    dicts.append(snapshot)
                }
                if let data = top["data"] as? [String: Any] {
                    dicts.append(data)
                }
            }
            return dicts
        }()

        for dict in candidateDicts {
            for key in ["id", "snapshot_id", "snapshotId"] {
                if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return ""
    }
}

private struct FeatureFlagsEnvelope: Decodable {
    let flags: [String: Bool]
}

final class SmithersiOSE2EDevtoolsSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_devtools_snapshot_post_writes_row() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let marker = client.uniqueMarker("post")
        let result = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": marker,
                "message": "hello from xcuitest",
            ]
        )

        XCTAssertEqual(
            result.statusCode, 201,
            "POST devtools snapshot should create a row; path=\(result.path), status=\(result.statusCode), body=\(result.body)"
        )
        XCTAssertFalse(
            result.snapshotID.isEmpty,
            "POST should return a row identifier (`id`/`snapshot_id`); body=\(result.body)"
        )
        XCTAssertFalse(
            result.body.lowercased().contains("unauthorized"),
            "authenticated POST must not fail auth; body=\(result.body)"
        )
    }

    func test_devtools_snapshot_shape_streams_new_row() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let marker = client.uniqueMarker("shape")
        let probe = try client.openShapeProbe()
        defer { probe.close() }

        // Negative assertion before the write: the unique marker must not
        // already be present in the live stream buffer.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(
            probe.currentBody().contains(marker),
            "pre-write shape stream unexpectedly already contained the unique marker"
        )

        let write = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": marker,
                "line": "shape fan-out",
            ]
        )
        XCTAssertEqual(
            write.statusCode, 201,
            "write must succeed before the shape can fan out; path=\(write.path), body=\(write.body)"
        )

        let streamed = probe.waitForContains(marker, timeout: 5)
        XCTAssertEqual(
            streamed.statusCode, 200,
            "shape subscription should stay healthy while waiting for the new row; body=\(streamed.body)"
        )
        XCTAssertTrue(
            streamed.body.contains(marker),
            "shape stream did not surface the new devtools snapshot within 5s; body=\(streamed.body)"
        )
        XCTAssertFalse(
            streamed.body.contains("where clause with repository_id filter is required"),
            "shape request must include the required repository_id filter; body=\(streamed.body)"
        )
    }

    func test_devtools_snapshot_latest_per_kind_returns_one() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let oldMarker = client.uniqueMarker("latest-old")
        let newMarker = client.uniqueMarker("latest-new")

        let first = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": oldMarker,
                "message": "first console payload",
            ]
        )
        XCTAssertEqual(first.statusCode, 201, "first write should succeed; body=\(first.body)")

        Thread.sleep(forTimeInterval: 0.2)

        let second = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": newMarker,
                "message": "second console payload",
            ]
        )
        XCTAssertEqual(second.statusCode, 201, "second write should succeed; body=\(second.body)")

        let latest = try client.fetchLatestView(waitFor: newMarker, timeout: 5)
        let kindPattern = "\"kind\"\\s*:\\s*\"\(NSRegularExpression.escapedPattern(for: second.apiKind))\""

        XCTAssertEqual(
            latest.statusCode, 200,
            "latest read should succeed; source=\(latest.source), body=\(latest.body)"
        )
        XCTAssertEqual(
            client.regexCount(pattern: kindPattern, in: latest.body),
            1,
            "latest-per-kind read should contain exactly one row for \(second.apiKind); source=\(latest.source), body=\(latest.body)"
        )
        XCTAssertTrue(
            latest.body.contains(newMarker),
            "latest read should expose the newer payload marker; body=\(latest.body)"
        )
        XCTAssertFalse(
            latest.body.contains(oldMarker),
            "latest read must not still expose the overwritten payload marker; body=\(latest.body)"
        )
    }

    func test_devtools_snapshot_different_kinds_all_latest() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let consoleMarker = client.uniqueMarker("console")
        let networkMarker = client.uniqueMarker("network")

        let consoleWrite = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": consoleMarker,
                "message": "console payload",
            ]
        )
        XCTAssertEqual(consoleWrite.statusCode, 201, "console write should succeed; body=\(consoleWrite.body)")

        let networkWrite = try client.postSnapshot(
            logicalKind: .network,
            payload: [
                "marker": networkMarker,
                "request": "GET /healthz",
            ]
        )
        XCTAssertEqual(networkWrite.statusCode, 201, "network write should succeed; body=\(networkWrite.body)")

        let latest = try client.fetchLatestView(waitFor: networkMarker, timeout: 5)
        let consoleKindPattern = "\"kind\"\\s*:\\s*\"\(NSRegularExpression.escapedPattern(for: consoleWrite.apiKind))\""
        let networkKindPattern = "\"kind\"\\s*:\\s*\"\(NSRegularExpression.escapedPattern(for: networkWrite.apiKind))\""

        XCTAssertEqual(
            latest.statusCode, 200,
            "latest read should succeed after two distinct kinds; source=\(latest.source), body=\(latest.body)"
        )
        XCTAssertTrue(
            latest.body.contains(consoleMarker),
            "latest read must include the console snapshot; body=\(latest.body)"
        )
        XCTAssertTrue(
            latest.body.contains(networkMarker),
            "latest read must include the network snapshot; body=\(latest.body)"
        )
        XCTAssertEqual(
            client.regexCount(pattern: consoleKindPattern, in: latest.body),
            1,
            "latest read should contain one console-kind row; body=\(latest.body)"
        )
        XCTAssertEqual(
            client.regexCount(pattern: networkKindPattern, in: latest.body),
            1,
            "latest read should contain one network-kind row; body=\(latest.body)"
        )
    }

    func test_devtools_snapshot_requires_auth() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let warmup = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": client.uniqueMarker("auth-warmup"),
            ]
        )
        XCTAssertEqual(
            warmup.statusCode, 201,
            "warmup write must succeed so the test has a real endpoint to retry without auth; path=\(warmup.path), body=\(warmup.body)"
        )

        let unauthorized = try client.postSnapshot(
            path: warmup.path,
            apiKind: warmup.apiKind,
            payload: [
                "marker": client.uniqueMarker("auth-none"),
            ],
            authMode: .none
        )

        XCTAssertEqual(
            unauthorized.statusCode, 401,
            "devtools snapshot write without a bearer should be rejected; path=\(warmup.path), body=\(unauthorized.body)"
        )
        XCTAssertNotEqual(
            unauthorized.statusCode, 201,
            "unauthenticated write must not create a row; body=\(unauthorized.body)"
        )
        XCTAssertTrue(
            unauthorized.body.lowercased().contains("auth") ||
            unauthorized.body.lowercased().contains("token") ||
            unauthorized.body.lowercased().contains("unauthorized"),
            "401 body should mention the auth failure; body=\(unauthorized.body)"
        )
    }

    func test_devtools_snapshot_scoped_to_workspace() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()
        guard let workspaceID = client.context.workspaceID, !workspaceID.isEmpty else {
            throw DevtoolsTestError.missingEnvironment(DevtoolsEnvKey.workspaceID)
        }

        let marker = client.uniqueMarker("scope")
        let write = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": marker,
                "workspace_id": workspaceID,
            ]
        )
        XCTAssertEqual(write.statusCode, 201, "scoped write should succeed; body=\(write.body)")

        let ownView = try client.fetchLatestView(
            sessionID: client.context.sessionID,
            repoID: client.context.repoID,
            workspaceID: workspaceID,
            waitFor: marker,
            timeout: 5
        )
        XCTAssertEqual(ownView.statusCode, 200, "own workspace read should succeed; body=\(ownView.body)")
        XCTAssertTrue(
            ownView.body.contains(marker),
            "own workspace/session scope should include the snapshot; body=\(ownView.body)"
        )

        let otherWorkspaceID = UUID().uuidString.lowercased()
        let otherSessionID = UUID().uuidString.lowercased()
        let otherView = try client.fetchLatestView(
            sessionID: otherSessionID,
            repoID: client.context.repoID,
            workspaceID: otherWorkspaceID,
            waitFor: nil,
            timeout: 2
        )

        XCTAssertNotEqual(workspaceID, otherWorkspaceID, "negative scope control must use a distinct workspace id")
        XCTAssertFalse(
            otherView.body.contains(marker),
            "other workspace/session scope must not surface the snapshot; source=\(otherView.source), body=\(otherView.body)"
        )
        XCTAssertFalse(
            otherView.statusCode == 401,
            "cross-scope negative should test isolation, not auth breakage; source=\(otherView.source), body=\(otherView.body)"
        )
    }

    func test_devtools_snapshot_payload_size_limit() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let oversizedBlob = String(repeating: "x", count: 10 * 1024 * 1024)
        let result = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": client.uniqueMarker("oversized"),
                "blob": oversizedBlob,
            ]
        )

        XCTAssertTrue(
            [400, 413, 422].contains(result.statusCode),
            "oversized payload should be rejected with 413 or equivalent; path=\(result.path), status=\(result.statusCode), body=\(result.body)"
        )
        XCTAssertFalse(
            (200...299).contains(result.statusCode),
            "oversized payload must not be accepted; body=\(result.body)"
        )
        XCTAssertTrue(
            result.body.lowercased().contains("payload") ||
            result.body.lowercased().contains("size") ||
            result.body.lowercased().contains("large"),
            "oversized rejection should mention payload size; body=\(result.body)"
        )
    }

    func test_devtools_snapshot_rate_limit() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()

        let burstLimit = 80
        var statuses: [Int] = []
        var lastBody = ""

        for idx in 0..<burstLimit {
            let result = try client.postSnapshot(
                logicalKind: .console,
                payload: [
                    "marker": client.uniqueMarker("rate-\(idx)"),
                    "seq": idx,
                ]
            )
            statuses.append(result.statusCode)
            lastBody = result.body

            if result.statusCode == 429 {
                break
            }

            if ![200, 201, 202].contains(result.statusCode) {
                XCTFail("rate-limit burst hit unexpected status \(result.statusCode) at request \(idx + 1); body=\(result.body)")
                return
            }
        }

        XCTAssertTrue(
            statuses.contains(429),
            "rapid POST burst should eventually hit 429; observed statuses=\(statuses), lastBody=\(lastBody)"
        )
        XCTAssertFalse(
            statuses.allSatisfy { [200, 201, 202].contains($0) },
            "rate-limit scenario must not be all-success responses; statuses=\(statuses)"
        )
    }

    func test_devtools_snapshot_flag_gate() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        if try client.featureFlagState(named: "devtools_snapshot_enabled") == true {
            throw XCTSkip("flag-gate scenario requires devtools_snapshot_enabled=false on the target backend")
        }

        let result = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": client.uniqueMarker("flag"),
            ]
        )

        XCTAssertTrue(
            [403, 404].contains(result.statusCode),
            "when devtools_snapshot_enabled=false, POST should be gated with 403/404; path=\(result.path), status=\(result.statusCode), body=\(result.body)"
        )
        XCTAssertNotEqual(
            result.statusCode, 201,
            "flag-gated endpoint must not create rows while disabled; body=\(result.body)"
        )
        XCTAssertTrue(
            result.body.lowercased().contains("devtools") ||
            result.body.lowercased().contains("disabled") ||
            result.body.lowercased().contains("not found"),
            "flag-gate response should explain the devtools surface is unavailable; body=\(result.body)"
        )
    }

    func test_devtools_snapshot_listed_in_ui() throws {
        let client = try DevtoolsTestClient.fromEnvironment()
        try client.skipPositiveScenariosIfFlagExplicitlyDisabled()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[E2ELaunchKey.seededData] == "1",
            "UI scenario requires PLUE_E2E_SEEDED=1 so the test can open a workspace detail shell"
        )

        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in shell must mount before probing the devtools UI surface"
        )

        app.buttons["content.ios.open-switcher"].tap()
        let seededWorkspaceID = ProcessInfo.processInfo.environment[E2ELaunchKey.seededWorkspaceID] ?? ""
        let rowButton: XCUIElement = {
            if !seededWorkspaceID.isEmpty {
                return app.buttons["switcher.row.\(seededWorkspaceID)"]
            }
            return app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
            ).firstMatch
        }()
        XCTAssertTrue(rowButton.waitForExistence(timeout: 15), "seeded workspace row should appear")
        rowButton.tap()

        let detail = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "workspace detail shell must render")

        // Current iOS code explicitly omits run-inspect/devtools routes.
        let openDevtools = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS[c] 'devtools'")
        ).firstMatch
        if openDevtools.exists {
            openDevtools.tap()
        }

        let candidateRoots = [
            "content.ios.workspace-detail.devtools",
            "content.ios.run-inspect.devtools",
            "run-inspect.devtools",
            "devtools.snapshot.panel",
        ]
        let devtoolsRoot = candidateRoots
            .map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
            .first(where: { $0.waitForExistence(timeout: 0.5) })

        try XCTSkipUnless(
            devtoolsRoot != nil,
            "bug candidate: iOS devtools snapshot surface is not wired; current ContentShell.iOS omits run-inspect/devtools routes"
        )

        let marker = client.uniqueMarker("ui")
        let markerQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker)
        ).firstMatch

        XCTAssertFalse(
            markerQuery.exists,
            "negative control: the unique marker must not be visible before writing the snapshot"
        )

        let write = try client.postSnapshot(
            logicalKind: .console,
            payload: [
                "marker": marker,
                "message": "visible in UI",
            ]
        )
        XCTAssertEqual(write.statusCode, 201, "UI scenario needs a successful write; body=\(write.body)")

        XCTAssertTrue(
            markerQuery.waitForExistence(timeout: 5),
            "devtools panel should reflect the newly written snapshot marker; root=\(String(describing: devtoolsRoot?.identifier))"
        )
    }
}
#endif
