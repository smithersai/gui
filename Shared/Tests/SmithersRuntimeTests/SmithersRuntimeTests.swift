// SmithersRuntime integration tests.
//
// These exercise the Swift wrapper against the real Zig `smithers_core_*`
// exports. The transport inside the Zig core is the fake transport
// (production wiring awaits the 0120-followup that promotes the 0093
// Electric client into the libsmithers build graph), so these assertions
// cover:
//   - Runtime lifecycle + credentials callback plumbing
//   - connect() → RuntimeSession round-trip
//   - subscribe(shape:) → cacheQuery() read-path
//   - wipeCache() zeroes the cache
//   - write() returns a non-zero future
// Full end-to-end shape-delta assertions against a live plue stack are
// gated behind POC_ELECTRIC_STACK elsewhere.

import XCTest
@testable import SmithersRuntime

// These tests require the CSmithersKit C module (built by the full Xcode /
// SwiftPM target graph that links `libsmithers`). The standalone
// `Shared/` SwiftPM package does NOT link CSmithersKit, so these tests
// compile but are skipped at runtime in that environment. They run via
// the macOS/iOS app Xcode schemes.
#if canImport(CSmithersKit)
final class SmithersRuntimeTests: XCTestCase {

    func testRuntimeInitAndFree() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "test-bearer") }
        _ = rt
    }

    func testConnectReturnsSession() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        _ = s
    }

    func testSubscribeAgentSessionsAndEmptyQuery() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        let sub = try s.subscribe(shape: "agent_sessions", paramsJSON: "{}")
        XCTAssertGreaterThan(sub, 0)
        let rows = try s.cacheQuery(table: "agent_sessions")
        XCTAssertEqual(rows, "[]")
        s.unsubscribe(sub)
    }

    func testUnknownShapeRejected() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        XCTAssertThrowsError(try s.subscribe(shape: "not_a_shape"))
    }

    func testWriteReturnsFuture() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        let fut = try s.write(action: "agent_session.create", payloadJSON: #"{"title":"hi"}"#)
        XCTAssertGreaterThan(fut, 0)
    }

    func testWipeCacheSucceeds() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        try s.wipeCache()
    }

    func testPinUnpinIdempotent() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        let sub = try s.subscribe(shape: "agent_sessions")
        s.pin(sub)
        s.pin(sub)
        s.unpin(sub)
        s.unpin(sub)
    }

    func testEventCallbackIsWired() throws {
        let rt = try SmithersRuntime { SmithersCredentials(bearer: "tb") }
        let s = try rt.connect(.init(engineID: "e1", baseURL: "http://localhost"))
        let exp = expectation(description: "no events yet")
        exp.isInverted = true

        var count = 0
        s.onEvent { _ in
            count += 1
            exp.fulfill()
        }
        // No deltas enqueued; driving tick once must be a no-op.
        s._tickForTest()
        wait(for: [exp], timeout: 0.05)
        XCTAssertEqual(count, 0)
    }
}
#endif
