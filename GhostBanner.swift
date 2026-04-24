import SwiftUI

struct GhostBanner: View {
    let isVisible: Bool
    let unmountedFrameNo: Int?
    let onClear: () -> Void

    init(isVisible: Bool, unmountedFrameNo: Int? = nil, onClear: @escaping () -> Void) {
        self.isVisible = isVisible
        self.unmountedFrameNo = unmountedFrameNo
        self.onClear = onClear
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.warning)

                Text(ghostMessage)
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
            .accessibilityLabel(ghostMessage)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("inspector.ghost.banner")
        }
    }

    private var ghostMessage: String {
        if let unmountedFrameNo {
            return "This node is no longer in the running tree (unmounted at frame \(unmountedFrameNo))."
        }
        return "This node is no longer in the running tree."
    }
}
