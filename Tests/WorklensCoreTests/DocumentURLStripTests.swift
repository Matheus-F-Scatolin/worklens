import Foundation
import GRDB
import Testing
@testable import WorklensCore

private let t0 = Date(timeIntervalSince1970: 1_757_000_000)
private let chrome = "com.google.Chrome"
private let vscode = "com.microsoft.VSCode"

private func storable(_ raw: String?, _ bundleID: String? = chrome, collect: Bool = true) -> String? {
    BrowserRegistry.storableDocumentURL(raw, bundleID: bundleID, collectBrowserURL: collect)
}

@Suite("ax_snapshots.document_url follows the tab URL's rule (#311)")
struct DocumentURLStripTests {
    // MARK: The rule

    @Test("Query and fragment go, scheme and host are lowercased, any scheme")
    func strips() {
        #expect(storable("https://example.com/a?token=x#y") == "https://example.com/a")
        #expect(storable("HTTPS://Example.COM/a") == "https://example.com/a")
        #expect(storable("chrome://history/?q=x") == "chrome://history/")
        #expect(storable("file:///tmp/page.html#top") == "file:///tmp/page.html")
        #expect(storable("file:///Users/x/notes.md", vscode) == "file:///Users/x/notes.md")
    }

    @Test("Nothing readable is stored as nil, never as the raw string")
    func nothingReadable() {
        #expect(storable(nil) == nil)
        #expect(storable("") == nil)
        #expect(storable("   ") == nil)
        #expect(storable("http://exa mple.com/a b?q=1") == nil)
        #expect(storable(nil, vscode) == nil)
    }

    @Test("With browser URLs off, a page stores nothing and an editor's file still does")
    func browserURLsOff() {
        #expect(storable("https://example.com/a", chrome, collect: false) == nil)
        // An http(s) address is a page whatever app reported it.
        #expect(storable("https://example.com/a?x=1", vscode, collect: false) == nil)
        #expect(storable("http://localhost:3000/", nil, collect: false) == nil)
        #expect(storable("file:///tmp/page.html#top", chrome, collect: false) == nil)
        #expect(storable("file:///Users/x/notes.md", vscode, collect: false) == "file:///Users/x/notes.md")
    }

    // MARK: The repair

    @Test("The migration strips stored rows and leaves everything else byte-identical")
    func migrationRepairsRows() throws {
        let queue = try DatabaseQueue(configuration: Database.configuration())
        try Migrations.migrator.migrate(queue, upTo: "capture-interval")

        let seeded: [(id: String, url: String?)] = [
            ("query", "https://Mail.Example.com/inbox?token=abc#msg"),
            ("fragment", "https://example.com/doc#section-2"),
            ("chrome", "chrome://history/?q=secret"),
            ("local-html", "file:///tmp/page.html#top"),
            ("file", "file:///Users/x/notes%20draft.md"),
            ("clean", "https://example.com/a"),
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
                    VALUES (?, 'full', 40, 12, 30, ?, ?, ?, ?, ?)
                    """, arguments: [row.id, "hash-\(row.id)", row.url, "outline \(row.id)",
                                     #"{"card":1}"#, t0])
            }
        }
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT capture_id, text, text_hash, redactions_json FROM ax_snapshots
                ORDER BY capture_id
                """)
        }

        try Migrations.migrator.migrate(queue)

        let urls = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db, sql: "SELECT capture_id, document_url FROM ax_snapshots"
            ).map { ($0["capture_id"] as String, $0["document_url"] as String?) })
        }
        #expect(urls.count == seeded.count)
        #expect(urls["query"] == "https://mail.example.com/inbox")
        #expect(urls["fragment"] == "https://example.com/doc")
        #expect(urls["chrome"] == "chrome://history/")
        #expect(urls["local-html"] == "file:///tmp/page.html")
        #expect(urls["file"] == "file:///Users/x/notes%20draft.md")
        #expect(urls["clean"] == "https://example.com/a")
        #expect(urls["null"] == .some(nil))

        let after = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT capture_id, text, text_hash, redactions_json FROM ax_snapshots
                ORDER BY capture_id
                """)
        }
        #expect(after == before)
        // String == is canonical equivalence; the title promises bytes.
        func bytes(_ rows: [Row]) -> [[UInt8]?] {
            rows.flatMap { row in
                ["capture_id", "text", "text_hash", "redactions_json"].map { column in
                    (row[column] as String?).map { Array($0.utf8) }
                }
            }
        }
        #expect(bytes(after) == bytes(before))

        // A second run finds nothing left to change.
        #expect(try queue.write { try AXSnapshotStore.normalizeDocumentURLs($0) } == 0)
    }

    @Test("The stripped address is not indexed, and neither is the omnibox query in the outline")
    func strippedQueryAndSearch() throws {
        let db = try Database.inMemory()
        let capture = Capture(capturedAt: t0, appBundleId: chrome, appName: "Google Chrome")
        try CaptureStore(db).insert(capture)
        // Written raw, as a row from before #311 was, so the repair is what strips it.
        try AXSnapshotStore(db).insert(AXSnapshotRecord(
            captureId: capture.id,
            coverage: .full,
            nodeCount: 40,
            textChars: 60,
            elapsedMs: 30,
            textHash: "h",
            documentUrl: "https://example.com/inbox?token=zqxvplonk#frag",
            text: "[AXTextField] example.com/inbox?token=zqxvplonk\n[AXStaticText] quarterly roadmap",
            redactionsJson: nil,
            createdAt: t0
        ))
        #expect(try db.writer.write { try AXSnapshotStore.normalizeDocumentURLs($0) } == 1)

        let stored = try db.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT document_url, text FROM ax_snapshots")
        }
        #expect(stored?["document_url"] as String? == "https://example.com/inbox")

        // #332 closes the gap #311 left: the outline showed the omnibox's address with no
        // scheme, and its query went into `text` and `search_fts`. Its repair strips it there too.
        #expect((stored?["text"] as String?)?.contains("token=zqxvplonk") == true)
        #expect(try db.writer.write { try AXOutlineRepair.stripURLQueries($0) } == 1)

        let text = try db.writer.read { try String.fetchOne($0, sql: "SELECT text FROM ax_snapshots") }
        #expect(text == "[AXTextField] example.com/inbox\n[AXStaticText] quarterly roadmap")
        #expect(try SearchService(db).search(query: "zqxvplonk").isEmpty)
        let hits = try SearchService(db).search(query: "quarterly")
        #expect(hits.map(\.captureId) == [capture.id])
        #expect(hits.allSatisfy { $0.kind == .ax })
    }
}
