import Foundation

/// What the sidebar is pointing at.
public enum ReaderSelection: Hashable, Sendable {
    /// A local day, `YYYY-MM-DD`.
    case day(String)
    /// A week, by its Monday. The week header's own row.
    case week(String)
}

/// One day in the sidebar.
public struct ReaderDay: Equatable, Sendable, Identifiable {
    public let day: String
    /// `Wed 9 Sept` — the year belongs to the week header above it.
    public let title: String
    /// `2h 15m · 84 frames`, or what there is of it.
    public let subtitle: String
    public let hasTimeline: Bool
    public let frames: Int
    public let activeMinutes: Int

    public init(
        day: String,
        title: String,
        subtitle: String,
        hasTimeline: Bool,
        frames: Int,
        activeMinutes: Int
    ) {
        self.day = day
        self.title = title
        self.subtitle = subtitle
        self.hasTimeline = hasTimeline
        self.frames = frames
        self.activeMinutes = activeMinutes
    }

    public var id: String { day }
    public var selection: ReaderSelection { .day(day) }
}

/// One ISO week: the header row, and the days under it.
public struct ReaderWeek: Equatable, Sendable, Identifiable {
    /// The Monday, `YYYY-MM-DD`.
    public let monday: String
    /// `2026-W36`, for anyone who thinks in week numbers.
    public let identifier: String
    /// `Week of 31 August 2026`.
    public let title: String
    public let days: [ReaderDay]

    public init(
        monday: String,
        identifier: String,
        title: String,
        days: [ReaderDay]
    ) {
        self.monday = monday
        self.identifier = identifier
        self.title = title
        self.days = days
    }

    public var id: String { monday }
    public var selection: ReaderSelection { .week(monday) }
}

/// Turns the day index into the sidebar's rows. Pure, so the whole sidebar is testable without a
/// window.
public enum ReaderIndex {
    /// Newest week first, and newest day first inside it — the reader opens on what just
    /// happened, not on the beginning of recorded time.
    public static func weeks(
        entries: [DayIndexEntry],
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> [ReaderWeek] {
        var order: [String] = []
        var grouped: [String: [ReaderDay]] = [:]
        var weeks: [String: ISOWeek] = [:]

        for entry in entries.sorted(by: { $0.day > $1.day }) {
            guard let week = ISOWeek.containing(dayString: entry.day, timeZone: timeZone) else {
                continue
            }
            if grouped[week.start] == nil {
                order.append(week.start)
                weeks[week.start] = week
            }
            grouped[week.start, default: []].append(
                day(entry, timeZone: timeZone, locale: locale)
            )
        }

        return order.compactMap { monday in
            guard let week = weeks[monday] else { return nil }
            return ReaderWeek(
                monday: monday,
                identifier: week.identifier,
                title: DayTitle.week(week, timeZone: timeZone, locale: locale),
                days: grouped[monday] ?? []
            )
        }
    }

    static func day(
        _ entry: DayIndexEntry, timeZone: TimeZone, locale: Locale
    ) -> ReaderDay {
        ReaderDay(
            day: entry.day,
            title: DayTitle.shortDay(entry.day, timeZone: timeZone, locale: locale),
            subtitle: subtitle(entry),
            hasTimeline: entry.hasTimeline,
            frames: entry.frames,
            activeMinutes: entry.activeMinutes
        )
    }

    /// Facts, not a verdict: how long the day was, how much of it was looked at, and — since
    /// #249 — the day's own sentence, so twenty rows stop being the same two numbers twenty
    /// times. No day is ever compared with another one.
    static func subtitle(_ entry: DayIndexEntry) -> String {
        var parts: [String] = []
        if entry.activeMinutes > 0 {
            parts.append(StatsAggregator.duration(entry.activeMinutes))
        }
        parts.append(entry.frames == 1
            ? L10n.string("1 screenshot")
            : L10n.format("%lld screenshots", entry.frames))
        if let headline = entry.headline, !headline.isEmpty { parts.append(headline) }
        return parts.joined(separator: " · ")
    }
}

/// Everything a page draws for one selection: its title and the Today chart or the Weeks grid.
///
/// Assembled here rather than in the view so a test can assert what a selection comes out as.
public struct ReaderDocument: Equatable, Sendable {
    public let selection: ReaderSelection
    public let kind: ReportKind
    /// `Your day — Thursday 3 September 2026`, derived from the period — never persisted.
    public let title: String
    /// The Today page's chart. Nil for a week and for a day with no active time.
    public let waterfall: Waterfall?
    /// The Weeks page's grid. Nil for a day.
    public let calendar: WeekCalendar.Week?

    public init(
        selection: ReaderSelection,
        kind: ReportKind,
        title: String,
        waterfall: Waterfall? = nil,
        calendar: WeekCalendar.Week? = nil
    ) {
        self.selection = selection
        self.kind = kind
        self.title = title
        self.waterfall = waterfall
        self.calendar = calendar
    }
}

/// The reader's own strings, kept beside the model so a test reads the same words the window does.
public enum ReaderCopy {
    public static let windowTitle = L10n.string("Worklens")
}

// MARK: - Reaching the whole history (#244)

/// A page of days the sidebar has not loaded yet: the window it covers, and how many recorded
/// days are in it, so **Earlier days** says what it would add.
public struct ReaderPage: Equatable, Sendable {
    /// Inclusive `YYYY-MM-DD` bounds — the pair `DayIndex.entries(limit:after:before:)` takes.
    public var after: String
    public var before: String
    public var days: Int

    public init(after: String, before: String, days: Int) {
        self.after = after
        self.before = before
        self.days = days
    }
}

/// How much of the history the day list has loaded, and what is behind it (#244).
///
/// The reader pages instead of loading a fixed 120 days, because the fixed limit made day 121
/// unreachable from the window and cost a group over the whole `captures` table to produce.
public struct ReaderPaging: Equatable, Sendable {
    /// One page is 60 calendar days. A date window is what bounds the read — a row limit is
    /// applied after the grouping and bounds nothing — so a page is a stretch of time, and the
    /// day list opens on two months of days.
    public static let pageDays = 60

    /// The oldest day the loaded window covers, inclusive. Nil before the first load.
    public var loadedFrom: String?
    public var pagesLoaded = 0
    /// The next page back, when there is one.
    public var earlier: ReaderPage?
    public var isLoadingEarlier = false
    /// The first day Worklens ever recorded, whether or not it is loaded.
    public var oldestRecordedDay: String?

    public init() {}

    public var hasEarlier: Bool { earlier != nil }

    /// The first page: the `pageDays` days ending on `newest`, with no upper bound, so a day
    /// recorded while the window is open belongs to it too.
    public static func firstWindow(
        newest: String, timeZone: TimeZone = .current
    ) -> (after: String, before: String?) {
        (day(newest, offsetBy: -(pageDays - 1), timeZone: timeZone), nil)
    }

    /// The page immediately before a loaded window.
    public static func previousWindow(
        loadedFrom: String, timeZone: TimeZone = .current
    ) -> (after: String, before: String) {
        (
            day(loadedFrom, offsetBy: -pageDays, timeZone: timeZone),
            day(loadedFrom, offsetBy: -1, timeZone: timeZone)
        )
    }

    /// How many calendar days a window covers, both ends included. The row limit of a bounded
    /// read is sized from this, so a `LIMIT` can never clip a day that is inside the window the
    /// list has loaded — the sidebar would otherwise lose its oldest days to a window that keeps
    /// growing as the app stays open (#244).
    public static func dayCount(
        from: String, to: String, timeZone: TimeZone = .current
    ) -> Int {
        let formatter = DayBoundaries.formatter(timeZone)
        guard let start = formatter.date(from: from), let end = formatter.date(from: to),
              start <= end
        else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return days + 1
    }

    /// `YYYY-MM-DD`, shifted by whole local days. Falls back to what it was given, so a
    /// malformed day cannot turn into a window over nothing.
    public static func day(
        _ day: String, offsetBy days: Int, timeZone: TimeZone = .current
    ) -> String {
        guard let start = DayBoundaries.formatter(timeZone).date(from: day) else { return day }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return day }
        return DayBoundaries.dayString(shifted, timeZone: timeZone)
    }
}

/// What an open reader should do about a tick.
public struct ReaderTickDecision: Equatable, Sendable {
    public var refreshIndex: Bool
    public var rebuildDocument: Bool

    public init(refreshIndex: Bool, rebuildDocument: Bool) {
        self.refreshIndex = refreshIndex
        self.rebuildDocument = rebuildDocument
    }

    public static let nothing = ReaderTickDecision(refreshIndex: false, rebuildDocument: false)
}

/// A tick's effect on an open reader window, decided without one (#244).
///
/// `AppModel` asks once a minute while a reader page is open, so only a page that holds today is
/// rebuilt: an earlier day or week you are reading is left where it is. Pure, so that is asserted
/// in a test rather than in a window.
public enum ReaderTick {
    public static func decide(
        open: ReaderSelection?,
        today: String,
        indexCoversToday: Bool = true,
        timeZone: TimeZone = .current
    ) -> ReaderTickDecision {
        // The day list is refreshed when today is one of the loaded rows: today's screenshot
        // count moves on every tick.
        ReaderTickDecision(
            refreshIndex: indexCoversToday,
            rebuildDocument: open.map { holdsToday($0, today: today, timeZone: timeZone) } ?? false
        )
    }

    /// Whether a page is one that changes: today, or the week holding it, whose chart and grid
    /// move with every frame.
    static func holdsToday(
        _ open: ReaderSelection, today: String, timeZone: TimeZone
    ) -> Bool {
        switch open {
        case let .day(day):
            return day == today
        case let .week(monday):
            return ISOWeek.containing(dayString: today, timeZone: timeZone)?.start == monday
        }
    }
}
