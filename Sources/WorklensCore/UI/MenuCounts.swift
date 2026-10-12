import Foundation
import GRDB

/// The numbers the menu-bar menu shows on its second line, and the Settings spend table's
/// "today" row. One grouped query plus one sum, so opening the menu costs two statements
/// rather than four `COUNT(*)`s.
public struct MenuCounts: Equatable, Sendable {
    /// Every row written today, including the idle/locked/blocked ones.
    public var captures: Int
    /// Frames that have a description — real calls plus free inherited copies.
    public var described: Int
    /// Frames queued for the vision model.
    public var pending: Int
    /// Frames that will never be described: three failed attempts, or nothing to describe them
    /// from. Zero on an ordinary day, which is why the menu only prints it when it is not (#125).
    public var failed: Int
    /// Frames the budget gate held back (`skip_reason = 'budget'`).
    public var skippedForBudget: Int
    /// #151: frames a blocklist matched, which stored their minute and nothing else — the same
    /// `is_redacted` flag the timeline's "redacted" blocks are built from, counted in frames
    /// because every other number on this line is in frames.
    public var blocked: Int
    /// #151: frames the vision model flagged sensitive. Inherited rows copy the flag, so this
    /// counts frames exactly as the timeline footer does.
    public var sensitive: Int
    /// #151: credentials `TextRedactor` replaced in a window title or a URL before the prompt was
    /// built, summed over described rows only — an inherited row carries a copy of the same
    /// `details_json`, and summing those would count one frame's redactions several times.
    public var redactions: Int
    /// Today's LLM spend in USD, from `llm_calls`.
    public var spendUSD: Double
    /// #146: how much of the day since Worklens first started it went unwatched — paused, not
    /// running, or without Screen Recording. Zero on an ordinary day, and the menu says nothing
    /// until it is material.
    public var uncoveredSeconds: TimeInterval

    public init(
        captures: Int = 0,
        described: Int = 0,
        pending: Int = 0,
        failed: Int = 0,
        skippedForBudget: Int = 0,
        blocked: Int = 0,
        sensitive: Int = 0,
        redactions: Int = 0,
        spendUSD: Double = 0,
        uncoveredSeconds: TimeInterval = 0
    ) {
        self.captures = captures
        self.described = described
        self.pending = pending
        self.failed = failed
        self.skippedForBudget = skippedForBudget
        self.blocked = blocked
        self.sensitive = sensitive
        self.redactions = redactions
        self.spendUSD = spendUSD
        self.uncoveredSeconds = uncoveredSeconds
    }

    public static let zero = MenuCounts()

    /// Reads the counts for one local day.
    public static func load(
        db: Database, day: String, timeZone: TimeZone = .current, now: Date = Date()
    ) throws -> MenuCounts {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return .zero }
        var counts = MenuCounts()
        try db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT describe_status AS status,
                       COALESCE(skip_reason, '') AS reason,
                       is_redacted AS redacted,
                       COUNT(*) AS n
                FROM captures
                WHERE captured_at >= ? AND captured_at < ?
                GROUP BY status, reason, redacted
                """, arguments: [range.start, range.end])
            for row in rows {
                let n: Int = row["n"]
                let status: String = row["status"]
                counts.captures += n
                // #151: one more column on the group, not one more query. A blocked frame is
                // still a capture and still idle-or-not; it is only what was kept that differs.
                if (row["redacted"] as Bool) == true { counts.blocked += n }
                switch DescribeStatus(rawValue: status) {
                case .described, .inherited: counts.described += n
                case .pending: counts.pending += n
                case .failed: counts.failed += n
                case .skipped where (row["reason"] as String) == SkipReason.budget.rawValue:
                    counts.skippedForBudget += n
                default: break
                }
            }
        }
        // #151: the two numbers that live on `descriptions` rather than `captures`. Small: one
        // COUNT, and one pass over the `details_json` of the day's described rows.
        let privacy = try DescriptionStore(db).privacyCounts(day: day, timeZone: timeZone)
        counts.sensitive = privacy.sensitive
        counts.redactions = privacy.redactions
        counts.spendUSD = try LLMCallStore(db).spend(from: range.start, to: range.end)
        // #146: one more small read, and only a number — the sentence behind it lives in the
        // timeline footer, where there is room for it.
        counts.uncoveredSeconds = (try? CoverageEventStore(db)
            .uncoveredSinceStart(day: day, timeZone: timeZone, now: now)) ?? 0
        return counts
    }

    public static func today(db: Database, timeZone: TimeZone = .current, now: Date = Date()) throws -> MenuCounts {
        try load(
            db: db, day: DayBoundaries.dayString(now, timeZone: timeZone), timeZone: timeZone, now: now
        )
    }
}
