import Foundation

/// A local calendar day, `YYYY-MM-DD`, parsed once instead of by every command that takes one.
///
/// Days are still plain `String`s everywhere below the CLI — this type exists so that six
/// commands stop carrying their own `DayBoundaries.range(day:) != nil` check with three
/// different error wordings, and so that `today`, `yesterday` and `-N` mean the same thing in
/// all of them.
public struct LocalDay: Equatable, Sendable, CustomStringConvertible {
    /// `YYYY-MM-DD`, always a day the calendar has.
    public let string: String

    public var description: String { string }

    private init(validated string: String) {
        self.string = string
    }

    /// Nil for anything that is not a day this accepts.
    ///
    /// Accepted: `YYYY-MM-DD`, `today`, `yesterday`, and a non-positive integer offset in days
    /// (`0` is today, `-3` is three days ago). The offsets only go backwards: a day that has not
    /// happened has nothing in it to report on, and `3` is far more likely to be a typo than a
    /// request for Thursday.
    public init?(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) {
        let cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch cleaned {
        case "today":
            self.init(validated: DayBoundaries.dayString(now, timeZone: timeZone))
        case "yesterday":
            guard let day = LocalDay.shift(now, by: -1, timeZone: timeZone) else { return nil }
            self.init(validated: day)
        default:
            if let offset = Int(cleaned), offset <= 0 {
                guard let day = LocalDay.shift(now, by: offset, timeZone: timeZone) else { return nil }
                self.init(validated: day)
                return
            }
            guard let day = LocalDay.normalize(cleaned, timeZone: timeZone) else { return nil }
            self.init(validated: day)
        }
    }

    /// `YYYY-MM-DD` back, or nil.
    ///
    /// The formatter behind `DayBoundaries.range(day:)` — which is what the six hand-written
    /// checks this type replaces each called — resolves `2026-02-30` to 2 March rather than
    /// refusing it, so every one of them accepted a day that does not exist and then reported on
    /// nothing. Comparing the numbers written with the numbers that came back rejects that while
    /// still accepting a real day written loosely: `2026-9-7` disagrees only about zero padding,
    /// and comes back padded.
    private static func normalize(_ text: String, timeZone: TimeZone) -> String? {
        guard let date = DayBoundaries.formatter(timeZone).date(from: text) else { return nil }
        let resolved = DayBoundaries.dayString(date, timeZone: timeZone)
        let written = text.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        let round = resolved.split(separator: "-").compactMap { Int($0) }
        guard written.count == 3, written == round else { return nil }
        return resolved
    }

    public static func today(now: Date = Date(), timeZone: TimeZone = .current) -> LocalDay {
        LocalDay(validated: DayBoundaries.dayString(now, timeZone: timeZone))
    }

    /// Calendar arithmetic rather than 86 400 seconds: a day with a DST change is not 24 hours
    /// long, and "yesterday" on the morning after one would otherwise land on today again.
    private static func shift(_ date: Date, by days: Int, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return DayBoundaries.dayString(shifted, timeZone: timeZone)
    }

    /// What the `--date` help line says, everywhere it appears.
    public static let argumentHelp =
        "Local day: YYYY-MM-DD, today, yesterday, or --date=-N for N days back. Defaults to today."
}
