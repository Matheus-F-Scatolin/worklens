import Foundation
import GRDB

/// The handful of reads and writes the describe worker needs that no repository from #5 offers.
/// A separate type rather than an extension: the stores keep their `Database` private, and #5's
/// files belong to another change.
public struct DescribeQueries: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    /// Frames the capture side marked `inherited` that still have no description row, oldest first.
    public func inheritedWithoutDescription(limit: Int) throws -> [Capture] {
        try db.writer.read { db in
            try Capture.fetchAll(db, sql: """
                SELECT c.* FROM captures c
                LEFT JOIN descriptions d ON d.capture_id = c.id
                WHERE c.describe_status = ? AND d.id IS NULL
                ORDER BY c.captured_at ASC
                LIMIT ?
                """, arguments: [DescribeStatus.inherited.rawValue, limit])
        }
    }

    /// The frame an unchanged capture was compared against: the latest earlier row that is neither
    /// an idle/lock row nor a blocked one. Nil for the very first frame ever recorded.
    ///
    /// Deliberately not bounded to the same local day. The scheduler forgets its fingerprint after
    /// every idle, lock or blocked stretch and re-describes on a 5-minute heartbeat, so a frame is
    /// only ever `inherited` when the screen genuinely did not change since the row before it —
    /// including across midnight.
    public func predecessor(of capture: Capture) throws -> Capture? {
        try db.writer.read { db in
            try Capture.fetchOne(db, sql: """
                SELECT * FROM captures
                WHERE captured_at < ? AND is_idle = 0 AND is_redacted = 0
                ORDER BY captured_at DESC
                LIMIT 1
                """, arguments: [capture.capturedAt])
        }
    }

    /// The context the describe prompt quotes (#65): the last thing done in another app, and the
    /// run this frame belongs to.
    ///
    /// The run is the stretch of consecutive captures carrying this frame's `app_bundle_id`,
    /// walking back until the bundle changes, an idle or locked row breaks it, or
    /// `DescribePrompt.runContextWindow` runs out. Inherited descriptions are never quoted — they
    /// are the previous frame's words by definition — but they do not end the run either: the
    /// screen simply did not change. One query and one pass; the compression is
    /// `RunContext.compressed`.
    public func runContext(for capture: Capture) throws -> DescribePrompt.RunContext {
        let since = capture.capturedAt.addingTimeInterval(-DescribePrompt.runContextWindow)
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.captured_at AS at, c.app_bundle_id AS bundle, c.is_idle AS is_idle,
                       c.is_redacted AS is_redacted, d.app_key AS app_key, d.task_key AS task_key,
                       d.summary_md AS summary, d.is_inherited AS is_inherited
                FROM captures c
                LEFT JOIN descriptions d ON d.capture_id = c.id
                WHERE c.captured_at < ? AND c.captured_at >= ? AND c.id <> ?
                ORDER BY c.captured_at DESC
                LIMIT ?
                """, arguments: [capture.capturedAt, since, capture.id, Self.runContextRowLimit])
        }

        var run: [DescribePrompt.RecentFrame] = []
        var before: DescribePrompt.RecentFrame?
        var runEnded = false
        for row in rows {
            let bundle: String? = row["bundle"]
            let sameApp = bundle == capture.appBundleId
            let broken: Bool = (row["is_idle"] ?? false) || (row["is_redacted"] ?? false)
            let quotable = Self.frame(row)

            if !runEnded {
                if broken || !sameApp {
                    runEnded = true
                } else if let quotable {
                    run.append(quotable)
                }
            }
            if runEnded, !sameApp, let quotable {
                before = quotable
                break
            }
        }

        return DescribePrompt.RunContext.compressed(before: before, run: run.reversed())
    }

    /// A row's description as a quotable frame, or nil when it has none or it is inherited.
    private static func frame(_ row: Row) -> DescribePrompt.RecentFrame? {
        guard let summary: String = row["summary"], !summary.isEmpty,
              let appKey: String = row["app_key"], let taskKey: String = row["task_key"],
              !(row["is_inherited"] ?? false)
        else { return nil }
        return DescribePrompt.RecentFrame(
            at: row["at"], appKey: appKey, taskKey: taskKey, summary: summary
        )
    }

    /// 90 minutes of captures is ~180 rows at production's cadence; the limit is only there so a
    /// pathological backlog cannot turn one prompt into a table scan.
    private static let runContextRowLimit = 600

    /// `describe_attempts += 1`, returning the new count.
    @discardableResult
    public func bumpAttempts(captureId: String) throws -> Int {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE captures SET describe_attempts = describe_attempts + 1 WHERE id = ?",
                arguments: [captureId]
            )
            return try Int.fetchOne(
                db, sql: "SELECT describe_attempts FROM captures WHERE id = ?", arguments: [captureId]
            ) ?? 0
        }
    }

    /// When the most recent frame was summarized, or nil on a machine that has never described
    /// one. Settings → Models & cost shows it next to the health line (#125): "running normally"
    /// is only reassuring next to a time.
    public func lastDescribedAt() throws -> Date? {
        try db.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(created_at) FROM descriptions")
        }
    }

    /// Puts back the frames a rejected key threw away (#125).
    ///
    /// `describe_status = 'failed'` is terminal — nothing in Worklens ever resets it — so before
    /// the refusal branch in `DescribeWorker.recordFailure` existed, a day spent with a mistyped
    /// key marked every frame it touched `failed`, and correcting the key did not bring them
    /// back. This is the one-time repair for a database in that state, and it runs on every
    /// config reload rather than as a command the user has to know about.
    ///
    /// Conservative on purpose: it does nothing at all unless the ledger shows the provider
    /// rejecting the *credential* on a describe call today — `DescribeHealth.keyWasRejected` is
    /// the whole test — and it only touches that day's failed frames, and only those that never
    /// produced a description. A frame it re-queues is simply pending again, with its attempts
    /// back at zero, so a frame that fails for its own reasons still settles after three.
    ///
    /// The credential test is narrower than the statuses this used to match (#189). A plain 400 —
    /// an oversized image, an unsupported part, a malformed request — is the provider refusing
    /// *this frame*, and a new key cannot change that answer. Re-queueing on one meant the frame
    /// burned three more paid describe calls at every launch and every configuration reload,
    /// wrote another 400 row, and was re-queued again by the row it had just written. Those
    /// frames now stay `failed`, which is what they are.
    ///
    /// Returns how many frames it put back.
    @discardableResult
    public func requeueRejectedFailures(
        day: String, timeZone: TimeZone = .current
    ) throws -> Int {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return 0 }
        return try db.writer.write { db in
            // Narrowed in SQL to the statuses that could possibly qualify, then decided in Swift:
            // only a 400 needs its stored `error` text read at all, and the text stops here.
            let candidates = try Row.fetchAll(db, sql: """
                SELECT http_status AS status, error AS error FROM llm_calls
                WHERE purpose = ? AND http_status IN (400, 401, 403)
                  AND created_at >= ? AND created_at < ?
                """, arguments: [LLMPurpose.describe.rawValue, range.start, range.end])
            let rejected = candidates.contains { row in
                DescribeHealth.keyWasRejected(httpStatus: row["status"], error: row["error"])
            }
            guard rejected else { return 0 }

            try db.execute(sql: """
                UPDATE captures
                SET describe_status = ?, describe_attempts = 0
                WHERE describe_status = ?
                  AND captured_at >= ? AND captured_at < ?
                  AND id NOT IN (SELECT capture_id FROM descriptions)
                """, arguments: [
                    DescribeStatus.pending.rawValue, DescribeStatus.failed.rawValue,
                    range.start, range.end,
                ])
            return db.changesCount
        }
    }

    /// Forgets a frame's image: used when the describer flagged it sensitive, or when the user
    /// asked for screenshots to be dropped once described.
    public func clearImagePath(captureId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE captures SET image_path = NULL WHERE id = ?", arguments: [captureId]
            )
        }
    }
}
