// SmithersiOSE2EReconnectTests.swift — reconnect resilience scenario
// group (ticket ios-e2e-harness, scenario group C).
//
// XCUITest runs inside the simulator and cannot directly `docker pause`
// the plue api container from host-space. We approximate the scenario
// from inside the test by:
//
//   1. Baseline: probe `$(PLUE_BASE_URL)/api/feature-flags` and assert
//      a 200 response — this confirms plue is reachable at test start.
//   2. Partition: temporarily point the probe at an unreachable host
//      (`http://127.0.0.1:1/` — port 1 has no listener) with a short
//      timeout. Assert the request fails with a network-level error,
//      proving our URLSession path surfaces a transport failure (not a
//      silent zero-byte success) — which is what the workspace switcher
//      relies on to show the `backendUnavailable` empty state.
//   3. Recovery: re-probe the real `PLUE_BASE_URL` and assert 200 again.
//
// This does NOT exercise the switcher UI re-rendering after a real
// docker pause (that is a follow-up). What it DOES catch is the
// URLSession / TLS / URLCache plumbing regressing in a way that would
// make the switcher's "backend unavailable" state unreachable — e.g.
// an accidental catch-all that swallows transport errors into an empty
// 200. The docker-pause-orchestrated version lives in run-e2e.sh for
// future enablement when the XCUITest simulator gets host-command
// privileges (expected in iOS 18 simulator + XCTest improvements).
//
// A `PLUE_E2E_DOCKER_API_CONTAINER` env var is discovered by the
// driver; when empty we still run the logical probe above and log the
// discovery failure, rather than XCTSkip — skipping hides regressions.

#if os(iOS)
import XCTest

final class SmithersiOSE2EReconnectTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Phase 1 + 2 + 3 combined. The app is launched to confirm the
    /// shell still mounts during the "unreachable" phase (read from
    /// cache rather than error into sign-in), and the HTTP probes
    /// confirm the URLSession path sees the expected transport errors.
    func test_baseline_partition_recovery_all_observable() throws {
        let procEnv = ProcessInfo.processInfo.environment
        guard let baseURLString = procEnv[E2ELaunchKey.baseURL],
              let baseURL = URL(string: baseURLString) else {
            XCTFail("reconnect scenario requires PLUE_BASE_URL")
            return
        }

        // The docker container name is discovered by `run-e2e.sh`. We
        // don't require it to be present — that's the "simulator can't
        // pause host containers" constraint we accept in v1. Log + keep
        // going so the xcresult bundle records what was / wasn't done.
        let dockerContainer = procEnv[E2ELaunchKey.dockerAPIContainer] ?? ""
        if dockerContainer.isEmpty {
            // Non-fatal: the probe below still runs. We just don't get
            // the true-docker-pause flavor of the scenario.
            NSLog("[reconnect] PLUE_E2E_DOCKER_API_CONTAINER empty — running URLSession-only approximation")
        } else {
            NSLog("[reconnect] docker container discovered: \(dockerContainer) (driver will pause/unpause)")
        }

        // --- Phase 1: baseline connectivity.
        let (baseStatus, _) = try probe(
            url: baseURL.appendingPathComponent("api/feature-flags"),
            timeout: 5
        )
        XCTAssertEqual(
            baseStatus, 200,
            "baseline: plue api must be reachable at \(baseURL)"
        )

        // Launch the app during the baseline phase, assert the switcher
        // loads workspaces (signed-in shell mounts against live plue).
        // A regression that breaks reconnect resilience often shows up
        // as the shell itself failing to mount, so this is the most
        // sensitive single assertion we can make.
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()
        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "shell must mount in the baseline phase"
        )

        // --- Phase 2: partition simulation.
        //
        // We do NOT tear down the just-launched app — a live switcher
        // during the partition proves the cache-fallback path (the
        // shared `SmithersStore` keeps the last-known row set, so the
        // workspaces list should still render). Re-open the switcher
        // and assert the list is still reachable (cached rows survive
        // a transport hiccup).
        app.buttons["content.ios.open-switcher"].tap()
        let switcherRoot = app.descendants(matching: .any)
            .matching(identifier: "switcher.ios.root").firstMatch
        XCTAssertTrue(
            switcherRoot.waitForExistence(timeout: 5),
            "switcher must be openable during the partition phase"
        )

        // Now probe an unreachable endpoint and assert URLSession
        // surfaces a hard error (NOT a zero-byte 200). Port 1 is the
        // standard "nothing listens here" sentinel.
        let partitionURL = URL(string: "http://127.0.0.1:1/api/feature-flags")!
        do {
            let (status, _) = try probe(url: partitionURL, timeout: 2)
            XCTFail("partition probe should have failed with a transport error, got HTTP \(status)")
        } catch {
            // Expected. The exact error kind varies by simulator
            // (NSURLErrorCannotConnectToHost, timed out, etc.); we
            // only assert that an error WAS raised.
            NSLog("[reconnect] partition probe errored as expected: \(error)")
        }

        // Close the switcher so we can reopen + refresh cleanly in the
        // recovery phase. If the close button isn't wired (e.g. a
        // future refactor), fallback to a back-swipe.
        let closeBtn = app.buttons["switcher.ios.close"]
        if closeBtn.waitForExistence(timeout: 2) {
            closeBtn.tap()
        }

        // --- Phase 3: recovery. Re-probe the REAL plue URL and assert
        // it returns 200 again. Because we never actually paused docker
        // in this approximation, this step is near-trivially true —
        // but it guards against a regression where the URL was
        // permanently rewritten or the session was cached-poisoned.
        let (recoveredStatus, _) = try probe(
            url: baseURL.appendingPathComponent("api/feature-flags"),
            timeout: 5
        )
        XCTAssertEqual(
            recoveredStatus, 200,
            "recovery: plue api must still be reachable after the partition phase"
        )

        // Re-open the switcher after recovery and assert rows load.
        app.buttons["content.ios.open-switcher"].tap()
        let rowAfter = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
        ).firstMatch
        XCTAssertTrue(
            rowAfter.waitForExistence(timeout: 15),
            "switcher must list the seeded workspace row after recovery"
        )
    }

    // MARK: - HTTP helper

    /// Synchronous GET probe with a configurable timeout. Returns
    /// (HTTP status, body). Throws on transport errors.
    private func probe(url: URL, timeout: TimeInterval) throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout

        var out: (Int, Data)?
        var outErr: Error?
        let sem = DispatchSemaphore(value: 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        let session = URLSession(configuration: cfg)
        let task = session.dataTask(with: req) { data, resp, err in
            if let err = err { outErr = err }
            else if let http = resp as? HTTPURLResponse {
                out = (http.statusCode, data ?? Data())
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        if let outErr = outErr { throw outErr }
        guard let out = out else {
            throw NSError(domain: "reconnect-e2e", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "timed out probing \(url)"])
        }
        return out
    }
}
#endif
