import Foundation
import GRDB

/// What one erase removed. Returned so the menu can say it in a sentence and the tests can
/// assert on it without reading the database back.
public struct EraseSummary: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    /// `captures` rows deleted. Their descriptions went with them, by cascade.
    public var frames: Int
    /// JPEGs unlinked. Always ≤ `frames`: a described-and-deleted frame has no file left.
    public var images: Int
    /// Screen blocks removed before the affected days were rebuilt.
    public var blocks: Int
    /// `foreground_sessions` rows deleted or trimmed (#46).
    public var sessions: Int
    /// `friction_items` rows deleted (#92). The ledger is gone (#299) but its table stays, and a
    /// row in it names projects and windows, so an erased day must not keep one.
    public var friction: Int
    /// The local days whose timeline was redrawn, oldest first.
    public var days: [String]

    public init(
        from: Date,
        to: Date,
        frames: Int = 0,
        images: Int = 0,
        blocks: Int = 0,
        sessions: Int = 0,
        friction: Int = 0,
        days: [String] = []
    ) {
        self.from = from
        self.to = to
        self.frames = frames
        self.images = images
        self.blocks = blocks
        self.sessions = sessions
        self.friction = friction
        self.days = days
    }

    /// `12 screenshots · 9 image files · 2026-09-07` — what the confirmation alert reports
    /// afterwards. Two counts, because a screenshot whose JPEG was already pruned is still a row
    /// this deleted (docs/copy.md: the row is the screenshot, the JPEG is an image file).
    public var sentence: String {
        var parts = ["\(frames) screenshot\(frames == 1 ? "" : "s")"]
        if images > 0 { parts.append("\(images) image file\(images == 1 ? "" : "s")") }
        if !days.isEmpty { parts.append(days.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// What `app_state.last_erase` holds: the range and when it was asked for. Not an audit trail —
/// one entry, overwritten — but enough for the timeline footer to say a stretch was removed
/// rather than never recorded.
public struct LastErase: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var at: Date

    public init(from: Date, to: Date, at: Date) {
        self.from = from
        self.to = to
        self.at = at
    }
}

/// Deletes a stretch of the day and leaves everything else consistent.
///
/// The order matters and is the whole design:
///
/// 1. `captures` in `[from, to]` go, taking their `descriptions` and their `ax_snapshots` — the
///    stored window outlines (#53) — with them by cascade, and their JPEGs are unlinked.
///    `CaptureStore.deleteRange` already returns the paths to unlink.
/// 2. Only the **screen** blocks overlapping the range are removed, not the whole day's: a
///    partial erase must not take down the blocks either side of it. `foreground_sessions` is
///    trimmed the same way (#46): rows inside the stretch go, rows that only overlap an edge keep
///    the part outside it, and a row spanning the whole stretch is split in two.
/// 3. Each affected local day's timeline is rebuilt, so `activity_blocks` agrees with what is
///    left, and its `DATA_DIR/timeline/<day>.md` — a copy written before #299 stopped writing
///    them — is removed, so it cannot outlive the erase.
/// 4. The affected days' `friction_items` rows go (#92), by plain SQL: the ledger that wrote them
///    is gone (#299), but the rows still name projects and windows. Whole days, because a
///    friction row is dated to a day and cannot say which of its minutes fell inside a partial
///    erase.
/// 5. The prompt instants inside the range and the agent turns overlapping it go (#321); the
///    sessions themselves, like `outputs`, stay.
///
/// Two things it deliberately does not touch: `llm_calls`, because money was really spent and a
/// budget that forgets is a broken budget; and `context_events`, because a meeting you attended
/// is not something Worklens watched you do.
public struct DataEraser: Sendable {
    /// `app_state` key holding the most recent erase.
    public static let lastEraseKey = "last_erase"

    private let config: Config
    private let db: Database
    private let captures: CaptureStore
    private let blocks: ActivityBlockStore
    private let sessions: ForegroundSessionStore
    private let appState: AppStateStore
    private let timeline: TimelineWriter?
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    public init(
        config: Config,
        db: Database,
        timeline: TimelineWriter? = nil,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.db = db
        self.captures = CaptureStore(db)
        self.blocks = ActivityBlockStore(db)
        self.sessions = ForegroundSessionStore(db)
        self.appState = AppStateStore(db)
        self.timeline = timeline
        self.timeZone = timeZone
        self.now = now
    }

    // MARK: Asking before doing

    /// How many frames an erase would remove. What the confirmation alert counts, so the user is
    /// never asked to approve an unknown number.
    public func count(from: Date, to: Date) throws -> Int {
        try db.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM captures WHERE captured_at >= ? AND captured_at <= ?",
                arguments: [from, to]
            ) ?? 0
        }
    }

    /// The range covering the last `minutes` minutes, ending now.
    public func recentRange(minutes: Int) -> (from: Date, to: Date) {
        let end = now()
        return (end.addingTimeInterval(-Double(minutes) * 60), end)
    }

    /// The instant range covering whole local days `[fromDay, toDay]`, for the date-range purge.
    public func dayRange(from fromDay: String, to toDay: String) -> (from: Date, to: Date)? {
        guard let start = DayBoundaries.range(day: fromDay, timeZone: timeZone)?.start,
              let end = DayBoundaries.range(day: toDay, timeZone: timeZone)?.end
        else { return nil }
        guard start <= end else { return dayRange(from: toDay, to: fromDay) }
        // `end` is the next day's midnight and the range is inclusive, so step back a moment or
        // an erase of "the 6th" would also take the first frame of the 7th.
        return (start, end.addingTimeInterval(-0.001))
    }

    // MARK: Erasing

    @discardableResult
    public func erase(from: Date, to: Date) async throws -> EraseSummary {
        guard from <= to else { return try await erase(from: to, to: from) }

        // The days are read off the rows before they go: a range can start in one local day and
        // end in the next, and after the delete there is nothing left to ask.
        let condemnedDays = try daysCovered(from: from, to: to)
        let frames = try count(from: from, to: to)
        let imagePaths = try captures.deleteRange(from: from, to: to)

        let unlinked = ScreenshotPaths.unlink(relativePaths: imagePaths, dataDir: config.dataDir)

        let blockDays = try blocks.deleteScreenBlocks(overlapping: from, to: to)
        let sessionCounts = try sessions.deleteRange(from: from, to: to)
        // #321: the prompts typed and the agent turns run inside the stretch. The store keeps
        // every erased range and the sync skips them all, so a re-read never brings them back.
        try AgentSessionStore(db).deleteActivity(from: from, to: to, remember: true)

        let days = Set(condemnedDays).union(blockDays).sorted()
        let frictionRows = (try? deleteFriction(days: days)) ?? 0
        for day in days {
            // No writer in the CLI paths that only need the rows gone; the app always has one.
            if let timeline { _ = try? await timeline.rebuild(day: day) }
            try? FileManager.default.removeItem(
                at: config.timelineDir.appendingPathComponent("\(day).md")
            )
        }

        try appState.setCodable(
            DataEraser.lastEraseKey, LastErase(from: from, to: to, at: now())
        )

        let summary = EraseSummary(
            from: from, to: to,
            frames: frames, images: unlinked, blocks: blockDays.count,
            sessions: sessionCounts.total, friction: frictionRows, days: days
        )
        // Deliberately no title, no app, no host: what was erased is exactly what must not be
        // written down again on the way out.
        Log.storage.info("erased \(summary.frames) frames over \(days.count) day(s)")
        return summary
    }

    public func lastErase() throws -> LastErase? {
        try appState.getCodable(DataEraser.lastEraseKey)
    }

    /// Removes the `friction_items` rows of whole local days. The table outlived the ledger
    /// (#299: no migration drops a table), so the erase deletes its rows directly.
    private func deleteFriction(days: [String]) throws -> Int {
        guard !days.isEmpty else { return 0 }
        return try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM friction_items WHERE day IN (\(databaseQuestionMarks(count: days.count)))",
                arguments: StatementArguments(days)
            )
            return db.changesCount
        }
    }

    /// The distinct local days the rows in a range belong to.
    private func daysCovered(from: Date, to: Date) throws -> [String] {
        let stamps: [Date] = try db.writer.read { db in
            try Date.fetchAll(
                db,
                sql: "SELECT captured_at FROM captures WHERE captured_at >= ? AND captured_at <= ?",
                arguments: [from, to]
            )
        }
        return Array(Set(stamps.map { DayBoundaries.dayString($0, timeZone: timeZone) })).sorted()
    }
}
