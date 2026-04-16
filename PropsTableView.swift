import SwiftUI

struct PropsTableView: View {
    let props: [String: JSONValue]
    let orderedKeys: [String]

    init(props: [String: JSONValue]) {
        self.props = props
        self.orderedKeys = props.keys.sorted()
    }

    init(props: [String: JSONValue], orderedKeys: [String]) {
        self.props = props
        self.orderedKeys = orderedKeys
    }

    var body: some View {
        if orderedKeys.isEmpty {
            emptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(orderedKeys, id: \.self) { key in
                    if let value = props[key] {
                        propRow(key: key, value: value)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector.props.table")
        }
    }

    private var emptyState: some View {
        Text("No props")
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityIdentifier("inspector.props.empty")
    }

    private func propRow(key: String, value: JSONValue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.synProperty)
                .frame(minWidth: 60, alignment: .leading)
                .accessibilityLabel("Property \(key)")

            PropValueView(value: value)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyValue(value)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(key) value")
            .accessibilityIdentifier("inspector.props.copy.\(key)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(key), \(accessibleValueDescription(value))")
    }

    private func copyValue(_ value: JSONValue) {
        let raw = rawStringValue(value)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    private func rawStringValue(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 {
                return String(format: "%.0f", n)
            }
            return String(n)
        case .string(let s): return s
        case .array, .object:
            return value.compactJSONString ?? String(describing: value)
        }
    }

    private func accessibleValueDescription(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return "\(n)"
        case .string(let s):
            if s.count > 100 { return "string, \(s.count) characters" }
            return s
        case .array(let a): return "array with \(a.count) items"
        case .object(let o): return "object with \(o.count) keys"
        }
    }
}
