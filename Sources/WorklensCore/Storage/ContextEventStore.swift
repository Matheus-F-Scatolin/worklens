import Foundation
import GRDB

/// Reads and writes `context_events`.
public struct ContextEventStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    /// The connection this store was built on. `Context/ContextEventStore+Sync.swift` adds the
    /// reads and writes the sync framework (#19) needs, and they need the same writer.
    var database: Database { db }

    /// Re-syncing a source must not duplicate rows, so this upserts on `(source, external_id)`
    /// and keeps the original `id`.
    public func upsert(_ event: ContextEvent) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO context_events
                      (id, source, external_id, start_at, end_at, title, participants_json,
                       body_md, body_path, is_meeting, raw_json, synced_at, outcomes_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source, external_id) DO UPDATE SET
                      start_at = excluded.start_at,
                      end_at = excluded.end_at,
                      title = excluded.title,
                      participants_json = excluded.participants_json,
                      body_md = excluded.body_md,
                      body_path = excluded.body_path,
                      is_meeting = excluded.is_meeting,
                      raw_json = excluded.raw_json,
                      synced_at = excluded.synced_at,
                      outcomes_json = excluded.outcomes_json
                    """,
                arguments: [
                    event.id, event.source.rawValue, event.externalId, event.startAt, event.endAt,
                    event.title, event.participantsJson, event.bodyMd, event.bodyPath,
                    event.isMeeting, event.rawJson, event.syncedAt, event.outcomesJson,
                ]
            )
        }
    }

    /// Events overlapping `[from, to)`, oldest first. Pass `sources` to narrow.
    public func fetch(from: Date, to: Date, sources: [ContextSource]? = nil) throws -> [ContextEvent] {
        try db.writer.read { db in
            var request = ContextEvent
                .filter(Column("start_at") >= from && Column("start_at") < to)
            if let sources, !sources.isEmpty {
                request = request.filter(sources.map(\.rawValue).contains(Column("source")))
            }
            return try request.order(Column("start_at").asc).fetchAll(db)
        }
    }

    /// When this source last stored anything, from `synced_at` (#141).
    ///
    /// The fallback for a grant that predates persisted status: without it a connection holding
    /// thousands of events reads "Connected · never synced" after every relaunch. `synced_at`
    /// rather than `MAX(start_at)`, which the review note suggested — Calendar syncs a day of
    /// *future* events, so the newest `start_at` is routinely tomorrow, and the card would say
    /// the last sync happened in twenty hours' time.
    public func lastSyncedAt(source: ContextSource) throws -> Date? {
        try db.writer.read { db in
            try Date.fetchOne(
                db, sql: "SELECT MAX(synced_at) FROM context_events WHERE source = ?",
                arguments: [source.rawValue]
            )
        }
    }

    /// The `body_path`s one source owns — the transcript files "Delete synced data…" removes
    /// alongside the rows (#141).
    public func bodyPaths(source: ContextSource) throws -> [String] {
        try db.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT body_path FROM context_events WHERE source = ? AND body_path IS NOT NULL",
                arguments: [source.rawValue]
            )
        }
    }

    /// The distinct local days this source has events in, so each one's timeline can be rebuilt
    /// after a delete (Settings → Connections' Delete synced data). Redrawing only today and
    /// yesterday is right after a sync and wrong after removing two years of meetings.
    ///
    /// Every day an event *touches*, not only the one it starts on: `ContextBlocks.meetingBlocks`
    /// clamps a 23:30–00:30 meeting into both days under the same id, so a delete that knew only
    /// about the start day left a titled block behind on the next one (#141).
    public func days(source: ContextSource, timeZone: TimeZone = .current) throws -> [String] {
        let spans: [(Date, Date?)] = try db.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT start_at, end_at FROM context_events WHERE source = ?",
                arguments: [source.rawValue]
            ).map { row in (row["start_at"], row["end_at"]) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var days: Set<String> = []
        for (start, endAt) in spans {
            // `ContextEvent.effectiveEndAt`'s fallback, so this covers exactly the days a block
            // can be drawn on.
            let end = endAt ?? start.addingTimeInterval(ContextEvent.assumedMeetingDuration)
            let endDay = DayBoundaries.dayString(end, timeZone: timeZone)
            var cursor = start
            var day = DayBoundaries.dayString(cursor, timeZone: timeZone)
            days.insert(day)
            // Bounded, so one row with a nonsense end date cannot spin here.
            var steps = 0
            while day < endDay, steps < 366,
                let next = calendar.date(byAdding: .day, value: 1, to: cursor) {
                cursor = next
                day = DayBoundaries.dayString(cursor, timeZone: timeZone)
                days.insert(day)
                steps += 1
            }
        }
        return days.sorted()
    }

    /// Removes every row one source owns and says how many went. The body files are the caller's
    /// to remove — it has the `Config` that knows where `DATA_DIR` is.
    @discardableResult
    public func deleteAll(source: ContextSource) throws -> Int {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM context_events WHERE source = ?", arguments: [source.rawValue]
            )
            return db.changesCount
        }
    }
}
