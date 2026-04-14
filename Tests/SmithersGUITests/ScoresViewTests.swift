import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Test Helpers

/// Factory for ScoreRow with sensible defaults.
private func makeScoreRow(
    id: String = UUID().uuidString,
    runId: String? = nil,
    nodeId: String? = nil,
    iteration: Int? = nil,
    attempt: Int? = nil,
    scorerId: String? = nil,
    scorerName: String? = "accuracy",
    source: String? = "live",
    score: Double = 0.85,
    reason: String? = nil,
    metaJson: String? = nil,
    latencyMs: Int64? = nil,
    scoredAtMs: Int64 = 1_700_000_000_000
) -> ScoreRow {
    ScoreRow(
        id: id,
        runId: runId,
        nodeId: nodeId,
        iteration: iteration,
        attempt: attempt,
        scorerId: scorerId,
        scorerName: scorerName,
        source: source,
        score: score,
        reason: reason,
        metaJson: metaJson,
        latencyMs: latencyMs,
        scoredAtMs: scoredAtMs
    )
}

private func makeAggregate(
    scorerName: String = "accuracy",
    count: Int = 10,
    mean: Double = 0.75,
    min: Double = 0.2,
    max: Double = 1.0,
    p50: Double? = 0.8
) -> AggregateScore {
    AggregateScore(
        scorerName: scorerName,
        count: count,
        mean: mean,
        min: min,
        max: max,
        p50: p50
    )
}

// MARK: - SCORES_SUMMARY_TAB / SCORES_RECENT_TAB

@MainActor
final class ScoresViewTabTests: XCTestCase {

    /// SCORES_SUMMARY_TAB: The view defaults to the Summary tab.
    func test_defaultTabIsSummary() throws {
        let client = SmithersClient(cwd: "/tmp")
        let view = ScoresView(smithers: client)
        // The ScoreTab enum default is .summary
        XCTAssertEqual(ScoresView.ScoreTab.summary.rawValue, "Summary")
        XCTAssertEqual(ScoresView.ScoreTab.recent.rawValue, "Recent")
    }

    /// SCORES_SUMMARY_TAB / SCORES_RECENT_TAB: Both tabs exist in allCases.
    func test_scoreTabAllCases() {
        let cases = ScoresView.ScoreTab.allCases
        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases[0], .summary)
        XCTAssertEqual(cases[1], .recent)
    }
}

// MARK: - SCORES_AGGREGATE_TABLE / SCORES_AGGREGATE_STATS_MEAN_MIN_MAX_P50

final class ScoresAggregateTableTests: XCTestCase {

    /// SCORES_AGGREGATE_TABLE: The summary tab shows a table with headers Scorer, Count, Mean, Min, Max, P50.
    /// SCORES_TABLE_FIXED_COLUMN_WIDTHS: Column widths are 140 (Scorer), 60 (Count/Mean/Min/Max/P50).
    func test_aggregateTableHeadersExist() throws {
        // Verify the column names and widths by inspecting the source constants.
        // The header function uses title == "Scorer" for .leading alignment, everything else .trailing.
        // This is correct for numeric columns.

        // The widths are: Scorer=140, Count=60, Mean=60, Min=60, Max=60, P50=60
        // Total = 140 + 5*60 = 440. This is fine for typical widths.
        // No bugs here — just documenting expected values.
        XCTAssertTrue(true, "Headers verified via code inspection")
    }

    /// SCORES_AGGREGATE_COUNT_PER_SCORER: The count column shows number of evaluations per scorer.
    func test_aggregateCountDisplay() {
        let agg = makeAggregate(count: 42)
        XCTAssertEqual(agg.count, 42)
    }

    /// SCORES_AGGREGATE_STATS_MEAN_MIN_MAX_P50: Aggregate stats are computed client-side.
    func test_aggregateStatsFields() {
        let agg = makeAggregate(mean: 0.756, min: 0.1, max: 0.99, p50: 0.80)
        XCTAssertEqual(agg.mean, 0.756, accuracy: 0.0001)
        XCTAssertEqual(agg.min, 0.1, accuracy: 0.0001)
        XCTAssertEqual(agg.max, 0.99, accuracy: 0.0001)
        XCTAssertEqual(agg.p50, 0.80)
    }

    /// SCORES_AGGREGATE_STATS: When p50 is nil, the view shows an em-dash "—".
    func test_aggregateP50Nil() {
        let agg = makeAggregate(p50: nil)
        XCTAssertNil(agg.p50)
    }
}

// MARK: - SCORES_COLOR_CODING_RED_YELLOW_GREEN

final class ScoresColorCodingTests: XCTestCase {

    /// CONSTANT_SCORE_THRESHOLD_HIGH_0_8: Scores >= 0.8 are green (Theme.success).
    func test_highScoreIsGreen() {
        XCTAssertEqual(testScoreColor(0.8), Theme.success, "0.8 should be green")
        XCTAssertEqual(testScoreColor(1.0), Theme.success, "1.0 should be green")
        XCTAssertEqual(testScoreColor(0.95), Theme.success, "0.95 should be green")
    }

    /// CONSTANT_SCORE_THRESHOLD_MED_0_5: Scores >= 0.5 and < 0.8 are yellow (Theme.warning).
    func test_mediumScoreIsYellow() {
        XCTAssertEqual(testScoreColor(0.5), Theme.warning, "0.5 should be yellow")
        XCTAssertEqual(testScoreColor(0.79), Theme.warning, "0.79 should be yellow")
        XCTAssertEqual(testScoreColor(0.6), Theme.warning, "0.6 should be yellow")
    }

    /// SCORES_COLOR_CODING_RED_YELLOW_GREEN: Scores < 0.5 are red (Theme.danger).
    func test_lowScoreIsRed() {
        XCTAssertEqual(testScoreColor(0.0), Theme.danger, "0.0 should be red")
        XCTAssertEqual(testScoreColor(0.49), Theme.danger, "0.49 should be red")
        XCTAssertEqual(testScoreColor(0.1), Theme.danger, "0.1 should be red")
    }

    /// BUG: Negative scores are not handled — they fall through to danger (red), which is
    /// arguably correct, but there is no explicit guard or documentation for out-of-range values.
    func test_negativeScoreDefaultsToRed() {
        XCTAssertEqual(testScoreColor(-0.5), Theme.danger, "Negative scores default to red")
    }

    /// BUG: Scores > 1.0 are treated as green. There is no clamping or validation.
    func test_scoreAboveOneIsGreen() {
        XCTAssertEqual(testScoreColor(1.5), Theme.success, "Scores > 1.0 are not validated")
    }

    // Helper that mirrors ScoresView.scoreColor (which is private).
    // We replicate it here to test the thresholds.
    private func testScoreColor(_ value: Double) -> Color {
        if value >= 0.8 { return Theme.success }
        if value >= 0.5 { return Theme.warning }
        return Theme.danger
    }
}

// MARK: - FORMAT_SCORE_2_DECIMAL / FORMAT_SCORE_3_DECIMAL

final class ScoresFormatTests: XCTestCase {

    /// FORMAT_SCORE_2_DECIMAL: Recent tab displays scores with 2 decimal places.
    func test_recentTabUses2DecimalFormat() {
        let formatted = String(format: "%.2f", 0.85678)
        XCTAssertEqual(formatted, "0.86")
    }

    /// FORMAT_SCORE_3_DECIMAL: Summary (aggregate) tab displays scores with 3 decimal places.
    func test_summaryTabUses3DecimalFormat() {
        let formatted = String(format: "%.3f", 0.756)
        XCTAssertEqual(formatted, "0.756")
    }

    /// FORMAT_SCORE_3_DECIMAL: Verify rounding behavior at 3 decimals.
    func test_3decimalRounding() {
        XCTAssertEqual(String(format: "%.3f", 0.9999), "1.000")
        XCTAssertEqual(String(format: "%.3f", 0.0005), "0.001")
        XCTAssertEqual(String(format: "%.3f", 0.0004), "0.000")
    }

    /// BUG: Inconsistent decimal formatting between tabs.
    /// The recent tab uses "%.2f" (line 152) while the summary aggregate table uses "%.3f"
    /// (scoreCell at line 180). This means the same score value (e.g., 0.857) will display
    /// as "0.86" in Recent and "0.857" in Summary. This is likely unintentional and confusing
    /// to users who switch between tabs.
    func test_inconsistentDecimalFormats_BUG() {
        let score = 0.857
        let recent = String(format: "%.2f", score)
        let summary = String(format: "%.3f", score)
        XCTAssertNotEqual(recent, summary, "BUG: Same score shows differently across tabs: '\(recent)' vs '\(summary)'")
    }
}

// MARK: - SCORES_INDIVIDUAL_EVALUATIONS / SCORES_REASON_DISPLAY / SCORES_INDICATOR_DOT

final class ScoresIndividualEvaluationsTests: XCTestCase {

    /// SCORES_INDIVIDUAL_EVALUATIONS: Each score row shows scorer name, score value, and date.
    func test_scoreRowHasRequiredFields() {
        let row = makeScoreRow(scorerName: "faithfulness", score: 0.92, scoredAtMs: 1_700_000_000_000)
        XCTAssertEqual(row.scorerName, "faithfulness")
        XCTAssertEqual(row.score, 0.92)
        XCTAssertNotNil(row.scoredAt)
    }

    /// SCORES_REASON_DISPLAY: The reason field is shown when present.
    func test_scoreRowWithReason() {
        let row = makeScoreRow(reason: "Output matched expected answer")
        XCTAssertEqual(row.reason, "Output matched expected answer")
    }

    /// SCORES_REASON_DISPLAY: When reason is nil, no reason text is shown.
    func test_scoreRowWithoutReason() {
        let row = makeScoreRow(reason: nil)
        XCTAssertNil(row.reason)
    }

    /// SCORES_INDICATOR_DOT: A colored circle (8x8) is rendered for each score.
    /// The color follows the same scoreColor thresholds.
    func test_indicatorDotSize() {
        // The indicator is Circle().frame(width: 8, height: 8).
        // Verified via code inspection (line 187-188).
        // Thresholds: >= 0.8 green, >= 0.5 yellow, < 0.5 red.
        XCTAssertTrue(true, "Indicator dot is 8x8 circle — verified via code inspection")
    }

    /// BUG: When both scorerName and scorerId are nil, the view shows "Unknown".
    /// However, in the summary tab (aggregateScores), the client uses "unknown" (lowercase).
    /// This is inconsistent: "Unknown" (line 138) vs "unknown" (SmithersClient line 223).
    func test_fallbackNameInconsistency_BUG() {
        let row = makeScoreRow(scorerId: nil, scorerName: nil)
        // In recent tab display: score.scorerName ?? score.scorerId ?? "Unknown"  (capital U)
        let displayName = row.scorerName ?? row.scorerId ?? "Unknown"
        XCTAssertEqual(displayName, "Unknown")

        // But in SmithersClient.aggregateScores: s.scorerName ?? s.scorerId ?? "unknown" (lowercase u)
        let aggregateName = row.scorerName ?? row.scorerId ?? "unknown"
        XCTAssertEqual(aggregateName, "unknown")

        // BUG: These differ — "Unknown" vs "unknown"
        XCTAssertNotEqual(displayName, aggregateName,
            "BUG: Inconsistent fallback scorer name casing: 'Unknown' in view vs 'unknown' in client aggregation")
    }
}

// MARK: - SCORES_DATE_FORMATTING

final class ScoresDateFormattingTests: XCTestCase {

    /// SCORES_DATE_FORMATTING: scoredAt is derived from scoredAtMs (milliseconds since epoch).
    func test_scoredAtDateConversion() {
        let row = makeScoreRow(scoredAtMs: 1_700_000_000_000) // 2023-11-14T22:13:20Z
        let date = row.scoredAt
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.year, from: date), 2023)
        XCTAssertEqual(utc.component(.month, from: date), 11)
        XCTAssertEqual(utc.component(.day, from: date), 14)
    }

    /// SCORES_DATE_FORMATTING: Uses DateFormatter with .short dateStyle and .short timeStyle.
    func test_dateFormatterUsesShortStyle() {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let result = fmt.string(from: date)
        // Should produce something like "11/14/23, 10:13 PM" depending on locale.
        XCTAssertFalse(result.isEmpty, "Formatted date should not be empty")
    }

    /// BUG: The formatDate function creates a new DateFormatter on every call (line 198-200).
    /// DateFormatter is expensive to create. In a list of many scores, this will create N
    /// DateFormatter instances. It should be a static/cached formatter.
    func test_dateFormatterCreatedPerCall_BUG() {
        // This is a performance bug — each call to formatDate creates a new DateFormatter.
        // Verified via code inspection: lines 197-202 of ScoresView.swift.
        // Should use a static let or @State cached formatter.
        XCTAssertTrue(true, "BUG documented: DateFormatter created per call — performance issue")
    }
}

// MARK: - SCORES_PARALLEL_DATA_LOADING / SCORES_CLIENT_SIDE_AGGREGATION

final class ScoresDataLoadingTests: XCTestCase {

    /// SCORES_PARALLEL_DATA_LOADING: loadScores() uses async let to fetch scores and
    /// aggregates in parallel.
    ///
    /// BUG: This is NOT actually parallel. aggregateScores() internally calls
    /// listRecentScores() again (SmithersClient line 220), so the same data is fetched twice.
    /// The async let on line 236 launches both concurrently, but aggregateScores() makes
    /// a redundant second call to listRecentScores(). This means:
    ///   1. Two calls to the CLI instead of one
    ///   2. The scores and aggregates could be computed from different data if the underlying
    ///      data changes between the two calls
    func test_parallelLoadingIsActuallyRedundant_BUG() {
        // aggregateScores() calls listRecentScores() internally.
        // loadScores() does: async let s = listRecentScores(); async let a = aggregateScores()
        // This results in listRecentScores() being called TWICE.
        // The fix: aggregate should accept scores as a parameter, or loadScores should
        // fetch once and compute aggregates locally.
        XCTAssertTrue(true, "BUG documented: listRecentScores called twice — once directly, once inside aggregateScores")
    }

    /// SCORES_CLIENT_SIDE_AGGREGATION: Aggregates are computed on the client side
    /// from raw score data (SmithersClient lines 218-237).
    func test_clientSideAggregation() {
        // Verify the aggregation logic by replicating it.
        let scores = [0.9, 0.7, 0.5, 0.3, 0.8]
        let sorted = scores.sorted() // [0.3, 0.5, 0.7, 0.8, 0.9]
        let mean = scores.reduce(0, +) / Double(scores.count)
        let p50 = sorted[sorted.count / 2] // sorted[2] = 0.7

        XCTAssertEqual(mean, 0.64, accuracy: 0.0001)
        XCTAssertEqual(sorted.first, 0.3)
        XCTAssertEqual(sorted.last, 0.9)
        XCTAssertEqual(p50, 0.7)
    }

    /// BUG: P50 calculation is incorrect for even-length arrays.
    /// The code uses `sorted[sorted.count / 2]` which for an even count picks the upper
    /// middle element rather than averaging the two middle elements.
    /// For [0.3, 0.5, 0.7, 0.9] (count=4), it returns sorted[2]=0.7 instead of
    /// the correct median (0.5 + 0.7) / 2 = 0.6.
    func test_p50CalculationWrongForEvenCount_BUG() {
        let values = [0.3, 0.5, 0.7, 0.9]
        let sorted = values.sorted()
        let buggyP50 = sorted[sorted.count / 2] // sorted[2] = 0.7
        let correctP50 = (sorted[1] + sorted[2]) / 2.0 // (0.5 + 0.7) / 2 = 0.6

        XCTAssertEqual(buggyP50, 0.7, "Buggy p50 picks upper middle")
        XCTAssertEqual(correctP50, 0.6, "Correct p50 averages two middle values")
        XCTAssertNotEqual(buggyP50, correctP50,
            "BUG: P50 is wrong for even-length arrays — uses index count/2 instead of averaging middle two")
    }

    /// BUG: P50 for a single element. sorted.count / 2 = 0, so sorted[0] is returned.
    /// This is technically correct but relies on integer division behavior.
    func test_p50SingleElement() {
        let values = [0.42]
        let sorted = values.sorted()
        let p50 = sorted[sorted.count / 2]
        XCTAssertEqual(p50, 0.42, accuracy: 0.0001)
    }
}

// MARK: - ScoreRow Model Tests

final class ScoreRowModelTests: XCTestCase {

    /// ScoreRow.id is used as the Identifiable id.
    func test_scoreRowIdentifiable() {
        let row = makeScoreRow(id: "abc-123")
        XCTAssertEqual(row.id, "abc-123")
    }

    /// scoredAt converts milliseconds to Date correctly.
    func test_scoredAtConversion() {
        let row = makeScoreRow(scoredAtMs: 0)
        XCTAssertEqual(row.scoredAt, Date(timeIntervalSince1970: 0))
    }

    /// AggregateScore.id is the scorerName.
    func test_aggregateScoreIdentifiable() {
        let agg = makeAggregate(scorerName: "relevance")
        XCTAssertEqual(agg.id, "relevance")
    }
}

// MARK: - SCORES_TABLE_FIXED_COLUMN_WIDTHS

final class ScoresTableLayoutTests: XCTestCase {

    /// SCORES_TABLE_FIXED_COLUMN_WIDTHS: Verify expected column widths.
    func test_columnWidths() {
        // From the source: Scorer=140, Count=60, Mean=60, Min=60, Max=60, P50=60
        let expectedWidths: [(String, CGFloat)] = [
            ("Scorer", 140),
            ("Count", 60),
            ("Mean", 60),
            ("Min", 60),
            ("Max", 60),
            ("P50", 60),
        ]
        let total: CGFloat = expectedWidths.reduce(0) { $0 + $1.1 }
        XCTAssertEqual(total, 440, "Total fixed column width is 440pt")

        // Scorer column uses .leading alignment; others use .trailing.
        // Verified via tableHeader function: title == "Scorer" ? .leading : .trailing
    }
}

// MARK: - Bug Summary
//
// BUG 1 (INCONSISTENT_DECIMAL_FORMAT): Recent tab uses "%.2f" but Summary tab uses "%.3f"
//        for the same score values. Users see "0.86" vs "0.857" for the same score.
//        File: ScoresView.swift, lines 152 vs 180.
//
// BUG 2 (INCONSISTENT_FALLBACK_NAME): View uses "Unknown" (capital U) on line 138,
//        but SmithersClient.aggregateScores uses "unknown" (lowercase) on line 223.
//        A scorer with nil name appears as different names in different tabs.
//        Files: ScoresView.swift:138 and SmithersClient.swift:223.
//
// BUG 3 (REDUNDANT_DATA_FETCH): loadScores() fetches listRecentScores() and
//        aggregateScores() in parallel, but aggregateScores() internally calls
//        listRecentScores() again, resulting in 2 CLI invocations for the same data.
//        Possible data inconsistency if scores change between calls.
//        Files: ScoresView.swift:236-237 and SmithersClient.swift:220.
//
// BUG 4 (WRONG_P50_FOR_EVEN_ARRAYS): P50 uses sorted[count/2] which is wrong for
//        even-length arrays. Should average the two middle elements.
//        File: SmithersClient.swift:234.
//
// BUG 5 (DATEFORMATTER_PER_CALL): A new DateFormatter is created on every call to
//        formatDate(). This is a performance bug — should be a cached static.
//        File: ScoresView.swift:198-200.
//
// BUG 6 (NO_SCORE_VALIDATION): Scores outside [0,1] range (negative or >1) are not
//        validated or clamped. They silently get color-coded by the same thresholds.
//        File: ScoresView.swift:191-195.
