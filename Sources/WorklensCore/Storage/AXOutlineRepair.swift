import Foundation
import GRDB

/// Repairs stored window outlines (`ax_snapshots.text`) written before #332, when
/// `TextRedactor` dropped a query only after `http://` or `https://`. A Chromium omnibox reads
/// `mail.example.com/inbox?token=…`, no scheme, so its query was stored, indexed as an `ax`
/// search row and sent to the describer.
public enum AXOutlineRepair {
    /// Puts every stored outline through `TextRedactor.stripURLQueries`. For each row it changes:
    /// `text`, `text_chars` and `text_hash` together, so the hash still matches the text, and the
    /// capture's `ax` search row. `redactions_json` stays: dropping a query is not a redaction of
    /// a kind, and anything found inside a stored query was counted when it was written.
    ///
    /// Strip only. Run once inside its migration; a second run changes nothing. Returns the number
    /// of rows changed.
    @discardableResult
    public static func stripURLQueries(_ db: GRDB.Database) throws -> Int {
        // Read first, then write: SQLite leaves a table's cursor undefined while it is updated.
        let rows = try Row.fetchAll(db, sql: """
            SELECT capture_id, text FROM ax_snapshots WHERE text IS NOT NULL
            """)
        var changed = 0
        for row in rows {
            let id: String = row["capture_id"]
            let raw: String = row["text"]
            let clean = TextRedactor.stripURLQueries(raw)
            guard clean != raw else { continue }
            try db.execute(
                sql: "UPDATE ax_snapshots SET text = ?, text_chars = ?, text_hash = ? WHERE capture_id = ?",
                arguments: [clean, clean.count, AXOutline.hash(clean), id]
            )
            try SearchIndex.set(db, captureId: id, kind: .ax, text: clean)
            changed += 1
        }
        Log.storage.debug("ax_snapshots: \(changed) outlines had URL queries stripped")
        return changed
    }
}
