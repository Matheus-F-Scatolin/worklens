import Foundation
import GRDB
import Testing
@testable import WorklensCore

/// Nine in the morning of a fixed day. The stores derive a row's `day` in the machine's own
/// timezone, exactly as the app does, so every expectation below asks `DayBoundaries` rather than
/// hard-coding a string.
private let nine = DayBoundaries.range(day: "2026-09-09", timeZone: .current)!
    .start.addingTimeInterval(9 * 3600)
private var fixtureDay: String { DayBoundaries.dayString(nine) }

/// A database with the schema migrated and one day of frames in it.
private struct Harness {
    let db: WorklensCore.Database
    let captures: CaptureStore
    let descriptions: DescriptionStore
    let axSnapshots: AXSnapshotStore
    let blocks: ActivityBlockStore
    let search: SearchService

    init() throws {
        db = try Database.inMemory()
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        axSnapshots = AXSnapshotStore(db)
        blocks = ActivityBlockStore(db)
        search = SearchService(db)
    }

    /// One frame, with any of its four texts. `outline` is the redacted window outline that
    /// `AXSnapshotStore` stores; `summary` is what the describer wrote.
    @discardableResult
    func frame(
        minute: Double,
        title: String? = "#general",
        url: String? = nil,
        summary: String? = nil,
        outline: String? = nil,
        appName: String = "Slack"
    ) throws -> Capture {
        let at = nine.addingTimeInterval(minute * 60)
        let capture = Capture(
            capturedAt: at,
            appBundleId: "com.tinyspeck.slackmacgap",
            appName: appName,
            windowTitle: title,
            browserUrl: url,
            urlHost: url.flatMap { URL(string: $0)?.host },
            describeStatus: .described
        )
        try captures.insert(capture)
        if let summary {
            try descriptions.insert(Description(
                captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
                appKey: "slack", taskKey: "reading_messages", summaryMd: summary, createdAt: at
            ))
        }
        if let outline {
            try axSnapshots.insert(AXSnapshotRecord(
                captureId: capture.id, coverage: .full, nodeCount: 40, textChars: outline.count,
                elapsedMs: 44, textHash: AXOutline.hash(outline), text: outline, createdAt: at
            ))
        }
        return capture
    }

    /// One `activity_blocks` row covering a stretch of the fixture day.
    func block(fromMinute: Double, toMinute: Double) throws {
        try blocks.upsert(ActivityBlock(
            day: fixtureDay,
            startAt: nine.addingTimeInterval(fromMinute * 60),
            endAt: nine.addingTimeInterval(toMinute * 60),
            appKey: "slack", taskKey: "reading_messages", title: "#general",
            captureCount: 4, source: .screen, createdAt: nine, updatedAt: nine
        ))
    }

    func rowCount() throws -> Int {
        try db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fts") ?? 0
        }
    }
}

@Suite("SearchService")
struct SearchServiceTests {
    @Test("a word that appears only in a window outline finds its frame")
    func findsOutlineOnlyWord() throws {
        let harness = try Harness()
        let wanted = try harness.frame(
            minute: 27,
            outline: "[AXStaticText] YETI Rambler 20oz tumbler, stainless"
        )
        try harness.frame(minute: 40, summary: "You read #general.", outline: "[AXStaticText] hello")

        let hits = try harness.search.search(query: "YETI")
        #expect(hits.count == 1)
        #expect(hits.first?.captureId == wanted.id)
        #expect(hits.first?.kind == .ax)
        #expect(hits.first?.snippet.contains("YETI") == true)
        #expect(hits.first?.day == fixtureDay)
        #expect(hits.first?.appName == "Slack")
    }

    @Test("descriptions, titles and URLs are all searchable")
    func everyKindIsIndexed() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, title: "Quarterly planning — Notion")
        try harness.frame(minute: 10, title: nil, url: "https://example.com/tapirs/habitat")
        try harness.frame(minute: 15, title: nil, summary: "You drafted the onboarding checklist.")

        #expect(try harness.search.search(query: "quarterly").first?.kind == .title)
        #expect(try harness.search.search(query: "tapirs").first?.kind == .url)
        #expect(try harness.search.search(query: "onboarding").first?.kind == .description)
    }

    @Test("a quoted phrase matches only where the words are adjacent")
    func quotedPhrase() throws {
        let harness = try Harness()
        let adjacent = try harness.frame(
            minute: 27, outline: "[AXStaticText] the YETI Rambler is on the desk"
        )
        try harness.frame(
            minute: 45, outline: "[AXStaticText] a YETI cooler and a Stanley Rambler mug"
        )

        #expect(try harness.search.search(query: "YETI Rambler").count == 2)
        let phrase = try harness.search.search(query: "\"yeti rambler\"")
        #expect(phrase.count == 1)
        #expect(phrase.first?.captureId == adjacent.id)
    }

    @Test("a description ranks above an outline that matches the same word")
    func descriptionOutranksOutline() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, title: nil, outline: "[AXStaticText] kubernetes rollout notes")
        let described = try harness.frame(
            minute: 200, title: nil, summary: "You debugged the kubernetes rollout."
        )
        // Different blocks, so ranking rather than collapsing decides the order.
        try harness.block(fromMinute: 0, toMinute: 60)
        try harness.block(fromMinute: 180, toMinute: 240)

        let hits = try harness.search.search(query: "kubernetes")
        #expect(hits.count == 2)
        #expect(hits.first?.captureId == described.id)
        #expect(hits.first?.kind == .description)
    }

    @Test("clearText removes the outline hit and keeps the description hit")
    func clearTextDropsOnlyTheOutline() throws {
        let harness = try Harness()
        let capture = try harness.frame(
            minute: 27,
            title: nil,
            summary: "You compared tumblers on Amazon.",
            outline: "[AXStaticText] YETI Rambler 20oz"
        )

        #expect(try harness.search.search(query: "YETI").count == 1)
        try harness.axSnapshots.clearText(captureId: capture.id)

        #expect(try harness.search.search(query: "YETI").isEmpty)
        let kept = try harness.search.search(query: "tumblers")
        #expect(kept.count == 1)
        #expect(kept.first?.kind == .description)
    }

    @Test("erasing a stretch leaves no index rows for it")
    func eraseLeavesNothing() async throws {
        let harness = try Harness()
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        var config = Config.defaults()
        config.dataDir = dataDir

        try harness.frame(minute: 5, title: "kept", outline: "[AXStaticText] narwhal sightings")
        try harness.frame(
            minute: 30, title: "doomed", summary: "You compared tumblers.",
            outline: "[AXStaticText] YETI Rambler 20oz"
        )

        let eraser = DataEraser(config: config, db: harness.db)
        _ = try await eraser.erase(
            from: nine.addingTimeInterval(20 * 60), to: nine.addingTimeInterval(60 * 60)
        )

        #expect(try harness.search.search(query: "YETI").isEmpty)
        #expect(try harness.search.search(query: "tumblers").isEmpty)
        #expect(try harness.search.search(query: "doomed").isEmpty)
        #expect(try harness.search.search(query: "narwhal").count == 1)
        // The kept frame's title and outline, and nothing else.
        #expect(try harness.rowCount() == 2)
    }

    @Test("consecutive frames of one block collapse into a single hit")
    func framesOfOneBlockCollapse() throws {
        let harness = try Harness()
        for minute in stride(from: 0.0, to: 20.0, by: 1.0) {
            try harness.frame(
                minute: minute, title: nil,
                outline: "[AXStaticText] YETI Rambler 20oz review, minute \(Int(minute))"
            )
        }
        try harness.frame(minute: 300, title: nil, outline: "[AXStaticText] YETI cooler, later")
        try harness.block(fromMinute: 0, toMinute: 30)

        let hits = try harness.search.search(query: "YETI")
        #expect(hits.count == 2)
        #expect(hits.first { $0.blockId != nil }?.frames == 20)
        #expect(hits.first { $0.blockId == nil }?.frames == 1)
    }

    @Test("the day range and the limit both bound the result")
    func boundsResults() throws {
        let harness = try Harness()
        try harness.frame(minute: 0, title: "otter one")
        try harness.frame(minute: 60, title: "otter two")
        try harness.frame(minute: -48 * 60, title: "otter long ago")

        #expect(try harness.search.search(query: "otter").count == 3)
        #expect(try harness.search.search(query: "otter", limit: 2).count == 2)
        let today = try harness.search.search(query: "otter", days: fixtureDay...fixtureDay)
        #expect(today.count == 2)
    }

    @Test("punctuation a person types is escaped rather than parsed as FTS5 syntax")
    func punctuationIsEscaped() throws {
        let harness = try Harness()
        try harness.frame(minute: 5, title: nil, url: "https://news.example.com/self-hosted-llms")

        #expect(try harness.search.search(query: "self-hosted").count == 1)
        // A bare `(` and a trailing `*` are FTS5 syntax; the first has to be escaped away and
        // the second has to survive as a prefix search.
        #expect(try harness.search.search(query: "(self-hosted*").count == 1)
        #expect(try harness.search.search(query: "-- ??").isEmpty)
        #expect(try harness.search.search(query: "   ").isEmpty)
    }

    @Test("backfill indexes rows that were written before the index existed")
    func backfillIndexesExistingRows() throws {
        let harness = try Harness()
        // Straight into the tables, bypassing the stores — the state every row on an existing
        // install is in when the `search-fts` migration runs.
        try harness.db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO captures (id, captured_at, window_title, browser_url,
                                          describe_status, describe_attempts, created_at)
                    VALUES ('c1', ?, 'Amazon.com', 'https://amazon.com/yeti', 'described', 1, ?);
                    """,
                arguments: [nine, nine]
            )
            try db.execute(
                sql: """
                    INSERT INTO ax_snapshots (capture_id, coverage, node_count, text_chars,
                                              elapsed_ms, text_hash, text, created_at)
                    VALUES ('c1', 'full', 12, 30, 40, 'h', '[AXStaticText] YETI Rambler 20oz', ?);
                    """,
                arguments: [nine]
            )
            try db.execute(
                sql: """
                    INSERT INTO descriptions (id, capture_id, provider, model, app_key, task_key,
                                              summary_md, created_at)
                    VALUES ('d1', 'c1', 'gemini', 'm', 'chrome', 'browsing',
                            'You compared tumblers.', ?);
                    """,
                arguments: [nine]
            )
        }
        #expect(try harness.rowCount() == 0)
        #expect(try harness.search.search(query: "YETI").isEmpty)

        try harness.db.writer.write { try SearchIndex.backfill($0) }

        #expect(try harness.rowCount() == 4)   // outline, description, title, url
        #expect(try harness.search.search(query: "YETI").count == 1)
        #expect(try harness.search.search(query: "tumblers").first?.kind == .description)
        #expect(try harness.search.search(query: "amazon.com").isEmpty == false)

        // Idempotent: a second pass replaces each row rather than doubling it.
        try harness.db.writer.write { try SearchIndex.backfill($0) }
        #expect(try harness.rowCount() == 4)
        #expect(try harness.search.search(query: "YETI").count == 1)
    }
}

// MARK: - Paging, and the total behind it (#244)

@Suite("Search paging (#244)")
struct SearchPagingTests {
    /// `count` frames, each its own result: no `activity_blocks` row is built, so nothing
    /// collapses and the count of hits is the count of frames.
    private func seeded(_ count: Int) throws -> Harness {
        let harness = try Harness()
        for index in 0..<count {
            try harness.frame(minute: Double(index) * 5, title: "tapir plan \(index)")
        }
        return harness
    }

    @Test("the call `worklens search` and the MCP tool make answers exactly what it did")
    func unchangedShape() throws {
        let harness = try seeded(5)
        let hits = try harness.search.search(query: "tapir")
        let page = try harness.search.page(query: "tapir")
        #expect(page.hits == hits)
        #expect(page.offset == 0)
        #expect(page.total == 5)
        #expect(page.isTotalExact)
        // A narrower limit is still the first `limit` of the same ranking, frame counts and all.
        #expect(try harness.search.search(query: "tapir", limit: 2) == Array(hits.prefix(2)))
        #expect(try harness.search.page(query: "tapir", limit: 2).hits == Array(hits.prefix(2)))
    }

    @Test("Show more adds exactly one page, and the counts agree with the rows")
    func pages() throws {
        let harness = try seeded(5)
        let all = try harness.search.search(query: "tapir", limit: 10)

        let first = try harness.search.page(query: "tapir", limit: 2)
        #expect(first.hits.count == 2)
        #expect(first.total == 5)
        #expect(first.shown == 2)
        #expect(first.hasMore)

        let second = try harness.search.page(query: "tapir", offset: 2, limit: 2)
        #expect(second.hits.count == 2)
        #expect(second.shown == 4)
        #expect(second.hasMore)

        let third = try harness.search.page(query: "tapir", offset: 4, limit: 2)
        #expect(third.hits.count == 1)
        #expect(third.shown == 5)
        #expect(!third.hasMore)

        // Three pages, five results, nothing shown twice and nothing left out.
        let paged = first.hits + second.hits + third.hits
        #expect(paged.map(\.captureId) == all.map(\.captureId))
        #expect(Set(paged.map(\.captureId)).count == 5)
    }

    @Test("an offset past the end is an empty page, not an error")
    func pastTheEnd() throws {
        let harness = try seeded(2)
        let page = try harness.search.page(query: "tapir", offset: 10, limit: 20)
        #expect(page.hits.isEmpty)
        #expect(page.total == 2)
        #expect(!page.hasMore)
    }

    @Test("a day range still bounds every page of it")
    func ranges() throws {
        let harness = try seeded(3)
        let day = fixtureDay
        #expect(try harness.search.page(query: "tapir", days: day...day).total == 3)
        // A window that ends before the day was recorded finds none of it, and says so with a
        // zero rather than with a shorter list.
        let before = DayBoundaries.dayString(nine.addingTimeInterval(-40 * 86_400))
        let page = try harness.search.page(query: "tapir", days: before...before)
        #expect(page.hits.isEmpty)
        #expect(page.total == 0)
        #expect(page.isTotalExact)
    }

    @Test("hits that collapse into one block are one result on every page")
    func collapsedResultsArePagedAsResults() throws {
        let harness = try Harness()
        for index in 0..<6 { try harness.frame(minute: Double(index), title: "tapir plan") }
        try harness.block(fromMinute: 0, toMinute: 10)
        try harness.frame(minute: 300, title: "tapir plan later")

        let page = try harness.search.page(query: "tapir", limit: 20)
        // Six frames of one block are one result; the seventh, outside it, is the other.
        #expect(page.total == 2)
        #expect(page.hits.count == 2)
        #expect(page.hits.map(\.frames).max() == 6)
    }

    /// The scan cap counts rows and the total counts collapsed results, so the two can disagree:
    /// one long block can fill the cap and still be one result. The header may only say "more
    /// than" while the page it is describing actually filled.
    @Test("a page that ran short of results states its count plainly")
    func shortPageIsAnExactCount() throws {
        let harness = try Harness()
        // More frames than the scan cap of a two-result page — max(2 * 20, 200) — all of them
        // inside one block, so the collapse has one result to give.
        for index in 0..<220 { try harness.frame(minute: Double(index) * 0.5, title: "tapir plan") }
        try harness.block(fromMinute: 0, toMinute: 200)

        let page = try harness.search.page(query: "tapir", limit: 2)
        #expect(page.total == 1)
        #expect(page.hits.count == 1)
        #expect(page.isTotalExact)
        // Nothing to page to, so no Show more row.
        #expect(!page.hasMore)
    }

    @Test("a page that filled off a capped scan still says its total is a floor")
    func filledPageOffACappedScanIsAFloor() throws {
        let harness = try Harness()
        // No block, so every frame is its own result and the page fills from the capped scan.
        for index in 0..<220 { try harness.frame(minute: Double(index) * 0.5, title: "tapir \(index)") }

        let page = try harness.search.page(query: "tapir", limit: 2)
        #expect(page.hits.count == 2)
        #expect(!page.isTotalExact)
        #expect(page.hasMore)
    }
}

// MARK: - d5 project keys (#315)

@Suite("Search project filter (#315)")
struct SearchProjectKeyTests {
    @Test("the project filter finds a frame that has only a key")
    func findsKeyOnlyFrame() throws {
        let harness = try Harness()
        func described(minute: Double, details: String) throws -> Capture {
            let capture = try harness.frame(minute: minute)
            try harness.descriptions.insert(Description(
                captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
                appKey: "slack", taskKey: "reading_messages", summaryMd: "Reviews the board deck.",
                detailsJson: details, createdAt: nine
            ))
            return capture
        }
        let keyed = try described(minute: 5, details: #"{"project_key":"acme"}"#)
        _ = try described(minute: 50, details: #"{"project_hint":"Globex"}"#)

        let result = try harness.search.search(query: "board", filters: SearchFilters(project: "Acme"))
        #expect(result.hits.map(\.captureId) == [keyed.id])
        #expect(result.excluded == 1)
    }

    /// One frame per key: `acme`, a key a merge folded into it, and a stranger's.
    private func keyedFrames(_ harness: Harness) throws -> (acme: Capture, merged: Capture) {
        func described(minute: Double, key: String) throws -> Capture {
            let capture = try harness.frame(minute: minute)
            try harness.descriptions.insert(Description(
                captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
                appKey: "slack", taskKey: "reading_messages", summaryMd: "Reviews the board deck.",
                detailsJson: #"{"project_key":"\#(key)"}"#, createdAt: nine
            ))
            return capture
        }
        let acme = try described(minute: 5, key: "acme")
        let merged = try described(minute: 20, key: "rocket")
        _ = try described(minute: 50, key: "globex")
        return (acme, merged)
    }

    private let catalog = [
        ProjectEntry(key: "acme", name: "Acme Corp", aliases: ["rocket"], kind: .company),
        ProjectEntry(key: "globex", name: "Globex"),
    ]

    @Test("filtering by an entry's name finds frames that have only its key")
    func findsByName() throws {
        let harness = try Harness()
        let frames = try keyedFrames(harness)
        let search = SearchService(harness.db, projects: catalog)

        let result = try search.search(query: "board", filters: SearchFilters(project: "Acme Corp"))
        #expect(Set(result.hits.map(\.captureId)) == [frames.acme.id, frames.merged.id])
        #expect(result.excluded == 1)
    }

    @Test("filtering by a merged-away key finds the frames of the entry it was merged into")
    func findsByMergedKey() throws {
        let harness = try Harness()
        let frames = try keyedFrames(harness)
        let search = SearchService(harness.db, projects: catalog)

        let result = try search.search(query: "board", filters: SearchFilters(project: "rocket"))
        #expect(Set(result.hits.map(\.captureId)) == [frames.acme.id, frames.merged.id])
    }
}
