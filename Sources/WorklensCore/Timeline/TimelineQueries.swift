import Foundation
import GRDB

/// The one read the timeline needs: a day's captures with whatever description each has.
public struct TimelineQueries: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    /// Every capture in one local day, oldest first, left-joined to its description so frames
    /// that are still pending come back too (they simply have no app or task yet).
    public func frames(day: String, timeZone: TimeZone = .current) throws -> [TimelineFrame] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        return try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id AS id, c.captured_at AS at, c.window_title AS title,
                       c.is_idle AS is_idle, c.is_redacted AS is_redacted,
                       c.app_bundle_id AS bundle_id, c.app_name AS app_name,
                       c.browser_url AS url, c.interval_seconds AS interval_seconds,
                       d.app_key AS app_key, d.task_key AS task_key, d.summary_md AS summary,
                       d.details_json AS details_json,
                       d.is_inherited AS is_inherited, d.is_meeting AS is_meeting,
                       d.is_sensitive AS is_sensitive
                FROM captures c
                LEFT JOIN descriptions d ON d.capture_id = c.id
                WHERE c.captured_at >= ? AND c.captured_at < ?
                ORDER BY c.captured_at ASC
                """, arguments: [range.start, range.end])
                .map { row in
                    let details = TimelineFrame.details(json: row["details_json"])
                    return TimelineFrame(
                        captureId: row["id"],
                        at: row["at"],
                        appKey: row["app_key"],
                        taskKey: row["task_key"],
                        title: row["title"],
                        summary: row["summary"],
                        document: details.document,
                        projectHint: details.projectHint,
                        projectKey: details.projectKey,
                        bundleID: row["bundle_id"],
                        appName: row["app_name"],
                        url: row["url"],
                        isIdle: row["is_idle"] ?? false,
                        isRedacted: row["is_redacted"] ?? false,
                        isMeeting: row["is_meeting"] ?? false,
                        isInherited: row["is_inherited"] ?? false,
                        isSensitive: row["is_sensitive"] ?? false,
                        intervalSeconds: (row["interval_seconds"] as Int?).map(TimeInterval.init)
                    )
                }
        }
    }
}
