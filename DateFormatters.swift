import Foundation

enum DateFormatters {
    enum Pattern {
        static let hourMinute = "h:mm a"
        static let hourMinuteSecond = "HH:mm:ss"
        static let hourMinuteSecondMillisecond = "HH:mm:ss.SSS"
        static let monthDayHourMinute = "MM/dd HH:mm"
        static let yearMonthDay = "yyyy-MM-dd"
        static let yearMonthDayHourMinute = "yyyy-MM-dd HH:mm"
        static let yearMonthDayHourMinuteSecond = "yyyy-MM-dd HH:mm:ss"
        static let compactYearMonthDayHourMinute = "yyyyMMdd-HHmm"
        static let fileYearMonthDayHourMinuteSecond = "yyyy-MM-dd-HHmmss"
    }

    static let iso8601InternetDateTimeWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601InternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let relativeShort: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static let localizedShortDateShortTime = localizedFormatter(dateStyle: .short, timeStyle: .short)
    static let localizedShortDateMediumTime = localizedFormatter(dateStyle: .short, timeStyle: .medium)
    static let localizedMediumDateShortTime = localizedFormatter(dateStyle: .medium, timeStyle: .short)

    static let hourMinute = fixedFormatter(Pattern.hourMinute)
    static let hourMinuteSecond = fixedFormatter(Pattern.hourMinuteSecond)
    static let hourMinuteSecondMillisecond = fixedFormatter(Pattern.hourMinuteSecondMillisecond)
    static let monthDayHourMinute = fixedFormatter(Pattern.monthDayHourMinute)
    static let yearMonthDay = fixedFormatter(Pattern.yearMonthDay)
    static let yearMonthDayHourMinute = fixedFormatter(Pattern.yearMonthDayHourMinute)
    static let yearMonthDayHourMinuteSecond = fixedFormatter(Pattern.yearMonthDayHourMinuteSecond)
    static let compactYearMonthDayHourMinute = fixedFormatter(Pattern.compactYearMonthDayHourMinute)
    static let fileYearMonthDayHourMinuteSecond = fixedFormatter(Pattern.fileYearMonthDayHourMinuteSecond)
    private static let relativeAgoComponentRegex = try! NSRegularExpression(pattern: #"(\d+)\s*([a-zA-Z]+)"#)

    static func parseISO8601InternetDateTime(_ value: String) -> Date? {
        iso8601InternetDateTimeWithFractionalSeconds.date(from: value) ?? iso8601InternetDateTime.date(from: value)
    }

    static func parseRelativeAgoDate(_ value: String, referenceDate: Date = Date()) -> Date? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: " ")
        guard !normalized.isEmpty else {
            return nil
        }

        if normalized == "now" || normalized == "just now" {
            return referenceDate
        }

        guard normalized.hasSuffix("ago") else {
            return nil
        }

        let body = String(normalized.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return nil
        }

        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = relativeAgoComponentRegex.matches(in: body, range: range)
        guard !matches.isEmpty else {
            return nil
        }

        var totalSeconds: Int64 = 0
        var matchedAnyComponent = false
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: body),
                  let unitRange = Range(match.range(at: 2), in: body),
                  let amount = Int64(body[valueRange]),
                  amount >= 0,
                  let unitSeconds = relativeAgoUnitSeconds(String(body[unitRange])) else {
                continue
            }
            matchedAnyComponent = true
            totalSeconds += amount * unitSeconds
        }

        guard matchedAnyComponent else {
            return nil
        }
        return referenceDate.addingTimeInterval(-Double(totalSeconds))
    }

    static func parseRelativeAgoTimestampMs(_ value: String, referenceDate: Date = Date()) -> Int64? {
        guard let date = parseRelativeAgoDate(value, referenceDate: referenceDate) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func localizedFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    private static func fixedFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter
    }

    private static func relativeAgoUnitSeconds(_ unitToken: String) -> Int64? {
        switch unitToken {
        case "s", "sec", "secs", "second", "seconds":
            return 1
        case "m", "min", "mins", "minute", "minutes":
            return 60
        case "h", "hr", "hrs", "hour", "hours":
            return 60 * 60
        case "d", "day", "days":
            return 60 * 60 * 24
        case "w", "wk", "wks", "week", "weeks":
            return 60 * 60 * 24 * 7
        case "mo", "mos", "month", "months":
            return 60 * 60 * 24 * 30
        case "y", "yr", "yrs", "year", "years":
            return 60 * 60 * 24 * 365
        default:
            return nil
        }
    }
}
