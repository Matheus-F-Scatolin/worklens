import Foundation
import GRDB

/// Reads and writes `descriptions`.
public struct DescriptionStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    public func insert(_ description: Description) throws {
        try db.writer.write { db in
            try description.insert(db)
            try SearchIndex.set(
                db, captureId: description.captureId, kind: .description,
                text: description.summaryMd
            )
        }
    }

    public func fetch(captureId: String) throws -> Description? {
        try db.writer.read { db in
            try Description.filter(Column("capture_id") == captureId).fetchOne(db)
        }
    }

    /// Most recent first, joined with the capture time and app so callers do not need a second query.
    public func fetchRecent(limit: Int) throws -> [DescriptionWithCapture] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.*, c.captured_at AS c_captured_at, c.app_name AS c_app_name,
                       c.window_title AS c_window_title
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                ORDER BY c.captured_at DESC
                LIMIT ?
                """, arguments: [limit])
                .map(DescriptionStore.joined)
        }
    }

    /// Every description captured inside `start...end`, newest first. A window is a span of
    /// time, not a row budget: `fetchRecent(limit:)` would hide the tail of a long window as
    /// soon as the capture interval got shorter.
    public func fetchBetween(_ start: Date, _ end: Date) throws -> [DescriptionWithCapture] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.*, c.captured_at AS c_captured_at, c.app_name AS c_app_name,
                       c.window_title AS c_window_title
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at <= ?
                ORDER BY c.captured_at DESC
                """, arguments: [start, end])
                .map(DescriptionStore.joined)
        }
    }

    /// Every description for one local day, oldest first.
    public func fetch(day: String, timeZone: TimeZone = .current) throws -> [DescriptionWithCapture] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }
        return try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.*, c.captured_at AS c_captured_at, c.app_name AS c_app_name,
                       c.window_title AS c_window_title
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ?
                ORDER BY c.captured_at ASC
                """, arguments: [range.start, range.end])
                .map(DescriptionStore.joined)
        }
    }

    /// The two privacy numbers for one local day (#151): how many frames the model flagged
    /// sensitive, and how many credentials `TextRedactor` replaced before the prompt was built.
    ///
    /// Sensitive counts every row, inherited included, because that is a count of *frames* and it
    /// is what the timeline footer already says. Redactions count described rows only: an
    /// inherited row copies `details_json` wholesale (see `DescribeWorker`), so summing every row
    /// would report one frame's card number once per frame that inherited its description.
    public func privacyCounts(day: String, timeZone: TimeZone = .current) throws -> PrivacyCounts {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else {
            return PrivacyCounts()
        }
        return try db.writer.read { db in
            var counts = PrivacyCounts()
            counts.sensitive = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM descriptions d JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ? AND d.is_sensitive
                """, arguments: [range.start, range.end]) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.details_json AS details_json
                FROM descriptions d JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ?
                  AND d.is_inherited = 0 AND d.details_json IS NOT NULL
                """, arguments: [range.start, range.end])
            counts.redactions = rows.reduce(0) {
                $0 + DescriptionStore.redactions(json: $1["details_json"])
            }
            return counts
        }
    }

    /// How many items were replaced in one frame's `details_json`. Zero for the frames — nearly
    /// all of them — whose JSON carries no `redactions` object at all.
    static func redactions(json: String?) -> Int {
        guard let data = json?.nonEmpty?.data(using: .utf8),
            let payload = try? JSONDecoder().decode(RedactionsPayload.self, from: data),
            let redactions = payload.redactions
        else { return 0 }
        return redactions.values.reduce(0, +)
    }

    /// `capture_id` → the raw `project_hint`, for one local day (#70).
    ///
    /// Two columns rather than `fetch(day:)`'s whole rows, so a day's `raw_json` never comes along
    /// for a table of project minutes. Inherited rows carry a copy of `details_json`, so a frame
    /// that inherited its description carries its hint too. The JSON itself is decoded by #69's
    /// `TimelineFrame.details`, the one place that knows the shape of `details_json`.
    public func projectHints(day: String, timeZone: TimeZone = .current) throws -> [String: String] {
        try detailsField(day: day, timeZone: timeZone) { $0.projectHint }
    }

    /// `capture_id` → the catalog `project_key` a d5 frame picked (#315), for one local day. Rows
    /// older than d5 have none and are simply absent. The key is not checked against the
    /// catalog here: `ProjectNames.resolve` drops one the catalog no longer has.
    public func projectKeys(day: String, timeZone: TimeZone = .current) throws -> [String: String] {
        try detailsField(day: day, timeZone: timeZone) { $0.projectKey }
    }

    /// One field of `details_json` per capture for one local day, read from the same two columns.
    private func detailsField(
        day: String, timeZone: TimeZone, _ pick: @escaping @Sendable (TimelineFrame.Details) -> String?
    ) throws -> [String: String] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [:] }
        return try db.writer.read { db in
            var values: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.capture_id AS capture_id, d.details_json AS details_json
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ? AND d.details_json IS NOT NULL
                """, arguments: [range.start, range.end])
            for row in rows {
                guard let value = pick(TimelineFrame.details(json: row["details_json"])) else { continue }
                values[row["capture_id"]] = value
            }
            return values
        }
    }

    /// `capture_id` → the frame's `document` (#91), for one local day.
    ///
    /// The same two columns as `projectHints`, read for the other half of `details_json`: the
    /// document is what a thread falls back to when the frame named no project, so "the lyrics
    /// doc in Chrome" can still be counted as one thread returned to eight times.
    public func frameDocuments(day: String, timeZone: TimeZone = .current) throws -> [String: String] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [:] }
        return try db.writer.read { db in
            var documents: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.capture_id AS capture_id, d.details_json AS details_json
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ? AND d.details_json IS NOT NULL
                """, arguments: [range.start, range.end])
            for row in rows {
                guard let document = TimelineFrame.details(json: row["details_json"]).document
                else { continue }
                documents[row["capture_id"]] = document
            }
            return documents
        }
    }

    /// The same day's hints, each with the app name and window title it must not be a copy of
    /// (#90), and the d5 `project_key` beside it (#315). What `ProjectNames` needs to cluster a day, and what `ProjectLearning` reads for a
    /// window of days — still two columns more than `projectHints`, never `raw_json`.
    public func projectObservations(
        day: String, timeZone: TimeZone = .current
    ) throws -> [String: ProjectNames.Observation] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [:] }
        return try db.writer.read { db in
            var observations: [String: ProjectNames.Observation] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.capture_id AS capture_id, d.details_json AS details_json,
                       c.app_name AS app_name, c.window_title AS window_title
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ? AND d.details_json IS NOT NULL
                """, arguments: [range.start, range.end])
            for row in rows {
                let details = TimelineFrame.details(json: row["details_json"])
                guard details.projectHint != nil || details.projectKey != nil else { continue }
                observations[row["capture_id"]] = ProjectNames.Observation(
                    hint: details.projectHint, appName: row["app_name"],
                    windowTitle: row["window_title"], projectKey: details.projectKey
                )
            }
            return observations
        }
    }

    private static func joined(_ row: Row) throws -> DescriptionWithCapture {
        DescriptionWithCapture(
            description: try Description(row: row),
            capturedAt: row["c_captured_at"],
            appName: row["c_app_name"],
            windowTitle: row["c_window_title"]
        )
    }
}

/// The shape `redactions` takes in `descriptions.details_json` — `{"card": 1, "secret": 2}`,
/// written by `FrameDescription.detailsJSON(redactions:)`. Only that key; the rest of the object
/// is none of this counter's business.
private struct RedactionsPayload: Decodable {
    var redactions: [String: Int]?
}

/// #151: what one day's frames cost in privacy terms, as two numbers the menu can print.
public struct PrivacyCounts: Sendable, Equatable {
    /// Frames the vision model flagged `is_sensitive`.
    public var sensitive: Int
    /// Credentials replaced in a window title or a URL, counted as occurrences.
    public var redactions: Int

    public init(sensitive: Int = 0, redactions: Int = 0) {
        self.sensitive = sensitive
        self.redactions = redactions
    }
}
