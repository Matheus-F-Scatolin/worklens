import Foundation
import GRDB
import Testing
@testable import WorklensCore

private let nine = DayBoundaries.range(day: "2026-09-09", timeZone: .current)!
    .start.addingTimeInterval(9 * 3600)
private var fixtureDay: String { DayBoundaries.dayString(nine) }

private let rawTitle = "deploy.env — password=hunter2 — Code"
private let cleanTitle = "deploy.env — password=[PASSWORD] — Code"
private let rawURL = "https://alice:hunter2@intranet.example.com/deploy"
private let cleanURL = "https://intranet.example.com/deploy"

/// Security review #2: a window title was stored, indexed and returned over MCP as it was read,
/// and #5: a calendar or Granola title, body and outcomes went out over MCP unredacted.
@Suite("Stored metadata is redacted")
struct StoredMetadataRedactionTests {
    private func indexed(_ db: GRDB.Database, kind: SearchKind) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT capture_id, text FROM search_fts WHERE kind = ?
            """, arguments: [kind.rawValue]).map { ($0["capture_id"] as String, $0["text"] as String) })
    }

    // MARK: - Writing

    @Test("CaptureStore stores and indexes the title, address and signature redacted")
    func insertRedacts() throws {
        let db = try WorklensCore.Database.inMemory()
        let store = CaptureStore(db)
        let capture = Capture(
            capturedAt: nine, appBundleId: "com.microsoft.VSCode", appName: "Code",
            windowTitle: rawTitle, browserUrl: rawURL,
            contextSignature: "com.microsoft.VSCode|\(rawTitle)|-", describeStatus: .pending
        )
        try store.insert(capture)

        let row = try #require(try store.fetch(id: capture.id))
        #expect(row.windowTitle == cleanTitle)
        #expect(row.browserUrl == cleanURL)
        #expect(row.contextSignature == "com.microsoft.VSCode|\(cleanTitle)|-")
        try db.writer.read { db in
            #expect(try indexed(db, kind: .title) == [capture.id: cleanTitle])
            #expect(try indexed(db, kind: .url) == [capture.id: cleanURL])
            let all = try String.fetchAll(db, sql: "SELECT text FROM search_fts").joined(separator: " ")
            #expect(!all.contains("hunter2"))
        }

        // An update of the row read back changes nothing, and a raw title set on it is redacted.
        var again = row
        try store.update(again)
        #expect(try store.fetch(id: capture.id)?.windowTitle == cleanTitle)
        again.windowTitle = "token=abcdefgh12345678"
        try store.update(again)
        #expect(try store.fetch(id: capture.id)?.windowTitle == "token=[SECRET_1]")
    }

    @Test("REDACT_EXTRA_PATTERNS reach the stored title when the store is given them")
    func customPatternsOnStore() throws {
        let db = try WorklensCore.Database.inMemory()
        let store = CaptureStore(db, redactor: TextRedactor(extraPatterns: [#"ACCT-\d{6}"#]))
        let capture = Capture(capturedAt: nine, windowTitle: "Ledger ACCT-114322", describeStatus: .pending)
        try store.insert(capture)
        #expect(try store.fetch(id: capture.id)?.windowTitle == "Ledger [CUSTOM_1]")
    }

    @Test("BrowserRegistry drops a URL's userinfo, query or not")
    func normalizeDropsUserinfo() {
        #expect(BrowserRegistry.normalize("https://alice:hunter2@Example.com/a?b=1#c")?.absolute
            == "https://example.com/a")
        #expect(BrowserRegistry.normalize("https://alice@example.com/")?.absolute == "https://example.com/")
        #expect(BrowserRegistry.normalize("https://alice:hunter2@example.com/a?b=1", storeQuery: true)?.absolute
            == "https://example.com/a?b=1")
        #expect(BrowserRegistry.storableDocumentURL(
            "https://u:p@example.com/doc", bundleID: nil, collectBrowserURL: true
        ) == "https://example.com/doc")
    }

    // MARK: - Repairing what an older build stored

    @Test("the migration redacts stored titles, addresses, blocks and outlines, and their search rows")
    func migrationRepairs() throws {
        let queue = try DatabaseQueue(configuration: WorklensCore.Database.configuration())
        try Migrations.migrator.migrate(queue, upTo: "ledger-324-project-assignments")

        let jsonOutline = #"[AXStaticText] {"user": "ana", "password": "hunter2"}"#
        let cleanOutline = #"[AXStaticText] {"user": "ana", "password": [PASSWORD]}"#
        let plainOutline = "[AXStaticText] quarterly roadmap"
        try queue.write { db in
            func capture(_ id: String, title: String?, url: String?, offset: Double) throws {
                try db.execute(sql: """
                    INSERT INTO captures (id, captured_at, window_title, browser_url, context_signature,
                                          describe_status, describe_attempts, is_idle, is_redacted,
                                          is_meeting, created_at)
                    VALUES (?, ?, ?, ?, ?, 'described', 0, 0, 0, 0, ?)
                    """, arguments: [id, nine.addingTimeInterval(offset), title, url,
                                     title.map { "com.app|\($0)|-" }, nine])
                try SearchIndex.set(db, captureId: id, kind: .title, text: title)
                try SearchIndex.set(db, captureId: id, kind: .url, text: url)
            }
            try capture("leaky", title: rawTitle, url: rawURL, offset: 0)
            try capture("clean", title: "README.md — worklens", url: "https://github.com/a/b", offset: 1)
            try capture("null", title: nil, url: nil, offset: 2)

            func outline(_ id: String, _ text: String, documentURL: String?) throws {
                try db.execute(sql: """
                    INSERT INTO ax_snapshots (capture_id, coverage, node_count, text_chars,
                        elapsed_ms, text_hash, document_url, text, redactions_json, created_at)
                    VALUES (?, 'full', 40, ?, 30, ?, ?, ?, NULL, ?)
                    """, arguments: [id, text.count, AXOutline.hash(text), documentURL, text, nine])
                try SearchIndex.set(db, captureId: id, kind: .ax, text: text)
            }
            try outline("leaky", jsonOutline, documentURL: "https://u:p@intranet.example.com/doc")
            try outline("clean", plainOutline, documentURL: "https://github.com/a/b")

            try db.execute(sql: """
                INSERT INTO activity_blocks (id, day, start_at, end_at, app_key, task_key, title,
                                             summary_md, capture_count, source, created_at, updated_at)
                VALUES ('b-screen', ?, ?, ?, 'vscode', 'editing', ?, 'You edited password: a b c.', 2, 'screen', ?, ?),
                       ('b-cal', ?, ?, ?, 'meeting', 'meeting', 'Rotate keys', 'api_key=AbCdEf123456', 0, 'calendar', ?, ?)
                """, arguments: [fixtureDay, nine, nine.addingTimeInterval(60), rawTitle, nine, nine,
                                 fixtureDay, nine, nine.addingTimeInterval(60), nine, nine])
        }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let leaky = try #require(try Row.fetchOne(db, sql: "SELECT * FROM captures WHERE id = 'leaky'"))
            #expect(leaky["window_title"] as String? == cleanTitle)
            #expect(leaky["browser_url"] as String? == cleanURL)
            #expect(leaky["context_signature"] as String? == "com.app|\(cleanTitle)|-")
            let clean = try #require(try Row.fetchOne(db, sql: "SELECT * FROM captures WHERE id = 'clean'"))
            #expect(clean["window_title"] as String? == "README.md — worklens")
            #expect(clean["browser_url"] as String? == "https://github.com/a/b")

            #expect(try indexed(db, kind: .title) == ["leaky": cleanTitle, "clean": "README.md — worklens"])
            #expect(try indexed(db, kind: .url) == ["leaky": cleanURL, "clean": "https://github.com/a/b"])
            #expect(try indexed(db, kind: .ax) == ["leaky": cleanOutline, "clean": plainOutline])
            // FTS finds nothing by the old secret.
            let hits = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'hunter2'")
            #expect(hits == 0)
            let mapped = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_docs")
            #expect(mapped == 6)

            let outline = try #require(try Row.fetchOne(db, sql: "SELECT * FROM ax_snapshots WHERE capture_id = 'leaky'"))
            #expect(outline["text"] as String? == cleanOutline)
            #expect(outline["text_chars"] as Int? == cleanOutline.count)
            #expect(outline["text_hash"] as String? == AXOutline.hash(cleanOutline))
            #expect(outline["document_url"] as String? == "https://intranet.example.com/doc")
            let untouched = try #require(try Row.fetchOne(db, sql: "SELECT * FROM ax_snapshots WHERE capture_id = 'clean'"))
            #expect(untouched["text_hash"] as String? == AXOutline.hash(plainOutline))

            let blocks = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT id, title, summary_md FROM activity_blocks
                """).map { ($0["id"] as String, ($0["title"] as String?, $0["summary_md"] as String?)) })
            #expect(blocks["b-screen"]?.0 == cleanTitle)
            // A screen block's summary is the describer's prose and is left as it was.
            #expect(blocks["b-screen"]?.1 == "You edited password: a b c.")
            #expect(blocks["b-cal"]?.1 == "api_key=[SECRET_1]")
        }

        // A second run finds nothing left to change.
        #expect(try queue.write { try CaptureMetadataRepair.redactStoredMetadata($0) } == 0)
    }

    // MARK: - MCP

    private func registry(_ db: WorklensCore.Database) throws -> MCPToolRegistry {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir
        return WorklensMCPTools.registry(
            config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir), timeZone: .current
        )
    }

    @Test("MCP search redacts a title an older build stored raw, in the heading and the snippet")
    func searchRedactsOldRows() throws {
        let db = try WorklensCore.Database.inMemory()
        try db.writer.write { db in
            // Written the way a build before the fix did: straight in, nothing redacted.
            try db.execute(sql: """
                INSERT INTO captures (id, captured_at, app_name, window_title, describe_status,
                                      describe_attempts, is_idle, is_redacted, is_meeting, created_at)
                VALUES ('old', ?, 'Code', ?, 'described', 0, 0, 0, 0, ?)
                """, arguments: [nine, rawTitle, nine])
            try SearchIndex.set(db, captureId: "old", kind: .title, text: rawTitle)
        }
        let result = try registry(db).call(name: "search", arguments: .object(["query": "deploy", "days": 0]))
        #expect(!result.isError)
        #expect(result.text.contains("1 hit(s)"))
        #expect(result.text.contains("password=[PASSWORD]"))
        #expect(!result.text.contains("hunter2"))
    }

    @Test("context_events and the timeline redact a meeting's title, body and outcomes")
    func contextEventsRedacted() throws {
        let db = try WorklensCore.Database.inMemory()
        let outcomes = MeetingOutcomes(
            nextSteps: [.init(text: "Rotate the key", detail: "new one is token=abcdefgh12345678")],
            decisions: [.init(text: "Share password: hunter2 with ops")]
        )
        try ContextEventStore(db).upsert(ContextEvent(
            source: .granola, externalId: "n1",
            startAt: nine, endAt: nine.addingTimeInterval(3600),
            title: "Infra sync — password=hunter2",
            bodyMd: "We used AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY and https://bob:s3cr3t@ci.example.com/job",
            isMeeting: true, syncedAt: nine, outcomesJson: outcomes.encoded
        ))

        let text = try registry(db).call(name: "context_events", arguments: .object([
            "from": .string(fixtureDay), "to": .string(fixtureDay),
        ])).text
        #expect(text.contains("Infra sync — password=[PASSWORD]"))
        #expect(text.contains("We used [SECRET_1] and https://ci.example.com/job"))
        #expect(text.contains("new one is token=[SECRET_1]"))
        #expect(text.contains("Share password: [PASSWORD] with ops"))
        for leak in ["hunter2", "AIza", "s3cr3t", "bob", "abcdefgh12345678"] {
            #expect(!text.contains(leak), "\(leak)")
        }

        let events = try ContextEventStore(db).events(day: fixtureDay, timeZone: .current)
        let timeline = TimelineRenderer.contextSection(events, timeZone: .current).joined(separator: "\n")
        #expect(timeline.contains("Infra sync — password=[PASSWORD]"))
        for leak in ["hunter2", "AIza", "s3cr3t"] {
            #expect(!timeline.contains(leak), "\(leak)")
        }

        // The block built from the meeting stores its heading and summary redacted.
        let blocks = ContextBlocks.meetingBlocks(day: fixtureDay, events: events, timeZone: .current)
        #expect(blocks.first?.title == "Infra sync — password=[PASSWORD]")
        #expect(blocks.first?.summaryMd?.contains("AIza") == false)
    }
}
