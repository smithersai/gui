import Foundation

enum CWDResolver {
    static func resolve(
        _ cwd: String?,
        currentDirectoryPath: () -> String = { FileManager.default.currentDirectoryPath },
        homeDirectoryPath: () -> String = { NSHomeDirectory() },
        logWarning: (String, String) -> Void = CWDResolver.logRootFallback
    ) -> String {
        let resolved = cwd ?? currentDirectoryPath()
        guard resolved == "/" else { return resolved }

        let home = homeDirectoryPath()
        logWarning(resolved, home)
        return home
    }

    private static func logRootFallback(cwd: String, home: String) {
        NSLog("[CWDResolver] Warning: cwd resolved to '%@', falling back to home directory: %@", cwd, home)
    }
}
