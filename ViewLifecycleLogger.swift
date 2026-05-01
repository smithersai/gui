import SwiftUI

struct ViewLifecycleLogger: ViewModifier {
    let viewName: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppLogger.ui.debug("\(viewName) appeared")
            }
            .onDisappear {
                AppLogger.ui.debug("\(viewName) disappeared")
            }
    }
}

extension View {
    func logLifecycle(_ viewName: String) -> some View {
        modifier(ViewLifecycleLogger(viewName: viewName))
    }
}
