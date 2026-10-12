import Foundation

/// Reads a day (or a week) out of the database and hands it to the pure aggregator.
///
/// `StatsAggregator` stays a pure function of its inputs; this is the only place stats touch
/// storage, so tests can exercise the arithmetic without a database.
public struct StatsService: Sendable {
    private let db: Database
    private let timeZone: TimeZone
    private let category: StatsAggregator.CategoryResolver?
    /// The canonical project list, read afresh per day so an edit shows up in the next stats run
    /// without rebuilding the service (#90). Empty where no taxonomy was handed in — the day
    /// then groups by `ProjectNames`' clustering alone, as it did before #90.
    private let projects: @Sendable () -> [ProjectEntry]
    /// #318: the email domains a meeting never counts toward, read afresh like `projects`.
    private let ignoredDomains: @Sendable () -> [String]
    /// What time it is, so today's not-yet-held calendar meetings stay out of today's totals.
    private let now: @Sendable () -> Date
    /// The intervals a frame's own is compared with to find the battery cadence (#320).
    private let baseIntervals: DayAccounting.BaseIntervals

    public init(
        _ db: Database,
        timeZone: TimeZone = .current,
        category: StatsAggregator.CategoryResolver? = nil,
        projects: @escaping @Sendable () -> [ProjectEntry] = { [] },
        ignoredDomains: @escaping @Sendable () -> [String] = { [] },
        now: @escaping @Sendable () -> Date = { Date() },
        baseIntervals: DayAccounting.BaseIntervals = .shipped
    ) {
        self.db = db
        self.timeZone = timeZone
        self.category = category
        self.projects = projects
        self.ignoredDomains = ignoredDomains
        self.now = now
        self.baseIntervals = baseIntervals
    }

    public func daily(day: String) throws -> DailyStats {
        let blocks = try ActivityBlockStore(db).fetch(day: day)
        let captures = try CaptureStore(db).fetch(day: day, timeZone: timeZone)
        // #19: the meetings, for the count the report quotes.
        let events = try ContextEventStore(db).events(day: day, timeZone: timeZone)
        // #46: exact foreground intervals, where the recorder was running.
        let sessions = try ForegroundSessionStore(db).fetch(day: day, timeZone: timeZone)
        // #70: what the describer said each frame was *about*, for the by-project table.
        let projectHints = try DescriptionStore(db).projectHints(day: day, timeZone: timeZone)
        // #315: and which catalog entry a d5 frame picked, which outranks its hint.
        let projectKeys = try DescriptionStore(db).projectKeys(day: day, timeZone: timeZone)
        // #91: and what each frame said was *on screen*, for the threads no project was named on.
        let frameDocuments = try DescriptionStore(db).frameDocuments(day: day, timeZone: timeZone)
        // #319: and the document address each frame's window reported, for `byDocument`.
        let frameDocumentURLs = try AXSnapshotStore(db).documentURLs(day: day, timeZone: timeZone)
        let moment = now()
        // #320: where every minute of the day went. A failed coverage read drops only this.
        let accounting = try? Self.accounting(
            db: db, day: day, timeZone: timeZone, now: moment, blocks: blocks, captures: captures,
            sessions: sessions, baseIntervals: baseIntervals
        )
        // #322: and which project each stretch of it went to. A failed read keeps the per-frame
        // `byProject` and threads.
        let projectSpans = accounting.flatMap { accounting in
            try? ProjectSpanService(
                db, timeZone: timeZone, projects: projects, ignoredDomains: ignoredDomains,
                now: { moment }, baseIntervals: baseIntervals
            ).spans(day: day, accounting: accounting, blocks: blocks, events: events)
        }
        var stats = StatsAggregator.daily(
            day: day,
            blocks: blocks,
            captures: captures,
            contextEvents: events,
            sessions: sessions,
            projectHints: projectHints,
            projectKeys: projectKeys,
            frameDocuments: frameDocuments,
            frameDocumentURLs: frameDocumentURLs,
            projects: projects(),
            ignoredDomains: ignoredDomains(),
            category: category,
            llmCost: try llmCost(day: day),
            timeZone: timeZone,
            now: moment,
            projectSpans: projectSpans
        )
        stats.accounting = accounting
        return stats
    }

    /// One day inside a span: the three numbers a range is read for, and nothing else.
    public struct SpanDay: Codable, Sendable, Equatable {
        public var day: String
        public var trackedMinutes: Int
        public var activeMinutes: Int
        public var meetingMinutes: Int
        /// #320: the day's buckets, without its spans.
        public var accounting: DayAccounting?
    }

    /// Stats over an inclusive day range: the per-day line, the totals, and the range's top apps,
    /// categories and projects (#241). One call where thirty `daily` calls were the only way.
    public struct SpanStats: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
        /// Every day in the range, in order, including the ones with nothing in them.
        public var days: [SpanDay]
        /// How many of those days had any tracked time at all.
        public var daysWithActivity: Int
        public var trackedMinutes: Int
        public var activeMinutes: Int
        public var meetingMinutes: Int
        public var byApp: [Slice]
        public var byCategory: [Slice]
        public var byProject: [Slice]
        public var llmCostUSD: Double
        /// Time per document over the range (#319), merged by key like `byProject`.
        public var byDocument: [Slice] = []
        /// #320: every bucket, day and window, summed over the range's days.
        public var accounting = DayAccounting.Totals()
    }

    /// `daily` looped over the range and added up. The caller caps the range — one database read
    /// per day is cheap but not free.
    public func span(from: String, to: String) throws -> SpanStats {
        let days = Self.days(from: from, to: to, timeZone: timeZone)
        let stats = try days.map { try daily(day: $0) }
        var span = SpanStats(
            from: from,
            to: to,
            days: stats.map {
                SpanDay(
                    day: $0.day,
                    trackedMinutes: $0.trackedMinutes,
                    activeMinutes: $0.activeMinutes,
                    meetingMinutes: $0.meetingMinutes,
                    accounting: $0.accounting?.withoutSpans
                )
            },
            daysWithActivity: stats.filter { !$0.isEmpty }.count,
            trackedMinutes: stats.reduce(0) { $0 + $1.trackedMinutes },
            activeMinutes: stats.reduce(0) { $0 + $1.activeMinutes },
            meetingMinutes: stats.reduce(0) { $0 + $1.meetingMinutes },
            byApp: Self.merge(stats.map(\.byApp)),
            byCategory: Self.merge(stats.map(\.byCategory)),
            byProject: Self.merge(stats.map(\.byProject)),
            llmCostUSD: stats.reduce(0) { $0 + $1.llmCostUSD },
            accounting: DayAccounting.Totals(stats.compactMap(\.accounting))
        )
        span.byDocument = Self.capped(Self.merge(stats.map(\.byDocument)), limit: DocumentTime.limit)
        return span
    }

    /// #323: the range by project and by day, uncut. Reads each day's accounting (#320) and
    /// project spans (#322) and the agents' turns, never `daily`, so a quarter stays cheap.
    /// `project` is a catalog key; the answer then holds that one row.
    public func timesheet(from: String, to: String, project: String? = nil) throws -> Timesheet {
        let days = Self.days(from: from, to: to, timeZone: timeZone)
        let moment = now()
        let catalog = projects()
        let spanService = ProjectSpanService(
            db, timeZone: timeZone, projects: { catalog }, ignoredDomains: ignoredDomains,
            now: { moment }, baseIntervals: baseIntervals
        )
        let matcher = ProjectRuleMatcher(catalog: catalog)
        let agents = AgentSessionStore(db)
        let sessions = Dictionary(try agents.sessions().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var spans: [String: [ProjectSpan]] = [:]
        var accounting: [String: DayAccounting] = [:]
        var agent: [String: [Timesheet.Agent]] = [:]
        for day in days {
            // One day that cannot be read is left out, as `daily` does, rather than failing the range.
            guard let range = DayBoundaries.range(day: day, timeZone: timeZone),
                  let read = try? timesheetDay(
                      day, range: range, moment: moment, catalog: catalog, matcher: matcher,
                      spanService: spanService, agents: agents, sessions: sessions
                  )
            else { continue }
            accounting[day] = read.accounting
            spans[day] = read.spans
            agent[day] = read.agent
        }
        return Timesheet.build(
            days: days, spans: spans, accounting: accounting, agent: agent, projects: catalog, only: project
        )
    }

    /// One day of `timesheet`: its accounting, project spans and agent stretches; nil when the
    /// day has no accounting.
    private func timesheetDay(
        _ day: String, range: (start: Date, end: Date), moment: Date, catalog: [ProjectEntry], matcher: ProjectRuleMatcher,
        spanService: ProjectSpanService, agents: AgentSessionStore, sessions: [String: AgentSession]
    ) throws -> (accounting: DayAccounting, spans: [ProjectSpan], agent: [Timesheet.Agent])? {
        let blocks = try ActivityBlockStore(db).fetch(day: day)
        guard let dayAccounting = try Self.accounting(
            db: db, day: day, timeZone: timeZone, now: moment, blocks: blocks,
            captures: try CaptureStore(db).fetch(day: day, timeZone: timeZone),
            sessions: try ForegroundSessionStore(db).fetch(day: day, timeZone: timeZone),
            baseIntervals: baseIntervals
        ) else { return nil }
        let spans = try spanService.spans(
            day: day, accounting: dayAccounting, blocks: blocks,
            events: try ContextEventStore(db).events(day: day, timeZone: timeZone)
        )
        let through = min(range.end, max(range.start, moment))
        let agent = try agents.turns(from: range.start, to: through).compactMap { turn -> Timesheet.Agent? in
            let start = max(turn.startAt, range.start), end = min(turn.endAt, through)
            guard end > start else { return nil }
            let counted = sessions[turn.sessionId]?.parentId ?? turn.sessionId
            // A repo rule you wrote (#324) outranks a catalog name or alias, as it does for spans.
            let project = sessions[counted]?.repo.flatMap {
                (matcher.project(forRepo: $0) ?? ProjectSpanService.project(forRepo: $0, in: catalog))?.key
            }
            return Timesheet.Agent(project: project, start: start, end: end)
        }
        return (dayAccounting, spans, agent)
    }

    /// The top `limit` rows, with the rest and any day's own `other` folded into one `other` row,
    /// so a month of documents stays as short as a day's list.
    private static func capped(_ slices: [Slice], limit: Int) -> [Slice] {
        let named = slices.filter { $0.key != StatsAggregator.otherKey }
        let rest = named.dropFirst(limit) + slices.filter { $0.key == StatsAggregator.otherKey }
        guard !rest.isEmpty else { return slices }
        var kept = Array(named.prefix(limit))
        kept.append(Slice(
            key: StatsAggregator.otherKey,
            name: StatsAggregator.otherKey,
            minutes: rest.reduce(0) { $0 + $1.minutes },
            share: (rest.reduce(0) { $0 + $1.share } * 1000).rounded() / 1000
        ))
        return kept
    }

    /// Every local day from `from` to `to` inclusive, in order. Empty when the range is backwards
    /// or either end is not a day.
    public static func days(from: String, to: String, timeZone: TimeZone = .current) -> [String] {
        guard let start = DayBoundaries.range(day: from, timeZone: timeZone)?.start,
              DayBoundaries.range(day: to, timeZone: timeZone) != nil, from <= to
        else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var days: [String] = []
        var cursor = start
        while true {
            let day = DayBoundaries.dayString(cursor, timeZone: timeZone)
            guard day <= to else { break }
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Slices of many days added by key, re-shared against the new total and sorted by minutes.
    /// #318: a `byProject` row's meeting minutes and rules are added up too, and rank the row
    /// alongside its screen minutes; #322: its `share` is of every row's screen and meeting minutes.
    static func merge(_ slices: [[Slice]]) -> [Slice] {
        var minutes: [String: Int] = [:]
        var names: [String: String] = [:]
        var rules: [String: [String: Int]] = [:]
        for day in slices {
            for slice in day {
                minutes[slice.key, default: 0] += slice.minutes
                names[slice.key] = slice.name
                if let meetingRules = slice.meetingRules {
                    rules[slice.key, default: [:]].merge(meetingRules, uniquingKeysWith: +)
                }
            }
        }
        func covered(_ key: String) -> Int { (minutes[key] ?? 0) + (rules[key]?.values.reduce(0, +) ?? 0) }
        let total = minutes.keys.reduce(0) { $0 + covered($1) }
        return minutes
            .map { key, value in
                Slice(
                    key: key,
                    name: names[key] ?? key,
                    minutes: value,
                    share: total > 0 ? Double(covered(key)) / Double(total) : 0,
                    meetingMinutes: rules[key].map { $0.values.reduce(0, +) },
                    meetingRules: rules[key]
                )
            }
            .sorted {
                let left = $0.minutes + ($0.meetingMinutes ?? 0), right = $1.minutes + ($1.meetingMinutes ?? 0)
                return (left, $1.key) > (right, $0.key)
            }
    }

    /// Every day of the week that has tracked time, plus last week's totals for the deltas.
    public func weekly(_ week: ISOWeek, includePreviousWeek: Bool = true) throws -> WeeklyStats {
        // #320: a week carries each day's buckets, not its spans.
        let days = try week.days.map { day -> DailyStats in
            var stats = try daily(day: day)
            stats.accounting = stats.accounting?.withoutSpans
            stats.projectSpans = nil
            return stats
        }
        var previous: WeeklyStats?
        if includePreviousWeek, let earlier = week.previous(timeZone: timeZone) {
            let earlierDays = try earlier.days.map { try daily(day: $0) }
            if earlierDays.contains(where: { !$0.isEmpty }) {
                previous = StatsAggregator.weekly(days: earlierDays, timeZone: timeZone)
            }
        }
        var stats = StatsAggregator.weekly(days: days, previous: previous, timeZone: timeZone)
        // `weekly` infers the week from the days it was given, which is empty for an untracked
        // week; the caller always knows which week it asked for.
        stats.weekStart = week.start
        stats.weekEnd = week.end
        stats.isoWeek = week.identifier
        return stats
    }

    /// Seconds per document on the local day (#319), uncapped: what the `shipped` tool joins a
    /// PR or issue against. Reads the same frames and weights as `byDocument`.
    public func documentSeconds(day: String) throws -> [ArtifactKey: Double] {
        let blocks = try ActivityBlockStore(db).fetch(day: day)
        let captures = try CaptureStore(db).fetch(day: day, timeZone: timeZone)
        let urls = try AXSnapshotStore(db).documentURLs(day: day, timeZone: timeZone)
        return DocumentTime.seconds(
            weights: DocumentTime.onScreenWeights(blocks: blocks, captures: captures, now: now()),
            documentURLs: urls
        )
    }

    /// Model spend inside the local day, from the ledger.
    public func llmCost(day: String) throws -> Double {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return 0 }
        return try LLMCallStore(db).spend(from: range.start, to: range.end)
    }
}
