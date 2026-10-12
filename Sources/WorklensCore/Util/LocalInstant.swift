import Foundation

/// An instant typed on the command line (#324): `2026-10-06T15:00` is local time, and
/// `2026-10-06T15:00:00-03:00` or `…Z` is that instant wherever you are.
///
/// Accepted: `YYYY-MM-DDTHH:MM`, with optional `:SS`, a space in place of the `T`, and an
/// optional `Z` or `±HH:MM` offset. Anything else is nil, including a day or a time that does not
/// exist (`2026-02-30T10:00`, `25:00`).
public struct LocalInstant: Equatable, Sendable, CustomStringConvertible {
    public let date: Date
    public let text: String

    public var description: String { text }

    public init?(_ text: String, timeZone: TimeZone = .current) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: cleaned).map { String(cleaned[$0]) }
        }
        let numbers = (1...6).map { group($0).flatMap { Int($0) } }
        guard let year = numbers[0], let month = numbers[1], let day = numbers[2],
              let hour = numbers[3], let minute = numbers[4]
        else { return nil }
        let second = numbers[5] ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }

        var zone = timeZone
        if let offset = group(7)?.uppercased() {
            if offset == "Z" {
                zone = TimeZone(identifier: "UTC") ?? timeZone
            } else {
                let sign = offset.hasPrefix("-") ? -1 : 1
                let digits = offset.dropFirst().filter(\.isNumber)
                guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                      hours <= 23, minutes <= 59,
                      let fixed = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
                else { return nil }
                zone = fixed
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        // A day the calendar does not have rolls over; refuse it rather than move it.
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute
        else { return nil }
        self.date = date
        self.text = cleaned
    }
}
