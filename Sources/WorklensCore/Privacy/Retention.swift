import Foundation
import GRDB

/// What one retention pass removed (#144).
///
/// Returned so the menu can say it in a sentence and the tests can assert on it without reading
/// the database back — the same shape `DiskSweep` and `EraseSummary` already use.
public struct RetentionSweep: Sendable, Equatable {
    /// The oldest local day still kept, `YYYY-MM-DD`. Nil when `RETENTION_DAYS` is 0 and nothing
    /// ages out at all.
    public var oldestKeptDay: String?
    /// The local days whose frames went, oldest first.
    public var days: [String]
    /// `captures` rows deleted. Their descriptions and `ax_snapshots` went with them, by cascade.
    public var frames: Int
    /// JPEGs unlinked. Always ≤ `frames`: a described-and-deleted frame has no file left.
    public var images: Int
    /// `foreground_sessions` rows deleted or trimmed.
    public var sessions: Int
    /// `activity_blocks` rows deleted — only under `RETENTION_KEEP_REPORTS=false`.
    public var blocks: Int
    /// `friction_items` rows deleted — only under `RETENTION_KEEP_REPORTS=false`.
    public var friction: Int
    /// Timeline `.md` files deleted — only under `RETENTION_KEEP_REPORTS=false`.
    public var timelines: Int

    public init(
        oldestKeptDay: String? = nil,
        days: [String] = [],
        frames: Int = 0,
        images: Int = 0,
        sessions: Int = 0,
        blocks: Int = 0,
        friction: Int = 0,
        timelines: Int = 0
    ) {
        self.oldestKeptDay = oldestKeptDay
        self.days = days
        self.frames = frames
        self.images = images
        self.sessions = sessions
        self.blocks = blocks
        self.friction = friction
        self.timelines = timelines
    }

    /// True when the pass actually deleted something, so a quarter-hourly no-op stays silent.
    public var didAnything: Bool { frames > 0 || sessions > 0 || !days.isEmpty }
}

/// Lets the history age out: deletes what is older than `RETENTION_DAYS` (#144).
///
/// Before this there were two ways data went away on its own — screenshots by size
/// (`DiskBudget`, whole day folders oldest first) and log files by day (`FileLog`) — and one
/// that happened at describe time (`DELETE_SCREENSHOTS_AFTER_DESCRIBE` and
/// `DELETE_SENSITIVE_SCREENSHOTS` dropping the JPEG and the stored window outline). Every row
/// was kept forever, so "drop last quarter" meant driving the date-range purge in Settings →
/// Privacy by hand.
///
/// What a pass deletes, and what it deliberately leaves:
///
/// - **Gone:** `captures` older than the cutoff, taking their `descriptions` and `ax_snapshots`
///   with them by cascade, their JPEGs, and `foreground_sessions` over the same stretch.
/// - **Kept:** any timeline markdown written before #299, `activity_blocks`, `friction_items`, `context_events`,
///   `llm_calls` and every report written before the reports were cut (2026-10-05). Those are
///   the summaries the frames were collected for, and the spend ledger is money that was really
///   spent. `RETENTION_KEEP_REPORTS=false` drops the first three for the aged-out days; the rest
///   are never touched, as in `DataEraser`.
///
/// A pass **does not rebuild the timelines** for the days it empties. The blocks already built
/// are the surviving record of those days; rebuilding them from the frames that are now gone
/// would blank exactly what this is meant to keep. For the same reason it does not
/// write `app_state.last_erase`: the user did not erase anything, and Settings → Privacy must
/// not claim they did.
///
/// And like `DiskBudget.sweep`, **today and yesterday are never touched**, whatever
/// `RETENTION_DAYS` says.
public struct Retention: Sendable {
    /// Today and yesterday, never aged out. Same rule and same reason as `DiskBudget`.
    public static let protectedDays = DiskBudget.protectedDays

    private let config: Config
    private let db: Database
    private let captures: CaptureStore
    private let blocks: ActivityBlockStore
    private let sessions: ForegroundSessionStore
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    public init(
        config: Config,
        db: Database,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.db = db
        self.captures = CaptureStore(db)
        self.blocks = ActivityBlockStore(db)
        self.sessions = ForegroundSessionStore(db)
        self.timeZone = timeZone
        self.now = now
    }

    // MARK: The decision (pure)

    /// The first local day still kept, or nil when `days` is 0 and nothing ages out.
    ///
    /// Counting includes today: 1 keeps today, 30 keeps this month. Clamped so the answer is
    /// never later than yesterday — today and yesterday survive any number.
    ///
    /// Pure over a clock, which is what makes the boundary testable without a database.
    public static func oldestKeptDay(
        days: Int, today: Date, timeZone: TimeZone = .current
    ) -> String? {
        guard days > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let asked = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let protected = calendar.date(
                  byAdding: .day, value: -(Retention.protectedDays - 1), to: today
              )
        else { return nil }
        // The earlier of the two: a small RETENTION_DAYS may not reach past yesterday.
        return DayBoundaries.dayString(min(asked, protected), timeZone: timeZone)
    }

    /// The instant everything before goes: the start of `oldestKeptDay`, minus a moment, so the
    /// range handed to the stores is inclusive on both ends like `DataEraser`'s.
    public func cutoff() -> (day: String, lastCondemnedInstant: Date)? {
        guard let day = Retention.oldestKeptDay(
            days: config.retentionDays, today: now(), timeZone: timeZone
        ) else { return nil }
        guard let start = DayBoundaries.range(day: day, timeZone: timeZone)?.start else {
            return nil
        }
        return (day, start.addingTimeInterval(-0.001))
    }

    // MARK: Sweeping

    /// Deletes everything older than the cutoff. Idempotent, and cheap when there is nothing to
    /// do: one count and no writes.
    @discardableResult
    public func sweep() throws -> RetentionSweep {
        guard let (keptDay, last) = cutoff() else { return RetentionSweep() }
        // #321: a prompt's instant and an agent's turn age out with the screenshots of the same
        // days. Before the early return below, which only looks at captures and sessions.
        try AgentSessionStore(db).deleteActivity(from: .distantPast, to: last)

        let condemnedDays = try daysBefore(last)
        let frames = try count(through: last)
        guard frames > 0 || !condemnedDays.isEmpty || sessionsExist(through: last) else {
            return RetentionSweep(oldestKeptDay: keptDay)
        }

        let imagePaths = try captures.deleteRange(from: .distantPast, to: last)
        let unlinked = ScreenshotPaths.unlink(relativePaths: imagePaths, dataDir: config.dataDir)
        // The day folders those files lived in are empty now, and an empty folder that never
        // goes away is what `DiskBudget.measure` would keep walking forever.
        for day in condemnedDays { removeEmptyScreenshotFolder(day: day) }

        let sessionCounts = try sessions.deleteRange(from: .distantPast, to: last)

        var sweep = RetentionSweep(
            oldestKeptDay: keptDay,
            days: condemnedDays,
            frames: frames,
            images: unlinked,
            sessions: sessionCounts.total
        )
        if !config.retentionKeepReports {
            let derived = try dropDerivedRecord(days: condemnedDays)
            sweep.blocks = derived.blocks
            sweep.friction = derived.friction
            sweep.timelines = derived.timelines
        }

        // Deliberately no title, no app, no host: what aged out is exactly what must not be
        // written down again on the way out.
        Log.storage.info(
            "retention: deleted \(sweep.frames) frames over \(sweep.days.count) day(s) older than "
                + "\(config.retentionDays) days, \(sweep.images) image files"
        )
        return sweep
    }

    // MARK: Internals

    private func count(through last: Date) throws -> Int {
        try db.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM captures WHERE captured_at <= ?", arguments: [last]
            ) ?? 0
        }
    }

    private func sessionsExist(through last: Date) -> Bool {
        let count = try? db.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM foreground_sessions WHERE start_at <= ?",
                arguments: [last]
            ) ?? 0
        }
        return (count ?? 0) > 0
    }

    /// The distinct local days the condemned rows belong to, read before they go.
    private func daysBefore(_ last: Date) throws -> [String] {
        let stamps: [Date] = try db.writer.read { db in
            try Date.fetchAll(
                db, sql: "SELECT captured_at FROM captures WHERE captured_at <= ?",
                arguments: [last]
            )
        }
        return Array(Set(stamps.map { DayBoundaries.dayString($0, timeZone: timeZone) })).sorted()
    }

    private func removeEmptyScreenshotFolder(day: String) {
        let folder = config.screenshotsDir.appendingPathComponent(day)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard let contents, contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// `RETENTION_KEEP_REPORTS=false`: the day's derived record goes too — its blocks, its
    /// `friction_items` rows and any timeline markdown written before #299. Report files are never deleted.
    private func dropDerivedRecord(
        days: [String]
    ) throws -> (blocks: Int, friction: Int, timelines: Int) {
        var blockRows = 0
        for day in days {
            blockRows += try blocks.fetch(day: day).count
            try blocks.deleteBlocks(day: day, sources: ActivitySource.allCases)
        }
        // #299: the ledger is gone but its table stays, so its rows go by plain SQL.
        let frictionRows = (try? db.writer.write { db -> Int in
            guard !days.isEmpty else { return 0 }
            try db.execute(
                sql: "DELETE FROM friction_items WHERE day IN (\(databaseQuestionMarks(count: days.count)))",
                arguments: StatementArguments(days)
            )
            return db.changesCount
        }) ?? 0

        var timelines = 0
        for day in days {
            let url = config.timelineDir.appendingPathComponent("\(day).md")
            if (try? FileManager.default.removeItem(at: url)) != nil { timelines += 1 }
        }

        return (blockRows, frictionRows, timelines)
    }
}
