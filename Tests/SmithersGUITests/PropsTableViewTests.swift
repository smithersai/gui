import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension PropsTableView: @retroactive Inspectable {}

@MainActor
final class PropsTableViewTests: XCTestCase {

    // MARK: - Empty state

    func testZeroPropsShowsPlaceholder() throws {
        let view = PropsTableView(props: [:])
        XCTAssertNoThrow(try view.inspect().find(text: "No props"))
    }

    // MARK: - Single prop

    func testSinglePropRendersKeyAndValue() throws {
        let view = PropsTableView(props: ["agent": .string("claude")])
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "agent"))
        XCTAssertNoThrow(try inspected.find(text: "\"claude\""))
    }

    // MARK: - Multiple props

    func testMultiplePropsAllRendered() throws {
        var props: [String: JSONValue] = [:]
        for i in 0..<5 {
            props["key\(i)"] = .number(Double(i))
        }
        let view = PropsTableView(props: props)
        let inspected = try view.inspect()
        for i in 0..<5 {
            XCTAssertNoThrow(try inspected.find(text: "key\(i)"))
        }
    }

    // MARK: - Ordered keys

    func testOrderedKeysRespected() throws {
        let props: [String: JSONValue] = [
            "zebra": .string("z"),
            "alpha": .string("a"),
            "middle": .string("m"),
        ]
        let view = PropsTableView(props: props, orderedKeys: ["middle", "alpha", "zebra"])
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "middle"))
        XCTAssertNoThrow(try inspected.find(text: "alpha"))
        XCTAssertNoThrow(try inspected.find(text: "zebra"))
    }

    // MARK: - Large prop counts

    func testHundredPropsRenderable() throws {
        var props: [String: JSONValue] = [:]
        for i in 0..<100 {
            props["prop\(i)"] = .number(Double(i))
        }
        let view = PropsTableView(props: props)
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - Copy button accessibility

    func testCopyButtonAccessibility() throws {
        let view = PropsTableView(props: ["agent": .string("opus")])
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(ViewType.Button.self, where: { button in
            let id = try? button.accessibilityIdentifier()
            return id == "inspector.props.copy.agent"
        }))
    }
}
