import SwiftUI

struct GhostBanner: View {
    let isVisible: Bool
    let onClear: () -> Void

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.warning)

                Text("This node is no longer in the running tree.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.warning)

                Spacer()

                Button("Clear") {
                    onClear()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.warning)
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector.ghost.clear")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.warning.opacity(0.12))
            .overlay(
                Rectangle()
                    .fill(Theme.warning.opacity(0.4))
                    .frame(height: 1),
                alignment: .bottom
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This node is no longer in the running tree")
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("inspector.ghost.banner")
        }
    }
}
