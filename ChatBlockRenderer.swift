import SwiftUI

/// Renders a single chat transcript block with role-specific styling.
struct ChatBlockRenderer: View {
    let block: ChatBlock
    let timestamp: String?

    @State private var isExpanded = false

    private static let assistantCollapsedLineLimit = 24
    private static let toolCollapsedLineLimit = 6
    private static let defaultCollapsedLineLimit = 3
    private static let userCollapsedLineLimit = 8

    private var role: String {
        block.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var content: String {
        Self.decodeHTMLEntities(block.content)
    }

    var body: some View {
        Group {
            switch role {
            case "assistant", "agent":
                assistantView
            case "user", "prompt":
                userView
            case "tool", "tool_call":
                toolCallView
            case "tool_result":
                toolResultView
            case "stderr":
                stderrView
            default:
                systemView
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.roleLabel(for: role)) block")
        .accessibilityIdentifier("logs.block.role.\(role)")
    }

    private var assistantView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(label: "ASSISTANT", icon: "sparkles", color: Theme.accent)
            expandableContent(
                font: .system(size: 13),
                textColor: Theme.textPrimary,
                collapsedLineLimit: Self.assistantCollapsedLineLimit,
                expandButtonColor: Theme.accent
            )
        }
        .padding(12)
        .background(Theme.bubbleAssistant)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.25), lineWidth: 1)
        )
    }

    private var userView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(label: "PROMPT", icon: nil, color: Theme.success)
            expandableContent(
                font: .system(size: 11),
                textColor: Theme.textSecondary,
                collapsedLineLimit: Self.userCollapsedLineLimit,
                expandButtonColor: Theme.success
            )
        }
        .padding(10)
        .background(Theme.bubbleUser.opacity(0.5))
        .cornerRadius(8)
    }

    private var toolCallView: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench")
                .font(.system(size: 8))
                .foregroundColor(Theme.warning)
                .padding(.top, 2)
            expandableContent(
                font: .system(size: 10, design: .monospaced),
                textColor: Theme.textTertiary,
                collapsedLineLimit: Self.toolCollapsedLineLimit,
                expandButtonColor: Theme.warning
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var toolResultView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(label: "TOOL RESULT", icon: "checkmark.circle", color: Theme.info)
            expandableContent(
                font: .system(size: 10, design: .monospaced),
                textColor: Theme.textSecondary,
                collapsedLineLimit: Self.toolCollapsedLineLimit,
                expandButtonColor: Theme.info
            )
        }
        .padding(8)
        .background(Theme.surface2.opacity(0.55))
        .cornerRadius(6)
    }

    private var stderrView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(label: "STDERR", icon: "exclamationmark.triangle.fill", color: Theme.danger)
            expandableContent(
                font: .system(size: 10, design: .monospaced),
                textColor: Theme.danger,
                collapsedLineLimit: Self.defaultCollapsedLineLimit,
                expandButtonColor: Theme.danger
            )
        }
        .padding(8)
        .background(Theme.danger.opacity(0.10))
        .cornerRadius(6)
    }

    private var systemView: some View {
        HStack(spacing: 4) {
            expandableContent(
                font: .system(size: 10),
                textColor: Theme.textTertiary.opacity(0.8),
                collapsedLineLimit: Self.defaultCollapsedLineLimit,
                expandButtonColor: Theme.textTertiary
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func header(label: String, icon: String?, color: Color) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            Spacer()
            if let timestamp, !timestamp.isEmpty {
                Text(timestamp)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func expandableContent(
        font: Font,
        textColor: Color,
        collapsedLineLimit: Int,
        expandButtonColor: Color
    ) -> some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = content.components(separatedBy: .newlines).count
        let shouldShowExpand = lineCount > collapsedLineLimit || content.count > 12_000
        let effectiveLineLimit = isExpanded ? nil : collapsedLineLimit

        VStack(alignment: .leading, spacing: 2) {
            if trimmed.isEmpty {
                Text("[empty]")
                    .font(font)
                    .foregroundColor(Theme.textTertiary)
                    .italic()
            } else {
                Text(content)
                    .font(font)
                    .foregroundColor(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .lineLimit(effectiveLineLimit)
            }

            if shouldShowExpand {
                Button(isExpanded ? "[collapse]" : "[expand]") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(expandButtonColor)
                .accessibilityIdentifier("logs.block.expand")
            }
        }
    }

    static func roleLabel(for role: String) -> String {
        switch role.lowercased() {
        case "assistant", "agent": return "assistant"
        case "user", "prompt": return "user"
        case "tool", "tool_call": return "tool call"
        case "tool_result": return "tool result"
        case "stderr": return "stderr"
        case "system": return "system"
        case "status": return "status"
        default: return role.lowercased()
        }
    }

    static func plainTextTranscript(
        blocks: [ChatBlock],
        timestampProvider: (ChatBlock) -> String?
    ) -> String {
        blocks.map { plainText($0, timestamp: timestampProvider($0)) }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(_ block: ChatBlock, timestamp: String?) -> String {
        let role = roleLabel(for: block.role).uppercased()
        let header: String
        if let timestamp, !timestamp.isEmpty {
            header = "[\(timestamp)] \(role)"
        } else {
            header = role
        }
        return "\(header)\n\(decodeHTMLEntities(block.content))"
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let entities: [(String, String)] = [
            ("&quot;", "\""),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&#34;", "\""),
            ("&#x22;", "\""),
            ("&nbsp;", " "),
        ]

        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
