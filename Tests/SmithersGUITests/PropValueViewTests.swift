import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension PropValueView: @retroactive Inspectable {}

@MainActor
final class PropValueViewTests: XCTestCase {

    // MARK: - Scalar values

    func testNullRendersNullText() throws {
        let view = PropValueView(value: .null)
        let text = try view.inspect().find(text: "null")
        XCTAssertEqual(try text.string(), "null")
    }

    func testBoolTrueRendersTrue() throws {
        let view = PropValueView(value: .bool(true))
        XCTAssertNoThrow(try view.inspect().find(text: "true"))
    }

    func testBoolFalseRendersFalse() throws {
        let view = PropValueView(value: .bool(false))
        XCTAssertNoThrow(try view.inspect().find(text: "false"))
    }

    func testNumberRendersFormatted() throws {
        let view = PropValueView(value: .number(42.0))
        XCTAssertNoThrow(try view.inspect().find(text: "42"))
    }

    func testDecimalNumber() throws {
        let view = PropValueView(value: .number(3.14))
        XCTAssertNoThrow(try view.inspect().find(text: "3.14"))
    }

    // MARK: - Short strings

    func testShortStringInline() throws {
        let view = PropValueView(value: .string("hello"))
        XCTAssertNoThrow(try view.inspect().find(text: "\"hello\""))
    }

    func testStringAt200CharsIsInline() throws {
        let s = String(repeating: "a", count: 200)
        let view = PropValueView(value: .string(s))
        XCTAssertNoThrow(try view.inspect().find(text: "\"\(s)\""))
    }

    // MARK: - Long strings

    func testStringOver200CharsTruncated() throws {
        let s = String(repeating: "b", count: 250)
        let view = PropValueView(value: .string(s))
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(button: "[expand]"))
    }

    // MARK: - Empty collections

    func testEmptyArray() throws {
        let view = PropValueView(value: .array([]))
        XCTAssertNoThrow(try view.inspect().find(text: "[]"))
    }

    func testEmptyObject() throws {
        let view = PropValueView(value: .object([:]))
        XCTAssertNoThrow(try view.inspect().find(text: "{}"))
    }

    // MARK: - Non-empty collections (collapsed by default)

    func testArrayShowsCount() throws {
        let view = PropValueView(value: .array([.number(1), .number(2)]))
        XCTAssertNoThrow(try view.inspect().find(text: "Array(2)"))
    }

    func testObjectShowsCount() throws {
        let view = PropValueView(value: .object(["a": .number(1), "b": .number(2)]))
        XCTAssertNoThrow(try view.inspect().find(text: "Object(2)"))
    }

    // MARK: - Depth limiting

    func testDepthLimitMarker() throws {
        let view = PropValueView(value: .string("test"), depth: 50)
        XCTAssertNoThrow(try view.inspect().find(text: "[Depth limit reached]"))
    }

    func testBelowDepthLimit() throws {
        let view = PropValueView(value: .string("test"), depth: 49)
        XCTAssertNoThrow(try view.inspect().find(text: "\"test\""))
    }
}
