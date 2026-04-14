import Foundation

enum UITestSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting") ||
            ProcessInfo.processInfo.environment["SMITHERS_GUI_UITEST"] == "1"
    }

    static var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
