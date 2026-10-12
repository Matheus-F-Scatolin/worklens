import Foundation
import GRDB
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
/// Nine in the morning, the anchor every frame below is an offset from.
private let nine = dayStart.addingTimeInterval(9 * 3600)

/// An eraser over an in-memory database and a real temp `DATA_DIR`, so the file half of an
/// erase is exercised rather than assumed.
private struct Harness {
    let dataDir: URL
    let config: Config
    let db: WorklensCore.Database
    let eraser: DataEraser
    let timeline: TimelineWriter
    let captures: CaptureStore
    let descriptions: DescriptionStore
    let blocks: ActivityBlockStore
    let sessions: ForegroundSessionStore
    let ledger: LLMCallStore
    let axSnapshots: AXSnapshotStore

    init() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-erase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        var config = Config.defaults()
        config.dataDir = dataDir
        self.config = config

        db = try WorklensCore.Database.inMemory()
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        blocks = ActivityBlockStore(db)
        sessions = ForegroundSessionStore(db)
        ledger = LLMCallStore(db)
        axSnapshots = AXSnapshotStore(db)
        timeline = TimelineWriter(
            config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir),
            timeZone: utc, now: { nine.addingTimeInterval(6 * 3600) }
        )
        eraser = DataEraser(
            config: config, db: db, timeline: timeline, timeZone: utc,
            now: { nine.addingTimeInterval(6 * 3600) }
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }

    /// One described frame with a real JPEG-shaped file on disk.
    @discardableResult
    func addFrame(minute: Double, summary: String = "Reading #general.", withImage: Bool = true) throws -> Capture {
        let at = nine.addingTimeInterval(minute * 60)
        var capture = Capture(
            capturedAt: at,
            appBundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#general",
            describeStatus: .described
        )
        if withImage {
            let url = try ScreenshotPaths.url(for: at, id: capture.id, dataDir: dataDir, timeZone: utc)
            try Data("not really a jpeg".utf8).write(to: url)
            capture.imagePath = ScreenshotPaths.relativePath(for: at, id: capture.id, timeZone: utc)
        }
        try captures.insert(capture)
        try descriptions.insert(Description(
            captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
            appKey: "slack", taskKey: "reading_messages", summaryMd: summary, createdAt: at
        ))
        return capture
    }

    /// A stored window outline for one frame (#53).
    func addAXSnapshot(_ capture: Capture, text: String = "[AXStaticText] #general") throws {
        try axSnapshots.insert(AXSnapshotRecord(
            captureId: capture.id, coverage: .full, nodeCount: 40, textChars: text.count,
            elapsedMs: 44, textHash: AXOutline.hash(text), text: text,
            createdAt: capture.capturedAt
        ))
    }

    func imageExists(_ capture: Capture) -> Bool {
        guard let path = capture.imagePath else { return false }
        return FileManager.default.fileExists(atPath: dataDir.appendingPathComponent(path).path)
    }
}

@Suite("DataEraser")
struct DataEraserTests {
    @Test("erasing a stretch removes its rows, its descriptions and its files")
    func erasesRowsAndFiles() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let keptEarly = try harness.addFrame(minute: 0)
        let doomed = try harness.addFrame(minute: 30)
        let alsoDoomed = try harness.addFrame(minute: 35)
        let keptLate = try harness.addFrame(minute: 120)

        let summary = try await harness.eraser.erase(
            from: nine.addingTimeInterval(20 * 60), to: nine.addingTimeInterval(60 * 60)
        )

        #expect(summary.frames == 2)
        #expect(summary.images == 2)
        #expect(summary.days == [day])
        #expect(try harness.captures.fetch(id: doomed.id) == nil)
        #expect(try harness.captures.fetch(id: alsoDoomed.id) == nil)
        #expect(try harness.captures.fetch(id: keptEarly.id) != nil)
        #expect(try harness.captures.fetch(id: keptLate.id) != nil)
        // ON DELETE CASCADE is what takes the descriptions; assert it rather than trust it.
        #expect(try harness.descriptions.fetch(captureId: doomed.id) == nil)
        #expect(try harness.descriptions.fetch(captureId: keptLate.id) != nil)
        #expect(!harness.imageExists(doomed))
        #expect(!harness.imageExists(alsoDoomed))
        #expect(harness.imageExists(keptEarly))
        #expect(harness.imageExists(keptLate))
    }

    /// #53 stores the focused window's text beside the pixels, and it is the most literal record
    /// of the moment in the database. The foreign key is what removes it; that is exactly why it
    /// is asserted here rather than assumed.
    @Test("the stored window text goes with the frame, by cascade")
    func erasesAXSnapshots() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let doomed = try harness.addFrame(minute: 30)
        let kept = try harness.addFrame(minute: 120)
        try harness.addAXSnapshot(doomed, text: "[AXStaticText] Ana: standup at ten")
        try harness.addAXSnapshot(kept)

        #expect(try harness.axSnapshots.fetch(captureId: doomed.id) != nil)

        _ = try await harness.eraser.erase(
            from: nine.addingTimeInterval(20 * 60), to: nine.addingTimeInterval(60 * 60)
        )

        #expect(try harness.axSnapshots.fetch(captureId: doomed.id) == nil)
        #expect(try harness.axSnapshots.fetch(captureId: kept.id) != nil)
        // Nothing of the text is left behind anywhere in the table.
        let remaining = try await harness.db.writer.read { try AXSnapshotRecord.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(!(remaining[0].text ?? "").contains("standup"))
    }

    /// The one thing an erase must not touch. A budget that forgets what was spent is broken,
    /// and deleting the evidence of a charge does not undo the charge.
    @Test("llm_calls is left alone, so spend stays accurate")
    func spendSurvives() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 30)
        try harness.ledger.insert(LLMCall(
            provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
            costUsd: 0.0004, createdAt: nine.addingTimeInterval(30 * 60)
        ))
        let before = try harness.ledger.spend(from: dayStart, to: dayStart.addingTimeInterval(86_400))

        _ = try await harness.eraser.erase(from: nine, to: nine.addingTimeInterval(3600))

        let after = try harness.ledger.spend(from: dayStart, to: dayStart.addingTimeInterval(86_400))
        #expect(before == after)
        #expect(after > 0)
    }

    @Test("context_events survive: a meeting you attended is not something Worklens watched")
    func contextEventsSurvive() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 30)
        let events = ContextEventStore(harness.db)
        try events.upsert(ContextEvent(
            source: .calendar, externalId: "evt-1",
            startAt: nine.addingTimeInterval(30 * 60), endAt: nine.addingTimeInterval(60 * 60),
            title: "Northwind review", isMeeting: true, syncedAt: nine
        ))

        _ = try await harness.eraser.erase(from: nine, to: nine.addingTimeInterval(3600))
        #expect(try events.fetch(
            from: dayStart, to: dayStart.addingTimeInterval(86_400)
        ).count == 1)
    }

    @Test("the day's timeline is rebuilt, so the erased stretch is gone from it too")
    func timelineRebuilt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        for minute in stride(from: 0.0, to: 30.0, by: 5.0) {
            try harness.addFrame(minute: minute, summary: "Morning triage.")
        }
        for minute in stride(from: 60.0, to: 90.0, by: 5.0) {
            try harness.addFrame(minute: minute, summary: "Writing the Acme memo.")
        }
        _ = try await harness.timeline.rebuild(day: day)
        #expect(try harness.timeline.markdown(day: day).contains("Acme memo"))

        _ = try await harness.eraser.erase(
            from: nine.addingTimeInterval(55 * 60), to: nine.addingTimeInterval(95 * 60)
        )

        let markdown = try harness.timeline.markdown(day: day)
        #expect(!markdown.contains("Acme memo"))
        #expect(markdown.contains("Morning triage"))
    }

    /// #299: the ledger is gone but `friction_items` is not, and a timeline file written before
    /// the writer stopped writing them is still on disk. An erased day keeps neither.
    @Test("erasing a day removes its friction_items rows and its old timeline file")
    func frictionRowsAndTimelineFileGo() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 0)
        for (id, rowDay) in [("a", day), ("b", day), ("c", "2026-09-08")] {
            try await harness.db.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO friction_items (id, day, slug, kind, title, created_at)
                        VALUES (?, ?, 'pricing-deck', 're_entry', 'Came back to the pricing deck', ?)
                        """,
                    arguments: [id, rowDay, nine]
                )
            }
        }
        let timelineDir = harness.config.timelineDir
        try FileManager.default.createDirectory(at: timelineDir, withIntermediateDirectories: true)
        let erasedFile = timelineDir.appendingPathComponent("\(day).md")
        let keptFile = timelineDir.appendingPathComponent("2026-09-08.md")
        try Data("# \(day)\n".utf8).write(to: erasedFile)
        try Data("# 2026-09-08\n".utf8).write(to: keptFile)

        let range = try #require(harness.eraser.dayRange(from: day, to: day))
        let summary = try await harness.eraser.erase(from: range.from, to: range.to)

        let remaining: [String] = try await harness.db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT day FROM friction_items ORDER BY day")
        }
        #expect(summary.friction == 2)
        #expect(remaining == ["2026-09-08"])
        #expect(!FileManager.default.fileExists(atPath: erasedFile.path))
        // The next day was not in the range and keeps both.
        #expect(FileManager.default.fileExists(atPath: keptFile.path))
    }

    /// A partial erase must not take down the blocks either side of it, which is why the eraser
    /// deletes overlapping screen blocks rather than the whole day's.
    @Test("only the blocks overlapping the range are removed before the rebuild")
    func neighbouringBlocksSurvive() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        for minute in stride(from: 0.0, to: 20.0, by: 5.0) {
            try harness.addFrame(minute: minute, summary: "Morning triage.")
        }
        for minute in stride(from: 240.0, to: 260.0, by: 5.0) {
            try harness.addFrame(minute: minute, summary: "Afternoon review.")
        }
        _ = try await harness.timeline.rebuild(day: day)
        let before = try harness.blocks.fetch(day: day).filter { $0.source == .screen }
        #expect(before.count >= 2)

        _ = try await harness.eraser.erase(
            from: nine.addingTimeInterval(235 * 60), to: nine.addingTimeInterval(265 * 60)
        )

        let after = try harness.blocks.fetch(day: day).filter { $0.source == .screen }
        #expect(after.contains { $0.summaryMd?.contains("Morning triage") == true })
        #expect(!after.contains { $0.summaryMd?.contains("Afternoon review") == true })
    }

    @Test("the range is recorded in app_state so the app can say what it deleted")
    func lastEraseRecorded() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 30)
        #expect(try harness.eraser.lastErase() == nil)

        let from = nine, to = nine.addingTimeInterval(3600)
        _ = try await harness.eraser.erase(from: from, to: to)

        let record = try #require(try harness.eraser.lastErase())
        #expect(abs(record.from.timeIntervalSince(from)) < 1)
        #expect(abs(record.to.timeIntervalSince(to)) < 1)
    }

    @Test("erasing a stretch with nothing in it changes nothing and says so")
    func emptyRange() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let kept = try harness.addFrame(minute: 30)

        let summary = try await harness.eraser.erase(
            from: nine.addingTimeInterval(600 * 60), to: nine.addingTimeInterval(660 * 60)
        )
        #expect(summary.frames == 0)
        #expect(summary.days.isEmpty)
        #expect(try harness.captures.fetch(id: kept.id) != nil)
    }

    @Test("a frame whose image was already deleted is erased without a file to unlink")
    func rowWithoutImage() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let noImage = try harness.addFrame(minute: 30, withImage: false)
        let withImage = try harness.addFrame(minute: 31)

        let summary = try await harness.eraser.erase(from: nine, to: nine.addingTimeInterval(3600))
        #expect(summary.frames == 2)
        #expect(summary.images == 1)
        #expect(try harness.captures.fetch(id: noImage.id) == nil)
        #expect(try harness.captures.fetch(id: withImage.id) == nil)
    }

    @Test("a reversed range is read the way it was meant")
    func reversedRange() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let doomed = try harness.addFrame(minute: 30)
        let summary = try await harness.eraser.erase(from: nine.addingTimeInterval(3600), to: nine)
        #expect(summary.frames == 1)
        #expect(try harness.captures.fetch(id: doomed.id) == nil)
    }

    @Test("recentRange and dayRange are the two ways the UI asks for a window")
    func rangeHelpers() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let recent = harness.eraser.recentRange(minutes: 10)
        #expect(abs(recent.to.timeIntervalSince(recent.from) - 600) < 0.001)

        let range = try #require(harness.eraser.dayRange(from: "2026-09-06", to: "2026-09-07"))
        #expect(range.from == DayBoundaries.range(day: "2026-09-06", timeZone: utc)!.start)
        // Inclusive of the 7th, and not one instant into the 8th.
        let eighth = DayBoundaries.range(day: "2026-09-08", timeZone: utc)!.start
        #expect(range.to < eighth)
        #expect(range.to > eighth.addingTimeInterval(-1))
        #expect(harness.eraser.dayRange(from: "nonsense", to: "2026-09-07") == nil)
    }

    @Test("count is what the confirmation alert shows before anything is deleted")
    func countBeforeErasing() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.addFrame(minute: 5)
        try harness.addFrame(minute: 10)
        try harness.addFrame(minute: 400)

        #expect(try harness.eraser.count(from: nine, to: nine.addingTimeInterval(3600)) == 2)
        #expect(try harness.eraser.count(from: nine, to: nine.addingTimeInterval(86_400)) == 3)
        // Nothing was actually erased by asking.
        #expect(try harness.captures.fetch(day: day, timeZone: utc).count == 3)
    }
}

// MARK: - foreground_sessions (#46)

/// `minute` minutes past nine.
private func minute(_ value: Double) -> Date { nine.addingTimeInterval(value * 60) }

private func minutesIn(_ session: ForegroundSession) -> Double? {
    session.seconds.map { $0 / 60 }
}

@Suite("DataEraser and foreground_sessions")
struct DataEraserSessionTests {
    /// The erased stretch is 09:10 to 09:20 in every test below.
    private func erase(_ harness: Harness) async throws {
        _ = try await harness.eraser.erase(from: minute(10), to: minute(20))
    }

    private func remaining(_ harness: Harness) throws -> [ForegroundSession] {
        try harness.sessions.fetch(overlapping: .distantPast, to: .distantFuture)
    }

    @Test("a session entirely inside the erased stretch is deleted")
    func sessionInsideIsDeleted() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(
            startAt: minute(12), endAt: minute(18), appBundleId: "com.tinyspeck.slackmacgap"
        ))

        try await erase(harness)
        #expect(try remaining(harness).isEmpty)
    }

    @Test("a session outside the stretch is left alone")
    func sessionOutsideSurvives() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(
            startAt: minute(30), endAt: minute(45), appBundleId: "com.apple.dt.Xcode"
        ))

        try await erase(harness)
        let rows = try remaining(harness)
        #expect(rows.count == 1)
        #expect(minutesIn(rows[0]) == 15)
    }

    @Test("a session overlapping the start edge is trimmed back to it")
    func startEdgeIsTrimmed() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(
            startAt: minute(5), endAt: minute(15), appBundleId: "com.apple.dt.Xcode"
        ))

        try await erase(harness)
        let rows = try remaining(harness)
        #expect(rows.count == 1)
        #expect(rows[0].startAt == minute(5))
        #expect(rows[0].endAt == minute(10))
    }

    @Test("a session overlapping the end edge starts where the erase stops")
    func endEdgeIsTrimmed() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(
            startAt: minute(15), endAt: minute(25), appBundleId: "com.apple.dt.Xcode"
        ))

        try await erase(harness)
        let rows = try remaining(harness)
        #expect(rows.count == 1)
        #expect(rows[0].startAt == minute(20))
        #expect(rows[0].endAt == minute(25))
    }

    @Test("a session spanning the whole stretch is split, so the day still adds up")
    func straddlingSessionIsSplit() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(
            startAt: minute(0), endAt: minute(30), appBundleId: "com.apple.dt.Xcode"
        ))

        try await erase(harness)
        let rows = try remaining(harness).sorted { $0.startAt < $1.startAt }
        #expect(rows.count == 2)
        #expect(rows[0].startAt == minute(0))
        #expect(rows[0].endAt == minute(10))
        #expect(rows[1].startAt == minute(20))
        #expect(rows[1].endAt == minute(30))
        // Twenty minutes left of thirty; the ten inside the erase are gone, not donated.
        #expect(rows.compactMap(minutesIn).reduce(0, +) == 20)
    }

    @Test("an interval still open when the stretch is erased keeps running afterwards")
    func openSessionIsTrimmedNotClosed() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(
            startAt: minute(0), endAt: nil, appBundleId: "com.apple.dt.Xcode"
        ))

        try await erase(harness)
        let rows = try remaining(harness).sorted { $0.startAt < $1.startAt }
        #expect(rows.count == 2)
        #expect(rows[0].endAt == minute(10))
        #expect(rows[1].startAt == minute(20))
        #expect(rows[1].isOpen)
    }

    @Test("the summary counts what it removed and trimmed")
    func summaryCountsSessions() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.sessions.insert(ForegroundSession(startAt: minute(12), endAt: minute(14)))
        try harness.sessions.insert(ForegroundSession(startAt: minute(15), endAt: minute(25)))
        try harness.sessions.insert(ForegroundSession(startAt: minute(40), endAt: minute(50)))

        let summary = try await harness.eraser.erase(from: minute(10), to: minute(20))
        #expect(summary.sessions == 2)
        #expect(try remaining(harness).count == 2)
    }
}
