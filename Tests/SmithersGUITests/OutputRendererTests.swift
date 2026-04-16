import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension OutputRenderer: @retroactive Inspectable {}

@MainActor
final class OutputRendererTests: XCTestCase {

    func testEmptySchemaAndRowShowsEmptyState() throws {
        let view = OutputRenderer(row: [:], schema: OutputSchemaDescriptor(fields: []))
        XCTAssertNoThrow(try view.inspect().find(text: "No output fields."))
    }

    func testSingleStringFieldRendersValue() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "title", type: .string, optional: false, nullable: false)
        ])
        let view = OutputRenderer(row: ["title": .string("hello")], schema: schema)

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "title"))
        XCTAssertNoThrow(try inspected.find(text: "\"hello\""))
    }

    func testSchemaOrderRespected() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "first", type: .string, optional: false, nullable: false),
            field(name: "second", type: .string, optional: false, nullable: false),
            field(name: "third", type: .string, optional: false, nullable: false),
        ])

        let view = OutputRenderer(
            row: [
                "third": .string("3"),
                "first": .string("1"),
                "second": .string("2"),
            ],
            schema: schema
        )

        let texts = try view.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        let firstIndex = try XCTUnwrap(texts.firstIndex(of: "first"))
        let secondIndex = try XCTUnwrap(texts.firstIndex(of: "second"))
        let thirdIndex = try XCTUnwrap(texts.firstIndex(of: "third"))

        XCTAssertLessThan(firstIndex, secondIndex)
        XCTAssertLessThan(secondIndex, thirdIndex)
    }

    func testNestedObjectRendersCollapseControl() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "notes", type: .object, optional: false, nullable: false)
        ])
        let row: [String: JSONValue] = ["notes": .object(["summary": .string("ok")])]

        let view = OutputRenderer(row: row, schema: schema)
        XCTAssertNoThrow(try view.inspect().find(text: "Object(1)"))
    }

    func testEnumMismatchShowsWarningMarker() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(
                name: "rating",
                type: .string,
                optional: false,
                nullable: false,
                enumValues: [.string("approve"), .string("changes_requested")]
            )
        ])

        let view = OutputRenderer(row: ["rating": .string("unknown")], schema: schema)
        XCTAssertNoThrow(try view.inspect().find(text: "enum !"))
    }

    func testLongStringTruncatesWithExpandButton() throws {
        let longString = String(repeating: "a", count: 220)
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "body", type: .string, optional: false, nullable: false)
        ])

        let view = OutputRenderer(row: ["body": .string(longString)], schema: schema)
        XCTAssertNoThrow(try view.inspect().find(button: "[expand]"))
    }

    func testNullableNullFieldRendersNullValue() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "notes", type: .string, optional: true, nullable: true)
        ])

        let view = OutputRenderer(row: ["notes": .null], schema: schema)
        XCTAssertNoThrow(try view.inspect().find(text: "null"))
    }

    func testMissingRequiredFieldShowsNotProducedMarker() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "requiredField", type: .string, optional: false, nullable: false)
        ])

        let view = OutputRenderer(row: [:], schema: schema)
        XCTAssertNoThrow(try view.inspect().find(text: "not produced"))
    }

    func testDescriptionTooltipIndicatorPresent() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(
                name: "prompt",
                type: .string,
                optional: false,
                nullable: false,
                description: "Prompt text shown to the model"
            )
        ])

        let view = OutputRenderer(row: ["prompt": .string("p")], schema: schema)
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(ViewType.Image.self, where: { image in
            try image.accessibilityIdentifier() == "output.field.help.prompt"
        }))
    }

    func testSchemaNilFallsBackToUnorderedJSONRender() throws {
        let view = OutputRenderer(row: ["b": .number(2), "a": .number(1)], schema: nil)
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Schema descriptor unavailable; rendering unordered JSON."))
        XCTAssertNoThrow(try inspected.find(text: "a"))
        XCTAssertNoThrow(try inspected.find(text: "b"))
    }

    func testOutOfSchemaFieldMarkerShown() throws {
        let schema = OutputSchemaDescriptor(fields: [
            field(name: "known", type: .string, optional: false, nullable: false)
        ])

        let view = OutputRenderer(row: ["known": .string("ok"), "extra": .number(1)], schema: schema)
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Out of schema"))
        XCTAssertNoThrow(try inspected.find(text: "out-of-schema"))
    }

    private func field(
        name: String,
        type: OutputSchemaFieldType,
        optional: Bool,
        nullable: Bool,
        description: String? = nil,
        enumValues: [JSONValue]? = nil
    ) -> OutputSchemaFieldDescriptor {
        OutputSchemaFieldDescriptor(
            name: name,
            type: type,
            optional: optional,
            nullable: nullable,
            description: description,
            enumValues: enumValues
        )
    }
}
