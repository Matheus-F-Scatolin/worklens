import Foundation
import GRDB

/// Reads and writes `captures`.
public struct CaptureStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    /// `app_state` key holding the previous frame's fingerprint, so change detection survives a restart.
    public static let lastFingerprintKey = "last_fingerprint"

    /// `app_state` key holding the previous frame's **redacted** accessibility text hash (#53).
    /// Owned here, beside the fingerprint, because it is the same kind of thing: what the next
    /// tick compares against, and what a restart must not lose.
    public static let lastAXTextHashKey = "last_ax_text_hash"

    public func insert(_ capture: Capture) throws {
        try db.writer.write { db in
            try capture.insert(db)
            try index(capture, in: db)
        }
    }

    public func update(_ capture: Capture) throws {
        try db.writer.write { db in
            try capture.update(db)
            try index(capture, in: db)
        }
    }

    /// The two texts this table owns for `search_fts` (#88). The day is taken from the row in
    /// hand rather than read back, because this runs on every tick.
    private func index(_ capture: Capture, in db: GRDB.Database) throws {
        let day = DayBoundaries.dayString(capture.capturedAt)
        try SearchIndex.set(
            db, captureId: capture.id, day: day, kind: .title, text: capture.windowTitle
        )
        try SearchIndex.set(
            db, captureId: capture.id, day: day, kind: .url, text: capture.browserUrl
        )
    }

    public func fetch(id: String) throws -> Capture? {
        try db.writer.read { try Capture.fetchOne($0, key: id) }
    }

    /// Oldest-first, so the describe worker drains the backlog in order.
    public func fetchPendingDescribe(limit: Int) throws -> [Capture] {
        try db.writer.read { db in
            try Capture
                .filter(Column("describe_status") == DescribeStatus.pending.rawValue)
                .order(Column("captured_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// The most recent frame that actually got a description (used for inheritance).
    public func fetchLastDescribed() throws -> Capture? {
        try db.writer.read { db in
            try Capture
                .filter([DescribeStatus.described.rawValue, DescribeStatus.inherited.rawValue]
                    .contains(Column("describe_status")))
                .order(Column("captured_at").desc)
                .fetchOne(db)
        }
    }

    /// The newest row and what became of it, as the menu's two "Last frame" lines need it (#151).
    ///
    /// One read, and three columns of the description rather than the whole row: `raw_json` is
    /// the model's entire answer, and the menu wants one sentence of it. `fetchLastDescribed`
    /// cannot answer this — the newest frame is often not a described one, and a blocked or
    /// pending frame is exactly the case the user opened the menu to see.
    ///
    /// Bounded by `day`, because the counts it sits beside in the menu are. Unbounded it drew
    /// "Last frame: Safari · 2 hours ago · described" from Friday evening under Monday's
    /// `0 screenshots` — one line about a day that had ended and one about the day it had not.
    /// Nothing today means no line, which is the honest answer to a morning before the first
    /// capture.
    public func fetchLastFrame(day: String, timeZone: TimeZone = .current) throws -> LastFrame? {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return nil }
        return try db.writer.read { db in
            guard let capture = try Capture
                .filter(Column("captured_at") >= range.start && Column("captured_at") < range.end)
                .order(Column("captured_at").desc)
                .fetchOne(db)
            else { return nil }
            let row = try Row.fetchOne(db, sql: """
                SELECT summary_md, is_sensitive FROM descriptions WHERE capture_id = ? LIMIT 1
                """, arguments: [capture.id])
            var summary: String?
            var isSensitive = false
            if let row {
                summary = row["summary_md"]
                isSensitive = row["is_sensitive"] ?? false
            }
            return LastFrame(
                at: capture.capturedAt,
                appName: capture.appName,
                outcome: LastFrame.outcome(
                    describeStatus: capture.describeStatus,
                    skipReason: capture.skipReason,
                    isRedacted: capture.isRedacted,
                    isSensitive: isSensitive
                ),
                summary: summary
            )
        }
    }

    /// The previous frame's fingerprint, stored as JSON in `app_state` rather than as a column.
    public func fetchLastFingerprint<T: Decodable>() throws -> T? {
        try AppStateStore(db).getCodable(CaptureStore.lastFingerprintKey)
    }

    public func setLastFingerprint<T: Encodable>(_ value: T) throws {
        try AppStateStore(db).setCodable(CaptureStore.lastFingerprintKey, value)
    }

    /// The previous frame's accessibility text hash, or nil when there is nothing to compare
    /// against — a fresh install, a different app in front, or a stretch the scheduler forgot.
    public func fetchLastAXTextHash() throws -> String? {
        try AppStateStore(db).get(CaptureStore.lastAXTextHashKey)
    }

    public func setLastAXTextHash(_ hash: String) throws {
        try AppStateStore(db).set(CaptureStore.lastAXTextHashKey, hash)
    }

    public func deleteLastAXTextHash() throws {
        try AppStateStore(db).delete(CaptureStore.lastAXTextHashKey)
    }

    /// Every capture in one local day, oldest first.
    public func fetch(day: String, timeZone: TimeZone = .current) throws -> [Capture] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        return try db.writer.read { db in
            try Capture
                .filter(Column("captured_at") >= range.start && Column("captured_at") < range.end)
                .order(Column("captured_at").asc)
                .fetchAll(db)
        }
    }

    /// The browser bundle ids that got **no** URL out of today at all: at least one frame with
    /// `url_source = none` and not one frame with a URL from either reader.
    ///
    /// Read from the stored columns rather than from a counter in the collector (#64): a counter
    /// resets on every launch and cannot be tested against anything, while these rows are
    /// stored evidence. Says nothing about *why* — the caller pairs it with
    /// `AutomationPermission` to decide whether there is anything the user could do about it.
    ///
    /// "Not one frame" rather than "any frame", because the second was a lie by 10 a.m. on
    /// 2026-09-09: four Chrome frames missed their URL before Accessibility was granted, every
    /// frame after it had one, and a day-scoped "any" would have kept a "Browser URLs
    /// unavailable" line up until midnight while they worked. One frame from either reader is
    /// proof the path works, and it clears the line for the day.
    ///
    /// Only frames that recorded a `title_source` count, so a blocked or skipped row — which
    /// carries neither field by design — and every row a pre-#55 build wrote say nothing either
    /// way. Among those, a null `url_source` reads as `none`.
    public func browserBundlesWithoutURL(
        day: String, timeZone: TimeZone = .current
    ) throws -> Set<String> {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        let none = ForegroundContext.Source.none.rawValue
        let bundleIDs: [String] = try db.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT app_bundle_id
                FROM captures
                WHERE captured_at >= ? AND captured_at < ?
                  AND app_bundle_id IS NOT NULL AND title_source IS NOT NULL
                GROUP BY app_bundle_id
                HAVING SUM(CASE WHEN COALESCE(url_source, ?) = ? THEN 1 ELSE 0 END) > 0
                   AND SUM(CASE WHEN COALESCE(url_source, ?) <> ? THEN 1 ELSE 0 END) = 0
                """, arguments: [range.start, range.end, none, none, none, none])
        }
        return Set(bundleIDs.filter { BrowserRegistry.isBrowser($0) })
    }

    /// #286: when the first row of `day` was written — what General's status line means by
    /// "capturing since". The capture table rather than the timeline, because a calendar meeting
    /// laid over the morning is not Worklens having looked at anything.
    public func firstCaptureAt(day: String, timeZone: TimeZone = .current) throws -> Date? {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return nil }
        return try db.writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(captured_at) FROM captures WHERE captured_at >= ? AND captured_at < ?
                """, arguments: [range.start, range.end])
        }
    }

    public func markDescribed(id: String, status: DescribeStatus) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE captures SET describe_status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    public func countToday(timeZone: TimeZone = .current) throws -> Int {
        try count(day: DayBoundaries.dayString(Date(), timeZone: timeZone), timeZone: timeZone)
    }

    public func count(day: String, timeZone: TimeZone = .current) throws -> Int {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return 0 }
        return try db.writer.read { db in
            try Capture
                .filter(Column("captured_at") >= range.start && Column("captured_at") < range.end)
                .fetchCount(db)
        }
    }

    /// Whether a single frame has ever been stored, at any time, on any day.
    ///
    /// #131's launch gate asks this and nothing more: an install that has captured anything was
    /// running before the welcome window existed, so it is written down as onboarded and never
    /// interrupted. `EXISTS` rather than a count — the answer is the same and it stops at the
    /// first row.
    public func hasAny() throws -> Bool {
        try db.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM captures)") ?? false
        }
    }

    /// Blanks `image_path` for every frame of one local day, and reports how many rows changed.
    /// #18's disk sweep calls this before it unlinks the files: the descriptions stay, so the
    /// timeline and every report over that day are unaffected — the day just loses its pixels.
    @discardableResult
    public func clearImagePaths(day: String, timeZone: TimeZone = .current) throws -> Int {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return 0 }
        return try db.writer.write { db in
            try db.execute(sql: """
                UPDATE captures SET image_path = NULL
                WHERE image_path IS NOT NULL AND captured_at >= ? AND captured_at < ?
                """, arguments: [range.start, range.end])
            return db.changesCount
        }
    }

    /// Retires the pending frames older than `cutoff` as `skipped` / `budget`, and reports how
    /// many. #17's day rollover calls this: a frame that is still waiting a day later is waiting
    /// because the budget stopped it, and yesterday's screen is not worth today's money.
    @discardableResult
    public func markStalePendingOverBudget(before cutoff: Date) throws -> Int {
        try db.writer.write { db in
            try db.execute(sql: """
                UPDATE captures
                SET describe_status = ?, skip_reason = ?
                WHERE describe_status = ? AND captured_at < ?
                """, arguments: [
                    DescribeStatus.skipped.rawValue, SkipReason.budget.rawValue,
                    DescribeStatus.pending.rawValue, cutoff,
                ])
            return db.changesCount
        }
    }

    /// Puts the frames this day skipped for budget back in the describe queue, and reports how
    /// many. #137's one-day raise calls it: `CaptureScheduler` marks a frame `skipped`/`budget`
    /// at capture time while over budget, so raising the budget resumes nothing for the frames
    /// already taken unless they go back to `pending`. Only rows whose JPEG is still on disk —
    /// there is nothing left to describe once the image has been deleted.
    @discardableResult
    public func requeueBudgetSkipped(from: Date, to: Date) throws -> Int {
        try db.writer.write { db in
            try db.execute(sql: """
                UPDATE captures
                SET describe_status = ?, skip_reason = NULL
                WHERE describe_status = ? AND skip_reason = ? AND image_path IS NOT NULL
                  AND captured_at >= ? AND captured_at < ?
                """, arguments: [
                    DescribeStatus.pending.rawValue,
                    DescribeStatus.skipped.rawValue, SkipReason.budget.rawValue,
                    from, to,
                ])
            return db.changesCount
        }
    }

    /// Deletes every capture in `[from, to]` and returns the image paths the caller must unlink.
    /// Descriptions go with them via `ON DELETE CASCADE`.
    @discardableResult
    public func deleteRange(from: Date, to: Date) throws -> [String] {
        try db.writer.write { db in
            let condemned = try Capture
                .filter(Column("captured_at") >= from && Column("captured_at") <= to)
                .fetchAll(db)
            _ = try Capture
                .filter(Column("captured_at") >= from && Column("captured_at") <= to)
                .deleteAll(db)
            // `search_fts` is a virtual table, so no foreign key cascades into it: an erased
            // stretch stays erased only because this line runs in the same transaction (#88).
            try SearchIndex.removeAll(db, captureIds: condemned.map(\.id))
            return condemned.compactMap(\.imagePath)
        }
    }
}
