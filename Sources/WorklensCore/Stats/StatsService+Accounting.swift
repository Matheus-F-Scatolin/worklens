import Foundation

/// The storage side of `DayAccounting` (#320): the reads it needs beyond what `daily` already
/// fetched, and the call into the pure function.
extension StatsService {
    /// The day's accounting from the blocks, rows and sessions `daily` already read, plus the
    /// coverage gaps, the transitions and the row carried over midnight. Nil for a day that
    /// does not parse.
    static func accounting(
        db: Database,
        day: String,
        timeZone: TimeZone,
        now: Date,
        blocks: [ActivityBlock],
        captures: [Capture],
        sessions: [ForegroundSession],
        baseIntervals: DayAccounting.BaseIntervals
    ) throws -> DayAccounting? {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return nil }
        let through = min(range.end, max(range.start, now))
        let coverage = CoverageEventStore(db)
        return DayAccounting.compute(
            range: range,
            now: now,
            blocks: blocks,
            captures: captures,
            carryIn: try db.lastCaptureRow(before: range.start),
            sessions: sessions,
            coverageEvents: try coverage.events(from: range.start, to: through),
            gaps: try coverage.gaps(day: day, timeZone: timeZone, now: now),
            baseIntervals: baseIntervals
        )
    }
}
