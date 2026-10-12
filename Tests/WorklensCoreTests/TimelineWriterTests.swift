import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start

/// A writer over an in-memory database and a temp DATA_DIR.
private struct Harness {
    let dataDir: URL
    let config: Config
    let db: Database
    let writer: TimelineWriter
    let captures: CaptureStore
    let descriptions: DescriptionStore
    let blocks: ActivityBlockStore

    init(captureInterval: Int = 60) throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        var config = Config.defaults()
        config.dataDir = dataDir
        config.captureIntervalSeconds = captureInterval
        self.config = config

        db = try Database.inMemory()
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        blocks = ActivityBlockStore(db)
        writer = TimelineWriter(
            config: config,
            db: db,
            taxonomy: try TaxonomyStore(dataDir: dataDir),
            timeZone: utc,
            now: { dayStart.addingTimeInterval(12 * 3600) }
        )
    }

    /// One capture plus, unless `describe` is false, its description.
    @discardableResult
    func addFrame(
        minute: Double,
        app: String = "slack",
        task: String = "reading_messages",
        summary: String = "Reading #general.",
        describe: Bool = true,
        inherited: Bool = false,
        redacted: Bool = false,
        bundleID: String = "com.tinyspeck.slackmacgap",
        detailsJSON: String? = nil
    ) throws -> Capture {
        let at = dayStart.addingTimeInterval(9 * 3600 + minute * 60)
        let capture = Capture(
            capturedAt: at,
            imagePath: "screenshots/\(day)/x.jpg",
            appBundleId: bundleID,
            appName: "Slack",
            windowTitle: "#general",
            isRedacted: redacted,
            describeStatus: describe ? .described : .pending
        )
        try captures.insert(capture)
        if describe {
            try descriptions.insert(Description(
                captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
                appKey: app, taskKey: task, summaryMd: summary, detailsJson: detailsJSON,
                isInherited: inherited
            ))
        }
        return capture
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }
}

@Suite("TimelineWriter")
struct TimelineWriterTests {
    @Test("a rebuild writes blocks and returns the markdown, without writing a timeline file")
    func rebuildWritesBlocksOnly() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)
        try harness.addFrame(minute: 1)
        try harness.addFrame(minute: 2, task: "writing_messages", summary: "Replying in #general.")

        let markdown = try await harness.writer.rebuild(day: day)

        let stored = try harness.blocks.fetch(day: day)
        #expect(stored.count == 2)
        #expect(stored.map(\.taskKey) == ["reading_messages", "writing_messages"])

        // #299: nothing reads `timeline/<day>.md` any more, so nothing writes it.
        let url = harness.config.timelineDir.appendingPathComponent("\(day).md")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: harness.config.timelineDir.path))
        #expect(markdown == (try harness.writer.markdown(day: day)))
        #expect(markdown.contains("· Slack · Reading messages"))
    }

    @Test("rebuilding twice replaces the screen blocks instead of duplicating them")
    func rebuildIsIdempotent() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)
        try harness.addFrame(minute: 1)

        _ = try await harness.writer.rebuild(day: day)
        let first = try harness.blocks.fetch(day: day)
        _ = try await harness.writer.rebuild(day: day)
        let second = try harness.blocks.fetch(day: day)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].startAt == second[0].startAt)
    }

    @Test("a synced meeting becomes a block the rebuild keeps rewriting")
    func rebuildsContextBlocks() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)
        // #19 moved ownership of calendar/Granola blocks to the writer: they are rebuilt from
        // `context_events` on every pass, exactly as screen blocks are rebuilt from captures.
        let events = ContextEventStore(harness.db)
        try events.save(ContextEvent(
            source: .calendar, externalId: "evt-1",
            startAt: dayStart.addingTimeInterval(10 * 3600),
            endAt: dayStart.addingTimeInterval(11 * 3600),
            title: "Portfolio review", isMeeting: true
        ))

        let markdown = try await harness.writer.rebuild(day: day)
        let calendar = try harness.blocks.fetch(day: day).filter { $0.source == .calendar }
        #expect(calendar.count == 1)
        #expect(calendar.first?.title == "Portfolio review")
        #expect(calendar.first?.taskKey == ContextBlocks.taskKey)
        #expect(markdown.contains("source: calendar"))

        // A second pass must not duplicate it.
        _ = try await harness.writer.rebuild(day: day)
        #expect(try harness.blocks.fetch(day: day).filter { $0.source == .calendar }.count == 1)
    }

    @Test("a lunch on the calendar becomes an away block the rebuild owns (#94)")
    func rebuildsAwayBlocks() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)
        let events = ContextEventStore(harness.db)
        try events.save(ContextEvent(
            source: .calendar, externalId: "lunch",
            startAt: dayStart.addingTimeInterval(12 * 3600),
            endAt: dayStart.addingTimeInterval(13 * 3600),
            title: "Lunch at bem",
            isMeeting: false,
            rawJson: #"{"start":{"dateTime":"2026-09-07T12:00:00Z"},"attendees":"#
                + #"[{"email":"you@example.com","self":true},{"email":"ana@example.com"}]}"#
        ))

        let markdown = try await harness.writer.rebuild(day: day)
        let away = try harness.blocks.fetch(day: day).filter { $0.appKey == ContextBlocks.awayAppKey }
        #expect(away.count == 1)
        #expect(away.first?.title == "Lunch at bem")
        #expect(markdown.contains("· Away · \"Lunch at bem\""))

        // Owned by the rebuild like a meeting block: a second pass leaves exactly one.
        _ = try await harness.writer.rebuild(day: day)
        #expect(try harness.blocks.fetch(day: day)
            .filter { $0.appKey == ContextBlocks.awayAppKey }.count == 1)
    }

    @Test("a cancelled meeting disappears from the day on the next rebuild")
    func removesDeletedContextBlocks() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)
        let events = ContextEventStore(harness.db)
        try events.save(ContextEvent(
            source: .calendar, externalId: "evt-1",
            startAt: dayStart.addingTimeInterval(10 * 3600),
            endAt: dayStart.addingTimeInterval(11 * 3600),
            title: "Portfolio review", isMeeting: true
        ))
        _ = try await harness.writer.rebuild(day: day)

        try events.delete(source: .calendar, externalId: "evt-1")
        _ = try await harness.writer.rebuild(day: day)
        #expect(try harness.blocks.fetch(day: day).allSatisfy { $0.source == .screen })
    }

    @Test("a redacted frame is labeled from its bundle id, not from a description")
    func redactedFramesResolveFromMetadata() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(
            minute: 0, describe: false, redacted: true, bundleID: "com.apple.Safari"
        )
        let markdown = try await harness.writer.rebuild(day: day)

        let stored = try harness.blocks.fetch(day: day)
        #expect(stored.count == 1)
        #expect(stored[0].appKey == "browser")
        #expect(stored[0].taskKey == "redacted")
        #expect(markdown.contains("Redacted (blocked app)"))
    }

    @Test("a frame loads its document and project hint out of details_json (#69)")
    func documentLoadsFromDetails() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(
            minute: 0,
            detailsJSON: #"{"document":"Parody lyrics","people":["Ana"],"project_hint":"KPL"}"#
        )
        try harness.addFrame(minute: 1)

        let frames = try TimelineQueries(harness.db).frames(day: day, timeZone: utc)
        #expect(frames.count == 2)
        #expect(frames[0].document == "Parody lyrics")
        #expect(frames[0].projectHint == "KPL")
        #expect(frames[0].appName == "Slack")
        // A row with no details_json at all carries neither.
        #expect(frames[1].document == nil)
        #expect(frames[1].projectHint == nil)
    }

    @Test("details_json without a document, or malformed, loads nil rather than throwing")
    func documentToleratesMissingAndMalformedJSON() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0, detailsJSON: #"{"redactions":{"card":1}}"#)
        try harness.addFrame(minute: 1, detailsJSON: "not json")
        try harness.addFrame(minute: 2, detailsJSON: #"{"document":"   "}"#)

        let frames = try TimelineQueries(harness.db).frames(day: day, timeZone: utc)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.document == nil })
    }

    @Test("the gap tolerance follows the capture interval but never drops below three minutes")
    func gapToleranceFloor() async throws {
        let fast = try Harness(captureInterval: 30)
        defer { fast.cleanUp() }
        #expect(await fast.writer.gapTolerance == 180)

        let slow = try Harness(captureInterval: 120)
        defer { slow.cleanUp() }
        #expect(await slow.writer.gapTolerance == 360)
    }

    @Test("markdown(day:) renders without touching the database or the file")
    func markdownIsReadOnly() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)

        let markdown = try harness.writer.markdown(day: day)
        #expect(markdown.contains("Worklens timeline"))
        #expect(try harness.blocks.fetch(day: day).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.config.timelineDir.path))
    }

    @Test("nudges collapse into one rebuild")
    func nudgeDebounces() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)

        for _ in 0..<5 { await harness.writer.nudge(day: day) }
        await harness.writer.flush()

        #expect(try harness.blocks.fetch(day: day).count == 1)
    }

    @Test("rebuilding a 600-frame day stays well under a second")
    func rebuildIsFast() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        for minute in 0..<600 {
            try harness.addFrame(
                minute: Double(minute),
                task: minute % 20 == 0 ? "writing_messages" : "reading_messages",
                summary: "Frame \(minute)."
            )
        }

        // A quiet machine does this in well under 200 ms; with the whole suite running in
        // parallel the same rebuild measures 250 ms, so the bound is wide enough to be about
        // the code (a regression is slow every time) and not the scheduler. Best of three.
        var elapsed = Double.infinity
        for _ in 0..<3 {
            let started = Date()
            _ = try await harness.writer.rebuild(day: day)
            elapsed = min(elapsed, Date().timeIntervalSince(started))
        }
        #expect(elapsed < 1.0, "the fastest rebuild took \(Int(elapsed * 1000)) ms")
    }
}
