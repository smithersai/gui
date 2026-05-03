import Foundation

/// Hides transcript bodies while preserving enough structure to discuss a run
/// during screen sharing.
enum ChatPrivacyRedactor {
    static func redactedContent(forRole role: String) -> String {
        switch normalizedRole(role) {
        case "assistant", "agent":
            return "[assistant response hidden in privacy mode]"
        case "user", "prompt":
            return "[prompt hidden in privacy mode]"
        case "tool", "tool_call":
            return "[tool call hidden in privacy mode]"
        case "tool_result":
            return "[tool result hidden in privacy mode]"
        case "stderr":
            return "[stderr hidden in privacy mode]"
        case "system", "status":
            return "[system event hidden in privacy mode]"
        default:
            return "[content hidden in privacy mode]"
        }
    }

    private static func normalizedRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
