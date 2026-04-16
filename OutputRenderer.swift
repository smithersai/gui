import SwiftUI

struct OutputRenderer: View {
    let row: [String: JSONValue]
    let schema: OutputSchemaDescriptor?

    private var schemaFields: [OutputSchemaFieldDescriptor] {
        schema?.fields ?? []
    }

    private var schemaFieldNames: Set<String> {
        Set(schemaFields.map(\.name))
    }

    private var outOfSchemaFieldNames: [String] {
        row.keys
            .filter { !schemaFieldNames.contains($0) }
            .sorted()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if row.isEmpty && schemaFields.isEmpty {
                    emptyState
                } else if schema == nil {
                    fallbackRows
                } else {
                    schemaRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityIdentifier("output.renderer")
        .onAppear {
            logOutOfSchemaWarnings()
            let interval = AppLogger.performance.beginInterval("outputRendererRender")
            AppLogger.performance.endInterval("outputRendererRender", interval)
        }
    }

    private var emptyState: some View {
        Text("No output fields.")
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("output.renderer.empty")
    }

    private var fallbackRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.warning)
                Text("Schema descriptor unavailable; rendering unordered JSON.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(8)
            .background(Theme.warning.opacity(0.08))
            .cornerRadius(6)
            .accessibilityIdentifier("output.renderer.schemaMissing")

            ForEach(row.keys.sorted(), id: \.self) { key in
                if let value = row[key] {
                    outputRow(
                        key: key,
                        fieldType: .unknown,
                        value: value,
                        description: nil,
                        enumValues: nil,
                        isOutOfSchema: false,
                        isMissingRequiredField: false
                    )
                }
            }
        }
    }

    private var schemaRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(schemaFields, id: \.name) { field in
                outputRow(
                    key: field.name,
                    fieldType: field.type,
                    value: row[field.name],
                    description: field.description,
                    enumValues: field.enumValues,
                    isOutOfSchema: false,
                    isMissingRequiredField: !field.optional && row[field.name] == nil
                )
            }

            if !outOfSchemaFieldNames.isEmpty {
                Text("Out of schema")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.warning)
                    .textCase(.uppercase)
                    .padding(.top, 4)

                ForEach(outOfSchemaFieldNames, id: \.self) { key in
                    if let value = row[key] {
                        outputRow(
                            key: key,
                            fieldType: .unknown,
                            value: value,
                            description: nil,
                            enumValues: nil,
                            isOutOfSchema: true,
                            isMissingRequiredField: false
                        )
                    }
                }
            }
        }
    }

    private func outputRow(
        key: String,
        fieldType: OutputSchemaFieldType,
        value: JSONValue?,
        description: String?,
        enumValues: [JSONValue]?,
        isOutOfSchema: Bool,
        isMissingRequiredField: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.synProperty)

                if let description, !description.isEmpty {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                        .help(description)
                        .accessibilityIdentifier("output.field.help.\(safeIdentifier(key))")
                }

                typeBadge(fieldType)

                if isOutOfSchema {
                    markerBadge("out-of-schema", color: Theme.warning)
                }

                if isMissingRequiredField {
                    markerBadge("not produced", color: Theme.warning)
                }

                if let enumValues {
                    enumBadge(enumValues: enumValues, value: value)
                }

                Spacer()

                Button {
                    copyValue(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("output.copy.\(safeIdentifier(key))")
                .accessibilityLabel("Copy \(key) value")
            }

            if let value {
                PropValueView(value: value)
                    .padding(.leading, 4)
            } else {
                Text("not produced")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.warning)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(forKey: key, type: fieldType, value: value, isMissing: isMissingRequiredField))
        .accessibilityIdentifier("output.field.\(safeIdentifier(key))")
    }

    private func typeBadge(_ type: OutputSchemaFieldType) -> some View {
        Text(typeLabel(type))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.surface2)
            .cornerRadius(4)
            .accessibilityHidden(true)
    }

    private func markerBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.10))
            .cornerRadius(4)
            .accessibilityHidden(true)
    }

    private func enumBadge(enumValues: [JSONValue], value: JSONValue?) -> some View {
        let matches = value.map { enumValues.contains($0) } ?? false
        return Text(matches ? "enum ✓" : "enum !")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(matches ? Theme.success : Theme.warning)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((matches ? Theme.success : Theme.warning).opacity(0.10))
            .cornerRadius(4)
            .accessibilityHidden(true)
    }

    private func typeLabel(_ type: OutputSchemaFieldType) -> String {
        switch type {
        case .boolean:
            return "bool"
        default:
            return type.rawValue
        }
    }

    private func copyValue(_ value: JSONValue?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawStringValue(value), forType: .string)
    }

    private func rawStringValue(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 {
                return String(format: "%.0f", n)
            }
            return String(n)
        case .string(let s):
            return s
        case .array, .object:
            return value.compactJSONString ?? String(describing: value)
        }
    }

    private func accessibilityLabel(
        forKey key: String,
        type: OutputSchemaFieldType,
        value: JSONValue?,
        isMissing: Bool
    ) -> String {
        if isMissing {
            return "\(key), \(typeLabel(type)), not produced"
        }
        return "\(key), \(typeLabel(type))"
    }

    private func safeIdentifier(_ key: String) -> String {
        key.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    private func logOutOfSchemaWarnings() {
        for key in outOfSchemaFieldNames {
            AppLogger.ui.warning("Output row field out of schema", metadata: ["field": key])
        }
        for field in schemaFields {
            guard let enumValues = field.enumValues, let value = row[field.name] else { continue }
            if !enumValues.contains(value) {
                AppLogger.ui.warning("Output enum mismatch", metadata: ["field": field.name])
            }
        }
    }
}
