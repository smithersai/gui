import Foundation

enum CWDResolver {
    static func resolve(
        _ cwd: String?,
        currentDirectoryPath: () -> String = { FileManager.default.currentDirectoryPath },
        homeDirectoryPath: () -> String = { NSHomeDirectory() },
        fileManager: FileManager = .default,
        logWarning: (String, String) -> Void = CWDResolver.logRootFallback
    ) -> String {
        let home = standardizedAbsolutePath(homeDirectoryPath(), relativeTo: currentDirectoryPath())
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed?.isEmpty == false ? trimmed! : currentDirectoryPath()
        let resolved = standardizedAbsolutePath(candidate, relativeTo: currentDirectoryPath())

        guard resolved != "/" else {
            logWarning(resolved, home)
            return home
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            logWarning(resolved, home)
            return home
        }

        return resolved
    }

    private static func standardizedAbsolutePath(_ path: String, relativeTo basePath: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (basePath as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    private static func logRootFallback(cwd: String, home: String) {
        AppLogger.lifecycle.warning("CWDResolver falling back to home directory", metadata: ["resolved": cwd, "home": home])
    }
}
