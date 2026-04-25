import SwiftUI

struct TreeRowView: View {
    let node: DevToolsNode
    let isSelected: Bool
    let isExpanded: Bool
    let hasChildren: Bool
    let hasFailedDescendant: Bool
    let failedDescendantCount: Int
    let isDimmed: Bool
    let isGhost: Bool
    let isHighlighted: Bool
    let depth: Int
    let lastLogLine: String?
    let onSelect: () -> Void
    let onToggleExpand: () -> Void

    init(
        node: DevToolsNode,
        isSelected: Bool,
        isExpanded: Bool,
        hasChildren: Bool,
        hasFailedDescendant: Bool,
        failedDescendantCount: Int,
        isDimmed: Bool,
        isGhost: Bool = false,
        isHighlighted: Bool,
        depth: Int,
        lastLogLine: String? = nil,
        onSelect: @escaping () -> Void,
        onToggleExpand: @escaping () -> Void
    ) {
        self.node = node
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.hasChildren = hasChildren
        self.hasFailedDescendant = hasFailedDescendant
        self.failedDescendantCount = failedDescendantCount
        self.isDimmed = isDimmed
        self.isGhost = isGhost
        self.isHighlighted = isHighlighted
        self.depth = depth
        self.lastLogLine = lastLogLine
        self.onSelect = onSelect
        self.onToggleExpand = onToggleExpand
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: TaskExecutionState {
        extractState(from: node)
    }

    /// Running-node cursor: show a visible marker only on leaf task nodes that are
    /// actually in-flight at the current frame. Structural parents get the "running"
    /// label via rollup but we don't want to paint every ancestor — the glow should
    /// pinpoint discrete work units.
    private var showsRunningCursor: Bool {
        state == .running && node.children.isEmpty
    }

    private var showsLastLog: Bool {
        guard state == .running, node.children.isEmpty else { return false }
        guard let line = lastLogLine?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !line.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            runningCursor
            chevron
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    tagLabel
                    propsText
                }
                if showsLastLog, let line = lastLogLine {
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("tree.row.\(node.id).lastLog")
                }
            }
            Spacer(minLength: 4)
            stateBadge
            timingLabel
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // Subtle left-edge accent bar on running rows — separate from the state
            // badge label so the row reads as "currently-executing" at a glance.
            if showsRunningCursor {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .opacity(reduceMotion ? 1.0 : pulseOpacity)
                    .animation(
                        reduceMotion
                            ? .default
                            : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: showsRunningCursor
                    )
                    .accessibilityHidden(true)
            }
        }
        .opacity(rowOpacity)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier("tree.row.\(node.id)")
    }

    /// Small triangle glyph that appears just before the tag on rows whose state
    /// is `running`. Visible cue separate from the "Running" badge label so a user
    /// scanning the tree can immediately spot what's currently executing even when
    /// the badge column is offscreen.
    @ViewBuilder
    private var runningCursor: some View {
        if showsRunningCursor {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.accent)
                .frame(width: 10)
                .opacity(reduceMotion ? 1.0 : pulseOpacity)
                .animation(
                    reduceMotion
                        ? .default
                        : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: showsRunningCursor
                )
                .accessibilityIdentifier("tree.row.\(node.id).runningCursor")
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if hasChildren {
            ZStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 16, height: 16)

                if hasFailedDescendant {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 6, height: 6)
                        .offset(x: 7, y: -5)
                        .accessibilityLabel("\(failedDescendantCount) failed descendant\(failedDescendantCount == 1 ? "" : "s")")
                }
            }
            .onTapGesture { onToggleExpand() }
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private var tagLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: nodeTypeIcon(for: node.type))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(state.tagForeground.opacity(0.9))
                .accessibilityHidden(true)

            Text("<\(node.name)>")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(state.tagForeground)
                .strikethrough(state.isStrikethrough)
                .opacity(state.shouldPulse && !reduceMotion ? pulseOpacity : 1.0)
                .animation(
                    state.shouldPulse && !reduceMotion
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: state.shouldPulse
                )
        }
    }

    @ViewBuilder
    private var propsText: some View {
        let summary = keyPropsSummary(for: node)
        if !summary.isEmpty {
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 3) {
            if isGhost {
                HStack(spacing: 2) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Ghost")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.textTertiary.opacity(0.14))
                .clipShape(Capsule())
            }

            Image(systemName: state.icon)
                .font(.system(size: 10))
                .foregroundColor(state.color)

            Text(state.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(state.color)
        }
        .transition(reduceMotion ? .identity : .opacity.animation(.easeInOut(duration: 0.2)))
    }

    @ViewBuilder
    private var timingLabel: some View {
        if let elapsed = elapsedText(from: node) {
            Text(elapsed)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Theme.sidebarSelected
        }
        if isHighlighted {
            return Theme.accent.opacity(0.06)
        }
        if isGhost {
            return Theme.surface2.opacity(0.45)
        }
        return state.rowBackground
    }

    private var rowOpacity: Double {
        if isDimmed {
            return 0.35
        }
        if isGhost {
            return 0.58
        }
        return 1.0
    }

    private var pulseOpacity: Double { 0.6 }

    private var accessibilityLabelText: String {
        var parts = ["<\(node.name)>"]
        parts.append("type \(node.type.rawValue)")
        let summary = keyPropsSummary(for: node)
        if !summary.isEmpty { parts.append(summary) }
        parts.append(state.label)
        if showsRunningCursor {
            parts.append("currently running at this frame")
        }
        if isGhost {
            parts.append("unmounted ghost state")
        }
        if showsLastLog, let line = lastLogLine {
            parts.append("last log: \(line)")
        }
        if let iteration = node.task?.iteration {
            parts.append("iteration \(iteration)")
        }
        parts.append(isSelected ? "selected" : "not selected")
        parts.append(hasChildren ? "has children" : "leaf")
        if hasChildren {
            parts.append(isExpanded ? "expanded" : "collapsed")
        }
        if hasFailedDescendant {
            parts.append("\(failedDescendantCount) failed descendant\(failedDescendantCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    private var accessibilityValueText: String {
        var parts: [String] = []
        parts.append(isSelected ? "selected" : "not selected")
        parts.append(hasChildren ? "has children" : "leaf")
        if hasChildren {
            parts.append(isExpanded ? "expanded" : "collapsed")
        }
        if hasFailedDescendant {
            parts.append("\(failedDescendantCount) failed descendant\(failedDescendantCount == 1 ? "" : "s")")
        }
        if let elapsed = elapsedText(from: node) {
            parts.append(elapsed)
        }
        return parts.joined(separator: ", ")
    }
}
