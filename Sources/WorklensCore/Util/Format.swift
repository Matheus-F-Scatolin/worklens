import Foundation

/// Every number, clock and date a person reads, in one place (#157).
///
/// Two audiences, one helper. Anything that lands in a file, a prompt or a test fixture is
/// written in `Format.fixed` — `en_US_POSIX`, the locale this repository's golden files are in —
/// and comes out byte for byte the way it did before this type existed. Anything drawn on screen
/// is given the user's own locale instead, and Foundation then decides the decimal separator, the
/// currency symbol and whether the clock carries an AM.
///
/// The fixed branch is hand-rolled rather than a `NumberFormatter` set to `en_US_POSIX` on
/// purpose: that formatter produces `$ 0.00`, with a space, which is not what a single fixture,
/// golden file or menu test in this repository says.
///
/// What deliberately does **not** come through here: `SpendCSV` keeps its own fixed `%.4f`. Its
/// strings land in a file on disk, where a comma for a decimal point would change their meaning
/// and a developer's System Settings would change a test's outcome.
public enum Format {
    /// The one locale every artifact, prompt and test is written in.
    public static let fixed = Locale(identifier: "en_US_POSIX")

    /// True for the fixed locale, which takes the hand-rolled branch of every function below.
    static func isFixed(_ locale: Locale) -> Bool { locale.identifier == fixed.identifier }

    // MARK: Money

    /// `$0.19`, `$0.0042` — two decimals down to a cent, four below it, because one describe call
    /// costs a fraction of a cent and rounding a morning of them to `$0.00` reads as free.
    ///
    /// Always USD: Worklens is billed in dollars wherever it runs, so a Brazilian user sees
    /// `US$ 0,19` rather than a number that looks like reais.
    public static func money(_ usd: Double, locale: Locale = Format.fixed) -> String {
        let subCent = usd > 0 && usd < 0.01
        guard !isFixed(locale) else {
            return subCent
                ? "$\(String(format: "%.4f", usd))"
                : "$\(String(format: "%.2f", usd))"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = subCent ? 4 : 2
        formatter.maximumFractionDigits = subCent ? 4 : 2
        return formatter.string(from: usd as NSNumber) ?? money(usd, locale: fixed)
    }

    // MARK: Clocks and dates

    /// `14:05`, or `2:05 PM` where the user's region says so.
    public static func clock(
        _ date: Date, timeZone: TimeZone, locale: Locale = Format.fixed
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        if isFixed(locale) {
            formatter.locale = fixed
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.locale = locale
            // `j` is "the hour the way this region writes it", which is the whole point: a
            // hard-coded `HH` shows 24-hour time to somebody whose Mac is set to 12-hour.
            formatter.setLocalizedDateFormatFromTemplate("jm")
        }
        return formatter.string(from: date)
    }

    /// `3 Sep` — a day without its year, for a menu that only ever names recent days.
    public static func shortDate(
        _ date: Date, timeZone: TimeZone, locale: Locale = Format.fixed
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        if isFixed(locale) {
            formatter.locale = fixed
            formatter.dateFormat = "d MMM"
        } else {
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        }
        return formatter.string(from: date)
    }

    /// `7 Sep 2025` — a day *with* its year, for a date that is not necessarily recent.
    ///
    /// `shortDate` is sized for a menu that only ever names the last few days; a record of when
    /// the user last deleted a range can be a year old, and `7 Sep` would read as last week.
    public static func dateWithYear(
        _ date: Date, timeZone: TimeZone, locale: Locale = Format.fixed
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        if isFixed(locale) {
            formatter.locale = fixed
            formatter.dateFormat = "d MMM yyyy"
        } else {
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        }
        return formatter.string(from: date)
    }

    /// `Today`, `Yesterday`, or `10 Sep` for anything older. Capitalised, because every caller
    /// starts a line with it.
    public static func day(
        _ date: Date, now: Date = Date(), timeZone: TimeZone, locale: Locale = Format.fixed
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return shortDate(date, timeZone: timeZone, locale: locale)
    }

    // MARK: Cadence

    /// `60 s`, `5 min`, `2.5 min` — whichever reads better at the length a menu row has.
    ///
    /// The unit stays English; translating the app is not what this is. What the locale changes
    /// is the decimal separator, so a Brazilian user reads `2,5 min` rather than a number their
    /// keyboard cannot type.
    public static func cadence(_ seconds: Int, locale: Locale = Format.fixed) -> String {
        if seconds < 120 { return "\(seconds) s" }
        let minutes = Double(seconds) / 60
        if minutes == minutes.rounded() { return "\(Int(minutes)) min" }
        return "\(decimal(minutes, places: 1, locale: locale)) min"
    }

    /// A whole count with the user's grouping: `4,312`, `4.312`. #286's delete confirm names the
    /// number of screenshots, and `4312` is harder to read at a glance than it needs to be.
    public static func count(_ value: Int, locale: Locale = Format.fixed) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = true
        return formatter.string(from: value as NSNumber) ?? String(value)
    }

    /// `1–7 Sep`, `30 Aug – 5 Sep`, `7 Sep`: a span of days the way the user's region writes one,
    /// with the year only when the span leaves this year. `from` and `to` are any instants inside
    /// the first and the last day.
    public static func dayRange(
        from: Date, to: Date, now: Date = Date(), timeZone: TimeZone = .current,
        locale: Locale = Format.fixed
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let thisYear = calendar.component(.year, from: now)
        let withYear = calendar.component(.year, from: from) != thisYear
            || calendar.component(.year, from: to) != thisYear
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        formatter.dateTemplate = withYear ? "dMMMy" : "dMMM"
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.startOfDay(for: max(from, to))
        return NoEmDash.range(formatter.string(from: start, to: end))
    }

    /// A plain number with a fixed number of decimals, in the user's separators.
    public static func decimal(
        _ value: Double, places: Int, locale: Locale = Format.fixed
    ) -> String {
        guard !isFixed(locale) else { return String(format: "%.\(places)f", value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        return formatter.string(from: value as NSNumber) ?? String(format: "%.\(places)f", value)
    }
}
