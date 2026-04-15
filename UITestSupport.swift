import Foundation

enum UITestSupport {
    static var isEnabled: Bool {
        isEnabled(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static var isRunningUnitTests: Bool {
        isRunningUnitTests(
            processName: ProcessInfo.processInfo.processName,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    static var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func isEnabled(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--uitesting") ||
            environment["SMITHERS_GUI_UITEST"] == "1"
    }

    static func isRunningUnitTests(processName: String, environment: [String: String]) -> Bool {
        isRunningUnitTests(processName: processName, arguments: [], environment: environment)
    }

    static func isRunningUnitTests(
        processName: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil ||
            processName == "xctest" ||
            processName.hasSuffix("Tests") ||
            arguments.contains { $0.contains(".xctest") }
    }
}
