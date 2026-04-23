// SmithersApp.swift — iOS entry point (ticket 0121).
//
// This file is intentionally minimal. It provides the SwiftUI @main entry for
// the iOS target so the build system has a first-class iOS app to compile.
//
// Tickets 0122 (shared navigation/state refactor) and 0123 (terminal
// portability) will progressively replace `PlaceholderRootView` with the
// real cross-platform ContentView once those shared surfaces exist.
//
// Keep this file iOS-only. The macOS app entry lives in
// `macos/Sources/Smithers/Smithers.App.swift`.

#if os(iOS)
import SwiftUI

@main
struct SmithersiOSApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderRootView()
        }
    }
}

private struct PlaceholderRootView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Smithers iOS")
                    .font(.largeTitle.bold())
                Text("Build scaffolding only — UI lands in 0122/0123.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .navigationTitle("Smithers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
