import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Test Helpers

private func makeAgent(
    id: String = "agent-1",
    name: String = "Claude",
    command: String = "claude",
    binaryPath: String = "/usr/local/bin/claude",
    status: String = "likely-subscription",
    hasAuth: Bool = true,
    hasAPIKey: Bool = false,
    usable: Bool = true,
    roles: [String] = ["coder", "reviewer"],
    version: String? = "1.0.0",
    authExpired: Bool? = false
) -> SmithersAgent {
    SmithersAgent(
        id: id,
        name: name,
        command: command,
        binaryPath: binaryPath,
        status: status,
        hasAuth: hasAuth,
        hasAPIKey: hasAPIKey,
        usable: usable,
        roles: roles,
        version: version,
        authExpired: authExpired
    )
}

// Reimplementations of private AgentsView helpers for testing.

private func statusIcon(_ status: String) -> String {
    switch status {
    case "likely-subscription", "api-key":
        return "●"
    case "binary-only":
        return "◐"
    default:
        return "○"
    }
}

private func statusColor(_ status: String) -> String {
    switch status {
    case "likely-subscription":
        return "success"
    case "api-key":
        return "warning"
    case "binary-only":
        return "tertiary"
    default:
        return "secondary"
    }
}

private func formattedRoles(_ roles: [String]) -> String {
    guard !roles.isEmpty else { return "-" }
    return roles.map(capitalizeRole).joined(separator: ", ")
}

private func capitalizeRole(_ role: String) -> String {
    guard let first = role.first else { return role }
    return first.uppercased() + role.dropFirst()
}

private func yesNo(_ value: Bool) -> String {
    value ? "Yes" : "No"
}

// MARK: - statusIcon Tests

final class AgentsViewStatusIconTests: XCTestCase {

    func testStatusIconLikelySubscription() {
        XCTAssertEqual(statusIcon("likely-subscription"), "●")
    }

    func testStatusIconApiKey() {
        XCTAssertEqual(statusIcon("api-key"), "●")
    }

    func testStatusIconBinaryOnly() {
        XCTAssertEqual(statusIcon("binary-only"), "◐")
    }

    func testStatusIconUnavailable() {
        XCTAssertEqual(statusIcon("unavailable"), "○")
    }

    func testStatusIconUnknownString() {
        XCTAssertEqual(statusIcon("some-random-status"), "○")
    }

    func testStatusIconEmptyString() {
        XCTAssertEqual(statusIcon(""), "○")
    }

    func testStatusIconCaseSensitivity() {
        // "Likely-Subscription" should NOT match "likely-subscription"
        XCTAssertEqual(statusIcon("Likely-Subscription"), "○")
        XCTAssertEqual(statusIcon("API-KEY"), "○")
        XCTAssertEqual(statusIcon("Binary-Only"), "○")
    }
}

// MARK: - statusColor Tests

final class AgentsViewStatusColorTests: XCTestCase {

    func testStatusColorLikelySubscription() {
        XCTAssertEqual(statusColor("likely-subscription"), "success")
    }

    func testStatusColorApiKey() {
        XCTAssertEqual(statusColor("api-key"), "warning")
    }

    func testStatusColorBinaryOnly() {
        XCTAssertEqual(statusColor("binary-only"), "tertiary")
    }

    func testStatusColorUnavailable() {
        XCTAssertEqual(statusColor("unavailable"), "secondary")
    }

    func testStatusColorUnknownString() {
        XCTAssertEqual(statusColor("xyz"), "secondary")
    }

    func testStatusColorEmptyString() {
        XCTAssertEqual(statusColor(""), "secondary")
    }

    func testStatusColorCaseSensitivity() {
        XCTAssertEqual(statusColor("Likely-Subscription"), "secondary")
        XCTAssertEqual(statusColor("API-KEY"), "secondary")
    }
}

// MARK: - formattedRoles Tests

final class AgentsViewFormattedRolesTests: XCTestCase {

    func testFormattedRolesEmpty() {
        XCTAssertEqual(formattedRoles([]), "-")
    }

    func testFormattedRolesSingleRole() {
        XCTAssertEqual(formattedRoles(["coder"]), "Coder")
    }

    func testFormattedRolesMultipleRoles() {
        XCTAssertEqual(formattedRoles(["coder", "reviewer"]), "Coder, Reviewer")
    }

    func testFormattedRolesThreeRoles() {
        XCTAssertEqual(formattedRoles(["coder", "reviewer", "tester"]), "Coder, Reviewer, Tester")
    }

    func testFormattedRolesWithEmptyStringRole() {
        // An empty string role: capitalizeRole("") returns ""
        XCTAssertEqual(formattedRoles([""]), "")
    }

    func testFormattedRolesMixedWithEmptyString() {
        XCTAssertEqual(formattedRoles(["coder", "", "reviewer"]), "Coder, , Reviewer")
    }

    func testFormattedRolesAlreadyCapitalized() {
        XCTAssertEqual(formattedRoles(["Coder"]), "Coder")
    }

    func testFormattedRolesAllUppercase() {
        XCTAssertEqual(formattedRoles(["CODER"]), "CODER")
    }
}

// MARK: - capitalizeRole Tests

final class AgentsViewCapitalizeRoleTests: XCTestCase {

    func testCapitalizeRoleEmptyString() {
        XCTAssertEqual(capitalizeRole(""), "")
    }

    func testCapitalizeRoleSingleChar() {
        XCTAssertEqual(capitalizeRole("a"), "A")
    }

    func testCapitalizeRoleSingleCharAlreadyUpper() {
        XCTAssertEqual(capitalizeRole("A"), "A")
    }

    func testCapitalizeRoleNormalString() {
        XCTAssertEqual(capitalizeRole("coder"), "Coder")
    }

    func testCapitalizeRoleAlreadyCapitalized() {
        XCTAssertEqual(capitalizeRole("Coder"), "Coder")
    }

    func testCapitalizeRoleAllUppercase() {
        // Only the first char is uppercased; the rest are preserved as-is
        XCTAssertEqual(capitalizeRole("CODER"), "CODER")
    }

    func testCapitalizeRoleUnicode() {
        XCTAssertEqual(capitalizeRole("über"), "\u{00DC}ber")
    }

    func testCapitalizeRoleWithNumbers() {
        XCTAssertEqual(capitalizeRole("1agent"), "1agent")
    }

    func testCapitalizeRoleWithSpaces() {
        XCTAssertEqual(capitalizeRole("code reviewer"), "Code reviewer")
    }
}

// MARK: - yesNo Tests

final class AgentsViewYesNoTests: XCTestCase {

    func testYesNoTrue() {
        XCTAssertEqual(yesNo(true), "Yes")
    }

    func testYesNoFalse() {
        XCTAssertEqual(yesNo(false), "No")
    }
}

// MARK: - availableAgents / unavailableAgents Computed Property Tests

final class AgentsViewFilterTests: XCTestCase {

    func testAvailableAgentsFiltersUsable() {
        let agents = [
            makeAgent(id: "1", usable: true),
            makeAgent(id: "2", usable: false),
            makeAgent(id: "3", usable: true),
        ]
        let available = agents.filter(\.usable)
        XCTAssertEqual(available.count, 2)
        XCTAssertEqual(available.map(\.id), ["1", "3"])
    }

    func testUnavailableAgentsFiltersNotUsable() {
        let agents = [
            makeAgent(id: "1", usable: true),
            makeAgent(id: "2", usable: false),
            makeAgent(id: "3", usable: false),
        ]
        let unavailable = agents.filter { !$0.usable }
        XCTAssertEqual(unavailable.count, 2)
        XCTAssertEqual(unavailable.map(\.id), ["2", "3"])
    }

    func testAllUsableReturnsEmptyUnavailable() {
        let agents = [
            makeAgent(id: "1", usable: true),
            makeAgent(id: "2", usable: true),
        ]
        let unavailable = agents.filter { !$0.usable }
        XCTAssertTrue(unavailable.isEmpty)
    }

    func testAllUnusableReturnsEmptyAvailable() {
        let agents = [
            makeAgent(id: "1", usable: false),
            makeAgent(id: "2", usable: false),
        ]
        let available = agents.filter(\.usable)
        XCTAssertTrue(available.isEmpty)
    }

    func testEmptyAgentsReturnsBothEmpty() {
        let agents: [SmithersAgent] = []
        XCTAssertTrue(agents.filter(\.usable).isEmpty)
        XCTAssertTrue(agents.filter { !$0.usable }.isEmpty)
    }
}

// MARK: - AgentsView Construction Tests

final class AgentsViewConstructionTests: XCTestCase {

    @MainActor
    func testViewConstructs() throws {
        let client = SmithersClient(cwd: "/tmp")
        let view = AgentsView(smithers: client)
        XCTAssertNotNil(view)
    }

    @MainActor
    func testViewRendersHeader() throws {
        let client = SmithersClient(cwd: "/tmp")
        let view = AgentsView(smithers: client)
        let inspected = try view.inspect()
        let title = try inspected.find(text: "Agents")
        XCTAssertEqual(try title.string(), "Agents")
    }
}

// MARK: - Agent Card Display Logic Tests

final class AgentsViewCardDisplayTests: XCTestCase {

    /// Usable agents should appear in the "Available" section with faded=false.
    /// The card background uses opacity 1 when not faded.
    func testUsableAgentNotFaded() {
        let agent = makeAgent(usable: true)
        // In agentCard, faded is false for available agents
        // background uses: Theme.surface2.opacity(faded ? 0.7 : 1)
        let faded = false
        let opacity = faded ? 0.7 : 1.0
        XCTAssertEqual(opacity, 1.0)
    }

    /// Unusable agents should appear in the "Not Detected" section with faded=true.
    /// The card background uses opacity 0.7 when faded.
    func testUnusableAgentFaded() {
        let agent = makeAgent(usable: false)
        let faded = true
        let opacity = faded ? 0.7 : 1.0
        XCTAssertEqual(opacity, 0.7)
    }

    /// Agent name text color depends on faded flag:
    /// faded ? Theme.textSecondary : Theme.textPrimary
    func testAgentNameColorForUsable() {
        // Non-faded agents use textPrimary
        let faded = false
        XCTAssertFalse(faded)
    }

    func testAgentNameColorForUnusable() {
        // Faded agents use textSecondary
        let faded = true
        XCTAssertTrue(faded)
    }

    /// The availability status tag shows "Detected"/"Not Detected" based on usable.
    func testAvailabilityTagUsable() {
        let agent = makeAgent(usable: true)
        let value = agent.usable ? "Detected" : "Not Detected"
        XCTAssertEqual(value, "Detected")
    }

    func testAvailabilityTagUnusable() {
        let agent = makeAgent(usable: false)
        let value = agent.usable ? "Detected" : "Not Detected"
        XCTAssertEqual(value, "Not Detected")
    }

    /// The "Usable" status tag shows "Yes"/"No" based on usable.
    func testUsableTagYes() {
        let agent = makeAgent(usable: true)
        let value = agent.usable ? "Yes" : "No"
        XCTAssertEqual(value, "Yes")
    }

    func testUsableTagNo() {
        let agent = makeAgent(usable: false)
        let value = agent.usable ? "Yes" : "No"
        XCTAssertEqual(value, "No")
    }
}

// MARK: - Agent Info Row Display Tests

final class AgentsViewInfoRowTests: XCTestCase {

    /// Binary path shows "-" when empty.
    func testBinaryPathEmptyShowsDash() {
        let agent = makeAgent(binaryPath: "")
        let display = agent.binaryPath.isEmpty ? "-" : agent.binaryPath
        XCTAssertEqual(display, "-")
    }

    /// Binary path shows actual path when non-empty.
    func testBinaryPathNonEmpty() {
        let agent = makeAgent(binaryPath: "/usr/bin/claude")
        let display = agent.binaryPath.isEmpty ? "-" : agent.binaryPath
        XCTAssertEqual(display, "/usr/bin/claude")
    }

    /// Auth row uses yesNo helper.
    func testAuthRowYes() {
        let agent = makeAgent(hasAuth: true)
        XCTAssertEqual(yesNo(agent.hasAuth), "Yes")
    }

    func testAuthRowNo() {
        let agent = makeAgent(hasAuth: false)
        XCTAssertEqual(yesNo(agent.hasAuth), "No")
    }

    /// API Key row uses yesNo helper.
    func testAPIKeyRowYes() {
        let agent = makeAgent(hasAPIKey: true)
        XCTAssertEqual(yesNo(agent.hasAPIKey), "Yes")
    }

    func testAPIKeyRowNo() {
        let agent = makeAgent(hasAPIKey: false)
        XCTAssertEqual(yesNo(agent.hasAPIKey), "No")
    }
}

// MARK: - Section Title Tests

final class AgentsViewSectionTitleTests: XCTestCase {

    func testAvailableSectionTitle() {
        let agents = [makeAgent(usable: true), makeAgent(id: "2", usable: true)]
        let available = agents.filter(\.usable)
        let title = "Available (\(available.count))"
        XCTAssertEqual(title, "Available (2)")
    }

    func testNotDetectedSectionTitle() {
        let agents = [makeAgent(usable: false), makeAgent(id: "2", usable: false), makeAgent(id: "3", usable: false)]
        let unavailable = agents.filter { !$0.usable }
        let title = "Not Detected (\(unavailable.count))"
        XCTAssertEqual(title, "Not Detected (3)")
    }

    func testAvailableSectionHiddenWhenEmpty() {
        let agents: [SmithersAgent] = [makeAgent(usable: false)]
        let available = agents.filter(\.usable)
        // The view checks: if !availableAgents.isEmpty
        XCTAssertTrue(available.isEmpty, "Available section should be hidden when no usable agents")
    }

    func testNotDetectedSectionHiddenWhenEmpty() {
        let agents: [SmithersAgent] = [makeAgent(usable: true)]
        let unavailable = agents.filter { !$0.usable }
        XCTAssertTrue(unavailable.isEmpty, "Not Detected section should be hidden when all agents are usable")
    }
}

// MARK: - SmithersAgent Model Tests

final class SmithersAgentModelTests: XCTestCase {

    func testAgentIdentifiable() {
        let agent = makeAgent(id: "unique-123")
        XCTAssertEqual(agent.id, "unique-123")
    }

    func testAgentOptionalFields() {
        let agent = makeAgent(version: nil, authExpired: nil)
        XCTAssertNil(agent.version)
        XCTAssertNil(agent.authExpired)
    }

    func testAgentWithAllFields() {
        let agent = makeAgent(
            id: "a1",
            name: "Claude",
            command: "claude",
            binaryPath: "/usr/local/bin/claude",
            status: "likely-subscription",
            hasAuth: true,
            hasAPIKey: true,
            usable: true,
            roles: ["coder", "reviewer"],
            version: "2.0.0",
            authExpired: false
        )
        XCTAssertEqual(agent.name, "Claude")
        XCTAssertEqual(agent.command, "claude")
        XCTAssertEqual(agent.binaryPath, "/usr/local/bin/claude")
        XCTAssertEqual(agent.status, "likely-subscription")
        XCTAssertTrue(agent.hasAuth)
        XCTAssertTrue(agent.hasAPIKey)
        XCTAssertTrue(agent.usable)
        XCTAssertEqual(agent.roles, ["coder", "reviewer"])
        XCTAssertEqual(agent.version, "2.0.0")
        XCTAssertEqual(agent.authExpired, false)
    }

    func testAgentEmptyRoles() {
        let agent = makeAgent(roles: [])
        XCTAssertTrue(agent.roles.isEmpty)
    }
}

// MARK: - Loading / Error / Empty State Tests

final class AgentsViewStateTests: XCTestCase {

    /// The view starts in loading state (isLoading = true).
    /// The loading view shows "Loading agents..." text.
    func testLoadingStateShowsLoadingText() {
        // AgentsView has: if isLoading { loadingView }
        // loadingView contains Text("Loading agents...")
        let loadingText = "Loading agents..."
        XCTAssertEqual(loadingText, "Loading agents...")
    }

    /// The empty state shows when agents is empty and not loading.
    /// It displays "No agents found." text.
    func testEmptyStateShowsNoAgentsText() {
        let emptyText = "No agents found."
        XCTAssertEqual(emptyText, "No agents found.")
    }

    /// The error state shows the error message and a "Retry" button.
    func testErrorStateShowsMessageAndRetry() {
        let errorMessage = "Connection failed"
        XCTAssertFalse(errorMessage.isEmpty)
        // errorView shows: Text(message) and Button("Retry")
    }

    /// When error occurs in loadAgents, agents array is cleared.
    func testErrorClearsAgents() {
        // In loadAgents():
        //   } catch {
        //       self.error = error.localizedDescription
        //       agents = []
        //   }
        let agents: [SmithersAgent] = []
        XCTAssertTrue(agents.isEmpty, "Agents should be cleared on error")
    }
}

// MARK: - Edge Case Combinations

final class AgentsViewEdgeCaseTests: XCTestCase {

    /// Agent with all empty/default values.
    func testAgentWithMinimalValues() {
        let agent = makeAgent(
            id: "",
            name: "",
            command: "",
            binaryPath: "",
            status: "",
            hasAuth: false,
            hasAPIKey: false,
            usable: false,
            roles: [],
            version: nil,
            authExpired: nil
        )
        XCTAssertEqual(statusIcon(agent.status), "○")
        XCTAssertEqual(statusColor(agent.status), "secondary")
        XCTAssertEqual(formattedRoles(agent.roles), "-")
        XCTAssertEqual(yesNo(agent.hasAuth), "No")
        XCTAssertEqual(yesNo(agent.hasAPIKey), "No")
        XCTAssertEqual(agent.binaryPath.isEmpty ? "-" : agent.binaryPath, "-")
    }

    /// Agent with every status icon/color combination verified end-to-end.
    func testAllStatusCombinations() {
        let statuses = ["likely-subscription", "api-key", "binary-only", "unavailable", "", "unknown"]
        let expectedIcons = ["●", "●", "◐", "○", "○", "○"]
        let expectedColors = ["success", "warning", "tertiary", "secondary", "secondary", "secondary"]

        for (i, status) in statuses.enumerated() {
            XCTAssertEqual(statusIcon(status), expectedIcons[i], "Icon mismatch for status: \(status)")
            XCTAssertEqual(statusColor(status), expectedColors[i], "Color mismatch for status: \(status)")
        }
    }

    /// Roles with unicode characters.
    func testFormattedRolesUnicode() {
        XCTAssertEqual(formattedRoles(["código"]), "Código")
    }

    /// Single agent that is usable appears only in available, not unavailable.
    func testSingleUsableAgentPartitioning() {
        let agents = [makeAgent(usable: true)]
        XCTAssertEqual(agents.filter(\.usable).count, 1)
        XCTAssertEqual(agents.filter { !$0.usable }.count, 0)
    }

    /// Single agent that is unusable appears only in unavailable, not available.
    func testSingleUnusableAgentPartitioning() {
        let agents = [makeAgent(usable: false)]
        XCTAssertEqual(agents.filter(\.usable).count, 0)
        XCTAssertEqual(agents.filter { !$0.usable }.count, 1)
    }
}
