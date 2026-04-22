import Foundation

@MainActor
final class SmithersUpgrader: ObservableObject {
    enum Status: Equatable {
        case idle
        case running(step: String)
        case failed(String)
        case succeeded(summary: String)
    }

    @Published private(set) var status: Status = .idle

    private let cwd: String

    init(cwd: String) {
        self.cwd = cwd
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func upgrade() async {
        guard !isRunning else { return }
        status = .running(step: "Updating smithers-orchestrator…")

        let workDir = cwd
        let report = await Task.detached(priority: .userInitiated) { () -> UpgradeReport in
            Self.runUpgrade(cwd: workDir)
        }.value

        switch report {
        case .success(let summary):
            status = .succeeded(summary: summary)
        case .failure(let message):
            status = .failed(message)
        }
    }

    private enum UpgradeReport {
        case success(String)
        case failure(String)
    }

    // MARK: - Worker (nonisolated)

    nonisolated private static func runUpgrade(cwd: String) -> UpgradeReport {
        let packageName = "smithers-orchestrator"
        var actions: [String] = []
        var failures: [String] = []

        // Global upgrades for each detected package manager.
        let managers: [(name: String, detect: String, install: String)] = [
            ("bun", "bun pm ls -g 2>/dev/null", "bun add -g \(packageName)@latest"),
            ("npm", "npm ls -g --depth=0 2>/dev/null", "npm install -g \(packageName)@latest"),
            ("pnpm", "pnpm ls -g --depth=0 2>/dev/null", "pnpm add -g \(packageName)@latest"),
            ("yarn", "yarn global list 2>/dev/null", "yarn global add \(packageName)@latest"),
        ]

        for manager in managers {
            guard toolAvailable(manager.name) else { continue }
            guard let listOutput = runShell(manager.detect, cwd: cwd)?.stdout,
                  listOutput.contains(packageName) else { continue }

            let result = runShell(manager.install, cwd: cwd)
            if let result, result.exitCode == 0 {
                actions.append("\(manager.name) global")
            } else {
                let err = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "unknown error"
                failures.append("\(manager.name) global: \(err)")
            }
        }

        // Local (workspace) upgrade.
        let candidateDirs = [cwd, (cwd as NSString).appendingPathComponent(".smithers")]
        for dir in candidateDirs {
            let pkgPath = (dir as NSString).appendingPathComponent("package.json")
            guard let contents = try? String(contentsOfFile: pkgPath, encoding: .utf8),
                  contents.contains("\"\(packageName)\"") else { continue }

            let lockManager = detectLockfileManager(in: dir)
            guard toolAvailable(lockManager.tool) else {
                failures.append("local (\(dir)): \(lockManager.tool) not installed")
                continue
            }
            let cmd = "\(lockManager.tool) \(lockManager.addSubcommand) \(packageName)@latest"
            let result = runShell(cmd, cwd: dir)
            if let result, result.exitCode == 0 {
                actions.append("local (\(lockManager.tool))")
            } else {
                let err = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "unknown error"
                failures.append("local \(lockManager.tool): \(err)")
            }
        }

        if actions.isEmpty && failures.isEmpty {
            return .failure("No smithers-orchestrator install found to update.")
        }
        if !failures.isEmpty {
            return .failure(failures.joined(separator: "\n"))
        }
        return .success("Updated: \(actions.joined(separator: ", "))")
    }

    private struct LocalManager {
        let tool: String
        let addSubcommand: String
    }

    nonisolated private static func detectLockfileManager(in dir: String) -> LocalManager {
        let fm = FileManager.default
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("bun.lock"))
            || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("bun.lockb")) {
            return LocalManager(tool: "bun", addSubcommand: "add")
        }
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("pnpm-lock.yaml")) {
            return LocalManager(tool: "pnpm", addSubcommand: "add")
        }
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("yarn.lock")) {
            return LocalManager(tool: "yarn", addSubcommand: "add")
        }
        return LocalManager(tool: "npm", addSubcommand: "install")
    }

    nonisolated private static func toolAvailable(_ name: String) -> Bool {
        runShell("command -v \(name)", cwd: nil)?.exitCode == 0
    }

    private struct ShellResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated private static func runShell(_ command: String, cwd: String?) -> ShellResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Inherit env verbatim — a login shell (-l) would re-read .zprofile and can reorder PATH so we upgrade a different `smithers` than the app resolves.
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
