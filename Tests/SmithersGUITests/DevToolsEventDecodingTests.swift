import XCTest
@testable import SmithersGUI

/// Reproduces and guards against the "Malformed event" regression where the
/// libsmithers stream fallback path emits `{"method":..., "args":...}` for
/// methods it doesn't recognise — which lands in the Swift decoder as a
/// top-level `keyNotFound("type")`, exactly like the screenshot:
///
///     Malformed event: keyNotFound(CodingKeys(stringValue: "type", ...),
///       Swift.DecodingError.Context(codingPath: [], ...))
///
/// Root cause in the wild: the shipped GUI binary was linked against an older
/// libsmithers.a that did not yet route `streamDevTools` to the snapshot
/// producer, so `streamImpl`'s fallback emitted the method/args envelope.
final class DevToolsEventDecodingTests: XCTestCase {

    // MARK: - Happy path

    func testDecodesRealSnapshotEnvelope() throws {
        let json = Data("""
        {
          "type": "snapshot",
          "runId": "run-1",
          "frameNo": 2,
          "seq": 2,
          "root": {
            "id": 0,
            "type": "workflow",
            "name": "ticket-kanban",
            "props": {"state": "running"},
            "task": null,
            "children": [],
            "depth": 0
          }
        }
        """.utf8)

        let event = try JSONDecoder().decode(DevToolsEvent.self, from: json)
        guard case .snapshot(let snapshot) = event else {
            XCTFail("Expected .snapshot, got \(event)")
            return
        }
        XCTAssertEqual(snapshot.runId, "run-1")
        XCTAssertEqual(snapshot.frameNo, 2)
        XCTAssertEqual(snapshot.seq, 2)
        XCTAssertEqual(snapshot.root.type, .workflow)
    }

    // MARK: - Regression: stale libsmithers fallback

    /// When the libsmithers stream path doesn't recognise `streamDevTools`, it
    /// falls back to pushing `{"method":..., "args":...}`. Make sure that
    /// payload decodes to a useful `DevToolsClientError.malformedEvent` so the
    /// UI banner + reconnect logic can react (rather than silently hanging).
    func testStaleLibsmithersFallbackSurfacesAsMalformedEvent() {
        let json = Data("""
        {"method":"streamDevTools","args":{"runId":"run-1","fromSeq":null}}
        """.utf8)

        do {
            _ = try JSONDecoder().decode(DevToolsEvent.self, from: json)
            XCTFail("Expected keyNotFound decoding error")
        } catch let decodingError as DecodingError {
            guard case .keyNotFound(let key, let context) = decodingError else {
                XCTFail("Expected .keyNotFound, got \(decodingError)")
                return
            }
            XCTAssertEqual(key.stringValue, "type")
            XCTAssertTrue(context.codingPath.isEmpty, "Missing key should be at top level")

            let clientError = DevToolsClientError.from(decodingError: decodingError)
            guard case .malformedEvent(let detail) = clientError else {
                XCTFail("Expected .malformedEvent, got \(clientError)")
                return
            }
            XCTAssertTrue(detail.contains("type"), "Detail should mention missing key: \(detail)")
        } catch {
            XCTFail("Expected DecodingError, got \(type(of: error))")
        }
    }

    // MARK: - Unknown type

    func testUnknownEventTypeProducesDataCorrupted() {
        let json = Data(#"{"type":"surprise","runId":"run-1","frameNo":0,"seq":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DevToolsEvent.self, from: json)) { error in
            guard let decodingError = error as? DecodingError,
                  case .dataCorrupted = decodingError else {
                XCTFail("Expected .dataCorrupted, got \(error)")
                return
            }
        }
    }
}
