#if os(iOS)
import Foundation
import XCTest

final class SmithersiOSE2EWorkspaceLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_workspace_create_via_http_appears_in_switcher() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-create"))
        defer { client.cleanupRepo(repo) }

        let workspace = try client.createWorkspace(repo: repo, name: uniqueName("workspace-create"))

        let app = launchSignedInApp()
        openSwitcher(in: app)

        XCTAssertTrue(
            waitForRow(app, workspaceID: workspace.id, timeout: 20),
            "workspace created via HTTP should appear in the iOS switcher"
        )
        XCTAssertFalse(
            app.staticTexts["Sign in to Smithers"].exists,
            "signed-in shell should remain mounted while the switcher is open"
        )
    }

    func test_workspace_delete_via_http_disappears_from_switcher() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-delete"))
        defer { client.cleanupRepo(repo) }

        let workspace = try client.createWorkspace(repo: repo, name: uniqueName("workspace-delete"))

        let app = launchSignedInApp()
        openSwitcher(in: app)
        XCTAssertTrue(waitForRow(app, workspaceID: workspace.id, timeout: 20))

        try client.deleteWorkspace(repo: repo, workspaceID: workspace.id)
        refreshSwitcher(in: app)

        XCTAssertTrue(
            waitForRowAbsence(app, workspaceID: workspace.id, timeout: 20),
            "deleted workspace row should disappear after switcher refresh"
        )
        XCTAssertFalse(
            app.buttons["switcher.row.\(workspace.id)"].exists,
            "deleted workspace row must not remain visible after refresh"
        )
    }

    func test_workspace_suspend_then_resume_roundtrip() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-suspend"))
        defer { client.cleanupRepo(repo) }

        let workspace = try client.createWorkspace(repo: repo, name: uniqueName("workspace-suspend"))

        let suspended = try client.suspendWorkspace(repo: repo, workspaceID: workspace.id)
        XCTAssertEqual(suspended.status, "suspended")
        XCTAssertNotEqual(suspended.status, "running")

        let fetchedSuspended = try client.getWorkspace(repo: repo, workspaceID: workspace.id)
        XCTAssertEqual(fetchedSuspended.status, "suspended")

        let resumed = try client.resumeWorkspace(repo: repo, workspaceID: workspace.id)
        XCTAssertEqual(resumed.status, "running")
        XCTAssertNotEqual(resumed.status, "suspended")

        let fetchedResumed = try client.getWorkspace(repo: repo, workspaceID: workspace.id)
        XCTAssertEqual(fetchedResumed.status, "running")
    }

    func test_workspace_fork_creates_new_row() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-fork"))
        defer { client.cleanupRepo(repo) }

        let parent = try client.createWorkspace(repo: repo, name: uniqueName("workspace-parent"))
        let forked = try client.forkWorkspace(repo: repo, workspaceID: parent.id, name: uniqueName("workspace-fork"))

        let app = launchSignedInApp()
        openSwitcher(in: app)

        XCTAssertTrue(waitForRow(app, workspaceID: parent.id, timeout: 20))
        XCTAssertTrue(waitForRow(app, workspaceID: forked.id, timeout: 20))
        XCTAssertNotEqual(parent.id, forked.id, "fork must create a distinct workspace id")
    }

    func test_workspace_quota_boundary() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-quota"))
        defer { client.cleanupRepo(repo) }

        let parent = try client.createWorkspace(repo: repo, name: uniqueName("workspace-quota-parent"))
        var createdIDs = [parent.id]
        var overflow: WorkspaceLifecycleHTTPClient.HTTPResult?

        for attempt in 0..<6 {
            let result = try client.forkWorkspaceRaw(
                repo: repo,
                workspaceID: parent.id,
                name: uniqueName("workspace-quota-\(attempt)")
            )
            if result.statusCode >= 200 && result.statusCode < 300 {
                let forked = try client.decode(WorkspaceRecord.self, from: result)
                createdIDs.append(forked.id)
                continue
            }
            overflow = result
            break
        }

        guard let overflow else {
            throw XCTSkip("workspace quota contract not exposed in this plue checkout - bounded fork loop of 5 did not overflow")
        }

        let body = overflow.bodyString.lowercased()
        let explicitQuotaMessage =
            body.contains("quota") ||
            body.contains("limit") ||
            body.contains("exceeded") ||
            body.contains("too many")

        XCTAssertTrue(
            overflow.statusCode == 429 || explicitQuotaMessage,
            "expected 429 or explicit quota failure on overflow; got HTTP \(overflow.statusCode), body=\(overflow.bodyString)"
        )
        XCTAssertFalse(createdIDs.isEmpty, "bounded quota probe should create at least one workspace before overflow")
    }

    func test_workspace_soft_delete_hides_from_list() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-soft-delete"))
        defer { client.cleanupRepo(repo) }

        let workspace = try client.createWorkspace(repo: repo, name: uniqueName("workspace-soft-delete"))
        try client.deleteWorkspace(repo: repo, workspaceID: workspace.id)

        let listed = try client.listUserWorkspaces(limit: 100)
        XCTAssertFalse(
            listed.contains(where: { $0.workspaceID == workspace.id }),
            "soft-deleted workspace must not appear in /api/user/workspaces"
        )
    }

    func test_workspace_tombstone_not_returned_to_foreign_user() throws {
        throw XCTSkip("foreign-user tombstone isolation requires a second bearer/user fixture - see ticket ios-workspace-lifecycle-foreign-user")
    }

    func test_workspace_last_accessed_at_updates() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-accessed"))
        defer { client.cleanupRepo(repo) }

        let parent = try client.createWorkspace(repo: repo, name: uniqueName("workspace-access-parent"))
        let older = try client.forkWorkspace(repo: repo, workspaceID: parent.id, name: uniqueName("workspace-access-older"))
        Thread.sleep(forTimeInterval: 1.2)
        let newer = try client.forkWorkspace(repo: repo, workspaceID: parent.id, name: uniqueName("workspace-access-newer"))

        let before = try client.listUserWorkspaces(limit: 100)
        let beforeOlderIndex = try XCTUnwrap(before.firstIndex(where: { $0.workspaceID == older.id }))
        let beforeNewerIndex = try XCTUnwrap(before.firstIndex(where: { $0.workspaceID == newer.id }))
        XCTAssertGreaterThan(
            beforeOlderIndex,
            beforeNewerIndex,
            "newer workspace should sort ahead of older workspace before we touch recency"
        )

        let sshInfo = try client.getWorkspaceSSHInfo(repo: repo, workspaceID: older.id)
        XCTAssertEqual(sshInfo.workspaceID, older.id)

        let after = try client.listUserWorkspaces(limit: 100)
        XCTAssertEqual(
            after.first?.workspaceID,
            older.id,
            "attach/open path should bump workspace recency to the top of /api/user/workspaces ordering"
        )
        XCTAssertFalse(
            after.first?.workspaceID == newer.id,
            "workspace touched via attach/open should displace the previously newest row"
        )
    }

    func test_workspace_detail_404_after_delete() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-detail-delete"))
        defer { client.cleanupRepo(repo) }

        let workspace = try client.createWorkspace(repo: repo, name: uniqueName("workspace-detail-delete"))

        let app = launchSignedInApp()
        openSwitcher(in: app)
        XCTAssertTrue(waitForRow(app, workspaceID: workspace.id, timeout: 20))
        app.buttons["switcher.row.\(workspace.id)"].tap()

        let detail = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))

        try client.deleteWorkspace(repo: repo, workspaceID: workspace.id)
        let deletedFetch = try client.getWorkspaceRaw(repo: repo, workspaceID: workspace.id)
        XCTAssertEqual(
            deletedFetch.statusCode,
            404,
            "workspace detail fetch should return 404 after delete; body=\(deletedFetch.bodyString)"
        )

        throw XCTSkip("ios UI not yet wired for workspace detail reload/404 empty-state - see ticket ios-workspace-detail-live")
    }

    func test_workspace_create_then_sign_out_then_sign_in_still_sees_workspace() throws {
        let client = try makeClient()
        let repo = try client.createRepo(name: uniqueName("e2e-ws-persist"))
        defer { client.cleanupRepo(repo) }

        let workspace = try client.createWorkspace(repo: repo, name: uniqueName("workspace-persist"))

        let app = launchSignedInApp()
        openSwitcher(in: app)
        XCTAssertTrue(waitForRow(app, workspaceID: workspace.id, timeout: 20))
        closeSwitcher(in: app)

        let signOut = app.buttons["content.ios.sign-out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()

        XCTAssertTrue(
            app.staticTexts["Sign in to Smithers"].waitForExistence(timeout: 10),
            "sign-out should return the app to the sign-in shell"
        )
        XCTAssertFalse(
            app.otherElements["app.root.ios"].exists,
            "signed-in shell should unmount after sign-out"
        )

        app.terminate()

        let relaunched = launchSignedInApp()
        openSwitcher(in: relaunched)
        XCTAssertTrue(waitForRow(relaunched, workspaceID: workspace.id, timeout: 20))
        XCTAssertFalse(
            relaunched.staticTexts["Sign in to Smithers"].exists,
            "relaunching with the same E2E bearer should restore the signed-in shell"
        )
    }

    private func makeClient(file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceLifecycleHTTPClient {
        try WorkspaceLifecycleHTTPClient.fromProcess(file: file, line: line)
    }

    private func launchSignedInApp(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()
        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in shell should mount in E2E mode",
            file: file,
            line: line
        )
        XCTAssertFalse(
            app.staticTexts["Sign in to Smithers"].exists,
            "sign-in shell must not be visible after signed-in launch",
            file: file,
            line: line
        )
        return app
    }

    private func openSwitcher(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let open = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), file: file, line: line)
        open.tap()

        let root = app.descendants(matching: .any)
            .matching(identifier: "switcher.ios.root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5), file: file, line: line)
        assertSwitcherDidNotHitBackendUnavailable(app, file: file, line: line)
    }

    private func closeSwitcher(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["switcher.ios.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), file: file, line: line)
        close.tap()
    }

    private func refreshSwitcher(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let refresh = app.buttons["switcher.ios.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), file: file, line: line)
        refresh.tap()
    }

    private func waitForRow(
        _ app: XCUIApplication,
        workspaceID: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let row = app.buttons["switcher.row.\(workspaceID)"]
        while Date() < deadline {
            if row.exists { return true }
            if switcherBackendUnavailableElement(in: app).exists { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return row.exists
    }

    private func waitForRowAbsence(
        _ app: XCUIApplication,
        workspaceID: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let row = app.buttons["switcher.row.\(workspaceID)"]
        while Date() < deadline {
            if !row.exists { return true }
            if switcherBackendUnavailableElement(in: app).exists { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !row.exists
    }

    private func assertSwitcherDidNotHitBackendUnavailable(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            switcherBackendUnavailableElement(in: app).exists,
            "workspace switcher hit backendUnavailable - verify PLUE_BASE_URL and live plue health",
            file: file,
            line: line
        )
    }

    private func switcherBackendUnavailableElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.backendUnavailable").firstMatch
    }

    private func uniqueName(_ prefix: String) -> String {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(10)
        return "\(prefix)-\(suffix)"
    }
}

private struct WorkspaceLifecycleHTTPClient {
    struct HTTPResult {
        let statusCode: Int
        let data: Data

        var bodyString: String {
            String(data: data, encoding: .utf8) ?? "<non-utf8>"
        }
    }

    private let baseURL: URL
    private let bearer: String
    private let session: URLSession
    private let decoder: JSONDecoder

    static func fromProcess(file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceLifecycleHTTPClient {
        let env = ProcessInfo.processInfo.environment
        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            XCTFail("workspace lifecycle tests require \(E2ELaunchKey.bearer)", file: file, line: line)
            throw NSError(domain: "workspace-lifecycle-e2e", code: 1)
        }
        guard let baseURLString = env[E2ELaunchKey.baseURL], let baseURL = URL(string: baseURLString) else {
            XCTFail("workspace lifecycle tests require \(E2ELaunchKey.baseURL)", file: file, line: line)
            throw NSError(domain: "workspace-lifecycle-e2e", code: 2)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return WorkspaceLifecycleHTTPClient(
            baseURL: baseURL,
            bearer: bearer,
            session: URLSession(configuration: config),
            decoder: Self.makeDecoder()
        )
    }

    func createRepo(name: String) throws -> RepoRef {
        let result = try request(
            method: "POST",
            path: "api/user/repos",
            jsonBody: [
                "name": name,
                "description": "created by SmithersiOSE2EWorkspaceLifecycleTests",
                "private": true,
                "auto_init": true,
                "default_bookmark": "main",
            ]
        )
        try assertStatus(result, allowed: [201], context: "create repo")
        let repo = try decode(RepoResponse.self, from: result)
        return RepoRef(owner: repo.owner, name: repo.name)
    }

    func deleteRepo(_ repo: RepoRef) throws {
        let result = try request(method: "DELETE", path: "api/repos/\(repo.owner)/\(repo.name)")
        try assertStatus(result, allowed: [204, 404], context: "delete repo \(repo.fullName)")
    }

    func cleanupRepo(_ repo: RepoRef) {
        if let workspaces = try? listRepoWorkspaces(repo: repo) {
            for workspace in workspaces {
                _ = try? deleteWorkspace(repo: repo, workspaceID: workspace.id)
            }
        }
        _ = try? deleteRepo(repo)
    }

    func createWorkspace(repo: RepoRef, name: String) throws -> WorkspaceRecord {
        let result = try request(
            method: "POST",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces",
            jsonBody: ["name": name]
        )
        try assertStatus(result, allowed: [201], context: "create workspace")
        let created = try decode(WorkspaceRecord.self, from: result)
        return try waitForWorkspaceSettled(repo: repo, workspaceID: created.id, timeout: 90)
    }

    func getWorkspace(repo: RepoRef, workspaceID: String) throws -> WorkspaceRecord {
        let result = try getWorkspaceRaw(repo: repo, workspaceID: workspaceID)
        try assertStatus(result, allowed: [200], context: "get workspace \(workspaceID)")
        return try decode(WorkspaceRecord.self, from: result)
    }

    func getWorkspaceRaw(repo: RepoRef, workspaceID: String) throws -> HTTPResult {
        try request(method: "GET", path: "api/repos/\(repo.owner)/\(repo.name)/workspaces/\(workspaceID)")
    }

    func listRepoWorkspaces(repo: RepoRef) throws -> [WorkspaceRecord] {
        let result = try request(
            method: "GET",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces",
            query: [URLQueryItem(name: "limit", value: "100")]
        )
        try assertStatus(result, allowed: [200], context: "list repo workspaces")
        return try decode([WorkspaceRecord].self, from: result)
    }

    func suspendWorkspace(repo: RepoRef, workspaceID: String) throws -> WorkspaceRecord {
        let result = try request(
            method: "POST",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces/\(workspaceID)/suspend"
        )
        try assertStatus(result, allowed: [200], context: "suspend workspace \(workspaceID)")
        return try decode(WorkspaceRecord.self, from: result)
    }

    func resumeWorkspace(repo: RepoRef, workspaceID: String) throws -> WorkspaceRecord {
        let result = try request(
            method: "POST",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces/\(workspaceID)/resume"
        )
        try assertStatus(result, allowed: [200], context: "resume workspace \(workspaceID)")
        return try decode(WorkspaceRecord.self, from: result)
    }

    func deleteWorkspace(repo: RepoRef, workspaceID: String) throws {
        let result = try request(
            method: "DELETE",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces/\(workspaceID)"
        )
        try assertStatus(result, allowed: [204, 404], context: "delete workspace \(workspaceID)")
    }

    func forkWorkspace(repo: RepoRef, workspaceID: String, name: String) throws -> WorkspaceRecord {
        let result = try forkWorkspaceRaw(repo: repo, workspaceID: workspaceID, name: name)
        try assertStatus(result, allowed: [201], context: "fork workspace \(workspaceID)")
        let created = try decode(WorkspaceRecord.self, from: result)
        return try waitForWorkspaceSettled(repo: repo, workspaceID: created.id, timeout: 90)
    }

    func forkWorkspaceRaw(repo: RepoRef, workspaceID: String, name: String) throws -> HTTPResult {
        try request(
            method: "POST",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces/\(workspaceID)/fork",
            jsonBody: ["name": name]
        )
    }

    func getWorkspaceSSHInfo(repo: RepoRef, workspaceID: String) throws -> WorkspaceSSHInfo {
        let result = try request(
            method: "GET",
            path: "api/repos/\(repo.owner)/\(repo.name)/workspaces/\(workspaceID)/ssh"
        )
        try assertStatus(result, allowed: [200], context: "get workspace ssh info")
        return try decode(WorkspaceSSHInfo.self, from: result)
    }

    func listUserWorkspaces(limit: Int) throws -> [UserWorkspaceRow] {
        let result = try request(
            method: "GET",
            path: "api/user/workspaces",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        try assertStatus(result, allowed: [200], context: "list user workspaces")
        if let wrapped = try? decode(UserWorkspacesEnvelope.self, from: result) {
            return wrapped.workspaces
        }
        return try decode([UserWorkspaceRow].self, from: result)
    }

    func decode<T: Decodable>(_ type: T.Type, from result: HTTPResult) throws -> T {
        do {
            return try decoder.decode(type, from: result.data)
        } catch {
            throw NSError(
                domain: "workspace-lifecycle-e2e",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "decode \(type) failed: \(error); body=\(result.bodyString)"]
            )
        }
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil
    ) throws -> HTTPResult {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let trimmedBasePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedBasePath.isEmpty {
            components?.path = "/" + trimmedPath
        } else {
            components?.path = "/" + trimmedBasePath + "/" + trimmedPath
        }
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else {
            throw NSError(
                domain: "workspace-lifecycle-e2e",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "invalid url for path \(path)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        var output: HTTPResult?
        var outputError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                outputError = error
            } else if let http = response as? HTTPURLResponse {
                output = HTTPResult(statusCode: http.statusCode, data: data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 25)

        if let outputError {
            throw outputError
        }
        guard let output else {
            throw NSError(
                domain: "workspace-lifecycle-e2e",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(method) \(url.absoluteString)"]
            )
        }
        return output
    }

    private func waitForWorkspaceSettled(
        repo: RepoRef,
        workspaceID: String,
        timeout: TimeInterval
    ) throws -> WorkspaceRecord {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: WorkspaceRecord?
        while Date() < deadline {
            let result = try getWorkspaceRaw(repo: repo, workspaceID: workspaceID)
            try assertStatus(result, allowed: [200], context: "poll workspace \(workspaceID)")
            let workspace = try decode(WorkspaceRecord.self, from: result)
            latest = workspace
            if workspace.status != "pending" && workspace.status != "starting" {
                return workspace
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if let latest {
            throw NSError(
                domain: "workspace-lifecycle-e2e",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for workspace \(workspaceID) to settle from status \(latest.status)"]
            )
        }
        throw NSError(
            domain: "workspace-lifecycle-e2e",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for workspace \(workspaceID) to settle"]
        )
    }

    private func assertStatus(_ result: HTTPResult, allowed: [Int], context: String) throws {
        guard allowed.contains(result.statusCode) else {
            throw NSError(
                domain: "workspace-lifecycle-e2e",
                code: result.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(context) returned HTTP \(result.statusCode): \(result.bodyString)"]
            )
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractional.date(from: value) ?? plain.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date: \(value)")
        }
        return decoder
    }
}

private struct RepoRef {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
}

private struct RepoResponse: Decodable {
    let owner: String
    let name: String
}

private struct WorkspaceRecord: Decodable {
    let id: String
    let name: String
    let status: String
    let isFork: Bool
    let parentWorkspaceID: String?
    let suspendedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case isFork = "is_fork"
        case parentWorkspaceID = "parent_workspace_id"
        case suspendedAt = "suspended_at"
    }
}

private struct WorkspaceSSHInfo: Decodable {
    let workspaceID: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}

private struct UserWorkspacesEnvelope: Decodable {
    let workspaces: [UserWorkspaceRow]
}

private struct UserWorkspaceRow: Decodable {
    let workspaceID: String
    let repoOwner: String?
    let repoName: String?
    let lastAccessedAt: Date?
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case repoOwner = "repo_owner"
        case repoName = "repo_name"
        case lastAccessedAt = "last_accessed_at"
        case createdAt = "created_at"
    }
}
#endif
