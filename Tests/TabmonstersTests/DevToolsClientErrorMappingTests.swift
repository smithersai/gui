import XCTest
@testable import SmithersGUI

final class DevToolsClientErrorMappingTests: XCTestCase {

    // MARK: - Server error code mapping

    func testRunNotFoundMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "RunNotFound", message: "run_abc")
        XCTAssertEqual(error, .runNotFound("run_abc"))
    }

    func testFrameOutOfRangeMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "FrameOutOfRange", message: "42")
        XCTAssertEqual(error, .frameOutOfRange(42))
    }

    func testFrameOutOfRangeNonNumeric() {
        let error = DevToolsClientError.from(serverErrorCode: "FrameOutOfRange", message: "invalid")
        XCTAssertEqual(error, .frameOutOfRange(-1))
    }

    func testInvalidRunIdMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "InvalidRunId", message: "bad!!!")
        XCTAssertEqual(error, .invalidRunId("bad!!!"))
    }

    func testInvalidFrameNoMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "InvalidFrameNo", message: "7")
        XCTAssertEqual(error, .invalidFrameNo(7))
    }

    func testSeqOutOfRangeMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "SeqOutOfRange", message: "100")
        XCTAssertEqual(error, .seqOutOfRange(100))
    }

    func testSeqOutOfRangeNonNumeric() {
        let error = DevToolsClientError.from(serverErrorCode: "SeqOutOfRange", message: nil)
        XCTAssertEqual(error, .seqOutOfRange(-1))
    }

    func testBackpressureDisconnectMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "BackpressureDisconnect")
        XCTAssertEqual(error, .backpressureDisconnect)
    }

    func testConfirmationRequiredMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "ConfirmationRequired")
        XCTAssertEqual(error, .confirmationRequired)
    }

    func testBusyMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "Busy")
        XCTAssertEqual(error, .busy)
    }

    func testUnsupportedSandboxMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "UnsupportedSandbox", message: "unsupported")
        XCTAssertEqual(error, .unsupportedSandbox("unsupported"))
    }

    func testVcsErrorMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "VcsError", message: "jj failed")
        XCTAssertEqual(error, .vcsError("jj failed"))
    }

    func testRewindFailedMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "RewindFailed", message: "partial rollback")
        XCTAssertEqual(error, .rewindFailed("partial rollback"))
    }

    func testRateLimitedMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "RateLimited")
        XCTAssertEqual(error, .rateLimited)
    }

    func testUnknownErrorCodeMapping() {
        let error = DevToolsClientError.from(serverErrorCode: "SomeFutureError")
        XCTAssertEqual(error, .unknown("SomeFutureError"))
    }

    // MARK: - Network error mapping

    func testURLErrorMapping() {
        let urlError = URLError(.notConnectedToInternet)
        let error = DevToolsClientError.from(urlError: urlError)
        XCTAssertEqual(error, .network(urlError))
    }

    func testURLErrorTimedOut() {
        let urlError = URLError(.timedOut)
        let error = DevToolsClientError.from(urlError: urlError)
        if case .network(let captured) = error {
            XCTAssertEqual(captured.code, .timedOut)
        } else {
            XCTFail("Expected .network case")
        }
    }

    // MARK: - Decode error mapping

    func testDecodingErrorMapping() {
        let json = "{ invalid }".data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(DevToolsSnapshot.self, from: json)
            XCTFail("Expected decoding error")
        } catch let decodingError as DecodingError {
            let error = DevToolsClientError.from(decodingError: decodingError)
            if case .malformedEvent(let detail) = error {
                XCTAssertFalse(detail.isEmpty)
            } else {
                XCTFail("Expected .malformedEvent case")
            }
        } catch {
            XCTFail("Expected DecodingError, got \(type(of: error))")
        }
    }

    // MARK: - Display messages

    func testAllCasesHaveDisplayMessages() {
        let cases: [DevToolsClientError] = [
            .runNotFound("test"),
            .frameOutOfRange(5),
            .invalidRunId("bad"),
            .invalidFrameNo(7),
            .seqOutOfRange(10),
            .confirmationRequired,
            .busy,
            .unsupportedSandbox("x"),
            .vcsError("x"),
            .rewindFailed("x"),
            .rateLimited,
            .backpressureDisconnect,
            .network(URLError(.cancelled)),
            .malformedEvent("bad json"),
            .unknown("xyz"),
        ]
        for error in cases {
            XCTAssertFalse(error.displayMessage.isEmpty, "\(error) should have a display message")
        }
    }

    func testHintsForKnownErrors() {
        XCTAssertNotNil(DevToolsClientError.runNotFound("x").hint)
        XCTAssertNotNil(DevToolsClientError.frameOutOfRange(1).hint)
        XCTAssertNotNil(DevToolsClientError.invalidRunId("x").hint)
        XCTAssertNotNil(DevToolsClientError.invalidFrameNo(1).hint)
        XCTAssertNotNil(DevToolsClientError.seqOutOfRange(1).hint)
        XCTAssertNotNil(DevToolsClientError.confirmationRequired.hint)
        XCTAssertNotNil(DevToolsClientError.busy.hint)
        XCTAssertNotNil(DevToolsClientError.unsupportedSandbox("x").hint)
        XCTAssertNotNil(DevToolsClientError.vcsError("x").hint)
        XCTAssertNotNil(DevToolsClientError.rewindFailed("x").hint)
        XCTAssertNotNil(DevToolsClientError.rateLimited.hint)
        XCTAssertNotNil(DevToolsClientError.backpressureDisconnect.hint)
        XCTAssertNotNil(DevToolsClientError.network(URLError(.timedOut)).hint)
        XCTAssertNotNil(DevToolsClientError.malformedEvent("x").hint)
        XCTAssertNil(DevToolsClientError.unknown("x").hint)
    }

    // MARK: - Equality

    func testEqualitySameCase() {
        XCTAssertEqual(DevToolsClientError.runNotFound("a"), DevToolsClientError.runNotFound("a"))
        XCTAssertNotEqual(DevToolsClientError.runNotFound("a"), DevToolsClientError.runNotFound("b"))
    }

    func testEqualityDifferentCase() {
        XCTAssertNotEqual(
            DevToolsClientError.runNotFound("a") as DevToolsClientError,
            DevToolsClientError.invalidRunId("a") as DevToolsClientError
        )
    }

    func testNetworkEqualityByCode() {
        let a = DevToolsClientError.network(URLError(.timedOut))
        let b = DevToolsClientError.network(URLError(.timedOut))
        XCTAssertEqual(a, b)
    }

    // MARK: - Exhaustive server error code coverage

    // MARK: - libsmithers message parsing

    func testLibsmithersMessageMapsAttemptNotFinished() {
        let mapped = DevToolsClientError.from(libsmithersMessage: "client call: error.AttemptNotFinished")
        XCTAssertEqual(mapped, .attemptNotFinished)
    }

    func testLibsmithersMessageMapsDiffTooLarge() {
        let mapped = DevToolsClientError.from(libsmithersMessage: "client call: error.DiffTooLarge")
        XCTAssertEqual(mapped, .diffTooLarge(nil))
    }

    func testLibsmithersMessageReturnsNilForUnknownTail() {
        XCTAssertNil(DevToolsClientError.from(libsmithersMessage: "client call: error.BrandNewCode"))
    }

    func testLibsmithersMessageReturnsNilWhenNoErrorPrefix() {
        XCTAssertNil(DevToolsClientError.from(libsmithersMessage: "some other failure"))
    }

    func testLibsmithersMessageReturnsNilWhenTailIsLowercase() {
        XCTAssertNil(DevToolsClientError.from(libsmithersMessage: "client call: error.attemptNotFinished"))
    }

    func testEveryServerErrorCodeMapsToExactlyOneCase() {
        let codes = [
            "RunNotFound",
            "FrameOutOfRange",
            "InvalidRunId",
            "InvalidFrameNo",
            "SeqOutOfRange",
            "ConfirmationRequired",
            "Busy",
            "UnsupportedSandbox",
            "VcsError",
            "RewindFailed",
            "RateLimited",
            "BackpressureDisconnect",
        ]
        var seen = Set<String>()
        for code in codes {
            let error = DevToolsClientError.from(serverErrorCode: code)
            let desc = String(describing: error)
            XCTAssertFalse(seen.contains(desc), "Duplicate mapping for \(code)")
            seen.insert(desc)

            if case .unknown = error {
                XCTFail("Known code \(code) should not map to .unknown")
            }
        }
    }
}
