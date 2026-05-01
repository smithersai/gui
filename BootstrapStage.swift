// BootstrapStage.swift
//
// Shared root-shell loading/bootstrap stage extracted from ContentView.swift
// in ticket 0122. Blocks the shell until `SmithersClient.checkConnection()`
// finishes and first-snapshot state is ready, then renders the platform
// container passed in as a `@ViewBuilder` closure.
//
// The macOS shell wraps `MacOSContentShell` and the iOS shell wraps
// `IOSContentShell`; both reuse this stage to get the same "block until
// connected / first snapshot" behavior the spec calls for.

#if os(macOS)
import SwiftUI

struct BootstrapStageView<Content: View>: View {
    @ObservedObject var smithers: SmithersClient
    let onReady: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to Smithers...")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.base)
                .task {
                    let logStats = await AppLogger.fileWriter.stats()
                    AppLogger.lifecycle.info("File logging ready", metadata: [
                        "path": logStats.fileURL.path,
                        "entries": String(logStats.entryCount),
                        "size_bytes": String(logStats.sizeBytes)
                    ])
                    AppLogger.lifecycle.info("App launching, checking connection")
                    await smithers.checkConnection()
                    AppLogger.lifecycle.info("Connection check complete", metadata: [
                        "connected": String(smithers.isConnected),
                        "cliAvailable": String(smithers.cliAvailable)
                    ])
                    if !UITestSupport.isEnabled {
                        AppNotifications.shared.beginRunEventMonitoring(smithers: smithers)
                    }
                    isLoading = false
                    onReady()
                }
            } else {
                content()
            }
        }
    }
}

#endif
