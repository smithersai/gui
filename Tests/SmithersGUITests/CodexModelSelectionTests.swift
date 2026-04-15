import XCTest
@testable import SmithersGUI

// MARK: - CodexReasoningEffort Tests

final class CodexReasoningEffortTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(CodexReasoningEffort.allCases.count, 4)
    }

    func testRawValues() {
        XCTAssertEqual(CodexReasoningEffort.minimal.rawValue, "minimal")
        XCTAssertEqual(CodexReasoningEffort.low.rawValue, "low")
        XCTAssertEqual(CodexReasoningEffort.medium.rawValue, "medium")
        XCTAssertEqual(CodexReasoningEffort.high.rawValue, "high")
    }

    func testDisplayNames() {
        XCTAssertEqual(CodexReasoningEffort.minimal.displayName, "Minimal")
        XCTAssertEqual(CodexReasoningEffort.low.displayName, "Low")
        XCTAssertEqual(CodexReasoningEffort.medium.displayName, "Medium")
        XCTAssertEqual(CodexReasoningEffort.high.displayName, "High")
    }

    func testCodable() throws {
        let json = Data(#""high""#.utf8)
        let decoded = try JSONDecoder().decode(CodexReasoningEffort.self, from: json)
        XCTAssertEqual(decoded, .high)

        let encoded = try JSONEncoder().encode(CodexReasoningEffort.minimal)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #""minimal""#)
    }
}

// MARK: - CodexReasoningPreset Tests

final class CodexReasoningPresetTests: XCTestCase {

    func testIdIsEffortRawValue() {
        let preset = CodexReasoningPreset(effort: .high, description: "Deep reasoning")
        XCTAssertEqual(preset.id, "high")
    }

    func testEquality() {
        let a = CodexReasoningPreset(effort: .medium, description: "Balanced")
        let b = CodexReasoningPreset(effort: .medium, description: "Balanced")
        XCTAssertEqual(a, b)
    }
}

// MARK: - CodexModelPreset Tests

final class CodexModelPresetTests: XCTestCase {

    func testCatalogHasPresets() {
        XCTAssertFalse(CodexModelCatalog.presets.isEmpty)
    }

    func testDefaultPresetExists() {
        let defaultPreset = CodexModelCatalog.presets.first(where: \.isDefault)
        XCTAssertNotNil(defaultPreset)
        XCTAssertEqual(defaultPreset?.model, "gpt-5-codex")
    }

    func testGPT5PresetExists() {
        let gpt5 = CodexModelCatalog.presets.first(where: { $0.model == "gpt-5" })
        XCTAssertNotNil(gpt5)
        XCTAssertFalse(gpt5!.isDefault)
    }

    func testPresetsSupportedEfforts() {
        for preset in CodexModelCatalog.presets {
            XCTAssertFalse(preset.supportedReasoningEfforts.isEmpty, "\(preset.model) has no supported efforts")
            XCTAssertTrue(
                preset.supportedReasoningEfforts.contains(where: { $0.effort == preset.defaultReasoningEffort }),
                "\(preset.model) default effort not in supported list"
            )
        }
    }
}

// MARK: - CodexModelSelection Tests

final class CodexModelSelectionTests: XCTestCase {

    func testFallbackValues() {
        let fb = CodexModelSelection.fallback
        XCTAssertEqual(fb.model, "gpt-5-codex")
        XCTAssertEqual(fb.reasoningEffort, .medium)
        XCTAssertNil(fb.activeProfile)
    }

    func testSummaryLabelWithEffort() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: .high)
        XCTAssertEqual(sel.summaryLabel, "gpt-5 · High")
    }

    func testSummaryLabelWithoutEffort() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: nil)
        XCTAssertEqual(sel.summaryLabel, "gpt-5")
    }

    func testEquality() {
        let a = CodexModelSelection(model: "gpt-5", reasoningEffort: .medium, activeProfile: nil)
        let b = CodexModelSelection(model: "gpt-5", reasoningEffort: .medium, activeProfile: nil)
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentModel() {
        let a = CodexModelSelection(model: "gpt-5", reasoningEffort: .medium)
        let b = CodexModelSelection(model: "gpt-5-codex", reasoningEffort: .medium)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityDifferentEffort() {
        let a = CodexModelSelection(model: "gpt-5", reasoningEffort: .low)
        let b = CodexModelSelection(model: "gpt-5", reasoningEffort: .high)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - CodexModelCatalog Tests

final class CodexModelCatalogTests: XCTestCase {

    func testAvailablePresetsIncludesKnownModel() {
        let sel = CodexModelSelection(model: "gpt-5-codex", reasoningEffort: .medium)
        let presets = CodexModelCatalog.availablePresets(including: sel)
        XCTAssertEqual(presets.count, CodexModelCatalog.presets.count)
    }

    func testAvailablePresetsAddsCustomModelFirst() {
        let sel = CodexModelSelection(model: "custom-model-xyz", reasoningEffort: .high)
        let presets = CodexModelCatalog.availablePresets(including: sel)
        XCTAssertEqual(presets.count, CodexModelCatalog.presets.count + 1)
        XCTAssertEqual(presets.first?.model, "custom-model-xyz")
        XCTAssertTrue(presets.first?.id.hasPrefix("custom-") ?? false)
    }

    func testCustomModelHasAllEfforts() {
        let sel = CodexModelSelection(model: "my-model", reasoningEffort: .low)
        let presets = CodexModelCatalog.availablePresets(including: sel)
        let custom = presets.first(where: { $0.model == "my-model" })!
        XCTAssertEqual(custom.supportedReasoningEfforts.count, CodexReasoningEffort.allCases.count)
    }

    func testCustomModelDefaultEffortMatchesSelection() {
        let sel = CodexModelSelection(model: "my-model", reasoningEffort: .high)
        let presets = CodexModelCatalog.availablePresets(including: sel)
        let custom = presets.first(where: { $0.model == "my-model" })!
        XCTAssertEqual(custom.defaultReasoningEffort, .high)
    }

    func testCustomModelNilEffortFallsToMedium() {
        let sel = CodexModelSelection(model: "my-model", reasoningEffort: nil)
        let presets = CodexModelCatalog.availablePresets(including: sel)
        let custom = presets.first(where: { $0.model == "my-model" })!
        XCTAssertEqual(custom.defaultReasoningEffort, .medium)
    }

    func testPresetForKnownModel() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: .medium)
        let preset = CodexModelCatalog.preset(for: "gpt-5", including: sel)
        XCTAssertEqual(preset.model, "gpt-5")
    }

    func testPresetForUnknownModelReturnsCustom() {
        let sel = CodexModelSelection(model: "unknown-model", reasoningEffort: .low)
        let preset = CodexModelCatalog.preset(for: "unknown-model", including: sel)
        XCTAssertEqual(preset.model, "unknown-model")
    }

    func testPresetForMismatchedModelFallsToFirst() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: .medium)
        let preset = CodexModelCatalog.preset(for: "nonexistent", including: sel)
        // Should return first available preset
        XCTAssertNotNil(preset)
    }

    // MARK: - Normalization

    func testNormalizedKeepsSupportedEffort() {
        let sel = CodexModelSelection(model: "gpt-5-codex", reasoningEffort: .low)
        let normalized = CodexModelCatalog.normalized(sel)
        XCTAssertEqual(normalized.model, "gpt-5-codex")
        XCTAssertEqual(normalized.reasoningEffort, .low)
    }

    func testNormalizedFallsBackToDefaultForUnsupportedEffort() {
        // gpt-5-codex doesn't support .minimal
        let sel = CodexModelSelection(model: "gpt-5-codex", reasoningEffort: .minimal)
        let normalized = CodexModelCatalog.normalized(sel)
        XCTAssertEqual(normalized.model, "gpt-5-codex")
        // Should fall back to default
        let preset = CodexModelCatalog.presets.first(where: { $0.model == "gpt-5-codex" })!
        XCTAssertEqual(normalized.reasoningEffort, preset.defaultReasoningEffort)
    }

    func testNormalizedFallsBackWhenNilEffort() {
        let sel = CodexModelSelection(model: "gpt-5-codex", reasoningEffort: nil)
        let normalized = CodexModelCatalog.normalized(sel)
        XCTAssertNotNil(normalized.reasoningEffort)
    }

    func testNormalizedPreservesActiveProfile() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: .medium, activeProfile: "prod")
        let normalized = CodexModelCatalog.normalized(sel)
        XCTAssertEqual(normalized.activeProfile, "prod")
    }

    func testNormalizedUnknownModelPassesThrough() {
        let sel = CodexModelSelection(model: "totally-unknown", reasoningEffort: .high)
        let normalized = CodexModelCatalog.normalized(sel)
        // Unknown model with no preset match: should return selection as-is
        XCTAssertEqual(normalized.model, "totally-unknown")
        XCTAssertEqual(normalized.reasoningEffort, .high)
    }

    func testGPT5SupportsMinimal() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: .minimal)
        let normalized = CodexModelCatalog.normalized(sel)
        XCTAssertEqual(normalized.reasoningEffort, .minimal)
    }
}

// MARK: - CodexModelSelectionError Tests

final class CodexModelSelectionErrorTests: XCTestCase {

    func testErrorDescription() {
        let err = CodexModelSelectionError("oops")
        XCTAssertEqual(err.errorDescription, "oops")
        XCTAssertEqual(err.message, "oops")
    }

    func testEquality() {
        let a = CodexModelSelectionError("x")
        let b = CodexModelSelectionError("x")
        XCTAssertEqual(a, b)
    }
}

// MARK: - CodexModelConfigStore Tests

final class CodexModelConfigStoreTests: XCTestCase {

    func testLoadSelectionReturnsFallbackInUnitTests() {
        let sel = CodexModelConfigStore.loadSelection()
        XCTAssertEqual(sel, CodexModelSelection.fallback)
    }

    func testLoadSelectionWithCWDReturnsFallbackInUnitTests() {
        let sel = CodexModelConfigStore.loadSelection(cwd: "/tmp")
        XCTAssertEqual(sel, CodexModelSelection.fallback)
    }

    func testPersistSelectionReturnsNormalizedInUnitTests() {
        let sel = CodexModelSelection(model: "gpt-5", reasoningEffort: .high)
        let result = CodexModelConfigStore.persistSelection(sel)
        switch result {
        case .success(let persisted):
            XCTAssertEqual(persisted.model, "gpt-5")
            XCTAssertEqual(persisted.reasoningEffort, .high)
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }
    }

    func testPersistNormalizesUnsupportedEffort() {
        let sel = CodexModelSelection(model: "gpt-5-codex", reasoningEffort: .minimal)
        let result = CodexModelConfigStore.persistSelection(sel)
        switch result {
        case .success(let persisted):
            // gpt-5-codex doesn't support minimal, should normalize
            XCTAssertNotEqual(persisted.reasoningEffort, .minimal)
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }
    }
}

// MARK: - CodexApprovalPolicy Tests

final class CodexApprovalPolicyTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(CodexApprovalPolicy.untrusted.rawValue, "untrusted")
        XCTAssertEqual(CodexApprovalPolicy.onFailure.rawValue, "on-failure")
        XCTAssertEqual(CodexApprovalPolicy.onRequest.rawValue, "on-request")
        XCTAssertEqual(CodexApprovalPolicy.never.rawValue, "never")
    }

    func testDisplayNames() {
        XCTAssertEqual(CodexApprovalPolicy.untrusted.displayName, "Untrusted")
        XCTAssertEqual(CodexApprovalPolicy.onFailure.displayName, "On Failure")
        XCTAssertEqual(CodexApprovalPolicy.onRequest.displayName, "On Request")
        XCTAssertEqual(CodexApprovalPolicy.never.displayName, "Never")
    }
}

// MARK: - CodexApprovalSelection Tests

final class CodexApprovalSelectionTests: XCTestCase {

    func testFallbackValues() {
        let fallback = CodexApprovalSelection.fallback
        XCTAssertEqual(fallback.approvalPolicy, .onRequest)
        XCTAssertEqual(fallback.sandboxMode, .readOnly)
    }

    func testFullAccessFlag() {
        let fullAccess = CodexApprovalSelection(
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess
        )
        XCTAssertTrue(fullAccess.isFullAccess)
    }

    func testSummaryUsesPresetLabel() {
        let auto = CodexApprovalSelection(
            approvalPolicy: .onRequest,
            sandboxMode: .workspaceWrite
        )
        XCTAssertEqual(auto.summaryLabel, "Auto")
    }
}

// MARK: - CodexApprovalPresetCatalog Tests

final class CodexApprovalPresetCatalogTests: XCTestCase {

    func testPresetsMatchTUIModes() {
        XCTAssertEqual(CodexApprovalPresetCatalog.presets.count, 3)
        XCTAssertEqual(CodexApprovalPresetCatalog.presets.map(\.id), ["read-only", "auto", "full-access"])
    }

    func testPresetLookupBySelection() {
        let selection = CodexApprovalSelection(
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess
        )
        let preset = CodexApprovalPresetCatalog.preset(for: selection)
        XCTAssertEqual(preset?.id, "full-access")
    }
}

// MARK: - CodexApprovalConfigStore Tests

final class CodexApprovalConfigStoreTests: XCTestCase {

    func testLoadSelectionReturnsFallbackInUnitTests() {
        let selection = CodexApprovalConfigStore.loadSelection()
        XCTAssertEqual(selection, CodexApprovalSelection.fallback)
    }
}
