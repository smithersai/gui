import SwiftUI

struct TreeRowView: View {
    let node: DevToolsNode
    let isSelected: Bool
    let isExpanded: Bool
    let hasChildren: Bool
    let hasFailedDescendant: Bool
    let failedDescendantCount: Int
    let isDimmed: Bool
    let isHighlighted: Bool
    let depth: Int
    let onSelect: () -> Void
    let onToggleExpand: () -> Void

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

    var body: some View {
        HStack(spacing: 4) {
            runningCursor
            chevron
            tagLabel
            propsText
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
        .opacity(isDimmed ? 0.35 : 1.0)
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
        return state.rowBackground
    }

    private var pulseOpacity: Double { 0.6 }

    private var accessibilityLabelText: String {
        var parts = ["<\(node.name)>"]
        let summary = keyPropsSummary(for: node)
        if !summary.isEmpty { parts.append(summary) }
        parts.append(state.label)
        if showsRunningCursor {
            parts.append("currently running at this frame")
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
