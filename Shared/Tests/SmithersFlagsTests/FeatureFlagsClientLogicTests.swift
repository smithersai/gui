import Foundation
import XCTest
@testable import SmithersFlags

@MainActor
final class FeatureFlagsClientLogicTests: XCTestCase {
    func testRefreshDecodesDirectDictionaryAndSendsBearer() async throws {
        let transport = RecordingFlagsTransport(responses: [
            .init(status: 200, body: #"{"remote_sandbox_enabled":true,"devtools_snapshot_enabled":true}"#),
        ])
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "flag-token" },
            now: { transport.now }
        )

        let snapshot = try await client.refresh(force: true)

        XCTAssertTrue(snapshot.isRemoteSandboxEnabled)
        XCTAssertTrue(snapshot.isDevtoolsSnapshotEnabled)
        XCTAssertEqual(client.lastRefreshAt, transport.now)
        XCTAssertNil(client.lastErrorDescription)
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.recorded[0].url.absoluteString, "https://plue.test/api/feature-flags")
        XCTAssertEqual(transport.recorded[0].headers["Authorization"], "Bearer flag-token")
        XCTAssertEqual(transport.recorded[0].headers["Accept"], "application/json")
    }

    func testRefreshCoalescesConcurrentInFlightRequest() async throws {
        let gate = AsyncGate()
        let transport = RecordingFlagsTransport(
            responses: [.init(status: 200, body: #"{"flags":{"approvals_flow_enabled":true}}"#)],
            gate: gate
        )
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "flag-token" }
        )

        async let first = client.refresh(force: true)
        async let second = client.refresh(force: true)
        await gate.waitForWaiter()
        gate.open()

        let snapshots = try await [first, second]

        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertTrue(snapshots[0].isApprovalsFlowEnabled)
        XCTAssertEqual(snapshots[0], snapshots[1])
        XCTAssertFalse(client.isRefreshing)
    }

    func testUnauthorizedRefreshSurfacesErrorAndKeepsExistingSnapshot() async throws {
        let transport = RecordingFlagsTransport(responses: [
            .init(status: 401, body: #"{"error":"unauthorized"}"#),
        ])
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "expired-token" },
            initialSnapshot: FeatureFlagsSnapshot(flags: ["run_shape_enabled": true])
        )

        do {
            _ = try await client.refresh(force: true)
            XCTFail("Expected unauthorized error")
        } catch let error as FeatureFlagsError {
            XCTAssertEqual(error, .unauthorized)
        }

        XCTAssertTrue(client.isRunShapeEnabled)
        XCTAssertEqual(client.lastErrorDescription, "Unauthorized.")
        XCTAssertFalse(client.isRefreshing)
    }

    func testEnvironmentOverrideOnlyAcceptsKnownBooleanValues() {
        let enabled = FeatureFlagsSnapshot(flags: ["remote_sandbox_enabled": true])
        let disabled = FeatureFlagsSnapshot(flags: ["remote_sandbox_enabled": false])

        XCTAssertFalse(enabled.effectiveRemoteSandboxEnabled(environment: [
            FeatureFlagsEnvironment.remoteSandboxEnvVar: "off",
        ]))
        XCTAssertTrue(disabled.effectiveRemoteSandboxEnabled(environment: [
            FeatureFlagsEnvironment.remoteSandboxEnvVar: "YES",
        ]))
        XCTAssertTrue(enabled.effectiveRemoteSandboxEnabled(environment: [
            FeatureFlagsEnvironment.remoteSandboxEnvVar: "maybe",
        ]))
    }
}

private final class RecordingFlagsTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
    }

    struct Recorded {
        let url: URL
        let method: String
        let headers: [String: String]
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let lock = NSLock()
    private var responses: [Response]
    private let gate: AsyncGate?
    private(set) var recorded: [Recorded] = []

    init(responses: [Response], gate: AsyncGate? = nil) {
        self.responses = responses
        self.gate = gate
    }

    func send(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        await gate?.waitUntilOpen()

        return lock.withLock {
            recorded.append(Recorded(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:]
            ))
            let response = responses.isEmpty
                ? Response(status: 500, body: "")
                : responses.removeFirst()
            return (Data(response.body.utf8), response.status, [:])
        }
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterRegisteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var waiterCount = 0

    func waitUntilOpen() async {
        await withCheckedContinuation { continuation in
            let registered: [CheckedContinuation<Void, Never>]
            var resumeNow = false

            lock.lock()
            waiterCount += 1
            registered = waiterRegisteredContinuations
            waiterRegisteredContinuations.removeAll()
            if isOpen {
                resumeNow = true
            } else {
                waiters.append(continuation)
            }
            lock.unlock()

            registered.forEach { $0.resume() }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func waitForWaiter() async {
        await withCheckedContinuation { continuation in
            var resumeNow = false

            lock.lock()
            if waiterCount > 0 {
                resumeNow = true
            } else {
                waiterRegisteredContinuations.append(continuation)
            }
            lock.unlock()

            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let continuations: [CheckedContinuation<Void, Never>]

        lock.lock()
        isOpen = true
        continuations = waiters
        waiters.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
