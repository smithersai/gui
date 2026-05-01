import SwiftUI

struct OutputFailedView: View {
    let partial: [String: JSONValue]?

    @State private var showPartial: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                    Text("Task failed before producing final output.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .accessibilityIdentifier("output.failed.banner")

                if let partial, !partial.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showPartial.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showPartial ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                                Text("Last partial output")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("output.failed.partial.toggle")

                        if showPartial {
                            PropValueView(value: .object(partial))
                                .padding(8)
                                .background(Theme.surface2)
                                .cornerRadius(6)
                                .accessibilityIdentifier("output.failed.partial.value")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityIdentifier("output.failed")
    }
}
