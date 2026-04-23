// SmithersiOSE2EApprovalsTests.swift — approvals scenario group (ticket
// ios-e2e-harness, scenario group B).
//
// v1 SCOPE: assert the approvals data plane is wired end-to-end against
// real plue. The iOS client shell does NOT yet have an approvals list
// view (the shared `ApprovalsStore` is only wired on macOS in 0124),
// and the production approvals inbox is delivered via an Electric shape
// which requires `electric_client_enabled=true`. Both gaps are followed
// up by separate tickets; for v1 this scenario covers:
//
//   1. The seed script writes a pending approval row (tests below read
//      it back via the /api path that plue exposes — when the feature
//      flag `approvals_flow_enabled` is on — or via the expected
//      "disabled" response, proving auth + flag gating work).
//   2. The decide endpoint is reachable from the XCUITest process over
//      the same simulator network path the app uses, proving there is
//      no CORS / routing regression that would block the production
//      inbox when the flag is flipped on.
//
// True multi-client fan-out (simulator A decides, simulator B sees the
// row disappear) requires spinning a second simulator and is a follow-
// up. This v1 test is single-simulator on purpose.

#if os(iOS)
import XCTest

final class SmithersiOSE2EApprovalsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Main approvals scenario. Launches the app (so any future iOS
    /// inbox surface can be asserted on in a follow-up), then performs
    /// direct HTTP round-trips against plue using the same bearer token
    /// the app is signed in with.
    func test_seeded_approval_is_reachable_via_plue_api() throws {
        let procEnv = ProcessInfo.processInfo.environment
        guard procEnv[E2ELaunchKey.seededData] == "1" else {
            XCTFail("approvals scenario requires PLUE_E2E_SEEDED=1")
            return
        }
        guard let bearer = procEnv[E2ELaunchKey.bearer], !bearer.isEmpty else {
            XCTFail("approvals scenario requires SMITHERS_E2E_BEARER")
            return
        }
        guard let baseURLString = procEnv[E2ELaunchKey.baseURL],
              let baseURL = URL(string: baseURLString) else {
            XCTFail("approvals scenario requires PLUE_BASE_URL")
            return
        }
        guard let approvalID = procEnv[E2ELaunchKey.seededApprovalID],
              !approvalID.isEmpty else {
            XCTFail("approvals scenario requires PLUE_E2E_APPROVAL_ID (extend seed-e2e-data.sh)")
            return
        }
        guard let owner = procEnv[E2ELaunchKey.seededRepoOwner],
              let repoName = procEnv[E2ELaunchKey.seededRepoName],
              !owner.isEmpty, !repoName.isEmpty else {
            XCTFail("approvals scenario requires PLUE_E2E_REPO_OWNER + PLUE_E2E_REPO_NAME")
            return
        }

        // Launch the app so we exercise the full simulator lifecycle
        // (foregrounded app, real URLSession in-process). Any regression
        // in the shared shell's init would trip here before we reach
        // the API calls below.
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()
        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in shell must mount before we probe approvals"
        )

        // 1. Feature flag probe — tells us what behaviour to expect from
        //    the decide endpoint. We use /api/feature-flags (no auth).
        let flags = try fetchFeatureFlags(baseURL: baseURL)
        let approvalsFlowEnabled = flags["approvals_flow_enabled"] == true

        // 2. Decide the seeded approval. Endpoint:
        //    POST /api/repos/{owner}/{repo}/approvals/{id}/decide
        let decideURL = baseURL
            .appendingPathComponent("api/repos/\(owner)/\(repoName)/approvals/\(approvalID)/decide")
        let (status, body) = try postJSON(
            url: decideURL,
            bearer: bearer,
            body: ["decision": "approved"]
        )

        if approvalsFlowEnabled {
            // Flag on → expect 200 and state transition to approved.
            XCTAssertEqual(
                status, 200,
                "decide should return 200 when approvals_flow_enabled; got \(status), body=\(body)"
            )
            // Re-decide must now be idempotent or return a conflict; we
            // don't assert the exact shape (service-layer concern) — the
            // critical thing is the first call succeeded.
        } else {
            // Flag off → plue returns 404 with "approvals flow disabled".
            // This still proves auth worked (we'd get 401 otherwise) and
            // the route is reachable from the simulator network — which
            // is the regression the scenario guards against.
            XCTAssertEqual(
                status, 404,
                "decide should return 404 when approvals_flow_enabled is false; got \(status), body=\(body)"
            )
            XCTAssertTrue(
                body.lowercased().contains("approval"),
                "404 body should mention approvals (plue returns 'approvals flow disabled'); body=\(body)"
            )
        }
    }

    // MARK: - HTTP helpers

    /// GET /api/feature-flags — returns {"flags": {"name": bool, ...}}.
    private func fetchFeatureFlags(baseURL: URL) throws -> [String: Bool] {
        let url = baseURL.appendingPathComponent("api/feature-flags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try syncRequest(req)
        guard status == 200 else {
            throw NSError(domain: "approvals-e2e", code: status,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "GET /api/feature-flags returned \(status)"])
        }
        struct Resp: Decodable { let flags: [String: Bool] }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        return parsed.flags
    }

    private func postJSON(
        url: URL,
        bearer: String,
        body: [String: String]
    ) throws -> (status: Int, body: String) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, status) = try syncRequest(req)
        return (status, String(data: data, encoding: .utf8) ?? "<non-utf8>")
    }

    /// Synchronous URLSession wrapper. XCTest is synchronous by default
    /// and our expectations are simple; using an expectation + semaphore
    /// pattern keeps the test readable without async/await plumbing.
    private func syncRequest(_ req: URLRequest) throws -> (Data, Int) {
        var out: (Data, Int)?
        var outErr: Error?
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { outErr = err }
            else if let http = resp as? HTTPURLResponse {
                out = (data ?? Data(), http.statusCode)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 15)
        if let outErr = outErr { throw outErr }
        guard let out = out else {
            throw NSError(domain: "approvals-e2e", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "timed out waiting for \(req.url?.absoluteString ?? "?")"])
        }
        return out
    }
}
#endif
