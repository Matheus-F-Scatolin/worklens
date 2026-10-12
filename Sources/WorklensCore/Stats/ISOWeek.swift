import Foundation

/// An ISO-8601 week: Monday through Sunday, written `YYYY-Www`.
///
/// The ISO year is not always the calendar year — 2027-01-01 is a Friday and belongs to 2026-W53 —
/// so weeks are always resolved through `Calendar(identifier: .iso8601)` rather than by arithmetic
/// on the date string.
public struct ISOWeek: Sendable, Equatable {
    /// ISO week-numbering year, which can differ from the calendar year at a year boundary.
    public let year: Int
    public let week: Int
    /// Monday, `YYYY-MM-DD`.
    public let start: String
    /// Sunday, `YYYY-MM-DD`.
    public let end: String
    /// All seven days, Monday first.
    public let days: [String]

    public init(year: Int, week: Int, start: String, end: String, days: [String]) {
        self.year = year
        self.week = week
        self.start = start
        self.end = end
        self.days = days
    }

    /// `YYYY-Www`, e.g. `2026-W36`.
    public var identifier: String { String(format: "%04d-W%02d", year, week) }

    /// Human form for a prompt header: `2026-W36 (Mon 2026-08-31 – Sun 2026-09-06)`.
    public var description: String { "\(identifier) (Mon \(start) to Sun \(end))" }

    // MARK: Construction

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The week containing a local day. Nil if `day` is not `YYYY-MM-DD`.
    public static func containing(dayString: String, timeZone: TimeZone = .current) -> ISOWeek? {
        guard let date = DayBoundaries.formatter(timeZone).date(from: dayString) else { return nil }
        return containing(date, timeZone: timeZone)
    }

    public static func containing(_ date: Date, timeZone: TimeZone = .current) -> ISOWeek? {
        let calendar = calendar(timeZone)
        let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
        guard let year = components.yearForWeekOfYear, let week = components.weekOfYear else { return nil }
        return make(year: year, week: week, timeZone: timeZone)
    }

    /// Parses `2026-W36` (and the looser `2026W36`). Nil for anything else, or for a week number
    /// that does not exist in that year.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> ISOWeek? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "-", with: "")
        let parts = cleaned.split(separator: "W", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let year = Int(parts[0]), let week = Int(parts[1]),
              parts[0].count == 4, (1...53).contains(week)
        else { return nil }
        return make(year: year, week: week, timeZone: timeZone)
    }

    /// Nil when the year has no such week (only ever week 53).
    static func make(year: Int, week: Int, timeZone: TimeZone) -> ISOWeek? {
        let calendar = calendar(timeZone)
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = week
        components.weekday = 2  // Monday, in the ISO calendar's 1 = Sunday numbering.
        guard let monday = calendar.date(from: components) else { return nil }
        // A 53rd week that does not exist rolls into week 1 of the next year; reject that.
        let resolved = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: monday)
        guard resolved.weekOfYear == week, resolved.yearForWeekOfYear == year else { return nil }

        let formatter = DayBoundaries.formatter(timeZone)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
            .map(formatter.string(from:))
        guard days.count == 7 else { return nil }
        return ISOWeek(year: year, week: week, start: days[0], end: days[6], days: days)
    }

    /// The week before this one.
    public func previous(timeZone: TimeZone = .current) -> ISOWeek? {
        let calendar = ISOWeek.calendar(timeZone)
        guard let monday = DayBoundaries.formatter(timeZone).date(from: start),
              let earlier = calendar.date(byAdding: .day, value: -7, to: monday)
        else { return nil }
        return ISOWeek.containing(earlier, timeZone: timeZone)
    }
}
