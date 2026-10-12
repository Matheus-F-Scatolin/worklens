import Foundation

/// The date titles the reader, the sidebar and the notifications show for a day or a week.
///
/// Derived from the period, never persisted, and written for the person reading them, so the
/// templates follow their locale.
public enum DayTitle {
    /// `Your day: Tuesday 9 September 2026`, `Your week: 31 August to 6 September 2026`.
    public static func of(
        kind: ReportKind,
        periodStart: String,
        periodEnd: String,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        switch kind {
        case .daily:
            return "Your day: \(longDay(periodStart, timeZone: timeZone, locale: locale))"
        case .weekly:
            let start = mediumDay(periodStart, timeZone: timeZone, locale: locale)
            let end = mediumDay(periodEnd, timeZone: timeZone, locale: locale)
            return "Your week: \(start) to \(end)"
        }
    }

    /// `Tuesday 9 September 2026`. Falls back to the `YYYY-MM-DD` it was given, which is still a
    /// day a reader can read.
    public static func longDay(
        _ day: String, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        format(day, template: "EEEEdMMMMy", timeZone: timeZone, locale: locale)
    }

    /// `Wed 9 Sept` — the sidebar row, where the year is the header's job.
    public static func shortDay(
        _ day: String, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        format(day, template: "EEEdMMM", timeZone: timeZone, locale: locale)
    }

    /// `9 September 2026`.
    public static func mediumDay(
        _ day: String, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        format(day, template: "dMMMMy", timeZone: timeZone, locale: locale)
    }

    /// The week's own heading: `Week of 31 August 2026`.
    public static func week(
        _ week: ISOWeek, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        "Week of \(mediumDay(week.start, timeZone: timeZone, locale: locale))"
    }

    private static func format(
        _ day: String, template: String, timeZone: TimeZone, locale: Locale
    ) -> String {
        guard let date = DayBoundaries.formatter(timeZone).date(from: day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // `setLocalizedDateFormatFromTemplate` rather than a literal pattern: the reader shows
        // these to a person, and "9 September" and "September 9" are both correct depending on
        // where they are.
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
