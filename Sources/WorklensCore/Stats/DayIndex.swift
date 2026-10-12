import Foundation
import GRDB

/// What the `days()` tool answers with: which local days have frames at all, so a client that is
/// about to ask for a timeline knows which days exist (#89).
///
/// Frozen on purpose. #134 moved the index here and gave it two more facts, and this shape is the
/// MCP contract: the `days` tool's JSON and its rendered table say exactly what they said before.
public struct MCPDay: Sendable, Equatable, Codable {
    public var day: String
    public var frames: Int
    public var described: Int
    /// #249: one plain sentence about the day — a historical daily report's opening line, or
    /// what the day's own stats say. Empty when there is neither.
    public var headline: String

    public init(day: String, frames: Int, described: Int, headline: String = "") {
        self.day = day
        self.frames = frames
        self.described = described
        self.headline = headline
    }
}

/// One local day as the reader's sidebar sees it (#134): the MCP facts plus whether there is a
/// timeline to show and how much of the day was active.
///
/// `hasTimeline` is "are there activity blocks for this day", not "is there a file": the reader
/// renders from the blocks, and a day whose `.md` has not been written yet still has a timeline
/// to draw.
public struct DayIndexEntry: Sendable, Equatable {
    public var day: String
    public var frames: Int
    public var described: Int
    public var hasTimeline: Bool
    /// The same number the day's Stats tab prints as "Active": the union of the non-inactive
    /// blocks, so two surfaces of one window never disagree about one day.
    public var activeMinutes: Int
    /// #249: the day's sentence — a historical report's lede when there is one, and what the
    /// day's own apps and minutes say when there is not. Nil for a day with nothing to say.
    public var headline: String?

    public init(
        day: String,
        frames: Int,
        described: Int,
        hasTimeline: Bool = false,
        activeMinutes: Int = 0,
        headline: String? = nil
    ) {
        self.day = day
        self.frames = frames
        self.described = described
        self.hasTimeline = hasTimeline
        self.activeMinutes = activeMinutes
        self.headline = headline
    }

    /// The fields MCP is allowed to see.
    public var mcpDay: MCPDay {
        MCPDay(day: day, frames: frames, described: described, headline: headline ?? "")
    }
}

/// Groups `captures` by local day in one query.
///
/// `date(captured_at, 'localtime')` rather than a Swift loop over `DayBoundaries`: the alternative
/// is one `COUNT(*)` per day, and the whole point of this tool is to be the cheap first call.
/// GRDB stores a `DATETIME` as UTC `YYYY-MM-DD HH:MM:SS.SSS`, which is exactly what SQLite's
/// `localtime` modifier reads.
///
/// #134 moved this out of `MCP/` — the reader's day sidebar needs the same index, and a type the
/// whole app reads should not live under the name of one of its callers. `MCPDayIndex` is still
/// the spelling MCP uses.
public struct DayIndex: Sendable {
    private let db: Database
    /// What time it is, so today's sidebar minutes leave out the meetings not held yet, as
    /// `StatsAggregator.daily` does.
    private let now: @Sendable () -> Date

    public init(_ db: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.now = now
    }

    /// The MCP `days` tool. Unchanged by #134, field for field.
    public func days(limit: Int, labels: TimelineLabels = TimelineLabels()) throws -> [MCPDay] {
        try entries(limit: limit, labels: labels).map(\.mcpDay)
    }

    /// The same days, with the two facts the reader needs and MCP never sees.
    ///
    /// `after` and `before` are inclusive `YYYY-MM-DD` bounds — the oldest and the newest day to
    /// look at — and both default to nil, which is the unbounded call every caller before #244
    /// made. They are what make this affordable: `date(captured_at, 'localtime')` is an
    /// expression no index can serve, so an unbounded call groups every capture row ever written
    /// to return the newest `limit` days, while a window is served by `idx_captures_captured_at`
    /// and reads only the rows inside it. The reader pages with them (#244); the MCP `days` tool
    /// still calls the unbounded shape and gets the same answer it always did.
    ///
    /// `labels` names the apps the stats headline lists the way the timeline and Settings name
    /// them (#249); without them a key falls back to `TimelineLabels.humanize`, which is what a
    /// caller with no taxonomy to hand gets.
    public func entries(
        limit: Int, after: String? = nil, before: String? = nil,
        labels: TimelineLabels = TimelineLabels(), timeZone: TimeZone = .current
    ) throws -> [DayIndexEntry] {
        // #249: the headline comes back with the day, so filling a sidebar costs one more
        // column rather than one `content_md` per row. Oldest first, so the newest report for a
        // day is the one that lands in the dictionary. The reports were cut on 2026-10-05; the
        // rows written before then still name their day.
        let reportRows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT period_start, headline FROM reports WHERE kind = ? ORDER BY created_at ASC
                """, arguments: [ReportKind.daily.rawValue])
        }
        var reportHeadlines: [String: String] = [:]
        for row in reportRows {
            guard let day: String = row["period_start"] else { continue }
            let headline: String? = row["headline"]
            if let headline, !headline.isEmpty { reportHeadlines[day] = headline }
            else { reportHeadlines[day] = nil }
        }
        // One grouped query for the frames, one plain fetch for the blocks rather than a join:
        // `captures` is grouped on an expression and `activity_blocks` on a stored column, so
        // joining them costs the index on both. The block fetch is bounded to the days this call
        // actually returns.
        let window = DayIndex.window(after: after, before: before, timeZone: timeZone)
        var arguments: [(any DatabaseValueConvertible)?] = [
            DescribeStatus.described.rawValue, DescribeStatus.inherited.rawValue,
        ]
        arguments.append(contentsOf: window.arguments.map { $0 as (any DatabaseValueConvertible)? })
        arguments.append(limit)
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT date(captured_at, 'localtime') AS day,
                       COUNT(*) AS frames,
                       SUM(CASE WHEN describe_status IN (?, ?) THEN 1 ELSE 0 END) AS described
                FROM captures
                WHERE \(window.sql)
                GROUP BY day
                ORDER BY day DESC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
        }
        let blocks = try blockFacts(
            days: rows.compactMap { $0["day"] as String? }, labels: labels
        )
        return rows.compactMap { row -> DayIndexEntry? in
            guard let day: String = row["day"] else { return nil }
            let facts = blocks[day] ?? DayBlockFacts()
            return DayIndexEntry(
                day: day,
                frames: row["frames"] ?? 0,
                described: row["described"] ?? 0,
                hasTimeline: facts.hasTimeline,
                activeMinutes: facts.activeMinutes,
                headline: reportHeadlines[day] ?? DayHeadline.fromStats(
                    names: facts.topApps, activeMinutes: facts.activeMinutes
                )
            )
        }
    }

    /// The recorded days inside a window, newest first and without the per-day facts: what the
    /// sidebar's **Earlier days** row counts before it loads anything (#244).
    ///
    /// The same bounded read as `entries`, minus the two joins, so the row can say how many days
    /// it would add rather than a number it guessed.
    public func recordedDays(
        limit: Int, after: String? = nil, before: String? = nil, timeZone: TimeZone = .current
    ) throws -> [String] {
        let window = DayIndex.window(after: after, before: before, timeZone: timeZone)
        var arguments: [(any DatabaseValueConvertible)?] =
            window.arguments.map { $0 as (any DatabaseValueConvertible)? }
        arguments.append(limit)
        return try db.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT date(captured_at, 'localtime') AS day
                FROM captures
                WHERE \(window.sql)
                GROUP BY day
                ORDER BY day DESC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
        }
    }

    /// The oldest local day with a screenshot in it, and the newest — the two ends of what there
    /// is to reach (#244). Nil when nothing has been recorded at all.
    ///
    /// One aggregate per query on purpose: SQLite serves a lone `MIN` or `MAX` from
    /// `idx_captures_captured_at` without reading the table, and two in one statement it does not.
    public func oldestDay(timeZone: TimeZone = .current) throws -> String? {
        try edgeDay(aggregate: "MIN", timeZone: timeZone)
    }

    public func newestDay(timeZone: TimeZone = .current) throws -> String? {
        try edgeDay(aggregate: "MAX", timeZone: timeZone)
    }

    private func edgeDay(aggregate: String, timeZone: TimeZone) throws -> String? {
        let at = try db.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT \(aggregate)(captured_at) FROM captures")
        }
        return at.map { DayBoundaries.dayString($0, timeZone: timeZone) }
    }

    /// The `captured_at` half of a day window: the SQL boolean and its arguments.
    ///
    /// The bounds are local days and the column is an instant, so they are resolved through
    /// `DayBoundaries` — the one place in the app that conversion happens.
    private static func window(
        after: String?, before: String?, timeZone: TimeZone
    ) -> (sql: String, arguments: [Date]) {
        var clauses: [String] = []
        var values: [Date] = []
        if let after, let range = DayBoundaries.range(day: after, timeZone: timeZone) {
            clauses.append("captured_at >= ?")
            values.append(range.start)
        }
        if let before, let range = DayBoundaries.range(day: before, timeZone: timeZone) {
            clauses.append("captured_at < ?")
            values.append(range.end)
        }
        return (clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), values)
    }

    /// The two facts a day's blocks carry, kept apart on purpose: a day whose only block is an
    /// idle stretch still has a timeline to draw, and no active minutes in it.
    struct DayBlockFacts: Equatable {
        var hasTimeline = false
        var activeMinutes = 0
        /// #249: the app names the day mostly went into, longest first — the same keys the
        /// timeline labels, never a window title.
        var topApps: [String] = []
    }

    /// What the blocks say about each of these days.
    ///
    /// The minutes are computed the way the rest of the app computes them — the union of the
    /// non-inactive intervals, exactly `StatsAggregator.daily`'s `activeMinutes` — and not as
    /// `SUM(end_at - start_at)` over the table. That sum counts the idle and away blocks the app
    /// treats as inactive everywhere else, and counts a meeting twice, because #19 deliberately
    /// lays a calendar block *on top of* the screen blocks it contains. It would let the sidebar
    /// claim more minutes than a day has, and disagree with the Stats tab of the same window
    /// about the same day.
    private func blockFacts(
        days: [String], labels: TimelineLabels = TimelineLabels()
    ) throws -> [String: DayBlockFacts] {
        guard !days.isEmpty else { return [:] }
        let blocks = try db.writer.read { db in
            try ActivityBlock.filter(days.contains(Column("day"))).fetchAll(db)
        }
        return Dictionary(
            grouping: StatsAggregator.clippedToNow(blocks, now: now()), by: \.day
        ).mapValues { blocks in
            let active = blocks.filter { !StatsAggregator.isInactive($0) }
            return DayBlockFacts(
                hasTimeline: true,
                activeMinutes: StatsAggregator.minutes(StatsAggregator.unionSeconds(active)),
                topApps: DayIndex.topApps(active, labels: labels)
            )
        }
    }

    /// The apps a day's active blocks spent the most time in, longest first, named the way the
    /// timeline names them (#249). Ties break on the key so two runs say the same thing.
    private static func topApps(
        _ active: [ActivityBlock], labels: TimelineLabels = TimelineLabels()
    ) -> [String] {
        var seconds: [String: Double] = [:]
        for block in active where !block.appKey.isEmpty {
            seconds[block.appKey, default: 0] += StatsAggregator.seconds(block)
        }
        return seconds
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(DayHeadline.nameLimit)
            .map { labels.app($0.key) }
    }
}

/// The spelling the MCP tools use. Same type, same answers (#134).
public typealias MCPDayIndex = DayIndex
