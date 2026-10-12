import Foundation
import GRDB

/// Repairs what was stored before window titles went through `TextRedactor` on the way in, and
/// before the redactor knew JSON and YAML credentials, credential assignment names and URL
/// userinfo. A title such as `deploy.env — password=hunter2` was stored verbatim, indexed as a
/// `title` search row and returned by the MCP `search` tool.
public enum CaptureMetadataRepair {
    /// Runs every repair below with the built-in redactor. Run once inside its migration; a second
    /// run changes nothing. Returns the number of rows changed across all tables.
    @discardableResult
    public static func redactStoredMetadata(_ db: GRDB.Database) throws -> Int {
        let redactor = TextRedactor()
        let captures = try redactCaptures(db, redactor: redactor)
        let blocks = try redactBlockTitles(db, redactor: redactor)
        let outlines = try redactOutlines(db, redactor: redactor)
        let documents = try AXSnapshotStore.normalizeDocumentURLs(db)
        Log.storage.debug(
            "metadata repair: \(captures) captures, \(blocks) blocks, \(outlines) outlines, \(documents) document addresses"
        )
        return captures + blocks + outlines + documents
    }

    /// `captures.window_title`, `browser_url` and `context_signature`, and the capture's `title`
    /// and `url` search rows when either changed.
    @discardableResult
    static func redactCaptures(_ db: GRDB.Database, redactor: TextRedactor) throws -> Int {
        // Read first, then write: SQLite leaves a table's cursor undefined while it is updated.
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, window_title, browser_url, context_signature FROM captures
            WHERE window_title IS NOT NULL OR browser_url IS NOT NULL OR context_signature IS NOT NULL
            """)
        var changed = 0
        for row in rows {
            let id: String = row["id"]
            let title: String? = row["window_title"]
            let url: String? = row["browser_url"]
            let signature: String? = row["context_signature"]
            let cleanTitle = redactor.redactIfPresent(title).text
            let cleanURL = redactor.redactIfPresent(url).text
            let cleanSignature = redactor.redactIfPresent(signature).text
            guard cleanTitle != title || cleanURL != url || cleanSignature != signature else { continue }
            try db.execute(
                sql: """
                    UPDATE captures SET window_title = ?, browser_url = ?, context_signature = ?
                    WHERE id = ?
                    """,
                arguments: [cleanTitle, cleanURL, cleanSignature, id]
            )
            if cleanTitle != title { try SearchIndex.set(db, captureId: id, kind: .title, text: cleanTitle) }
            if cleanURL != url { try SearchIndex.set(db, captureId: id, kind: .url, text: cleanURL) }
            changed += 1
        }
        return changed
    }

    /// `activity_blocks.title`, which `BlockBuilder` copied from the frames' window titles (or a
    /// meeting's title) and the timeline renders as the block's heading; and, on a block built
    /// from a calendar event or a Granola note, `summary_md`, which is that event's body. A screen
    /// block's summary is the describer's own prose and is left alone.
    @discardableResult
    static func redactBlockTitles(_ db: GRDB.Database, redactor: TextRedactor) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title, summary_md, source FROM activity_blocks
            WHERE title IS NOT NULL OR (summary_md IS NOT NULL AND source != 'screen')
            """)
        var changed = 0
        for row in rows {
            let id: String = row["id"]
            let title: String? = row["title"]
            let summary: String? = row["summary_md"]
            let source: String = row["source"]
            let cleanTitle = redactor.redactIfPresent(title).text
            let cleanSummary = source == "screen" ? summary : redactor.redactIfPresent(summary).text
            guard cleanTitle != title || cleanSummary != summary else { continue }
            try db.execute(
                sql: "UPDATE activity_blocks SET title = ?, summary_md = ? WHERE id = ?",
                arguments: [cleanTitle, cleanSummary, id]
            )
            changed += 1
        }
        return changed
    }

    /// `ax_snapshots.text` was redacted when it was written, but by the older rules. Only an
    /// outline holding a word one of the newer rules keys on can change, so the rest are never
    /// read: an outline is thousands of characters and there may be a great many of them.
    /// `text_chars`, `text_hash` and the `ax` search row change with the text, as in
    /// `AXOutlineRepair`. `redactions_json` stays: a value redacted before would be counted twice.
    @discardableResult
    static func redactOutlines(_ db: GRDB.Database, redactor: TextRedactor) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT capture_id, text FROM ax_snapshots
            WHERE text IS NOT NULL AND (
                text LIKE '%pass%' OR text LIKE '%pwd%' OR text LIKE '%senha%'
                OR text LIKE '%secret%' OR text LIKE '%token%' OR text LIKE '%key%'
                OR text LIKE '%credential%' OR text LIKE '%://%@%'
            )
            """)
        var changed = 0
        for row in rows {
            let id: String = row["capture_id"]
            let raw: String = row["text"]
            let clean = redactor.redact(raw).text
            guard clean != raw else { continue }
            try db.execute(
                sql: "UPDATE ax_snapshots SET text = ?, text_chars = ?, text_hash = ? WHERE capture_id = ?",
                arguments: [clean, clean.count, AXOutline.hash(clean), id]
            )
            try SearchIndex.set(db, captureId: id, kind: .ax, text: clean)
            changed += 1
        }
        return changed
    }
}
