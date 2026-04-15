import Foundation
import CCodexFFI

struct CodexMCPStatusSnapshot: Equatable, Sendable {
    var ok: Bool
    var servers: [CodexMCPServerStatus]
    var errors: [String]
    var error: String?

    static let empty = CodexMCPStatusSnapshot(ok: true, servers: [], errors: [], error: nil)
}

struct CodexMCPServerStatus: Identifiable, Equatable, Sendable {
    let name: String
    let enabled: Bool
    let status: String
    let authStatus: String
    let authLabel: String
    let startupTimeoutSec: Double?
    let toolTimeoutSec: Double?
    let transport: CodexMCPTransport
    let tools: [String]
    let resources: [CodexMCPResource]
    let resourceTemplates: [CodexMCPResourceTemplate]
    let errors: [String]

    var id: String { name }
}

enum CodexMCPTransport: Equatable, Sendable {
    case stdio(command: String, args: [String], cwd: String?, envKeys: [String], envVars: [String])
    case streamableHTTP(
        url: String,
        bearerTokenEnvVar: String?,
        httpHeaderKeys: [String],
        envHTTPHeaders: [CodexMCPEnvHTTPHeader]
    )
    case unknown(type: String)
}

struct CodexMCPEnvHTTPHeader: Equatable, Sendable, Decodable {
    let name: String
    let envVar: String

    enum CodingKeys: String, CodingKey {
        case name
        case envVar = "env_var"
    }
}

struct CodexMCPResource: Identifiable, Equatable, Sendable, Decodable {
    let name: String
    let title: String?
    let uri: String

    var id: String { uri }
}

struct CodexMCPResourceTemplate: Identifiable, Equatable, Sendable, Decodable {
    let name: String
    let title: String?
    let uriTemplate: String

    enum CodingKeys: String, CodingKey {
        case name, title
        case uriTemplate = "uri_template"
    }

    var id: String { uriTemplate }
}

private struct CodexMCPStatusFFIResponse: Decodable {
    let ok: Bool
    let servers: [CodexMCPServerStatusFFI]
    let errors: [String]
    let error: String?
}

private struct CodexMCPServerStatusFFI: Decodable {
    let name: String
    let enabled: Bool
    let status: String
    let authStatus: String
    let authLabel: String
    let startupTimeoutSec: Double?
    let toolTimeoutSec: Double?
    let transport: CodexMCPTransport
    let tools: [String]
    let resources: [CodexMCPResource]
    let resourceTemplates: [CodexMCPResourceTemplate]
    let errors: [String]

    enum CodingKeys: String, CodingKey {
        case name, enabled, status, transport, tools, resources, errors
        case authStatus = "auth_status"
        case authLabel = "auth_label"
        case startupTimeoutSec = "startup_timeout_sec"
        case toolTimeoutSec = "tool_timeout_sec"
        case resourceTemplates = "resource_templates"
    }

    var domainModel: CodexMCPServerStatus {
        CodexMCPServerStatus(
            name: name,
            enabled: enabled,
            status: status,
            authStatus: authStatus,
            authLabel: authLabel,
            startupTimeoutSec: startupTimeoutSec,
            toolTimeoutSec: toolTimeoutSec,
            transport: transport,
            tools: tools,
            resources: resources,
            resourceTemplates: resourceTemplates,
            errors: errors
        )
    }
}

extension CodexMCPTransport: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case args
        case cwd
        case envKeys = "env_keys"
        case envVars = "env_vars"
        case url
        case bearerTokenEnvVar = "bearer_token_env_var"
        case httpHeaderKeys = "http_header_keys"
        case envHTTPHeaders = "env_http_headers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "stdio":
            self = .stdio(
                command: try container.decode(String.self, forKey: .command),
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                envKeys: try container.decodeIfPresent([String].self, forKey: .envKeys) ?? [],
                envVars: try container.decodeIfPresent([String].self, forKey: .envVars) ?? []
            )
        case "streamable_http":
            self = .streamableHTTP(
                url: try container.decode(String.self, forKey: .url),
                bearerTokenEnvVar: try container.decodeIfPresent(String.self, forKey: .bearerTokenEnvVar),
                httpHeaderKeys: try container.decodeIfPresent([String].self, forKey: .httpHeaderKeys) ?? [],
                envHTTPHeaders: try container.decodeIfPresent([CodexMCPEnvHTTPHeader].self, forKey: .envHTTPHeaders) ?? []
            )
        default:
            self = .unknown(type: type)
        }
    }
}

enum CodexMCPStatusStore {
    static func loadStatus(cwd: String? = nil) -> CodexMCPStatusSnapshot {
        if UITestSupport.isRunningUnitTests {
            return .empty
        }

        guard let response = decodeResponse({
            callWithOptionalCString(cwd) { cwdPtr in
                codex_get_mcp_status_json(cwdPtr)
            }
        }) else {
            return CodexMCPStatusSnapshot(
                ok: false,
                servers: [],
                errors: [],
                error: "Failed to read MCP status from Codex bridge."
            )
        }

        return CodexMCPStatusSnapshot(
            ok: response.ok,
            servers: response.servers.map(\.domainModel),
            errors: response.errors,
            error: response.error
        )
    }

    static func decodeStatusJSON(_ json: String) -> CodexMCPStatusSnapshot? {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(CodexMCPStatusFFIResponse.self, from: data)
        else {
            return nil
        }

        return CodexMCPStatusSnapshot(
            ok: response.ok,
            servers: response.servers.map(\.domainModel),
            errors: response.errors,
            error: response.error
        )
    }

    private static func decodeResponse(_ call: () -> UnsafeMutablePointer<CChar>?) -> CodexMCPStatusFFIResponse? {
        guard let rawPtr = call() else {
            return nil
        }
        defer { codex_string_free(rawPtr) }

        let json = String(cString: rawPtr)
        guard let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexMCPStatusFFIResponse.self, from: data)
    }

    private static func callWithOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else {
            return body(nil)
        }
        return value.withCString { ptr in
            body(ptr)
        }
    }
}
