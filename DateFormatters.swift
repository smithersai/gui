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

    static func parseISO8601InternetDateTime(_ value: String) -> Date? {
        iso8601InternetDateTimeWithFractionalSeconds.date(from: value) ?? iso8601InternetDateTime.date(from: value)
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
}
