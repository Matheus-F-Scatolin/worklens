import Foundation
import GRDB

/// The reads and writes a `ContextSyncSource` needs on top of `upsert`/`fetch`.
///
/// Added here rather than in `Storage/` so the sync framework (#19) stays in one directory.
public extension ContextEventStore {
    /// Whether an upsert created a row or refreshed one, so a sync can report `3 new, 1 updated`.
    enum SaveOutcome: Sendable, Equatable {
        case inserted
        case updated
        /// Nothing about the event changed, so nothing was written.
        case unchanged
    }

    /// One event by its source-side identity.
    func find(source: ContextSource, externalId: String) throws -> ContextEvent? {
        try database.writer.read { db in
            try ContextEvent
                .filter(Column("source") == source.rawValue && Column("external_id") == externalId)
                .fetchOne(db)
        }
    }

    /// Upserts and says what happened.
    ///
    /// `syncedAt` alone never counts as a change — otherwise every re-sync would report the whole
    /// window as updated — and timestamps are compared at the millisecond GRDB actually stores,
    /// so a `Date` that survived a round trip still equals the one the source just built.
    @discardableResult
    func save(_ event: ContextEvent) throws -> SaveOutcome {
        guard let existing = try find(source: event.source, externalId: event.externalId) else {
            try upsert(event)
            return .inserted
        }
        var candidate = event
        candidate.id = existing.id
        guard Self.comparable(candidate) != Self.comparable(existing) else { return .unchanged }

        var stored = event
        stored.id = existing.id
        try upsert(stored)
        return .updated
    }

    /// The event with the fields that do not mean "changed" flattened out.
    private static func comparable(_ event: ContextEvent) -> ContextEvent {
        var copy = event
        copy.startAt = storageDate(event.startAt)
        copy.endAt = event.endAt.map(storageDate)
        copy.syncedAt = .distantPast
        return copy
    }

    /// GRDB writes dates as `yyyy-MM-dd HH:mm:ss.SSS`, so anything finer than a millisecond is
    /// lost on the way to SQLite and must be dropped before comparing.
    private static func storageDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Removes a row (a cancelled calendar event) and its body file, if any.
    @discardableResult
    func delete(source: ContextSource, externalId: String, config: Config? = nil) throws -> Bool {
        let existing = try find(source: source, externalId: externalId)
        if let config, let path = existing?.bodyPath { ContextBody.delete(path, config: config) }
        return try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM context_events WHERE source = ? AND external_id = ?",
                arguments: [source.rawValue, externalId]
            )
            return db.changesCount > 0
        }
    }

    func count(source: ContextSource) throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM context_events WHERE source = ?",
                arguments: [source.rawValue]
            ) ?? 0
        }
    }

    /// Every event of one local day, oldest first.
    func fetch(day: String, timeZone: TimeZone = .current, sources: [ContextSource]? = nil) throws -> [ContextEvent] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        return try fetch(from: range.start, to: range.end, sources: sources)
    }

    /// Everything one local day should know about: the events that *started* in it, plus any
    /// meeting that started earlier and was still running when the day began.
    ///
    /// `fetch(day:)` filters on `start_at`, which is right for an instant and wrong for a call
    /// that crossed midnight. `TimelineWriter` already gives
    /// that day a meeting *block* for it (it rebuilds blocks by overlap), so the timeline's
    /// Context section and the day's meeting count have to see the same meeting or the two
    /// halves of the file contradict each other.
    func events(day: String, timeZone: TimeZone = .current) throws -> [ContextEvent] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        var byId: [String: ContextEvent] = [:]
        for event in try fetch(from: range.start, to: range.end) { byId[event.id] = event }
        for meeting in try meetings(overlapping: range.start, to: range.end) { byId[meeting.id] = meeting }
        return byId.values.sorted {
            $0.startAt == $1.startAt ? $0.id < $1.id : $0.startAt < $1.startAt
        }
    }

    /// The name of the synced meeting covering `instant`, with the detector's usual ±2 min
    /// tolerance, or nil when no calendar/Granola event does.
    ///
    /// This is the lookup behind the describe prompt's `In meeting: yes — "Title"` line. The
    /// describe worker uses it when a frame is sent.
    func meetingTitle(covering instant: Date) -> String? {
        let tolerance = MeetingDetector.calendarTolerance
        let events = (try? meetings(
            overlapping: instant.addingTimeInterval(-tolerance),
            to: instant.addingTimeInterval(tolerance)
        )) ?? []
        return MeetingDetector.meeting(covering: instant, in: events)?.title?.nonEmpty
    }

    /// Meetings that overlap `[from, to)` — an event that started before the window but is
    /// still running counts, which a plain `start_at` filter would miss.
    ///
    /// The left edge is decided by `end_at` where the source gave one, so a three-hour offsite is
    /// still "running" two hours in. Only an event with no end at all falls back to the assumed
    /// duration, and that fallback is spelled here and in `effectiveEndAt` and nowhere else; the
    /// exact overlap is then re-checked in Swift.
    func meetings(overlapping from: Date, to: Date) throws -> [ContextEvent] {
        let widened = from.addingTimeInterval(-ContextEvent.assumedMeetingDuration)
        let candidates = try database.writer.read { db in
            try ContextEvent
                .filter(Column("is_meeting") == true
                    && Column("start_at") < to
                    && (Column("end_at") > from
                        || (Column("end_at") == nil && Column("start_at") >= widened)))
                .order(Column("start_at").asc)
                .fetchAll(db)
        }
        return candidates.filter { $0.effectiveEndAt > from }
    }
}
