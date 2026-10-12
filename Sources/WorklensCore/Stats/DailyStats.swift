import Foundation

/// One row of a breakdown: an app, a category, a task or a host.
public struct Slice: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var minutes: Int
    /// Fraction of `activeMinutes`, 0...1, rounded to three decimals.
    public var share: Double
    /// The rows inside this one, where a breakdown has a second level (#90): a `byProject` row
    /// carries the apps the project's time was spent in, most minutes first, so the report can
    /// say "worklens: Claude Desktop 1h 10m, Web browser 25m". Nil everywhere else, and absent
    /// from the JSON of a stats row written before #90.
    public var parts: [Slice]?
    /// A `byProject` row's meeting minutes (#318): the Calendar and Granola meetings that counted
    /// toward this company, each meeting's share of the day's meeting union. Kept apart from
    /// `minutes` and `share`, which stay screen-only. Nil when no meeting counted.
    public var meetingMinutes: Int?
    /// `meetingMinutes` by the rule that put the meetings here (`MeetingCompany.Rule`), summing to
    /// it. On the `unattributed` row the keys are the reasons no company was named.
    public var meetingRules: [String: Int]?

    public init(
        key: String, name: String, minutes: Int, share: Double, parts: [Slice]? = nil,
        meetingMinutes: Int? = nil, meetingRules: [String: Int]? = nil
    ) {
        self.key = key
        self.name = name
        self.minutes = minutes
        self.share = share
        self.parts = parts
        self.meetingMinutes = meetingMinutes
        self.meetingRules = meetingRules
    }

    /// Sets `meetingRules` from seconds per rule, rounding each and summing them into
    /// `meetingMinutes`, so the two always agree. Rules that round to nothing are dropped.
    mutating func setMeetings(secondsByRule: [String: Double]) {
        let rules = secondsByRule
            .mapValues { Int(($0 / 60).rounded()) }
            .filter { $0.value > 0 }
        meetingRules = rules.isEmpty ? nil : rules
        meetingMinutes = rules.isEmpty ? nil : rules.values.reduce(0, +)
    }
}

/// One hour of the local day.
public struct HourBucket: Codable, Sendable, Equatable {
    public var hour: Int
    public var activeMinutes: Int
    public var dominantApp: String?

    public init(hour: Int, activeMinutes: Int, dominantApp: String?) {
        self.hour = hour
        self.activeMinutes = activeMinutes
        self.dominantApp = dominantApp
    }
}

/// The longest uninterrupted stretch on one thing.
public struct FocusBlock: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var minutes: Int
    public var appKey: String
    public var taskKey: String
    public var title: String?

    public init(start: Date, end: Date, minutes: Int, appKey: String, taskKey: String, title: String?) {
        self.start = start
        self.end = end
        self.minutes = minutes
        self.appKey = appKey
        self.taskKey = taskKey
        self.title = title
    }
}

/// How often one app hands over to another.
public struct SwitchPair: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var count: Int

    public init(from: String, to: String, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }
}

/// One thread of work through a day (#91): every stretch spent on the same thing, however often
/// it was left and returned to.
///
/// A thread is a canonical project (#90) where the frames named one, and the same app plus the
/// same `document` where they did not — "the lyrics doc in Chrome" is a thread even on a day the
/// describer never gave it a project. `visits` is what the report used to count by hand off the
/// timeline: `contextSwitches` says a day was busy, this says which returns actually cost
/// something.
public struct ThreadStat: Codable, Sendable, Equatable {
    /// What the runs are grouped on: the project's key, or `appKey/document` for a fallback
    /// thread. Case-folded, the way `Slice.key` is.
    public var key: String
    /// What to call it: the project's name, or `App — document`.
    public var project: String
    /// Maximal runs of consecutive blocks on this thread. Anything else in between — another
    /// thread, or a block nothing could be said about — ends a run and starts the next visit.
    public var visits: Int
    /// `visits - 1`: how many times the thread was come back to rather than started.
    public var reentries: Int
    /// The longest single visit. This is the number a "you had one good run at it" claim rests on.
    public var longestRunMinutes: Int
    /// Every visit's minutes. Block minutes, so this need not match the frame-weighted
    /// `byProject` row of the same project to the minute.
    public var totalMinutes: Int
    public var firstAt: Date
    public var lastAt: Date
    /// The median wall-clock gap between one visit ending and the next beginning. Zero for a
    /// thread with a single visit. Three minutes says the thread was never really put down.
    public var medianGapMinutes: Double

    public init(
        key: String,
        project: String,
        visits: Int,
        reentries: Int,
        longestRunMinutes: Int,
        totalMinutes: Int,
        firstAt: Date,
        lastAt: Date,
        medianGapMinutes: Double
    ) {
        self.key = key
        self.project = project
        self.visits = visits
        self.reentries = reentries
        self.longestRunMinutes = longestRunMinutes
        self.totalMinutes = totalMinutes
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.medianGapMinutes = medianGapMinutes
    }
}

/// One project's week, day by day (#91) — the row of the weekly ledger grid.
///
/// Merged from the days' `byProject` rows and nothing else, so a column adds up to exactly what
/// that day's table said, `other` and `unattributed` included.
public struct ProjectLedgerRow: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    /// `YYYY-MM-DD` → minutes. Days the project got none are absent rather than zero.
    public var minutesPerDay: [String: Int]
    public var totalMinutes: Int
    /// Days with any minutes at all — what "it ran all week" has to mean.
    public var daysSeen: Int

    public init(key: String, name: String, minutesPerDay: [String: Int], totalMinutes: Int, daysSeen: Int) {
        self.key = key
        self.name = name
        self.minutesPerDay = minutesPerDay
        self.totalMinutes = totalMinutes
        self.daysSeen = daysSeen
    }
}

/// Everything deterministic about a day, computed from `activity_blocks` and `captures`.
///
/// The report model reasons over these numbers; it never counts minutes itself, so a wrong figure
/// here is a bug rather than a hallucination.
public struct DailyStats: Codable, Sendable, Equatable {
    public var day: String
    public var firstActivity: Date?
    public var lastActivity: Date?
    /// Every block, idle included.
    public var trackedMinutes: Int
    /// Everything but idle and locked time.
    public var activeMinutes: Int
    public var idleMinutes: Int
    public var meetingMinutes: Int
    /// #94: minutes a timed calendar event with other people says you spent away from the
    /// machine — lunch, a coffee, an offsite. Part of `idleMinutes` (you were not at the screen)
    /// and never part of `meetingMinutes`: it is the calendar time that is not a call.
    public var awayMinutes: Int
    public var redactedMinutes: Int
    public var framesDescribed: Int
    public var framesInherited: Int
    public var byApp: [Slice]
    public var byCategory: [Slice]
    public var byTask: [Slice]
    public var byHost: [Slice]
    /// Time per project (#70), from the describer's `project_hint`, plus one `unattributed` row
    /// for the frames it named no project on. Empty for a day whose frames carried no hints.
    public var byProject: [Slice]
    /// The day's threads (#91), longest first: how often each project or document was returned
    /// to, and how long the best run at it was. Empty for a day whose frames named neither.
    public var threads: [ThreadStat]
    /// 24 buckets, local hours 0...23.
    public var hourly: [HourBucket]
    public var contextSwitches: Int
    public var switchesPerActiveHour: Double
    public var longestFocusBlock: FocusBlock?
    public var focusBlocksOver25Min: Int
    public var medianBlockMinutes: Double
    public var topSwitchPairs: [SwitchPair]
    public var distinctApps: Int
    /// How much of the day's active span `foreground_sessions` covers (#46) — the part of it whose
    /// per-app minutes are exact rather than sampled. Zero for days recorded before the recorder
    /// existed, or stretches where it was not running.
    public var sessionMinutes: Int
    /// The same coverage as a fraction of the active span, 0...1 (#61) — how far `byApp` and
    /// `byCategory` can be trusted as exact. The uncovered remainder is still counted, from the
    /// sampled block seconds, but it was never rescaled.
    public var sessionCoverage: Double
    /// Everything spent on models that day, from `llm_calls`.
    public var llmCostUSD: Double

    // Context sources (#19). Counted from `context_events`, not from the screen.
    /// Distinct meetings, after the same call known to both Granola and the calendar is collapsed.
    public var meetingsCount: Int
    /// Time per document (#319): Google files, GitHub PRs and issues and local paths, keyed by
    /// `ArtifactKey.displayKey`, top ten plus `other`. Empty for a day whose frames named none.
    public var byDocument: [Slice] = []
    /// #320: where every minute of the day went. Nil where no store was read; spans only on a
    /// one-day `stats` read.
    public var accounting: DayAccounting?
    /// #322: the day's project spans, in time order: disjoint stretches of screen and meeting time,
    /// each with its project or the reason it has none, and the rule that decided it. `byProject`
    /// is their sum. Nil inside `weekly` and where no store was read.
    public var projectSpans: [ProjectSpan]?

    public init(
        day: String,
        firstActivity: Date? = nil,
        lastActivity: Date? = nil,
        trackedMinutes: Int = 0,
        activeMinutes: Int = 0,
        idleMinutes: Int = 0,
        meetingMinutes: Int = 0,
        awayMinutes: Int = 0,
        redactedMinutes: Int = 0,
        framesDescribed: Int = 0,
        framesInherited: Int = 0,
        byApp: [Slice] = [],
        byCategory: [Slice] = [],
        byTask: [Slice] = [],
        byHost: [Slice] = [],
        byProject: [Slice] = [],
        threads: [ThreadStat] = [],
        hourly: [HourBucket] = [],
        contextSwitches: Int = 0,
        switchesPerActiveHour: Double = 0,
        longestFocusBlock: FocusBlock? = nil,
        focusBlocksOver25Min: Int = 0,
        medianBlockMinutes: Double = 0,
        topSwitchPairs: [SwitchPair] = [],
        distinctApps: Int = 0,
        sessionMinutes: Int = 0,
        sessionCoverage: Double = 0,
        llmCostUSD: Double = 0,
        meetingsCount: Int = 0,
        accounting: DayAccounting? = nil
    ) {
        self.day = day
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.trackedMinutes = trackedMinutes
        self.activeMinutes = activeMinutes
        self.idleMinutes = idleMinutes
        self.meetingMinutes = meetingMinutes
        self.awayMinutes = awayMinutes
        self.redactedMinutes = redactedMinutes
        self.framesDescribed = framesDescribed
        self.framesInherited = framesInherited
        self.byApp = byApp
        self.byCategory = byCategory
        self.byTask = byTask
        self.byHost = byHost
        self.byProject = byProject
        self.threads = threads
        self.hourly = hourly
        self.contextSwitches = contextSwitches
        self.switchesPerActiveHour = switchesPerActiveHour
        self.longestFocusBlock = longestFocusBlock
        self.focusBlocksOver25Min = focusBlocksOver25Min
        self.medianBlockMinutes = medianBlockMinutes
        self.topSwitchPairs = topSwitchPairs
        self.distinctApps = distinctApps
        self.sessionMinutes = sessionMinutes
        self.sessionCoverage = sessionCoverage
        self.llmCostUSD = llmCostUSD
        self.meetingsCount = meetingsCount
        self.accounting = accounting
    }

    /// True when nothing was tracked.
    public var isEmpty: Bool { trackedMinutes == 0 }
}

/// A week of days plus its aggregates: the Weeks page and the MCP `stats` tool read it.
public struct WeeklyStats: Codable, Sendable, Equatable {
    /// Monday's `YYYY-MM-DD`.
    public var weekStart: String
    /// Sunday's `YYYY-MM-DD`.
    public var weekEnd: String
    /// `YYYY-Www`.
    public var isoWeek: String
    /// One entry per day that had any tracked time, Monday first.
    public var days: [DailyStats]
    public var totals: WeeklyTotals
    /// Project → day → minutes (#91), merged from the days' `byProject` rows and ordered by the
    /// week's total. What lets "Biggest time sinks" name a project *and* its day pattern.
    public var projectLedger: [ProjectLedgerRow]
    /// Active minutes for all seven days, Monday first; zero for untracked days.
    public var perDayActiveMinutes: [Int]
    /// Relative change vs the previous week, per metric: `(this - last) / last`. Nil when there is
    /// no previous week to compare against.
    public var deltaVsPreviousWeek: [String: Double]?

    public init(
        weekStart: String,
        weekEnd: String,
        isoWeek: String,
        days: [DailyStats],
        totals: WeeklyTotals,
        projectLedger: [ProjectLedgerRow] = [],
        perDayActiveMinutes: [Int],
        deltaVsPreviousWeek: [String: Double]? = nil
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.isoWeek = isoWeek
        self.days = days
        self.totals = totals
        self.projectLedger = projectLedger
        self.perDayActiveMinutes = perDayActiveMinutes
        self.deltaVsPreviousWeek = deltaVsPreviousWeek
    }
}

/// Week-level sums and averages. Averages are over days with tracked time, not over seven.
public struct WeeklyTotals: Codable, Sendable, Equatable {
    public var daysTracked: Int
    public var trackedMinutes: Int
    public var activeMinutes: Int
    public var idleMinutes: Int
    public var meetingMinutes: Int
    public var contextSwitches: Int
    public var switchesPerActiveHour: Double
    public var focusBlocksOver25Min: Int
    public var averageActiveMinutesPerDay: Double
    public var longestFocusBlock: FocusBlock?
    public var byApp: [Slice]
    public var byCategory: [Slice]
    public var byTask: [Slice]
    public var byHost: [Slice]
    /// Time per project over the week (#70), merged from the days the way `byHost` is.
    public var byProject: [Slice]
    public var topSwitchPairs: [SwitchPair]
    public var distinctApps: Int
    public var llmCostUSD: Double
    /// Context-source counts (#19), summed over the week's tracked days.
    public var meetingsCount: Int
    /// Time per document over the week (#319), merged from the days the way `byHost` is.
    public var byDocument: [Slice] = []

    public init(
        daysTracked: Int = 0,
        trackedMinutes: Int = 0,
        activeMinutes: Int = 0,
        idleMinutes: Int = 0,
        meetingMinutes: Int = 0,
        contextSwitches: Int = 0,
        switchesPerActiveHour: Double = 0,
        focusBlocksOver25Min: Int = 0,
        averageActiveMinutesPerDay: Double = 0,
        longestFocusBlock: FocusBlock? = nil,
        byApp: [Slice] = [],
        byCategory: [Slice] = [],
        byTask: [Slice] = [],
        byHost: [Slice] = [],
        byProject: [Slice] = [],
        topSwitchPairs: [SwitchPair] = [],
        distinctApps: Int = 0,
        llmCostUSD: Double = 0,
        meetingsCount: Int = 0
    ) {
        self.daysTracked = daysTracked
        self.trackedMinutes = trackedMinutes
        self.activeMinutes = activeMinutes
        self.idleMinutes = idleMinutes
        self.meetingMinutes = meetingMinutes
        self.contextSwitches = contextSwitches
        self.switchesPerActiveHour = switchesPerActiveHour
        self.focusBlocksOver25Min = focusBlocksOver25Min
        self.averageActiveMinutesPerDay = averageActiveMinutesPerDay
        self.longestFocusBlock = longestFocusBlock
        self.byApp = byApp
        self.byCategory = byCategory
        self.byTask = byTask
        self.byHost = byHost
        self.byProject = byProject
        self.topSwitchPairs = topSwitchPairs
        self.distinctApps = distinctApps
        self.llmCostUSD = llmCostUSD
        self.meetingsCount = meetingsCount
    }
}
