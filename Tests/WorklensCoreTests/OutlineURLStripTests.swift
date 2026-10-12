import Foundation
import GRDB
import Testing
@testable import WorklensCore

private let t0 = Date(timeIntervalSince1970: 1_757_000_000)

@Suite("ax_snapshots.text drops URL queries, scheme or not (#332)")
struct OutlineURLStripTests {
    private let omnibox = "[AXTextField] mail.example.com/inbox?token=zqxvplonk\n[AXStaticText] quarterly roadmap"
    private let omniboxClean = "[AXTextField] mail.example.com/inbox\n[AXStaticText] quarterly roadmap"
    private let clean = "[AXStaticText] Is it example.com? see README.md, node.js? e.g. this"

    @Test("The migration strips stored outlines, re-indexes them and leaves the rest alone")
    func migrationRepairsOutlines() throws {
        let queue = try DatabaseQueue(configuration: Database.configuration())
        try Migrations.migrator.migrate(queue, upTo: "ledger-granola-next-steps-outcomes")

        let seeded: [(id: String, text: String?)] = [
            ("omnibox", omnibox),
            ("clean", clean),
            ("null", nil),
        ]
        try queue.write { db in
            for (index, row) in seeded.enumerated() {
                try db.execute(sql: """
                    INSERT INTO captures (id, captured_at, describe_status, describe_attempts,
                                          is_idle, is_redacted, is_meeting, created_at)
                    VALUES (?, ?, 'described', 0, 0, 0, 0, ?)
                    """, arguments: [row.id, t0.addingTimeInterval(Double(index)), t0])
                try db.execute(sql: """
                    INSERT INTO ax_snapshots (capture_id, coverage, node_count, text_chars,
                        elapsed_ms, text_hash, document_url, text, redactions_json, created_at)
                    VALUES (?, 'full', 40, ?, 30, ?, 'https://mail.example.com/inbox', ?, ?, ?)
                    """, arguments: [row.id, row.text?.count ?? 0, "hash-\(row.id)", row.text,
                                     #"{"secret":1}"#, t0])
                try SearchIndex.set(db, captureId: row.id, kind: .ax, text: row.text)
            }
        }
        let before = try snapshot(queue)

        try Migrations.migrator.migrate(queue)

        let after = try snapshot(queue)
        #expect(after.count == seeded.count)

        // The omnibox row: the query is gone, and the length and hash follow the new text.
        let fixed = try #require(after["omnibox"])
        #expect(fixed["text"] as String? == omniboxClean)
        #expect(fixed["text_chars"] as Int? == omniboxClean.count)
        #expect(fixed["text_hash"] as String? == AXOutline.hash(omniboxClean))
        #expect(fixed["document_url"] as String? == "https://mail.example.com/inbox")
        #expect(fixed["redactions_json"] as String? == #"{"secret":1}"#)

        // A clean outline is byte-identical, hash and all.
        func bytes(_ row: Row?) -> [[UInt8]?] {
            ["text", "text_hash", "redactions_json", "document_url"].map { column in
                (row?[column] as String?).map { Array($0.utf8) }
            }
        }
        #expect(bytes(after["clean"]) == bytes(before["clean"]))
        #expect(after["clean"]?["text_chars"] as Int? == before["clean"]?["text_chars"] as Int?)

        // NULL stays NULL, with no search row.
        #expect(after["null"]?["text"] as String? == nil)

        let indexed = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT capture_id, text FROM search_fts WHERE kind = 'ax'
                """).map { ($0["capture_id"] as String, $0["text"] as String) })
        }
        #expect(indexed == ["omnibox": omniboxClean, "clean": clean])
        let mapped = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_docs WHERE kind = 'ax'") }
        #expect(mapped == 2)

        // A second run finds nothing left to change.
        #expect(try queue.write { try AXOutlineRepair.stripURLQueries($0) } == 0)
    }

    private func snapshot(_ queue: DatabaseQueue) throws -> [String: Row] {
        try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT capture_id, text, text_chars, text_hash, document_url, redactions_json
                FROM ax_snapshots
                """).map { ($0["capture_id"] as String, $0) })
        }
    }
}
