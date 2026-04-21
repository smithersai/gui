import Foundation
import CSmithersKit

extension Smithers {
    enum Terminal {
        static func executablePath(
            name: String,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            commonPaths: [String] = []
        ) -> String? {
            try? callOptionalString("terminalExecutablePath", args: [
                "name": AnyEncodable(name),
                "environment": AnyEncodable(environment),
                "commonPaths": AnyEncodable(commonPaths),
            ])
        }

        static func neovimExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
            try? callOptionalString("neovimExecutablePath", args: [
                "environment": AnyEncodable(environment),
            ])
        }

        static func neovimIsAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            (try? call(Bool.self, "neovimIsAvailable", args: ["environment": AnyEncodable(environment)])) ?? false
        }

        static func tmuxExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
            try? callOptionalString("tmuxExecutablePath", args: [
                "environment": AnyEncodable(environment),
            ])
        }

        static func tmuxIsAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            (try? call(Bool.self, "tmuxIsAvailable", args: ["environment": AnyEncodable(environment)])) ?? false
        }

        static func tmuxSocketName(for workingDirectory: String) -> String {
            (try? call(String.self, "tmuxSocketName", args: [
                "workingDirectory": AnyEncodable(workingDirectory),
            ])) ?? ""
        }

        static func tmuxRootSurfaceId(for terminalId: String) -> String {
            (try? call(String.self, "tmuxRootSurfaceId", args: [
                "terminalId": AnyEncodable(terminalId),
            ])) ?? ""
        }

        static func tmuxSessionName(for surfaceId: String) -> String {
            (try? call(String.self, "tmuxSessionName", args: [
                "surfaceId": AnyEncodable(surfaceId),
            ])) ?? ""
        }

        static func tmuxAttachCommand(
            socketName: String?,
            sessionName: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> String? {
            try? callOptionalString("tmuxAttach", args: [
                "socketName": AnyEncodable(socketName),
                "sessionName": AnyEncodable(sessionName),
                "environment": AnyEncodable(environment),
            ])
        }

        static func tmuxEnsureSession(
            socketName: String,
            sessionName: String,
            workingDirectory: String?,
            command: String?,
            title: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            (try? call(Bool.self, "tmuxEnsureSession", args: [
                "socketName": AnyEncodable(socketName),
                "sessionName": AnyEncodable(sessionName),
                "workingDirectory": AnyEncodable(workingDirectory),
                "command": AnyEncodable(command),
                "title": AnyEncodable(title),
                "environment": AnyEncodable(environment),
            ])) ?? false
        }

        static func tmuxTerminateSession(
            socketName: String?,
            sessionName: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            _ = try? call(Bool.self, "tmuxTerminateSession", args: [
                "socketName": AnyEncodable(socketName),
                "sessionName": AnyEncodable(sessionName),
                "environment": AnyEncodable(environment),
            ])
        }

        static func tmuxCapturePane(socketName: String, sessionName: String, lines: Int = 200) throws -> String {
            let result = try call(TmuxCommandResult.self, "tmuxCapturePane", args: [
                "socketName": AnyEncodable(socketName),
                "sessionName": AnyEncodable(sessionName),
                "lines": AnyEncodable(lines),
            ])
            try result.throwIfFailed()
            return result.output ?? ""
        }

        static func tmuxSendText(socketName: String, sessionName: String, text: String, enter: Bool = false) throws {
            let result = try call(TmuxCommandResult.self, "tmuxSendText", args: [
                "socketName": AnyEncodable(socketName),
                "sessionName": AnyEncodable(sessionName),
                "text": AnyEncodable(text),
                "enter": AnyEncodable(enter),
            ])
            try result.throwIfFailed()
        }

        private static func callOptionalString(
            _ method: String,
            args: [String: AnyEncodable] = [:]
        ) throws -> String? {
            try call(OptionalStringBox.self, method, args: args).value
        }

        private static func call<Value: Decodable>(
            _ type: Value.Type,
            _ method: String,
            args: [String: AnyEncodable] = [:]
        ) throws -> Value {
            let data = try callData(method, args: args)
            if Value.self == String.self,
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded as! Value
            }
            return try JSONDecoder().decode(Value.self, from: data)
        }

        private static func callData(_ method: String, args: [String: AnyEncodable]) throws -> Data {
            try withClient { client in
                let argsData = try JSONEncoder().encode(args)
                let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                var outError = smithers_error_s(code: 0, msg: nil)
                let result = method.withCString { methodPtr in
                    argsJSON.withCString { argsPtr in
                        smithers_client_call(client, methodPtr, argsPtr, &outError)
                    }
                }
                if let message = Smithers.message(from: outError) {
                    smithers_string_free(result)
                    throw SmithersError.api(message)
                }
                defer { smithers_string_free(result) }
                return Data(Smithers.string(from: result, free: false).utf8)
            }
        }

        private static func withClient<Value>(_ body: @escaping (smithers_client_t) throws -> Value) throws -> Value {
            let run = {
                guard let app = smithers_app_new(nil) else {
                    throw SmithersError.notAvailable("libsmithers app is unavailable")
                }
                defer { smithers_app_free(app) }
                guard let client = smithers_client_new(app) else {
                    throw SmithersError.notAvailable("libsmithers client is unavailable")
                }
                defer { smithers_client_free(client) }
                return try body(client)
            }
            if Thread.isMainThread {
                return try run()
            }
            return try DispatchQueue.main.sync(execute: run)
        }
    }
}

private struct OptionalStringBox: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = container.decodeNil() ? nil : try container.decode(String.self)
    }
}

private struct TmuxCommandResult: Decodable {
    let ok: Bool
    let code: String?
    let error: String?
    let output: String?

    func throwIfFailed() throws {
        guard !ok else { return }
        switch code {
        case "tmuxUnavailable":
            throw TmuxControllerError.tmuxUnavailable
        default:
            throw TmuxControllerError.commandFailed(error ?? "")
        }
    }
}
