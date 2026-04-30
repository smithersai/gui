import Foundation
import CryptoKit

extension Smithers {
    enum Terminal {
        static func executablePath(
            name: String,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            commonPaths: [String] = []
        ) -> String? {
            guard !name.isEmpty else { return nil }
            if name.contains("/") {
                return FileManager.default.isExecutableFile(atPath: name) ? name : nil
            }
            for dir in searchPaths(environment: environment, commonPaths: commonPaths) {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }

        static func neovimExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
            executablePath(name: "nvim", environment: environment, commonPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        }

        static func neovimIsAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            neovimExecutablePath(environment: environment) != nil
        }

        static func tmuxExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
            executablePath(name: "tmux", environment: environment, commonPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        }

        static func tmuxIsAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            tmuxExecutablePath(environment: environment) != nil
        }

        static func tmuxSocketName(for workingDirectory: String) -> String {
            let digest = SHA256.hash(data: Data(workingDirectory.utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            return "smithers-\(digest)"
        }

        static func tmuxRootSurfaceId(for terminalId: String) -> String {
            "tmux:\(terminalId)"
        }

        static func tmuxSessionName(for surfaceId: String) -> String {
            let allowed = surfaceId.map { char -> Character in
                char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
            }
            let name = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            return name.isEmpty ? "smithers" : String(name.prefix(80))
        }

        static func tmuxAttachCommand(
            socketName: String?,
            sessionName: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> String? {
            guard let tmux = tmuxExecutablePath(environment: environment),
                  let socketName,
                  let sessionName else { return nil }
            return "\(tmux) -L \(shellQuote(socketName)) attach -t \(shellQuote(sessionName))"
        }

        static func tmuxEnsureSession(
            socketName: String,
            sessionName: String,
            workingDirectory: String?,
            command: String?,
            title: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            guard let tmux = tmuxExecutablePath(environment: environment) else { return false }
            var args = ["-L", socketName, "new-session", "-d", "-s", sessionName]
            if let workingDirectory { args += ["-c", workingDirectory] }
            if let command, !command.isEmpty { args.append(command) }
            _ = title
            return run(executable: tmux, arguments: args, environment: environment).status == 0
        }

        static func tmuxTerminateSession(
            socketName: String?,
            sessionName: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            guard let tmux = tmuxExecutablePath(environment: environment),
                  let socketName,
                  let sessionName else { return }
            _ = run(executable: tmux, arguments: ["-L", socketName, "kill-session", "-t", sessionName], environment: environment)
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
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> (status: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
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
    }
}
