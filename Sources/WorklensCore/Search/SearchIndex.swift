import Foundation
import GRDB

/// What a `search_fts` row was made from. One row per (capture, kind), so a frame contributes at
/// most four: its window outline, its description, its window title and its URL.
public enum SearchKind: String, Sendable, CaseIterable, Codable {
    case ax, description, title, url

    /// bm25 multiplier applied to this kind's rows. bm25 is negative and smaller is better, so a
    /// weight above 1 pushes a kind up the list: a sentence the describer wrote about the frame is
    /// a better answer to "where did I see that" than the same word buried in a 2.8k-char outline.
    var rankWeight: Double {
        switch self {
        case .description: 1.6
        case .title: 1.4
        case .url: 1.2
        case .ax: 1.0
        }
    }
}

/// Maintenance of `search_fts`, called from the stores that own the text (#88).
///
/// Deliberately not triggers: the write path stays readable in Swift, and the two rules that
/// matter — the index must never outlive the text it indexes, and an erased capture must leave
/// nothing behind — are then visible next to the delete that motivates them.
///
/// Every function takes the GRDB connection rather than a `Database`, so the index change joins
/// the same transaction as the row it describes.
///
/// `search_docs` exists because an FTS5 table cannot index its own `UNINDEXED` columns:
/// `DELETE FROM search_fts WHERE capture_id = ?` would scan and read every document in the table,
/// on a path (`clearText`) that runs once per described frame. The mapping turns that into a
/// primary-key lookup plus a rowid delete.
public enum SearchIndex {
    /// Replaces one (capture, kind) row, looking the capture's local day up on the way.
    /// A capture that is already gone, or empty text, leaves no row.
    public static func set(
        _ db: GRDB.Database,
        captureId: String,
        kind: SearchKind,
        text: String?,
        timeZone: TimeZone = .current
    ) throws {
        guard let day = try day(db, captureId: captureId, timeZone: timeZone) else { return }
        try set(db, captureId: captureId, day: day, kind: kind, text: text)
    }

    /// Same, for callers that already know the day and need no second read.
    public static func set(
        _ db: GRDB.Database, captureId: String, day: String, kind: SearchKind, text: String?
    ) throws {
        try remove(db, captureId: captureId, kind: kind)
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.execute(
            sql: "INSERT INTO search_fts(text, capture_id, day, kind) VALUES (?, ?, ?, ?)",
            arguments: [trimmed, captureId, day, kind.rawValue]
        )
        try db.execute(
            sql: "INSERT OR REPLACE INTO search_docs(capture_id, kind, doc_id) VALUES (?, ?, ?)",
            arguments: [captureId, kind.rawValue, db.lastInsertedRowID]
        )
    }

    /// Drops one (capture, kind) row. The lever `clearText` pulls: text that has been dropped for
    /// retention or because the frame was sensitive must not stay searchable through the index.
    public static func remove(_ db: GRDB.Database, captureId: String, kind: SearchKind) throws {
        let docId = try Int64.fetchOne(
            db,
            sql: "SELECT doc_id FROM search_docs WHERE capture_id = ? AND kind = ?",
            arguments: [captureId, kind.rawValue]
        )
        guard let docId else { return }
        try db.execute(sql: "DELETE FROM search_fts WHERE rowid = ?", arguments: [docId])
        try db.execute(
            sql: "DELETE FROM search_docs WHERE capture_id = ? AND kind = ?",
            arguments: [captureId, kind.rawValue]
        )
    }

    /// Drops every row of every kind for these captures. `search_fts` is a virtual table, so no
    /// foreign key cascades into it — this is what keeps an erased stretch erased.
    public static func removeAll(_ db: GRDB.Database, captureIds: [String]) throws {
        guard !captureIds.isEmpty else { return }
        for chunk in stride(from: 0, to: captureIds.count, by: 400) {
            let ids = Array(captureIds[chunk..<min(chunk + 400, captureIds.count)])
            let holes = databaseQuestionMarks(count: ids.count)
            let args = StatementArguments(ids)
            let docIds = try Int64.fetchAll(
                db,
                sql: "SELECT doc_id FROM search_docs WHERE capture_id IN (\(holes))",
                arguments: args
            )
            for docId in docIds {
                try db.execute(sql: "DELETE FROM search_fts WHERE rowid = ?", arguments: [docId])
            }
            try db.execute(
                sql: "DELETE FROM search_docs WHERE capture_id IN (\(holes))",
                arguments: args
            )
        }
    }

    /// Builds the whole index from the rows already on disk. Run once inside the `search-fts`
    /// migration; safe to run again, because each `set` replaces the row it would duplicate.
    public static func backfill(_ db: GRDB.Database, timeZone: TimeZone = .current) throws {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT c.id AS capture_id,
                   c.captured_at AS captured_at,
                   c.window_title AS window_title,
                   c.browser_url AS browser_url,
                   a.text AS ax_text,
                   (SELECT d.summary_md FROM descriptions d
                     WHERE d.capture_id = c.id ORDER BY d.created_at DESC LIMIT 1) AS summary_md
            FROM captures c
            LEFT JOIN ax_snapshots a ON a.capture_id = c.id
            """)
        while let row = try rows.next() {
            let id: String = row["capture_id"]
            let day = DayBoundaries.dayString(row["captured_at"], timeZone: timeZone)
            try set(db, captureId: id, day: day, kind: .ax, text: row["ax_text"])
            try set(db, captureId: id, day: day, kind: .description, text: row["summary_md"])
            try set(db, captureId: id, day: day, kind: .title, text: row["window_title"])
            try set(db, captureId: id, day: day, kind: .url, text: row["browser_url"])
        }
    }

    private static func day(
        _ db: GRDB.Database, captureId: String, timeZone: TimeZone
    ) throws -> String? {
        let at = try Date.fetchOne(
            db, sql: "SELECT captured_at FROM captures WHERE id = ?", arguments: [captureId]
        )
        return at.map { DayBoundaries.dayString($0, timeZone: timeZone) }
    }
}
