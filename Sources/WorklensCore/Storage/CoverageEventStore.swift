import Foundation
import GRDB

/// Reads and writes `coverage_events`, and answers the one question the table exists for (#146):
/// which parts of a day was Worklens not watching?
public struct CoverageEventStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    public func insert(_ event: CoverageEvent) throws {
        try db.writer.write { db in try event.insert(db) }
    }

    /// The most recent transition, whenever it happened. The scheduler reads it at launch to
    /// notice a run that ended without saying so.
    public func latest() throws -> CoverageEvent? {
        try db.writer.read { db in
            try CoverageEvent.order(Column("at").desc).fetchOne(db)
        }
    }

    /// Everything in `[start, end)`, plus the last event before `start` — the one that says
    /// whether the day began with Worklens running.
    public func events(from start: Date, to end: Date) throws -> [CoverageEvent] {
        try db.writer.read { db in try Self.events(db, from: start, to: end) }
    }

    /// The uncovered spans of one local day: the transitions, plus the stretches the budget gate
    /// held back.
    ///
    /// `now` clips the day at the present moment, so today's report never claims Worklens will
    /// not be watching this evening.
    public func gaps(
        day: String, timeZone: TimeZone = .current, now: Date = Date()
    ) throws -> [CoverageGap] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        let end = min(range.end, max(range.start, now))
        // One read for the events, the rows and the proofs, so they describe the same moment.
        let (events, rows, proofs) = try db.writer.read { db in
            let rows = try Self.skipRows(db, from: range.start, to: end)
            return (
                try Self.events(db, from: range.start, to: end),
                rows,
                try Self.proofs(db, from: range.start, to: end, captureTimes: rows.map(\.at))
            )
        }
        let transitions = CoverageSpans.gaps(events: events, proofs: proofs, start: range.start, end: end)
        let budget = CoverageSpans.clip(
            CoverageSpans.budgetGaps(rows: rows, end: end),
            outside: transitions
        )
        return CoverageSpans.merge(transitions + budget)
    }

    /// What the menu asks: how much of today Worklens missed *since it first started today*.
    ///
    /// Measured from the day's first transition rather than from midnight, because the hours
    /// before you open your laptop are not a gap anybody wants told about — and telling them
    /// every morning is the fastest way to teach the eye to skip the line. The budget's spans are
    /// left out too: the counts line already says how many frames it held back.
    ///
    /// The exception is a day that *begins* with Worklens up and not watching — paused last
    /// night, or Screen Recording revoked and never restored. That is not the overnight quiet;
    /// it is the one thing this line exists to say, so it counts from midnight.
    ///
    /// The menu asks on every refresh, so this is one read, and a day with nothing to measure
    /// from returns before the captures are scanned.
    public func uncoveredSinceStart(
        day: String, timeZone: TimeZone = .current, now: Date = Date()
    ) throws -> TimeInterval {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return 0 }
        let end = min(range.end, max(range.start, now))
        return try db.writer.read { db in
            let all = try Self.events(db, from: range.start, to: end)
            let opening = all.last(where: { $0.at <= range.start })?.opensGap
            let carried = opening == .paused || opening == .permissionMissing
            guard let from = carried ? range.start : all.first(where: { $0.at > range.start })?.at
            else { return 0 }
            let captureTimes = try Self.skipRows(db, from: range.start, to: end).map(\.at)
            return CoverageSpans.total(CoverageSpans.gaps(
                events: all,
                proofs: try Self.proofs(db, from: range.start, to: end, captureTimes: captureTimes),
                start: from, end: end
            ))
        }
    }

    private static func events(_ db: GRDB.Database, from start: Date, to end: Date) throws -> [CoverageEvent] {
        let before = try CoverageEvent
            .filter(Column("at") <= start)
            .order(Column("at").desc)
            .fetchOne(db)
        let inside = try CoverageEvent
            .filter(Column("at") > start && Column("at") < end)
            .order(Column("at").asc)
            .fetchAll(db)
        return (before.map { [$0] } ?? []) + inside
    }

    /// Times only a running Worklens writes, ascending (#313): the range's captures and
    /// foreground-session starts, plus the latest of each before the range — the carry-in that
    /// says a `stopped` from yesterday was not the end. `end_at` is left out because it is
    /// written at quit. Timestamps only; nothing about what was on screen.
    private static func proofs(
        _ db: GRDB.Database, from start: Date, to end: Date, captureTimes: [Date]
    ) throws -> [Date] {
        let lastCapture = try Date.fetchOne(
            db, sql: "SELECT MAX(captured_at) FROM captures WHERE captured_at < ?", arguments: [start]
        )
        let lastSession = try Date.fetchOne(
            db, sql: "SELECT MAX(start_at) FROM foreground_sessions WHERE start_at <= ?", arguments: [start]
        )
        let sessions = try Date.fetchAll(
            db,
            sql: "SELECT start_at FROM foreground_sessions WHERE start_at > ? AND start_at < ?",
            arguments: [start, end]
        )
        return ([lastCapture, lastSession].compactMap { $0 } + captureTimes + sessions).sorted()
    }

    /// `(time, skip reason)` for the day's captures, in order — everything `budgetGaps` needs and
    /// nothing else, so a day's coverage costs one indexed scan rather than a row decode.
    private static func skipRows(
        _ db: GRDB.Database, from start: Date, to end: Date
    ) throws -> [(at: Date, skipReason: SkipReason?)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT captured_at, skip_reason FROM captures
                WHERE captured_at >= ? AND captured_at < ?
                ORDER BY captured_at ASC
                """,
            arguments: [start, end]
        ).map { row in
            (at: row["captured_at"] as Date, skipReason: (row["skip_reason"] as String?).flatMap(SkipReason.init(rawValue:)))
        }
    }
}
