// FeatureFlagsClientEdgeTests.swift — cache, TTL, and error-path coverage
// for FeatureFlagsClient. Companion to FeatureFlagsClientTests.swift.
//
// Notes about the SUT (FeatureFlagsClient) that shape these tests:
//   * The cache is a strict TTL (no stale-while-revalidate). When the cache
//     is fresh, refresh() returns the in-memory snapshot without hitting the
//     network. When TTL has elapsed, refresh() refetches and either updates
//     the snapshot (success) or rethrows (failure). On failure the previous
//     snapshot is preserved but lastErrorDescription is populated.
//   * FeatureFlagsSnapshot stores only [String: Bool]. Non-bool JSON values
//     should fail decoding with .invalidResponse.
//   * In-flight de-dup is keyed on `inFlightRefresh`; concurrent callers
//     await the same Task.

import Foundation
import XCTest
@testable import SmithersAuth

@MainActor
final class FeatureFlagsClientEdgeTests: XCTestCase {

    // MARK: - Helpers

    private func makeClient(
        transport: MockHTTPTransport,
        clock: EdgeTestClock,
        ttl: TimeInterval = 60,
        bearer: String? = "FAKE_BEARER"
    ) -> FeatureFlagsClient {
        FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { bearer },
            ttl: ttl,
            now: { clock.now }
        )
    }

    private static func envelope(_ flags: [String: Bool]) -> MockHTTPTransport.CannedResponse {
        .json(payload: ["flags": flags])
    }

    // MARK: - Cache hit before TTL expiry

    func test_cache_hit_within_ttl_does_not_hit_network() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope(["a": true])]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(30) // still within TTL

        let cached = try await client.refresh()

        XCTAssertEqual(transport.recorded.count, 1, "second refresh should reuse cache")
        XCTAssertTrue(cached.flag(named: "a"))
    }

    func test_cache_hit_at_exact_boundary_just_inside_ttl_reuses_cache() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(59.999)
        let cached = try await client.refresh()

        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertTrue(cached.flag(named: "a"))
    }

    // MARK: - Cache miss after TTL expiry

    func test_cache_miss_after_ttl_triggers_refetch() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(60.001) // strictly past TTL
        let refreshed = try await client.refresh()

        XCTAssertEqual(transport.recorded.count, 2)
        XCTAssertFalse(refreshed.flag(named: "a"))
    }

    func test_cache_miss_at_exact_ttl_boundary_refetches() async throws {
        // The implementation uses `< ttl` so equality refetches.
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(60) // exactly TTL — falls outside `<`
        _ = try await client.refresh()

        XCTAssertEqual(transport.recorded.count, 2)
    }

    // MARK: - Stale-while-revalidate (NOT implemented)

    func test_no_stale_while_revalidate_error_during_refresh_surfaces_to_caller() async throws {
        // Behavior assertion: there is NO stale-while-revalidate. After TTL
        // expiry, a failing refresh throws. The previous snapshot remains
        // in `client.snapshot` but the call itself does not silently succeed.
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            .init(status: 500, body: Data("boom".utf8), headers: [:]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(120)

        await assertThrowsError(try await client.refresh())
        // Previous snapshot is still observable on the client.
        XCTAssertTrue(client.snapshot.flag(named: "a"))
        XCTAssertNotNil(client.lastErrorDescription)
    }

    // MARK: - Network error path

    func test_transport_throws_propagates_as_transport_error() async throws {
        let transport = ThrowingHTTPTransport(error: URLError(.notConnectedToInternet))
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch let FeatureFlagsError.transport(message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_transport_error_does_not_poison_cache() async throws {
        // After a failed refresh the next call must still try the network
        // (i.e. the failure was not cached).
        let transport = MockHTTPTransport()
        transport.responses = [
            .init(status: 500, body: Data("boom".utf8), headers: [:]),
            Self.envelope(["a": true]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        await assertThrowsError(try await client.refresh(force: true))
        let next = try await client.refresh(force: true)
        XCTAssertEqual(transport.recorded.count, 2)
        XCTAssertTrue(next.flag(named: "a"))
    }

    // MARK: - 4xx / 5xx response handling

    func test_401_maps_to_unauthorized_error() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(status: 401, body: Data("nope".utf8), headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.unauthorized {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_403_maps_to_badStatus() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(status: 403, body: Data("forbidden".utf8), headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch let FeatureFlagsError.badStatus(status, snippet) {
            XCTAssertEqual(status, 403)
            XCTAssertTrue(snippet.contains("forbidden"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_4xx_response_does_not_update_snapshot_or_cache() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            .init(status: 404, body: Data("missing".utf8), headers: [:]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(120)
        await assertThrowsError(try await client.refresh())

        XCTAssertTrue(client.snapshot.flag(named: "a"))
        // After failure the cache is stale (cachedAt unchanged) so a new call
        // hits the network again.
        transport.responses = [Self.envelope(["a": false])]
        let third = try await client.refresh()
        XCTAssertFalse(third.flag(named: "a"))
    }

    func test_500_maps_to_badStatus_and_does_not_update_cache() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(status: 500, body: Data("upstream".utf8), headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch let FeatureFlagsError.badStatus(status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(client.lastRefreshAt)
    }

    func test_502_maps_to_badStatus() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(status: 502, body: Data("bad gateway".utf8), headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch let FeatureFlagsError.badStatus(status, snippet) {
            XCTAssertEqual(status, 502)
            XCTAssertTrue(snippet.contains("bad gateway"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_status_snippet_truncates_to_256_bytes() async throws {
        let big = String(repeating: "x", count: 1024)
        let transport = MockHTTPTransport()
        transport.responses = [.init(status: 503, body: Data(big.utf8), headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch let FeatureFlagsError.badStatus(_, snippet) {
            XCTAssertEqual(snippet.count, 256)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Malformed / unexpected JSON

    func test_malformed_json_throws_invalidResponse() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(
            status: 200,
            body: Data("{not really json".utf8),
            headers: ["Content-Type": "application/json"]
        )]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_empty_body_throws_invalidResponse() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(status: 200, body: Data(), headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_non_object_root_throws_invalidResponse() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [.init(
            status: 200,
            body: Data("[1,2,3]".utf8),
            headers: ["Content-Type": "application/json"]
        )]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Empty flag set

    func test_empty_flag_set_decodes_to_empty_snapshot() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope([:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        let snap = try await client.refresh(force: true)
        XCTAssertTrue(snap.flags.isEmpty)
        XCTAssertFalse(snap.isRemoteSandboxEnabled)
        XCTAssertFalse(snap.isApprovalsFlowEnabled)
    }

    func test_direct_map_root_decodes() async throws {
        // The decoder also accepts a bare [String: Bool] root.
        let transport = MockHTTPTransport()
        let body = try JSONSerialization.data(withJSONObject: [
            "remote_sandbox_enabled": true,
            "approvals_flow_enabled": false,
        ])
        transport.responses = [.init(status: 200, body: body, headers: ["Content-Type": "application/json"])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        let snap = try await client.refresh(force: true)
        XCTAssertTrue(snap.isRemoteSandboxEnabled)
        XCTAssertFalse(snap.isApprovalsFlowEnabled)
    }

    // MARK: - Flag value type variations

    func test_string_valued_flags_are_rejected_as_invalidResponse() async throws {
        // FeatureFlagsSnapshot stores [String: Bool]. A string-valued flag
        // should not silently coerce.
        let transport = MockHTTPTransport()
        let body = try JSONSerialization.data(withJSONObject: ["flags": ["a": "true"]])
        transport.responses = [.init(status: 200, body: body, headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_numeric_valued_flags_are_rejected_as_invalidResponse() async throws {
        let transport = MockHTTPTransport()
        let body = try JSONSerialization.data(withJSONObject: ["flags": ["a": 1]])
        transport.responses = [.init(status: 200, body: body, headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_object_valued_flags_are_rejected_as_invalidResponse() async throws {
        let transport = MockHTTPTransport()
        let body = try JSONSerialization.data(withJSONObject: [
            "flags": ["a": ["nested": true]],
        ])
        transport.responses = [.init(status: 200, body: body, headers: [:])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_bool_flag_round_trips_for_all_known_named_accessors() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope([
            "remote_sandbox_enabled": true,
            "approvals_flow_enabled": true,
            "electric_client_enabled": true,
            "devtools_snapshot_enabled": true,
            "run_shape_enabled": true,
        ])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        let snap = try await client.refresh(force: true)
        XCTAssertTrue(snap.isRemoteSandboxEnabled)
        XCTAssertTrue(snap.isApprovalsFlowEnabled)
        XCTAssertTrue(snap.isElectricClientEnabled)
        XCTAssertTrue(snap.isDevtoolsSnapshotEnabled)
        XCTAssertTrue(snap.isRunShapeEnabled)
    }

    // MARK: - Missing flag → fallback default (false)

    func test_missing_flag_returns_false_default() async throws {
        let snap = FeatureFlagsSnapshot(flags: ["something_else": true])
        XCTAssertFalse(snap.flag(named: "remote_sandbox_enabled"))
        XCTAssertFalse(snap.isRemoteSandboxEnabled)
        XCTAssertFalse(snap.flag(named: "totally_unknown"))
    }

    func test_explicit_false_in_payload_returns_false() async throws {
        let snap = FeatureFlagsSnapshot(flags: ["remote_sandbox_enabled": false])
        XCTAssertFalse(snap.isRemoteSandboxEnabled)
    }

    // MARK: - Concurrent reads → in-flight de-dup

    func test_concurrent_refreshes_share_a_single_network_call() async throws {
        let transport = MockHTTPTransport()
        transport.sendDelayNanoseconds = 50_000_000 // 50ms
        transport.responses = [Self.envelope(["a": true])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )

        async let r1 = client.refresh(force: true)
        async let r2 = client.refresh(force: true)
        async let r3 = client.refresh(force: true)
        let results = try await [r1, r2, r3]

        XCTAssertEqual(transport.recorded.count, 1, "in-flight refresh should dedupe concurrent callers")
        for snap in results {
            XCTAssertTrue(snap.flag(named: "a"))
        }
    }

    // MARK: - Clock skew

    func test_cache_serves_refetch_after_clock_rewind() async throws {
        // Regression: a backwards clock jump (DST, NTP correction, manual
        // change) used to make the cache freeze forever because
        // `(now - cachedAt) < ttl` is trivially true for any negative age.
        // The fix clamps negative age to "expired" so we refetch.
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
            Self.envelope(["a": true]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(120) // expire
        let two = try await client.refresh()
        XCTAssertFalse(two.flag(named: "a"))
        XCTAssertEqual(transport.recorded.count, 2)

        // Jump the clock backwards. cachedAt is now "in the future" relative
        // to `now`; age is negative. With the fix, this counts as expired.
        clock.now.addTimeInterval(-1_000)
        let three = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 3, "negative age must NOT reuse cache")
        XCTAssertTrue(three.flag(named: "a"))
    }

    func test_cache_rewind_exactly_to_fetched_at_keeps_cache() async throws {
        // age == 0 is still a valid (just-written) cache: must not refetch.
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        let fetchedAt = clock.now
        clock.now.addTimeInterval(30)
        // Rewind exactly back to fetchedAt — age == 0, still fresh.
        clock.now = fetchedAt
        _ = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 1, "age == 0 should still be a cache hit")
    }

    func test_cache_rewind_by_large_amount_refetches() async throws {
        // A multi-year backwards jump (e.g. dead RTC battery resetting epoch)
        // must not freeze the cache.
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        // Years backwards.
        clock.now.addTimeInterval(-60 * 60 * 24 * 365 * 5)
        let next = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 2, "huge negative age must refetch")
        XCTAssertFalse(next.flag(named: "a"))
    }

    func test_cache_rewind_then_forward_returns_to_normal_ttl_semantics() async throws {
        // Rewind triggers a refetch; subsequent forward time movement should
        // honor TTL relative to the most recent successful fetch.
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
            Self.envelope(["a": true]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        // Rewind: triggers refetch.
        clock.now.addTimeInterval(-500)
        let two = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 2)
        XCTAssertFalse(two.flag(named: "a"))

        // From the new (rewound) cachedAt, advance within TTL — cache hit.
        clock.now.addTimeInterval(30)
        let three = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 2, "within new TTL window")
        XCTAssertFalse(three.flag(named: "a"))

        // Advance past TTL — refetch again.
        clock.now.addTimeInterval(60)
        let four = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 3)
        XCTAssertTrue(four.flag(named: "a"))
    }

    func test_clock_unchanged_keeps_cache_indefinitely() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope(["a": true])]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 60)

        _ = try await client.refresh(force: true)
        for _ in 0..<10 {
            _ = try await client.refresh()
        }
        XCTAssertEqual(transport.recorded.count, 1)
    }

    // MARK: - Very large flag set

    func test_very_large_flag_set_decodes() async throws {
        var flags: [String: Bool] = [:]
        flags.reserveCapacity(10_000)
        for i in 0..<10_000 {
            flags["flag_\(i)"] = (i % 2 == 0)
        }
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope(flags)]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )

        let snap = try await client.refresh(force: true)
        XCTAssertEqual(snap.flags.count, 10_000)
        XCTAssertTrue(snap.flag(named: "flag_0"))
        XCTAssertFalse(snap.flag(named: "flag_1"))
        XCTAssertTrue(snap.flag(named: "flag_9998"))
        XCTAssertFalse(snap.flag(named: "flag_9999"))
    }

    // MARK: - Unicode flag names

    func test_unicode_flag_names_decode_and_lookup() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope([
            "функция": true,
            "機能": true,
            "feature_with_emoji_🚀": true,
            "feature.with-dashes/and.dots": true,
        ])]
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )
        let snap = try await client.refresh(force: true)
        XCTAssertTrue(snap.flag(named: "функция"))
        XCTAssertTrue(snap.flag(named: "機能"))
        XCTAssertTrue(snap.flag(named: "feature_with_emoji_🚀"))
        XCTAssertTrue(snap.flag(named: "feature.with-dashes/and.dots"))
        XCTAssertFalse(snap.flag(named: "ascii_missing"))
    }

    // MARK: - TTL boundary values

    func test_ttl_zero_always_refetches() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            Self.envelope(["a": true]),
            Self.envelope(["a": false]),
            Self.envelope(["a": true]),
        ]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: 0)

        _ = try await client.refresh(force: true)
        _ = try await client.refresh()
        _ = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 3, "ttl=0 means cached age 0 is never `< 0`")
    }

    func test_ttl_max_never_expires_within_test_horizon() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [Self.envelope(["a": true])]
        let clock = EdgeTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = makeClient(transport: transport, clock: clock, ttl: .greatestFiniteMagnitude)

        _ = try await client.refresh(force: true)
        clock.now.addTimeInterval(1_000_000_000)
        _ = try await client.refresh()
        clock.now.addTimeInterval(1_000_000_000)
        _ = try await client.refresh()
        XCTAssertEqual(transport.recorded.count, 1)
    }

    // MARK: - notSignedIn / bearer

    func test_missing_bearer_throws_notSignedIn() async throws {
        let transport = MockHTTPTransport()
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { nil }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.notSignedIn {
            // expected — and no network call should have been made.
            XCTAssertEqual(transport.recorded.count, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_empty_bearer_throws_notSignedIn() async throws {
        let transport = MockHTTPTransport()
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "" }
        )
        do {
            _ = try await client.refresh(force: true)
            XCTFail("expected throw")
        } catch FeatureFlagsError.notSignedIn {
            XCTAssertEqual(transport.recorded.count, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Test doubles

private final class EdgeTestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

private final class ThrowingHTTPTransport: HTTPTransport {
    let error: Error
    init(error: Error) { self.error = error }
    func send(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        throw error
    }
}

// MARK: - Async assertion helper

private func assertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
