import SwiftUI

struct PropValueView: View {
    let value: JSONValue
    let depth: Int

    @State private var isExpanded: Bool = false

    static let maxStringPreviewLength = 200
    static let maxDepth = 50

    init(value: JSONValue, depth: Int = 0) {
        self.value = value
        self.depth = depth
    }

    var body: some View {
        if depth >= Self.maxDepth {
            Text("[Depth limit reached]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.warning)
                .accessibilityLabel("Depth limit reached")
        } else {
            valueContent
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        switch value {
        case .null:
            Text("null")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.synKeyword)
                .accessibilityLabel("null")

        case .bool(let b):
            Text(b ? "true" : "false")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.synKeyword)
                .accessibilityLabel(b ? "true" : "false")

        case .number(let n):
            Text(formatNumber(n))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.synNumber)
                .accessibilityLabel("Number \(formatNumber(n))")

        case .string(let s):
            stringView(s)

        case .array(let arr):
            arrayView(arr)

        case .object(let obj):
            objectView(obj)
        }
    }

    @ViewBuilder
    private func stringView(_ s: String) -> some View {
        if !s.isValidUTF8Representation {
            Text("[Binary \(s.utf8.count) bytes]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.warning)
        } else if s.count <= Self.maxStringPreviewLength {
            Text("\"\(s)\"")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.synString)
                .textSelection(.enabled)
                .accessibilityLabel("String value \(s)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if isExpanded {
                    Text("\"\(s)\"")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.synString)
                        .textSelection(.enabled)

                    Button("[collapse]") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded = false
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse string value")
                } else {
                    let preview = String(s.prefix(Self.maxStringPreviewLength))
                    HStack(alignment: .top, spacing: 4) {
                        Text("\"\(preview)…\"")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.synString)
                            .lineLimit(3)

                        Button("[expand]") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isExpanded = true
                            }
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Expand string value, \(s.count) characters")
                    }

                    if s.count > 1_000_000 {
                        Text("⚠ \(formatByteCount(s.utf8.count))")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.warning)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func arrayView(_ arr: [JSONValue]) -> some View {
        if arr.isEmpty {
            Text("[]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.synPunctuation)
                .accessibilityLabel("Empty array")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 10)
                        Text("Array(\(arr.count))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.synType)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse array with \(arr.count) items" : "Expand array with \(arr.count) items")

                if isExpanded {
                    ForEach(Array(arr.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\(index):")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .frame(minWidth: 24, alignment: .trailing)
                            PropValueView(value: item, depth: depth + 1)
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func objectView(_ obj: [String: JSONValue]) -> some View {
        if obj.isEmpty {
            Text("{}")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.synPunctuation)
                .accessibilityLabel("Empty object")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 10)
                        Text("Object(\(obj.count))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.synType)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse object with \(obj.count) keys" : "Expand object with \(obj.count) keys")

                if isExpanded {
                    ForEach(obj.keys.sorted(), id: \.self) { key in
                        if let val = obj[key] {
                            HStack(alignment: .top, spacing: 4) {
                                Text("\(key):")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.synProperty)
                                PropValueView(value: val, depth: depth + 1)
                            }
                            .padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(format: "%.0f", n)
        }
        return String(n)
    }

    private func formatByteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}

private extension String {
    var isValidUTF8Representation: Bool {
        self.utf8.withContiguousStorageIfAvailable { _ in true } ?? true
    }
}
