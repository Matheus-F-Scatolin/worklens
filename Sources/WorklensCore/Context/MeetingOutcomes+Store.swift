import Foundation
import GRDB

public extension ContextEvent {
    /// The parsed `outcomesJson`, or nil when there is none.
    var outcomes: MeetingOutcomes? { MeetingOutcomes.decode(outcomesJson) }
}

public extension ContextEventStore {
    /// Whose Granola account this is: the `owner.name` on most stored Granola rows, ties broken by
    /// name. A note a colleague shared with you carries *their* name as owner, so a per-note owner
    /// would flag their action items as yours; the majority is you.
    func granolaYouName() throws -> String? {
        try database.writer.read { db in try Self.granolaYouName(db) }
    }

    private static func granolaYouName(_ db: GRDB.Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT json_extract(raw_json, '$.owner.name') FROM context_events
            WHERE source = ? AND json_valid(raw_json)
              AND IFNULL(json_extract(raw_json, '$.owner.name'), '') != ''
            GROUP BY 1 ORDER BY COUNT(*) DESC, 1 LIMIT 1
            """, arguments: [ContextSource.granola.rawValue])
    }

    /// Parses the outcomes of every Granola row that has none yet, or that an older parser wrote,
    /// from the note JSON already stored; with `all`, every Granola row, as after the account's
    /// name (`granolaYouName`) changed. Returns how many rows it wrote.
    ///
    /// The sync skips a note whose `updated_at` has not moved, so without this the meetings synced
    /// before #316 (and every row after a `parserVersion` bump) would never get their next steps.
    /// It writes `outcomes_json` and nothing else: `synced_at` and the body stay as they were.
    @discardableResult
    func refreshMeetingOutcomes(all: Bool = false) throws -> Int {
        try database.writer.write { db in
            let you = try Self.granolaYouName(db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, raw_json FROM context_events
                WHERE source = ? AND (? OR CASE
                  WHEN outcomes_json IS NULL OR NOT json_valid(outcomes_json) THEN 1
                  ELSE IFNULL(json_extract(outcomes_json, '$.v'), 0) < ?
                END)
                """, arguments: [ContextSource.granola.rawValue, all, MeetingOutcomes.parserVersion])

            for row in rows {
                let id: String = row["id"]
                let raw: String? = row["raw_json"]
                let note = raw.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                let outcomes = MeetingOutcomes.parse(
                    summaryMarkdown: note.flatMap(GranolaSource.summaryMarkdown),
                    youName: you
                )
                try db.execute(
                    sql: "UPDATE context_events SET outcomes_json = ? WHERE id = ?",
                    arguments: [outcomes.encoded, id]
                )
            }
            return rows.count
        }
    }
}
