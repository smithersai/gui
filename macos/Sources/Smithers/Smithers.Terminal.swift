import Darwin
import Foundation
import CryptoKit

extension Smithers {
    enum Terminal {
        private static let fallbackShell = "/bin/zsh"
        private static let defaultPathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        private static let loginEnvironmentTimeout: DispatchTimeInterval = .seconds(8)
        private static let loginEnvironmentLock = NSLock()
        private static var cachedLoginEnvironmentShell: String?
        private static var cachedLoginEnvironment: [String: String]?

        static func executablePath(
            name: String,
            environment: [String: String]? = nil,
            commonPaths: [String] = []
        ) -> String? {
            guard !name.isEmpty else { return nil }
            if name.contains("/") {
                return FileManager.default.isExecutableFile(atPath: name) ? name : nil
            }
            let env = environment ?? toolEnvironment()
            for dir in searchPaths(environment: env, commonPaths: commonPaths) {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }

        static func neovimExecutablePath(environment: [String: String]? = nil) -> String? {
            executablePath(name: "nvim", environment: environment, commonPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        }

        static func neovimIsAvailable(environment: [String: String]? = nil) -> Bool {
            neovimExecutablePath(environment: environment) != nil
        }

        static func tmuxExecutablePath(environment: [String: String]? = nil) -> String? {
            executablePath(name: "tmux", environment: environment, commonPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        }

        static func tmuxIsAvailable(environment: [String: String]? = nil) -> Bool {
            tmuxExecutablePath(environment: environment) != nil
        }

        static func userConfiguredShell(
            passwdShell: String? = currentPasswdShell(),
            environment: [String: String] = ProcessInfo.processInfo.environment,
            fallback: String = fallbackShell,
            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        ) -> String {
            for candidate in [passwdShell, environment["SHELL"], fallback] {
                guard let shell = normalizedShell(candidate),
                      isExecutable(shell) else { continue }
                return shell
            }
            return fallback
        }

        static func loginShellLaunchCommand(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> String {
            let shell = TerminalShellPreference.resolvedShellPath(
                environment: environment,
                detectedLoginShellPath: currentPasswdShell()
            ) ?? userConfiguredShell(environment: environment)
            return "\(shellQuote(shell)) -l"
        }

        static func toolEnvironment(
            shell explicitShell: String? = nil,
            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            refresh: Bool = false,
            bundledPathEntries: [String]? = nil
        ) -> [String: String] {
            let shell = normalizedShell(explicitShell)
                ?? TerminalShellPreference.resolvedShellPath(
                    environment: baseEnvironment,
                    detectedLoginShellPath: currentPasswdShell()
                )
                ?? userConfiguredShell(environment: baseEnvironment)
            let loginEnv = loginShellEnvironment(
                shell: shell,
                baseEnvironment: baseEnvironment,
                refresh: refresh
            )
            return enrichToolEnvironment(
                baseEnvironment: loginEnv,
                shell: shell,
                bundledPathEntries: bundledPathEntries ?? bundledExecutablePathEntries()
            )
        }

        static func reloadToolEnvironment(
            shell explicitShell: String? = nil,
            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [String: String] {
            toolEnvironment(
                shell: explicitShell,
                baseEnvironment: baseEnvironment,
                refresh: true
            )
        }

        static func loginShellEnvironment(
            shell: String,
            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            refresh: Bool = false
        ) -> [String: String] {
            loginEnvironmentLock.lock()
            if !refresh,
               cachedLoginEnvironmentShell == shell,
               let cached = cachedLoginEnvironment {
                loginEnvironmentLock.unlock()
                return cached
            }
            loginEnvironmentLock.unlock()

            let captured = captureLoginShellEnvironment(shell: shell, baseEnvironment: baseEnvironment)
            var env = captured.isEmpty ? baseEnvironment : captured
            env["SHELL"] = shell

            loginEnvironmentLock.lock()
            cachedLoginEnvironmentShell = shell
            cachedLoginEnvironment = env
            loginEnvironmentLock.unlock()

            return env
        }

        static func captureLoginShellEnvironment(
            shell: String,
            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [String: String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", "env"]
            var launchEnvironment = baseEnvironment
            launchEnvironment["SHELL"] = shell
            process.environment = launchEnvironment

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")

            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            do {
                try process.run()
            } catch {
                group.leave()
                AppLogger.terminal.warning("Failed to launch login shell for environment", metadata: [
                    "shell": shell,
                    "error": "\(error)",
                ])
                return baseEnvironment
            }

            guard group.wait(timeout: .now() + loginEnvironmentTimeout) == .success else {
                process.terminate()
                _ = group.wait(timeout: .now() + .seconds(1))
                AppLogger.terminal.warning("Timed out loading login shell environment", metadata: ["shell": shell])
                return baseEnvironment
            }

            guard process.terminationStatus == 0 else {
                AppLogger.terminal.warning("Login shell environment exited non-zero", metadata: [
                    "shell": shell,
                    "status": "\(process.terminationStatus)",
                ])
                return baseEnvironment
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return baseEnvironment
            }
            let parsed = parseEnvironmentOutput(output)
            return parsed.isEmpty ? baseEnvironment : parsed
        }

        static func parseEnvironmentOutput(_ output: String) -> [String: String] {
            var env: [String: String] = [:]
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let idx = line.firstIndex(of: "="),
                      idx != line.startIndex else { continue }
                let key = String(line[..<idx])
                let value = String(line[line.index(after: idx)...])
                env[key] = value
            }
            return env
        }

        static func enrichToolEnvironment(
            baseEnvironment: [String: String],
            shell: String,
            bundledPathEntries: [String] = bundledExecutablePathEntries(),
            fallbackPathEntries: [String] = defaultPathEntries
        ) -> [String: String] {
            var env = baseEnvironment
            env["SHELL"] = shell
            let currentPathEntries = (env["PATH"] ?? defaultPathEntries.joined(separator: ":"))
                .split(separator: ":")
                .map(String.init)
                .filter { !$0.isEmpty }
            env["PATH"] = uniquePathEntries(
                bundledPathEntries + currentPathEntries + fallbackPathEntries
            ).joined(separator: ":")
            return env
        }

        static func tmuxSocketName(for workingDirectory: String) -> String {
            let digest = SHA256.hash(data: Data(workingDirectory.utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            return "smithers-\(digest)"
        }

        static func tmuxRootSurfaceId(for terminalId: String) -> String {
            "\(terminalId)-root"
        }

        static func tmuxSessionName(for surfaceId: String) -> String {
            var output = ""
            var previousDash = false
            for scalar in surfaceId.unicodeScalars {
                let character = Character(scalar)
                let lower = String(character).lowercased()
                let isAllowed = lower.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                }
                let next = isAllowed ? lower : "-"
                if next == "-" {
                    if previousDash { continue }
                    previousDash = true
                } else {
                    previousDash = false
                }
                output += next
            }
            let name = output.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            if name.isEmpty {
                let digest = SHA256.hash(data: Data(surfaceId.utf8))
                    .prefix(8)
                    .map { String(format: "%02x", $0) }
                    .joined()
                return "smt-\(digest)"
            }
            return "smt-\(name.prefix(80))"
        }

        static func tmuxAttachCommand(
            socketName: String?,
            sessionName: String?,
            environment: [String: String]? = nil
        ) -> String? {
            let env = environment ?? toolEnvironment()
            guard let tmux = tmuxExecutablePath(environment: env),
                  let socketName = normalized(socketName),
                  let sessionName = normalized(sessionName) else { return nil }
            return "\(shellQuote(tmux)) -L \(shellQuote(socketName)) attach-session -t \(shellQuote(sessionName))"
        }

        static func tmuxEnsureSession(
            socketName: String,
            sessionName: String,
            workingDirectory: String?,
            command: String?,
            title: String?,
            environment: [String: String]? = nil
        ) -> Bool {
            let env = environment ?? toolEnvironment()
            guard let tmux = tmuxExecutablePath(environment: env) else { return false }
            var args = ["-L", socketName, "new-session", "-d", "-s", sessionName]
            if let workingDirectory { args += ["-c", workingDirectory] }
            if let command, !command.isEmpty { args.append(command) }
            _ = title
            return run(executable: tmux, arguments: args, environment: env).status == 0
        }

        static func tmuxTerminateSession(
            socketName: String?,
            sessionName: String?,
            environment: [String: String]? = nil
        ) {
            let env = environment ?? toolEnvironment()
            guard let tmux = tmuxExecutablePath(environment: env),
                  let socketName,
                  let sessionName else { return }
            _ = run(executable: tmux, arguments: ["-L", socketName, "kill-session", "-t", sessionName], environment: env)
        }

        static func tmuxCapturePane(socketName: String, sessionName: String, lines: Int = 200) throws -> String {
            guard let tmux = tmuxExecutablePath() else { throw TmuxControllerError.tmuxUnavailable }
            let result = run(executable: tmux, arguments: [
                "-L", socketName, "capture-pane", "-p", "-t", sessionName, "-S", "-\(lines)",
            ])
            guard result.status == 0 else { throw TmuxControllerError.commandFailed(result.stderr) }
            return result.stdout
        }

        static func tmuxSendText(socketName: String, sessionName: String, text: String, enter: Bool = false) throws {
            guard let tmux = tmuxExecutablePath() else { throw TmuxControllerError.tmuxUnavailable }
            var args = ["-L", socketName, "send-keys", "-t", sessionName, text]
            if enter { args.append("Enter") }
            let result = run(executable: tmux, arguments: args)
            guard result.status == 0 else { throw TmuxControllerError.commandFailed(result.stderr) }
        }

        private static func searchPaths(environment: [String: String], commonPaths: [String]) -> [String] {
            let pathDirs = (environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
                .filter { !$0.isEmpty }
            var seen = Set<String>()
            return (pathDirs + commonPaths).filter { seen.insert($0).inserted }
        }

        private static func run(
            executable: String,
            arguments: [String],
            environment: [String: String]? = nil
        ) -> (status: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment ?? toolEnvironment()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (127, "", "\(error)")
            }
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        }

        private static func shellQuote(_ value: String) -> String {
            "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }

        private static func normalized(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        private static func normalizedShell(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.hasPrefix("/"),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        private static func currentPasswdShell() -> String? {
            guard let passwd = getpwuid(getuid()),
                  let shell = passwd.pointee.pw_shell else { return nil }
            let value = String(cString: shell)
            return value.isEmpty ? nil : value
        }

        private static func bundledExecutablePathEntries() -> [String] {
            guard let resourcePath = Bundle.main.resourcePath else { return [] }
            let bin = URL(fileURLWithPath: resourcePath, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: bin, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return [] }
            return [bin]
        }

        private static func uniquePathEntries(_ entries: [String]) -> [String] {
            var seen = Set<String>()
            return entries
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }
}
