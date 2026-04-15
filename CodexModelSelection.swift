import Foundation
import CCodexFFI

enum CodexReasoningEffort: String, CaseIterable, Codable, Sendable {
    case minimal
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

enum CodexApprovalPolicy: String, CaseIterable, Codable, Sendable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"
    case never

    var displayName: String {
        switch self {
        case .untrusted: return "Untrusted"
        case .onFailure: return "On Failure"
        case .onRequest: return "On Request"
        case .never: return "Never"
        }
    }
}

enum CodexSandboxMode: String, CaseIterable, Codable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    var displayName: String {
        switch self {
        case .readOnly: return "Read Only"
        case .workspaceWrite: return "Workspace Write"
        case .dangerFullAccess: return "Danger Full Access"
        }
    }
}

struct CodexReasoningPreset: Identifiable, Equatable, Sendable {
    let effort: CodexReasoningEffort
    let description: String

    var id: String { effort.rawValue }
}

struct CodexModelPreset: Identifiable, Equatable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultReasoningEffort: CodexReasoningEffort
    let supportedReasoningEfforts: [CodexReasoningPreset]
    let isDefault: Bool
}

struct CodexModelSelection: Equatable, Sendable {
    var model: String
    var reasoningEffort: CodexReasoningEffort?
    var activeProfile: String?

    static let fallback = CodexModelSelection(
        model: "gpt-5-codex",
        reasoningEffort: .medium,
        activeProfile: nil
    )

    var summaryLabel: String {
        guard let reasoningEffort else { return model }
        return "\(model) · \(reasoningEffort.displayName)"
    }
}

struct CodexModelSelectionError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct CodexApprovalPreset: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let description: String
    let approvalPolicy: CodexApprovalPolicy
    let sandboxMode: CodexSandboxMode
}

struct CodexApprovalSelection: Equatable, Sendable {
    var approvalPolicy: CodexApprovalPolicy
    var sandboxMode: CodexSandboxMode

    static let fallback = CodexApprovalSelection(
        approvalPolicy: .onRequest,
        sandboxMode: .readOnly
    )

    var summaryLabel: String {
        CodexApprovalPresetCatalog.preset(for: self)?.label ?? "\(approvalPolicy.rawValue) · \(sandboxMode.rawValue)"
    }

    var isFullAccess: Bool {
        approvalPolicy == .never && sandboxMode == .dangerFullAccess
    }
}

struct CodexApprovalSelectionError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum CodexApprovalPresetCatalog {
    static let presets: [CodexApprovalPreset] = [
        CodexApprovalPreset(
            id: "read-only",
            label: "Read Only",
            description: "Codex can read files and answer questions. Codex requires approval to make edits, run commands, or access network.",
            approvalPolicy: .onRequest,
            sandboxMode: .readOnly
        ),
        CodexApprovalPreset(
            id: "auto",
            label: "Auto",
            description: "Codex can read files, make edits, and run commands in the workspace. Codex requires approval to work outside the workspace or access network.",
            approvalPolicy: .onRequest,
            sandboxMode: .workspaceWrite
        ),
        CodexApprovalPreset(
            id: "full-access",
            label: "Full Access",
            description: "Codex can read files, make edits, and run commands with network access, without approval.",
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess
        ),
    ]

    static func preset(for selection: CodexApprovalSelection) -> CodexApprovalPreset? {
        presets.first {
            $0.approvalPolicy == selection.approvalPolicy &&
                $0.sandboxMode == selection.sandboxMode
        }
    }
}

private struct CodexModelPresetsFFIResponse: Decodable {
    let ok: Bool
    let presets: [CodexModelPresetFFI]?
    let error: String?
}

private struct CodexModelPresetFFI: Decodable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [CodexReasoningPresetFFI]
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName = "display_name"
        case description
        case defaultReasoningEffort = "default_reasoning_effort"
        case supportedReasoningEfforts = "supported_reasoning_efforts"
        case isDefault = "is_default"
    }
}

private struct CodexReasoningPresetFFI: Decodable {
    let effort: String
    let description: String
}

enum CodexModelCatalog {
    private static let fallbackPresets: [CodexModelPreset] = [
        CodexModelPreset(
            id: "gpt-5-codex",
            model: "gpt-5-codex",
            displayName: "gpt-5-codex",
            description: "Optimized for coding tasks with many tools.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [
                CodexReasoningPreset(
                    effort: .low,
                    description: "Fastest responses with limited reasoning"
                ),
                CodexReasoningPreset(
                    effort: .medium,
                    description: "Dynamically adjusts reasoning based on the task"
                ),
                CodexReasoningPreset(
                    effort: .high,
                    description: "Maximizes reasoning depth for complex or ambiguous problems"
                ),
            ],
            isDefault: true
        ),
        CodexModelPreset(
            id: "gpt-5",
            model: "gpt-5",
            displayName: "gpt-5",
            description: "Broad world knowledge with strong general reasoning.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [
                CodexReasoningPreset(
                    effort: .minimal,
                    description: "Fastest responses with little reasoning"
                ),
                CodexReasoningPreset(
                    effort: .low,
                    description: "Balances speed with some reasoning"
                ),
                CodexReasoningPreset(
                    effort: .medium,
                    description: "Solid balance of reasoning depth and latency"
                ),
                CodexReasoningPreset(
                    effort: .high,
                    description: "Maximizes reasoning depth for complex or ambiguous problems"
                ),
            ],
            isDefault: false
        ),
    ]

    static let presets: [CodexModelPreset] = loadPresetsFromFFI()

    static func availablePresets(including selection: CodexModelSelection) -> [CodexModelPreset] {
        if presets.contains(where: { $0.model == selection.model }) {
            return presets
        }

        let fallbackEffort = selection.reasoningEffort ?? .medium
        let customPreset = CodexModelPreset(
            id: "custom-\(selection.model)",
            model: selection.model,
            displayName: selection.model,
            description: "Custom model from your Codex configuration.",
            defaultReasoningEffort: fallbackEffort,
            supportedReasoningEfforts: CodexReasoningEffort.allCases.map {
                CodexReasoningPreset(
                    effort: $0,
                    description: "Effort support depends on the configured provider."
                )
            },
            isDefault: false
        )

        return [customPreset] + presets
    }

    static func preset(for model: String, including selection: CodexModelSelection) -> CodexModelPreset {
        availablePresets(including: selection)
            .first(where: { $0.model == model }) ?? availablePresets(including: selection).first ?? presets[0]
    }

    static func normalized(_ selection: CodexModelSelection) -> CodexModelSelection {
        let preset = availablePresets(including: selection)
            .first(where: { $0.model == selection.model })

        guard let preset else {
            return selection
        }

        let supported = Set(preset.supportedReasoningEfforts.map(\.effort))
        let effort = selection.reasoningEffort
        let normalizedEffort: CodexReasoningEffort

        if let effort, supported.contains(effort) {
            normalizedEffort = effort
        } else {
            normalizedEffort = preset.defaultReasoningEffort
        }

        return CodexModelSelection(
            model: selection.model,
            reasoningEffort: normalizedEffort,
            activeProfile: selection.activeProfile
        )
    }

    private static func loadPresetsFromFFI() -> [CodexModelPreset] {
        if UITestSupport.isRunningUnitTests {
            return fallbackPresets
        }

        guard let rawPtr = codex_get_model_presets_json() else {
            return fallbackPresets
        }

        defer { codex_string_free(rawPtr) }

        let json = String(cString: rawPtr)
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(CodexModelPresetsFFIResponse.self, from: data)
        else {
            AppLogger.codex.warning("Codex model presets decode failed; using fallback presets")
            return fallbackPresets
        }

        guard response.ok, let presets = response.presets else {
            AppLogger.codex.warning(
                "Codex model presets load failed; using fallback presets",
                metadata: ["error": response.error ?? "unknown"]
            )
            return fallbackPresets
        }

        let mapped: [CodexModelPreset] = presets.compactMap { (preset: CodexModelPresetFFI) -> CodexModelPreset? in
            let supported: [CodexReasoningPreset] = preset.supportedReasoningEfforts.compactMap { (option: CodexReasoningPresetFFI) -> CodexReasoningPreset? in
                guard let effort = CodexReasoningEffort(rawValue: option.effort) else {
                    return nil
                }

                return CodexReasoningPreset(
                    effort: effort,
                    description: option.description
                )
            }

            guard let defaultEffort = CodexReasoningEffort(rawValue: preset.defaultReasoningEffort) else {
                return nil
            }

            var normalizedSupported = supported
            if !normalizedSupported.contains(where: { $0.effort == defaultEffort }) {
                normalizedSupported.append(
                    CodexReasoningPreset(
                        effort: defaultEffort,
                        description: "Default model reasoning effort"
                    )
                )
            }

            return CodexModelPreset(
                id: preset.id,
                model: preset.model,
                displayName: preset.displayName,
                description: preset.description,
                defaultReasoningEffort: defaultEffort,
                supportedReasoningEfforts: normalizedSupported,
                isDefault: preset.isDefault
            )
        }

        if mapped.isEmpty {
            AppLogger.codex.warning("Codex model presets were empty after decode; using fallback presets")
            return fallbackPresets
        }

        return mapped
    }
}

private struct CodexSelectionFFIResponse: Decodable {
    let ok: Bool
    let model: String?
    let reasoningEffort: String?
    let activeProfile: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case model
        case reasoningEffort = "reasoning_effort"
        case activeProfile = "active_profile"
        case error
    }
}

private struct CodexApprovalSelectionFFIResponse: Decodable {
    let ok: Bool
    let approvalPolicy: String?
    let sandboxMode: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case approvalPolicy = "approval_policy"
        case sandboxMode = "sandbox_mode"
        case error
    }
}

enum CodexModelConfigStore {
    static func loadSelection(cwd: String? = nil) -> CodexModelSelection {
        if UITestSupport.isRunningUnitTests {
            return .fallback
        }

        let response = decodeResponse {
            callWithOptionalCString(cwd) { cwdPtr in
                codex_get_model_selection_json(cwdPtr)
            }
        }

        guard let response else {
            return .fallback
        }

        let fallbackSelection = CodexModelSelection(
            model: response.model ?? CodexModelSelection.fallback.model,
            reasoningEffort: response.reasoningEffort.flatMap { CodexReasoningEffort(rawValue: $0) } ?? CodexModelSelection.fallback.reasoningEffort,
            activeProfile: response.activeProfile
        )

        if !response.ok {
            AppLogger.codex.warning(
                "Codex model selection load fallback",
                metadata: ["error": response.error ?? "unknown"]
            )
            return CodexModelCatalog.normalized(fallbackSelection)
        }

        return CodexModelCatalog.normalized(fallbackSelection)
    }

    static func persistSelection(
        _ selection: CodexModelSelection,
        cwd: String? = nil
    ) -> Result<CodexModelSelection, CodexModelSelectionError> {
        if UITestSupport.isRunningUnitTests {
            return .success(CodexModelCatalog.normalized(selection))
        }

        let normalized = CodexModelCatalog.normalized(selection)
        let response = decodeResponse {
            callWithOptionalCString(cwd) { cwdPtr in
                normalized.model.withCString { modelPtr in
                    if let effort = normalized.reasoningEffort {
                        return effort.rawValue.withCString { effortPtr in
                            codex_persist_model_selection_json(cwdPtr, modelPtr, effortPtr)
                        }
                    }
                    return codex_persist_model_selection_json(cwdPtr, modelPtr, nil)
                }
            }
        }

        guard let response else {
            return .failure(CodexModelSelectionError("Failed to persist model selection"))
        }

        guard response.ok else {
            return .failure(CodexModelSelectionError(response.error ?? "Failed to persist model selection"))
        }

        let persisted = CodexModelSelection(
            model: response.model ?? normalized.model,
            reasoningEffort: response.reasoningEffort.flatMap { CodexReasoningEffort(rawValue: $0) } ?? normalized.reasoningEffort,
            activeProfile: response.activeProfile
        )

        return .success(CodexModelCatalog.normalized(persisted))
    }

    private static func decodeResponse(_ call: () -> UnsafeMutablePointer<CChar>?) -> CodexSelectionFFIResponse? {
        guard let rawPtr = call() else {
            return nil
        }

        defer { codex_string_free(rawPtr) }

        let json = String(cString: rawPtr)
        guard let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexSelectionFFIResponse.self, from: data)
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

enum CodexApprovalConfigStore {
    static func loadSelection(cwd: String? = nil) -> CodexApprovalSelection {
        if UITestSupport.isRunningUnitTests {
            return .fallback
        }

        let response = decodeResponse {
            callWithOptionalCString(cwd) { cwdPtr in
                codex_get_approval_sandbox_json(cwdPtr)
            }
        }

        guard let response else {
            return .fallback
        }

        let fallback = CodexApprovalSelection(
            approvalPolicy: response.approvalPolicy.flatMap { CodexApprovalPolicy(rawValue: $0) } ?? CodexApprovalSelection.fallback.approvalPolicy,
            sandboxMode: response.sandboxMode.flatMap { CodexSandboxMode(rawValue: $0) } ?? CodexApprovalSelection.fallback.sandboxMode
        )

        if !response.ok {
            AppLogger.codex.warning(
                "Codex approval/sandbox selection load fallback",
                metadata: ["error": response.error ?? "unknown"]
            )
        }

        return fallback
    }

    private static func decodeResponse(_ call: () -> UnsafeMutablePointer<CChar>?) -> CodexApprovalSelectionFFIResponse? {
        guard let rawPtr = call() else {
            return nil
        }

        defer { codex_string_free(rawPtr) }

        let json = String(cString: rawPtr)
        guard let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexApprovalSelectionFFIResponse.self, from: data)
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
