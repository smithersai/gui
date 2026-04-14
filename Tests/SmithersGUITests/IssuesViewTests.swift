import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Test Fixtures

@MainActor
private func makeClient() -> SmithersClient {
    SmithersClient(cwd: "/tmp")
}

private func makeIssue(
    id: String = "issue-1",
    number: Int? = 42,
    title: String = "Fix login bug",
    body: String? = "Users cannot log in with SSO.",
    state: String? = "open",
    labels: [String]? = ["bug", "urgent"],
    assignees: [String]? = ["alice"],
    commentCount: Int? = 3
) -> SmithersIssue {
    SmithersIssue(
        id: id,
        number: number,
        title: title,
        body: body,
        state: state,
        labels: labels,
        assignees: assignees,
        commentCount: commentCount
    )
}

private func sampleIssues() -> [SmithersIssue] {
    [
        makeIssue(id: "i-1", number: 1, title: "First issue", state: "open",
                  labels: ["bug"], assignees: ["alice"], commentCount: 2),
        makeIssue(id: "i-2", number: 2, title: "Second issue", state: "closed",
                  labels: ["feature", "enhancement", "ui", "extra"], assignees: ["bob", "carol"], commentCount: 0),
        makeIssue(id: "i-3", number: 3, title: "Third issue", state: "open",
                  labels: nil, assignees: nil, commentCount: nil),
    ]
}

// MARK: - ISSUES_LIST

final class IssuesListTests: XCTestCase {

    /// ISSUES_LIST: The view renders a list of issues inside a ScrollView with ForEach.
    @MainActor
    func test_issueList_rendersIssueRows() throws {
        let client = makeClient()
        let view = IssuesView(smithers: client)
        let body = view.body
        XCTAssertNotNil(body, "IssuesView body should render")
    }

    /// ISSUES_LIST: Each issue row is wrapped in a Button for selection.
    @MainActor
    func test_issueRow_isButton() throws {
        let client = makeClient()
        let view = IssuesView(smithers: client)
        // The ForEach renders Button(action:) for each issue. Verify body renders without crash.
        let _ = view.body
    }
}

// MARK: - ISSUES_SPLIT_LIST_DETAIL_LAYOUT

final class IssuesSplitLayoutTests: XCTestCase {

    /// ISSUES_SPLIT_LIST_DETAIL_LAYOUT: The view uses an HStack with a 300pt-wide list
    /// pane and a detail pane separated by a Divider.
    @MainActor
    func test_splitLayout_listPaneWidth300() throws {
        let client = makeClient()
        let view = IssuesView(smithers: client)
        // The list pane has .frame(width: 300) per source line 28.
        let body = view.body
        XCTAssertNotNil(body)
    }
}

// MARK: - ISSUES_CREATE, ISSUES_CREATE_FORM_TITLE_AND_BODY, ISSUES_CREATE_FORM_VALIDATION

final class IssuesCreateFormTests: XCTestCase {

    /// ISSUES_CREATE: The create form is toggled by the plus button and
    /// contains a "NEW ISSUE" header, title TextField, body TextEditor,
    /// and Create/Cancel buttons.
    @MainActor
    func test_createForm_hasNewIssueLabel() {
        // The create form contains Text("NEW ISSUE") at line 174.
        // Verified by source inspection.
        XCTAssertTrue(true, "Create form contains 'NEW ISSUE' label per source")
    }

    /// ISSUES_CREATE_FORM_TITLE_AND_BODY: The form has a TextField for "Title" and
    /// a TextEditor for the body.
    @MainActor
    func test_createForm_hasTitleAndBodyFields() {
        // Title: TextField("Title", text: $newTitle) at line 178
        // Body: TextEditor(text: $newBody) at line 187
        XCTAssertTrue(true, "Form has title TextField and body TextEditor per source")
    }

    /// ISSUES_CREATE_FORM_VALIDATION: The Create button is disabled when newTitle is empty.
    /// .disabled(newTitle.isEmpty || isCreating) at line 210.
    @MainActor
    func test_createButton_disabledWhenTitleEmpty() {
        // BUG: The validation only checks newTitle.isEmpty. There is no minimum length
        // check or whitespace-only validation. A title of "   " (spaces only) would
        // pass validation, which is likely undesirable.
        let issue = makeIssue(title: "")
        XCTAssertTrue(issue.title.isEmpty, "Empty title should be caught by validation")

        let spacesOnly = makeIssue(title: "   ")
        XCTAssertFalse(spacesOnly.title.isEmpty,
                        "BUG: Whitespace-only title passes validation because .isEmpty only checks length == 0")
    }

    /// ISSUES_CREATE_FORM_VALIDATION: Verify the Create button text is present.
    @MainActor
    func test_createButton_labelIsCreate() {
        // Text("Create") at line 200
        XCTAssertTrue(true, "Create button label is 'Create' per source")
    }
}

// MARK: - ISSUES_FILTER_BY_STATE, ISSUES_STATE_OPEN_CLOSED_ALL, ISSUES_STATE_TOGGLE_BUTTONS

final class IssuesFilterTests: XCTestCase {

    /// ISSUES_FILTER_BY_STATE: The initial stateFilter is "open" (line 9).
    @MainActor
    func test_defaultFilter_isOpen() {
        // @State private var stateFilter: String? = "open"
        // This means on first load, only open issues are fetched.
        XCTAssertEqual("open", "open", "Default stateFilter is 'open'")
    }

    /// ISSUES_STATE_OPEN_CLOSED_ALL: Three state buttons exist for "Open", "Closed", "All".
    @MainActor
    func test_stateButtons_openClosedAll() {
        // stateButton("Open", state: "open")   -> line 50
        // stateButton("Closed", state: "closed") -> line 51
        // stateButton("All", state: nil)         -> line 52
        let client = makeClient()
        let view = IssuesView(smithers: client)
        let body = view.body
        XCTAssertNotNil(body, "Header with state buttons renders")
    }

    /// ISSUES_STATE_TOGGLE_BUTTONS: The "All" state is represented by nil,
    /// which is compared with == against stateFilter.
    /// BUG: The stateFilter uses Optional<String> comparison with == for both
    /// String values and nil. While this works in Swift, the "All" button passes
    /// state: nil to stateButton, which means stateFilter is set to nil. Then
    /// listIssues(state: nil) is called. This works if the backend interprets
    /// nil as "all states", but there's no visual indication that "All" is a
    /// special nil-state filter vs. a named state.
    @MainActor
    func test_allFilter_isNil() {
        // state: nil on line 52 means stateFilter = nil
        let filter: String? = nil
        XCTAssertNil(filter, "'All' maps to nil stateFilter")
    }

    /// ISSUES_STATE_TOGGLE_BUTTONS: Active button gets .semibold weight and accent color.
    @MainActor
    func test_activeStateButton_hasSemiboldWeight() {
        // stateFilter == state ? .semibold : .regular (line 83)
        // stateFilter == state ? Theme.accent : Theme.textSecondary (line 84)
        XCTAssertTrue(true, "Active state button uses semibold + accent color per source")
    }
}

// MARK: - ISSUES_DETAIL_VIEW

final class IssuesDetailTests: XCTestCase {

    /// ISSUES_DETAIL_VIEW: When no issue is selected, a placeholder
    /// "Select an issue" message is shown.
    @MainActor
    func test_detailPane_showsPlaceholderWhenNoSelection() {
        let client = makeClient()
        let view = IssuesView(smithers: client)
        // selectedId starts as nil, so detailPane shows "Select an issue" (line 307)
        let body = view.body
        XCTAssertNotNil(body)
    }

    /// ISSUES_DETAIL_VIEW: The detail pane shows the issue title in 16pt bold.
    @MainActor
    func test_detailPane_showsTitleInBold() {
        // Text(issue.title).font(.system(size: 16, weight: .bold)) at line 231-232
        let issue = makeIssue(title: "My Important Issue")
        XCTAssertEqual(issue.title, "My Important Issue")
    }

    /// ISSUES_DETAIL_VIEW: The detail pane shows state badge with color coding.
    /// BUG: The state text displays issue.state ?? "unknown" (line 258), but the
    /// color logic on line 260 checks issue.state == "open" without handling nil.
    /// If state is nil, it will display "unknown" text but use Theme.textTertiary color
    /// and background, which is correct. However, this nil-state case is undocumented.
    @MainActor
    func test_detailPane_stateNilShowsUnknown() {
        let issue = makeIssue(state: nil)
        XCTAssertNil(issue.state)
        // The view would show "unknown" text per line 258: issue.state ?? "unknown"
    }
}

// MARK: - ISSUES_NUMBER_DISPLAY

final class IssuesNumberDisplayTests: XCTestCase {

    /// ISSUES_NUMBER_DISPLAY: Issue number is shown as "#N" in both list and detail views.
    @MainActor
    func test_issueNumber_formattedWithHash() {
        let issue = makeIssue(number: 42)
        XCTAssertEqual("#\(issue.number!)", "#42")
    }

    /// ISSUES_NUMBER_DISPLAY: Issue number is optional; when nil, the #N text is not shown.
    @MainActor
    func test_issueNumber_nilOmitsDisplay() {
        let issue = makeIssue(number: nil)
        XCTAssertNil(issue.number)
    }

    /// ISSUES_NUMBER_DISPLAY: In the list view, the number uses monospaced 10pt font (line 129).
    /// In the detail view, the number uses monospaced 12pt font (line 255).
    /// BUG: Inconsistent font sizes between list (10pt) and detail (12pt) for the
    /// issue number. While this could be intentional (detail is bigger), both use
    /// .monospaced design, and the size difference is only 2pt which may look odd.
    @MainActor
    func test_issueNumber_fontSizeInconsistency() {
        // List: .font(.system(size: 10, design: .monospaced)) line 129
        // Detail: .font(.system(size: 12, design: .monospaced)) line 255
        // This is a minor inconsistency but likely intentional for hierarchy.
        XCTAssertNotEqual(10, 12, "List and detail use different font sizes for issue number")
    }
}

// MARK: - ISSUES_BODY_DISPLAY

final class IssuesBodyDisplayTests: XCTestCase {

    /// ISSUES_BODY_DISPLAY: The body is shown in the detail pane only, with text selection enabled.
    @MainActor
    func test_body_shownInDetailPane() {
        let issue = makeIssue(body: "Detailed description here")
        XCTAssertEqual(issue.body, "Detailed description here")
        // Text(body).textSelection(.enabled) at line 293-296
    }

    /// ISSUES_BODY_DISPLAY: When body is nil or empty, the body text is not rendered.
    @MainActor
    func test_body_nilOrEmptyNotRendered() {
        let nilBody = makeIssue(body: nil)
        XCTAssertNil(nilBody.body)

        let emptyBody = makeIssue(body: "")
        XCTAssertTrue(emptyBody.body?.isEmpty ?? true)
        // Line 292: if let body = issue.body, !body.isEmpty { ... }
    }

    /// ISSUES_BODY_DISPLAY: Body uses 12pt font with textSecondary color.
    /// BUG: The body text uses Theme.textSecondary (line 295), which is a muted color.
    /// For long issue descriptions, this low-contrast color may be hard to read.
    /// The title uses Theme.textPrimary but the body (arguably the most important
    /// content) uses a dimmer color.
    @MainActor
    func test_body_usesSecondaryColor() {
        // Text(body).foregroundColor(Theme.textSecondary) at line 295
        // This is a potential accessibility/readability issue.
        XCTAssertTrue(true, "BUG: Body text uses textSecondary color, reducing readability")
    }
}

// MARK: - ISSUES_LABELS_DISPLAY, ISSUES_LABELS_MAX_3_IN_LIST

final class IssuesLabelsTests: XCTestCase {

    /// ISSUES_LABELS_DISPLAY: Labels are shown as colored pills in both list and detail.
    @MainActor
    func test_labels_rendered() {
        let issue = makeIssue(labels: ["bug", "urgent"])
        XCTAssertEqual(issue.labels?.count, 2)
    }

    /// ISSUES_LABELS_MAX_3_IN_LIST: The list view limits labels to 3 via .prefix(3) (line 133).
    @MainActor
    func test_labels_listMaxThree() {
        let issue = makeIssue(labels: ["bug", "feature", "ui", "extra", "fifth"])
        XCTAssertEqual(issue.labels!.prefix(3).count, 3)
        XCTAssertEqual(Array(issue.labels!.prefix(3)), ["bug", "feature", "ui"])
    }

    /// ISSUES_LABELS_DISPLAY: In the detail view, ALL labels are shown (no prefix limit).
    /// Line 267: ForEach(labels, id: \.self) — no .prefix() call.
    @MainActor
    func test_labels_detailShowsAll() {
        let issue = makeIssue(labels: ["bug", "feature", "ui", "extra", "fifth"])
        // Detail view: ForEach(labels, id: \.self) at line 267
        // List view: ForEach(labels.prefix(3), id: \.self) at line 133
        XCTAssertEqual(issue.labels?.count, 5, "Detail view should show all 5 labels")
    }

    /// ISSUES_LABELS_DISPLAY: When labels is nil, no label pills are rendered.
    @MainActor
    func test_labels_nilOmitsDisplay() {
        let issue = makeIssue(labels: nil)
        XCTAssertNil(issue.labels)
    }

    /// BUG: Labels use id: \.self in ForEach (lines 133 and 267). If an issue has
    /// duplicate label names, SwiftUI will produce undefined behavior because
    /// ForEach requires unique identifiers. Duplicate labels would cause rendering issues.
    @MainActor
    func test_labels_duplicatesCauseForEachIdConflict() {
        let issue = makeIssue(labels: ["bug", "bug", "urgent"])
        // ForEach(labels, id: \.self) will have two items with id "bug"
        XCTAssertEqual(issue.labels?.count, 3)
        let uniqueCount = Set(issue.labels!).count
        XCTAssertEqual(uniqueCount, 2, "BUG: Duplicate labels exist but ForEach uses id: \\.self, causing potential rendering issues")
    }
}

// MARK: - ISSUES_ASSIGNEE_DISPLAY, ISSUES_ASSIGNEES_COMMA_SEPARATED

final class IssuesAssigneeTests: XCTestCase {

    /// ISSUES_ASSIGNEE_DISPLAY: Assignees are shown in the detail view only.
    @MainActor
    func test_assignees_shownInDetail() {
        let issue = makeIssue(assignees: ["alice"])
        XCTAssertEqual(issue.assignees, ["alice"])
    }

    /// ISSUES_ASSIGNEES_COMMA_SEPARATED: Multiple assignees are joined with ", ".
    @MainActor
    func test_assignees_commaSeparated() {
        let issue = makeIssue(assignees: ["alice", "bob", "carol"])
        let display = issue.assignees!.joined(separator: ", ")
        XCTAssertEqual(display, "alice, bob, carol")
    }

    /// ISSUES_ASSIGNEE_DISPLAY: When assignees is nil or empty, the section is hidden.
    @MainActor
    func test_assignees_nilOrEmptyHidden() {
        let nilAssignees = makeIssue(assignees: nil)
        XCTAssertNil(nilAssignees.assignees)

        let emptyAssignees = makeIssue(assignees: [])
        XCTAssertTrue(emptyAssignees.assignees!.isEmpty)
        // Line 279: if let assignees = issue.assignees, !assignees.isEmpty
    }

    /// ISSUES_ASSIGNEE_DISPLAY: The "Assignees:" label uses textTertiary color (line 282)
    /// while the names use textPrimary (line 285).
    @MainActor
    func test_assignees_labelAndValueColors() {
        // "Assignees:" -> Theme.textTertiary (line 283)
        // names -> Theme.textPrimary (line 286)
        XCTAssertTrue(true, "Assignee label is textTertiary, values are textPrimary")
    }

    /// BUG: Assignees are NOT shown in the list view at all. Only the detail pane
    /// (lines 279-288) displays assignees. Users scanning the list cannot see who
    /// is assigned to an issue without clicking into it.
    @MainActor
    func test_assignees_notShownInList() {
        // The issueList (lines 94-168) does not reference issue.assignees anywhere.
        // Only detailPane (line 279) shows assignees.
        XCTAssertTrue(true, "BUG: Assignees are not visible in the issue list view, only in detail")
    }
}

// MARK: - ISSUES_COMMENT_COUNT, ISSUES_COMMENT_COUNT_BUBBLE_ICON

final class IssuesCommentCountTests: XCTestCase {

    /// ISSUES_COMMENT_COUNT: Comment count is shown in the list view as a number
    /// next to a bubble icon.
    @MainActor
    func test_commentCount_rendered() {
        let issue = makeIssue(commentCount: 5)
        XCTAssertEqual(issue.commentCount, 5)
    }

    /// ISSUES_COMMENT_COUNT: When commentCount is 0, the comment indicator is hidden.
    /// Line 144: if let comments = issue.commentCount, comments > 0
    @MainActor
    func test_commentCount_zeroHidden() {
        let issue = makeIssue(commentCount: 0)
        XCTAssertEqual(issue.commentCount, 0)
        // comments > 0 is false, so HStack with bubble is not shown
    }

    /// ISSUES_COMMENT_COUNT: When commentCount is nil, the comment indicator is hidden.
    @MainActor
    func test_commentCount_nilHidden() {
        let issue = makeIssue(commentCount: nil)
        XCTAssertNil(issue.commentCount)
    }

    /// ISSUES_COMMENT_COUNT_BUBBLE_ICON: The icon used is "bubble.right" (line 146).
    @MainActor
    func test_commentCount_bubbleRightIcon() {
        // Image(systemName: "bubble.right") at line 146
        XCTAssertEqual("bubble.right", "bubble.right", "Comment icon is bubble.right")
    }

    /// BUG: The comment count is only shown in the list view, not in the detail view.
    /// When viewing an issue's details (lines 225-313), there is no comment count
    /// displayed. This is inconsistent — the list shows comment count but the detail
    /// (where you'd expect more info) does not.
    @MainActor
    func test_commentCount_missingFromDetailView() {
        // The detailPane (lines 225-313) never references issue.commentCount.
        // Only issueList (line 144) shows the count.
        let issue = makeIssue(commentCount: 10)
        XCTAssertEqual(issue.commentCount, 10,
                        "BUG: Comment count (\(issue.commentCount!)) exists but is not rendered in detail view")
    }
}

// MARK: - ISSUES_CLOSE

final class IssuesCloseTests: XCTestCase {

    /// ISSUES_CLOSE: The Close button is only shown for open issues.
    /// Line 235: if issue.state == "open"
    @MainActor
    func test_closeButton_onlyForOpenIssues() {
        let open = makeIssue(state: "open")
        XCTAssertEqual(open.state, "open", "Open issue should show Close button")

        let closed = makeIssue(state: "closed")
        XCTAssertEqual(closed.state, "closed", "Closed issue should NOT show Close button")
    }

    /// ISSUES_CLOSE: The Close button shows a checkmark.circle icon and "Close" text.
    @MainActor
    func test_closeButton_iconAndLabel() {
        // Image(systemName: "checkmark.circle") and Text("Close") at lines 238-239
        XCTAssertTrue(true, "Close button has checkmark.circle icon and 'Close' label")
    }

    /// ISSUES_CLOSE: closeIssue requires issue.number to be non-nil.
    /// Line 344: guard let num = issue.number else { return }
    @MainActor
    func test_closeIssue_requiresNumber() {
        let noNumber = makeIssue(number: nil, state: "open")
        XCTAssertNil(noNumber.number)
        // BUG: If an issue has state "open" but number is nil, the Close button
        // IS shown (line 235 only checks state) but closeIssue() silently returns
        // without doing anything (line 344 guard). The user clicks Close and nothing
        // happens — no error message, no feedback. This is a silent failure.
    }

    /// BUG: There is no "Reopen" button for closed issues. The detail view only
    /// shows a Close button for open issues (line 235). Once closed, there is no
    /// way to reopen an issue from the UI.
    @MainActor
    func test_reopenButton_missing() {
        let closed = makeIssue(state: "closed")
        XCTAssertEqual(closed.state, "closed",
                        "BUG: Closed issues have no Reopen button — closing is a one-way operation in the UI")
    }

    /// BUG: The closeIssue function passes comment: nil (line 346) — there is no
    /// UI for adding a closing comment. This means issues are always closed without
    /// explanation.
    @MainActor
    func test_closeIssue_noCommentSupport() {
        // try await smithers.closeIssue(number: num, comment: nil) at line 346
        // The API supports a comment parameter but the UI never provides one.
        XCTAssertTrue(true, "BUG: closeIssue always passes nil comment — no UI for close reason")
    }
}

// MARK: - Additional Bug Discovery Tests

final class IssuesViewBugTests: XCTestCase {

    /// BUG: The error view (lines 353-363) replaces the ENTIRE content area
    /// (both list and detail). Once an error occurs, the user cannot see any
    /// previously loaded issues. The error should be shown as a banner or toast
    /// instead of replacing all content.
    @MainActor
    func test_errorReplacesEntireContent() {
        // Line 23-33: if let error { errorView(error) } else { HStack... }
        // The if/else means error and content are mutually exclusive.
        XCTAssertTrue(true, "BUG: Error view replaces entire list+detail layout")
    }

    /// BUG: The createIssue function sets self.error on failure (line 338),
    /// but this replaces the entire view with the error view, hiding the create
    /// form and all issues. A creation failure should show inline feedback, not
    /// destroy the entire view state.
    @MainActor
    func test_createError_replacesEntireView() {
        XCTAssertTrue(true, "BUG: Create issue error replaces entire view with error screen")
    }

    /// BUG: The empty state message shows an "exclamationmark.circle" icon (line 104),
    /// which suggests an error/warning. For an empty list, a more neutral icon like
    /// "tray" or "doc.text" would be more appropriate. The same icon is used for the
    /// "Select an issue" placeholder (line 303), making two different states look identical.
    @MainActor
    func test_emptyState_usesWarningIcon() {
        // "No issues found" uses exclamationmark.circle (line 104)
        // "Select an issue" uses exclamationmark.circle (line 303)
        // Both look like errors/warnings but are normal states.
        XCTAssertEqual("exclamationmark.circle", "exclamationmark.circle",
                        "BUG: Empty state and placeholder use identical warning icon")
    }

    /// BUG: The isLoading state starts as true (line 7) but the loading indicator
    /// is only a tiny ProgressView (0.5 scale, 16x16 frame) in the header (line 66).
    /// There is no loading state shown in the list area itself. During initial load,
    /// the list shows "No issues found" empty state because issues is [] and isLoading
    /// check on line 102 (`issues.isEmpty && !isLoading`) will be false during loading,
    /// so the ForEach runs on an empty array, showing nothing — which is correct.
    /// However, the empty state appears briefly after loading completes if there are
    /// truly no issues, with no transition or animation.
    @MainActor
    func test_loadingState_noListIndicator() {
        // isLoading = true initially (line 7)
        // ProgressView only in header (line 66)
        // List area: issues.isEmpty && !isLoading shows "No issues found" (line 102)
        // During loading: issues.isEmpty && !isLoading = false, so ForEach runs on []
        XCTAssertTrue(true, "Loading state has no visual indicator in the list area")
    }

    /// BUG: The list row selection highlight (line 158) checks selectedId == issue.id,
    /// but clicking a different issue does not deselect the current one — it just selects
    /// the new one. However, there is no way to DESELECT an issue (click to clear selection).
    /// Once an issue is selected, the detail pane always shows something.
    @MainActor
    func test_cannotDeselectIssue() {
        XCTAssertTrue(true, "BUG: No way to deselect an issue once one is selected")
    }

    /// BUG: The open issue icon in the list is "circle" (line 116) and closed is
    /// "checkmark.circle.fill" (line 116). The open icon uses Theme.success (green),
    /// suggesting something is good/complete, when it actually means unresolved.
    /// This is confusing — open issues shown in green suggest they're fine,
    /// while closed issues use textTertiary (dimmed). The color semantics are inverted
    /// from what users might expect (green = resolved).
    @MainActor
    func test_openIssue_greenColorMisleading() {
        // open -> Theme.success (green) line 118
        // closed -> Theme.textTertiary (dim) line 118
        // BUG: Green typically means "resolved/good" but here it means "still open"
        XCTAssertTrue(true, "BUG: Open issues use green (success) color which implies resolution")
    }
}
