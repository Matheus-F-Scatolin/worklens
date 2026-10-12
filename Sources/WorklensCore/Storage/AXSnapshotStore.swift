import Foundation
import GRDB

/// Reads and writes `ax_snapshots` (#53).
public struct AXSnapshotStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    public func insert(_ record: AXSnapshotRecord) throws {
        try db.writer.write { db in
            try record.insert(db)
            try SearchIndex.set(db, captureId: record.captureId, kind: .ax, text: record.text)
        }
    }

    public func fetch(captureId: String) throws -> AXSnapshotRecord? {
        try db.writer.read { try AXSnapshotRecord.fetchOne($0, key: captureId) }
    }

    /// Drops one snapshot's text and leaves everything else — the hash, the redaction counts and
    /// the coverage — in place. Retention's only lever on this table (`DescribeWorker`), and the
    /// reason the describe decision still works on a frame whose outline is gone.
    public func clearText(captureId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE ax_snapshots SET text = NULL WHERE capture_id = ?",
                arguments: [captureId]
            )
            // The index must not outlive the text (#88): under
            // `DELETE_SCREENSHOTS_AFTER_DESCRIBE`, or on a frame flagged sensitive, a searchable
            // copy of the outline would be exactly the evidence this call exists to drop.
            try SearchIndex.remove(db, captureId: captureId, kind: .ax)
        }
    }

    /// `capture_id` → `document_url` for the local day's frames that stored one (#319), for the
    /// document each frame was of. Read, never logged.
    public func documentURLs(day: String, timeZone: TimeZone = .current) throws -> [String: String] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [:] }
        return try db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.capture_id AS capture_id, a.document_url AS document_url
                FROM ax_snapshots a
                JOIN captures c ON c.id = a.capture_id
                WHERE c.captured_at >= ? AND c.captured_at < ? AND a.document_url IS NOT NULL
                """, arguments: [range.start, range.end])
            var urls: [String: String] = [:]
            for row in rows { urls[row["capture_id"]] = row["document_url"] as String }
            return urls
        }
    }

    /// Puts every stored `document_url` through `BrowserRegistry.storableDocumentURL` (#311):
    /// rows written before the rule kept a Chromium tab's query string and fragment. Run once
    /// inside its migration; a second run changes nothing. Returns the number of rows changed.
    ///
    /// Strip only: the `COLLECT_BROWSER_URL` gate is forward-only, because a migration cannot know
    /// the setting a past row was written under. A value `normalize` cannot read becomes NULL.
    @discardableResult
    public static func normalizeDocumentURLs(_ db: GRDB.Database) throws -> Int {
        // Read first, then write: SQLite leaves a table's cursor undefined while it is updated.
        // A few thousand short strings at most.
        let rows = try Row.fetchAll(db, sql: """
            SELECT capture_id, document_url FROM ax_snapshots WHERE document_url IS NOT NULL
            """)
        var changed = 0
        for row in rows {
            let id: String = row["capture_id"]
            let raw: String = row["document_url"]
            let clean = BrowserRegistry.storableDocumentURL(raw, bundleID: nil, collectBrowserURL: true)
            guard clean != raw else { continue }
            try db.execute(
                sql: "UPDATE ax_snapshots SET document_url = ? WHERE capture_id = ?",
                arguments: [clean, id]
            )
            changed += 1
        }
        Log.storage.debug("ax_snapshots: \(changed) document addresses stripped")
        return changed
    }
}
