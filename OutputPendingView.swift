import SwiftUI

struct OutputPendingView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 16))
                .foregroundColor(Theme.textTertiary)
            Text("Task has not produced output yet.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityIdentifier("output.pending")
    }
}
