import Foundation

/// Days in Worklens are local calendar days written `YYYY-MM-DD`; timestamps in the database are
/// absolute. These helpers are the only place that conversion happens.
public enum DayBoundaries {
    public static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// `YYYY-MM-DD` for the local day containing `date`.
    public static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone).string(from: date)
    }

    /// The half-open instant range `[start, end)` covering a local day. Nil if `day` is malformed.
    public static func range(day: String, timeZone: TimeZone = .current) -> (start: Date, end: Date)? {
        guard let start = formatter(timeZone).date(from: day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// `day` moved by whole local days.
    public static func shift(day: String, by offset: Int, timeZone: TimeZone) -> String? {
        guard let start = range(day: day, timeZone: timeZone)?.start else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let moved = calendar.date(byAdding: .day, value: offset, to: start) else {
            return nil
        }
        return dayString(moved, timeZone: timeZone)
    }
}
