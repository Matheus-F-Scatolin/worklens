import Foundation

/// Today's numbers, as the menu's tally row says them (#159, #231).
///
/// Deliberately *not* a `DailyStats`. `StatsService.daily` is six full-day table scans — blocks,
/// captures, context events, foreground sessions, project hints and frame documents — and the
/// menu needs four numbers out of it. This is computed from the day's `activity_blocks` alone
/// plus the two figures `MenuState` already carries (today's spend and the budget in force), so
/// opening the menu costs one narrow query, and the result is cached for `cacheSeconds` so a
/// person clicking twice pays for it once.
///
/// The arithmetic and every string live here rather than in the SwiftUI view: the view draws what
/// this hands it and does no formatting of its own.
public struct TodaySnapshot: Equatable, Sendable {
    /// The local day these numbers are about, `YYYY-MM-DD`.
    public let day: String
    public let activeMinutes: Int
    /// Whole meeting blocks only — see `make(day:blocks:…)`.
    public let meetingMinutes: Int
    public let firstActivity: Date?
    public let spendUSD: Double
    public let budgetUSD: Double
    /// When this was computed. The menu reuses a snapshot younger than `cacheSeconds`.
    public let computedAt: Date
    private let timeZone: TimeZone
    /// The locale the money on this card is written in. Fixed by default so the tests that
    /// assert `budgetLine` do not read System Settings; the app passes the user's own (#157).
    private let locale: Locale

    /// How long a snapshot is reused before the menu asks for another one. The 30 s refresh
    /// loop never computes one: this is the whole reason the type exists.
    public static let cacheSeconds: TimeInterval = 60

    public init(
        day: String,
        activeMinutes: Int = 0,
        meetingMinutes: Int = 0,
        firstActivity: Date? = nil,
        spendUSD: Double = 0,
        budgetUSD: Double = 0,
        computedAt: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Format.fixed
    ) {
        self.day = day
        self.activeMinutes = activeMinutes
        self.meetingMinutes = meetingMinutes
        self.firstActivity = firstActivity
        self.spendUSD = spendUSD
        self.budgetUSD = budgetUSD
        self.computedAt = computedAt
        self.timeZone = timeZone
        self.locale = locale
    }

    /// Whether this snapshot is old enough that the popover should compute another one.
    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(computedAt) >= TodaySnapshot.cacheSeconds
            || now.timeIntervalSince(computedAt) < 0
    }

    /// Nothing tracked yet today. The card says so in one line rather than drawing three dashes.
    public var isEmpty: Bool { activeMinutes == 0 && meetingMinutes == 0 && firstActivity == nil }

    /// `2h 05m`, `45m`, `—`.
    public var activeLine: String { StatsAggregator.duration(activeMinutes) }
    public var meetingLine: String { StatsAggregator.duration(meetingMinutes) }

    /// `09:12`, or `not yet` before anything was tracked.
    public var firstActivityLine: String {
        guard let firstActivity else { return L10n.string("not yet") }
        return TodaySnapshot.clock(firstActivity, timeZone: timeZone)
    }

    /// The same three bands the menu row and the icon already use — never re-derived here.
    public var spendLevel: SpendLevel { SpendLevel.of(spend: spendUSD, budget: budgetUSD) }

    /// How full the meter is, 0…1. Clamped: a day over budget draws a full bar, not a longer one.
    public var budgetFraction: Double {
        guard budgetUSD > 0 else { return 0 }
        return min(1, max(0, spendUSD / budgetUSD))
    }

    /// `$0.42 of $2.00`, or just the spend where no budget is set.
    public var budgetLine: String {
        guard budgetUSD > 0 else { return MenuModel.money(spendUSD, locale: locale) }
        return "\(MenuModel.money(spendUSD, locale: locale)) of "
            + MenuModel.money(budgetUSD, locale: locale)
    }

    /// The menu's one tally line (#231): what today has looked like so far, in one row —
    /// `2h 05m active · 45m in meetings · $0.42 of $2.00`. Empty while nothing is tracked yet,
    /// and the menu omits the row rather than drawing a line of dashes.
    ///
    /// Every clause is one of the lines above it, so the words and the rounding are theirs; this
    /// joins them and decides nothing. No comparison with another day and no score (PLAN §1.4):
    /// it says where the time went, never whether that was good.
    public var tallyLine: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        if activeMinutes > 0 { parts.append(L10n.format("%@ active", activeLine)) }
        if meetingMinutes > 0 { parts.append(L10n.format("%@ in meetings", meetingLine)) }
        parts.append(budgetLine)
        return parts.joined(separator: " · ")
    }

    /// Builds the card from the day's blocks.
    ///
    /// `blocks` may span more than `day`: the numbers use the rows whose `day` matches. Meeting time is whole meeting blocks only — `StatsAggregator`
    /// also folds in screen time whose *frames* were flagged as a meeting, and that needs the
    /// day's captures, which is a scan this deliberately does not do.
    public static func make(
        day: String,
        blocks: [ActivityBlock],
        spendUSD: Double,
        budgetUSD: Double,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Format.fixed
    ) -> TodaySnapshot {
        // The calendar sync writes the whole day's meetings up front; only what has happened
        // counts.
        let blocks = StatsAggregator.clippedToNow(blocks, now: now)
        let today = blocks.filter { $0.day == day }
        let active = today.filter { !StatsAggregator.isInactive($0) }
        // Union rather than sum: a calendar meeting block sits on top of the screen blocks it
        // contains, exactly as `StatsAggregator.daily` treats them.
        let activeSeconds = StatsAggregator.unionSeconds(active)
        let meetingSeconds = StatsAggregator.unionSeconds(
            today.filter { StatsAggregator.isMeeting($0) && !StatsAggregator.isInactive($0) }
        )
        return TodaySnapshot(
            day: day,
            activeMinutes: StatsAggregator.minutes(activeSeconds),
            meetingMinutes: StatsAggregator.minutes(meetingSeconds),
            firstActivity: active.map(\.startAt).min(),
            spendUSD: spendUSD,
            budgetUSD: budgetUSD,
            computedAt: now,
            timeZone: timeZone,
            locale: locale
        )
    }

    /// `09:12`, in the day's own time zone and never in the user's locale format.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
