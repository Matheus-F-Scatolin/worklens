import Foundation
import GRDB
import Testing

@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
/// The clock every test below runs on: noon on 2026-09-07.
private let today = "2026-09-07"
private let noon = DayBoundaries.range(day: today, timeZone: utc)!.start
    .addingTimeInterval(12 * 3600)

/// A retention pass over an in-memory database and a real temp `DATA_DIR`, so the file half —
/// the JPEGs, the empty day folder, the timeline markdown — is exercised rather than assumed.
private struct Harness {
    let dataDir: URL
    var config: Config
    let db: WorklensCore.Database
    let captures: CaptureStore
    let descriptions: DescriptionStore
    let blocks: ActivityBlockStore
    let sessions: ForegroundSessionStore
    let ledger: LLMCallStore

    init(days: Int, keepReports: Bool = true) throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        for folder in ["timeline", "reports"] {
            try FileManager.default.createDirectory(
                at: dataDir.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }

        var config = Config.defaults()
        config.dataDir = dataDir
        config.retentionDays = days
        config.retentionKeepReports = keepReports
        self.config = config

        db = try WorklensCore.Database.inMemory()
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        blocks = ActivityBlockStore(db)
        sessions = ForegroundSessionStore(db)
        ledger = LLMCallStore(db)
    }

    var retention: Retention {
        Retention(config: config, db: db, timeZone: utc, now: { noon })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }

    /// One described frame with a real JPEG-shaped file on disk, at an instant.
    @discardableResult
    func addFrame(at: Date, withImage: Bool = true) throws -> Capture {
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
            appKey: "slack", taskKey: "reading_messages", summaryMd: "Reading #general.",
            createdAt: at
        ))
        return capture
    }

    /// A frame at noon on a local day.
    @discardableResult
    func addFrame(day: String, hour: Double = 12) throws -> Capture {
        let start = DayBoundaries.range(day: day, timeZone: utc)!.start
        return try addFrame(at: start.addingTimeInterval(hour * 3600))
    }

    /// The derived record for a day: a block, a friction row, a timeline file, and a daily
    /// report with a file beside it as a build from before the reports were cut (2026-10-05)
    /// left it.
    func addDerivedRecord(day: String) throws {
        let start = DayBoundaries.range(day: day, timeZone: utc)!.start
        try blocks.upsert(ActivityBlock(
            day: day, startAt: start.addingTimeInterval(9 * 3600),
            endAt: start.addingTimeInterval(10 * 3600),
            appKey: "slack", taskKey: "reading_messages"
        ))
        try insertFriction(day: day)
        try Data("# \(day)\n".utf8).write(to: timelineURL(day: day))
        let reportPath = "reports/\(day).md"
        try Data("# Your day\n".utf8).write(to: dataDir.appendingPathComponent(reportPath))
        try insertReport(Report(
            kind: .daily, periodStart: day, periodEnd: day, provider: "anthropic",
            model: "claude-opus-5", contentMd: "# Your day", filePath: reportPath
        ))
    }

    /// A `friction_items` row as a build from before #299 left it. Raw SQL: the ledger that
    /// wrote these is gone, the table is not.
    func insertFriction(day: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO friction_items (id, day, slug, kind, title, created_at)
                    VALUES (?, ?, 'slack-scrollback', 'repetition', 'Hunting for a link in Slack', ?)
                    """,
                arguments: [UUID().uuidString, day, Date()]
            )
        }
    }

    func frictionCount(day: String) throws -> Int {
        try db.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM friction_items WHERE day = ?", arguments: [day]
            ) ?? 0
        }
    }

    func insertReport(_ report: Report) throws {
        try db.writer.write { try report.insert($0) }
    }

    /// Whether the `reports` table still holds a row for that period.
    func hasReport(_ kind: ReportKind, _ periodStart: String) throws -> Bool {
        try db.writer.read { db in
            try Report
                .filter(Column("kind") == kind.rawValue)
                .filter(Column("period_start") == periodStart)
                .fetchCount(db) > 0
        }
    }

    func timelineURL(day: String) -> URL {
        dataDir.appendingPathComponent("timeline").appendingPathComponent("\(day).md")
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dataDir.appendingPathComponent(relative).path)
    }

    func imageExists(_ capture: Capture) -> Bool {
        guard let path = capture.imagePath else { return false }
        return exists(path)
    }
}

@Suite("Retention (#144)")
struct RetentionTests {
    // MARK: The boundary, without a database

    @Test("RETENTION_DAYS=0 keeps everything, and says so by having no cutoff")
    func zeroKeepsEverything() {
        #expect(Retention.oldestKeptDay(days: 0, today: noon, timeZone: utc) == nil)
        #expect(Retention.oldestKeptDay(days: -7, today: noon, timeZone: utc) == nil)
    }

    @Test("counting includes today, so 30 days keeps the 30th day back")
    func countingIncludesToday() {
        #expect(Retention.oldestKeptDay(days: 30, today: noon, timeZone: utc) == "2026-08-09")
        #expect(Retention.oldestKeptDay(days: 7, today: noon, timeZone: utc) == "2026-09-01")
    }

    @Test("today and yesterday survive any number, as they do a disk sweep")
    func todayAndYesterdayAreProtected() {
        #expect(Retention.oldestKeptDay(days: 1, today: noon, timeZone: utc) == "2026-09-06")
        #expect(Retention.oldestKeptDay(days: 2, today: noon, timeZone: utc) == "2026-09-06")
        #expect(Retention.oldestKeptDay(days: 3, today: noon, timeZone: utc) == "2026-09-05")
    }

    // MARK: What a pass deletes

    @Test("nothing is deleted at the default of 0")
    func defaultDeletesNothing() throws {
        let harness = try Harness(days: 0)
        defer { harness.cleanUp() }
        let ancient = try harness.addFrame(day: "2024-01-01")

        let sweep = try harness.retention.sweep()

        #expect(sweep == RetentionSweep())
        #expect(!sweep.didAnything)
        #expect(try harness.captures.fetch(id: ancient.id) != nil)
        #expect(harness.imageExists(ancient))
    }

    @Test("the boundary is exact: the last kept day stays, the day before it goes")
    func boundaryIsExact() throws {
        let harness = try Harness(days: 30)
        defer { harness.cleanUp() }
        // 2026-08-09 is the oldest day 30 days back from 2026-09-07 keeps.
        let keptStart = DayBoundaries.range(day: "2026-08-09", timeZone: utc)!.start
        let firstKept = try harness.addFrame(at: keptStart)
        let lastCondemned = try harness.addFrame(at: keptStart.addingTimeInterval(-1))
        let ancient = try harness.addFrame(day: "2026-01-02")

        let sweep = try harness.retention.sweep()

        #expect(sweep.oldestKeptDay == "2026-08-09")
        #expect(sweep.frames == 2)
        #expect(sweep.images == 2)
        #expect(sweep.days == ["2026-01-02", "2026-08-08"])
        #expect(try harness.captures.fetch(id: firstKept.id) != nil)
        #expect(try harness.captures.fetch(id: lastCondemned.id) == nil)
        #expect(try harness.captures.fetch(id: ancient.id) == nil)
        #expect(harness.imageExists(firstKept))
        #expect(!harness.imageExists(lastCondemned))
        // The descriptions went by cascade, the same way the eraser's do.
        #expect(try harness.descriptions.fetch(captureId: lastCondemned.id) == nil)
        #expect(try harness.descriptions.fetch(captureId: firstKept.id) != nil)
        // And the day folder those JPEGs lived in is not left behind empty.
        #expect(!harness.exists("screenshots/2026-08-08"))
        #expect(harness.exists("screenshots/2026-08-09"))
    }

    @Test("a pass that would take everything still never touches today or yesterday")
    func aPassNeverTakesTodayOrYesterday() throws {
        let harness = try Harness(days: 1)
        defer { harness.cleanUp() }
        let todayFrame = try harness.addFrame(day: today, hour: 9)
        let yesterday = try harness.addFrame(day: "2026-09-06", hour: 9)
        let theDayBefore = try harness.addFrame(day: "2026-09-05", hour: 9)

        let sweep = try harness.retention.sweep()

        #expect(sweep.frames == 1)
        #expect(sweep.days == ["2026-09-05"])
        #expect(try harness.captures.fetch(id: todayFrame.id) != nil)
        #expect(try harness.captures.fetch(id: yesterday.id) != nil)
        #expect(try harness.captures.fetch(id: theDayBefore.id) == nil)
    }

    @Test("foreground sessions age out with the frames, and one straddling the cutoff is trimmed")
    func sessionsAgeOut() throws {
        let harness = try Harness(days: 30)
        defer { harness.cleanUp() }
        let cutoff = DayBoundaries.range(day: "2026-08-09", timeZone: utc)!.start
        try harness.sessions.insert(ForegroundSession(
            startAt: cutoff.addingTimeInterval(-7200), endAt: cutoff.addingTimeInterval(-3600),
            appBundleId: "com.tinyspeck.slackmacgap", appName: "Slack"
        ))
        try harness.sessions.insert(ForegroundSession(
            startAt: cutoff.addingTimeInterval(-1800), endAt: cutoff.addingTimeInterval(1800),
            appBundleId: "com.apple.Safari", appName: "Safari"
        ))

        let sweep = try harness.retention.sweep()

        #expect(sweep.sessions == 2)
        let left = try harness.sessions.fetch(
            overlapping: Date.distantPast, to: cutoff.addingTimeInterval(7200)
        )
        #expect(left.count == 1)
        #expect(left[0].appName == "Safari")
        // Trimmed to the part on the near side of the cutoff, not deleted outright.
        #expect(left[0].startAt >= cutoff.addingTimeInterval(-0.01))
    }

    // MARK: What a pass leaves standing

    @Test("the timeline, the reports, the blocks, the friction and the spend survive by default")
    func derivedRecordSurvives() throws {
        let harness = try Harness(days: 30)
        defer { harness.cleanUp() }
        try harness.addFrame(day: "2026-08-08")
        try harness.addDerivedRecord(day: "2026-08-08")
        try harness.ledger.insert(LLMCall(
            provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
            promptTokens: 400, outputTokens: 20, costUsd: 0.0002,
            createdAt: DayBoundaries.range(day: "2026-08-08", timeZone: utc)!.start
        ))

        let sweep = try harness.retention.sweep()

        #expect(sweep.frames == 1)
        #expect(sweep.blocks == 0)
        #expect(sweep.friction == 0)
        #expect(sweep.timelines == 0)
        // The markdown that is already written is the surviving record of that day: a pass
        // must not rebuild it from the frames it has just deleted.
        #expect(harness.exists("timeline/2026-08-08.md"))
        #expect(harness.exists("reports/2026-08-08.md"))
        #expect(try harness.hasReport(.daily, "2026-08-08"))
        #expect(try harness.blocks.fetch(day: "2026-08-08").count == 1)
        #expect(try harness.frictionCount(day: "2026-08-08") == 1)
        // Money that was really spent stays spent, exactly as in DataEraser.
        let spend = try harness.db.writer.read { try LLMCall.fetchAll($0) }
        #expect(spend.count == 1)
    }

    @Test("a pass never claims the user deleted anything")
    func passLeavesLastEraseAlone() throws {
        let harness = try Harness(days: 30)
        defer { harness.cleanUp() }
        try harness.addFrame(day: "2026-08-08")

        _ = try harness.retention.sweep()

        let eraser = DataEraser(config: harness.config, db: harness.db, timeZone: utc)
        #expect(try eraser.lastErase() == nil)
    }

    // MARK: RETENTION_KEEP_REPORTS=false

    @Test("with RETENTION_KEEP_REPORTS off the derived record for those days goes, and old reports stay")
    func keepReportsOffDropsTheDerivedRecord() throws {
        let harness = try Harness(days: 30, keepReports: false)
        defer { harness.cleanUp() }
        try harness.addFrame(day: "2026-08-08")
        try harness.addDerivedRecord(day: "2026-08-08")
        try harness.addFrame(day: "2026-08-09")
        try harness.addDerivedRecord(day: "2026-08-09")
        // A weekly report over the week the aged-out day belongs to.
        try harness.insertReport(Report(
            kind: .weekly, periodStart: "2026-08-03", periodEnd: "2026-08-09",
            provider: "anthropic", model: "claude-opus-5", contentMd: "# Your week"
        ))

        let sweep = try harness.retention.sweep()

        #expect(sweep.days == ["2026-08-08"])
        #expect(sweep.blocks == 1)
        #expect(sweep.friction == 1)
        #expect(sweep.timelines == 1)
        #expect(!harness.exists("timeline/2026-08-08.md"))
        #expect(try harness.blocks.fetch(day: "2026-08-08").isEmpty)
        #expect(try harness.frictionCount(day: "2026-08-08") == 0)
        // The kept day keeps all of it.
        #expect(harness.exists("timeline/2026-08-09.md"))
        // Reports are no longer written, and the ones already written are never deleted: no
        // row and no file, daily or weekly (2026-10-05).
        #expect(harness.exists("reports/2026-08-08.md"))
        #expect(try harness.hasReport(.daily, "2026-08-08"))
        #expect(try harness.hasReport(.weekly, "2026-08-03"))
    }

    // MARK: The configuration

    @Test("a negative RETENTION_DAYS is refused at load, by name")
    func negativeDaysAreRefused() {
        #expect(throws: ConfigError.self) {
            try Config.load(environment: ["RETENTION_DAYS": "-1"], cwd: URL(filePath: "/tmp"))
        }
        #expect(throws: ConfigError.self) {
            try Config.load(environment: ["RETENTION_DAYS": "ninety"], cwd: URL(filePath: "/tmp"))
        }
    }

    @Test("both keys default to keeping everything, which is what Worklens did before #144")
    func defaultsKeepEverything() {
        let config = Config.defaults()
        #expect(config.retentionDays == 0)
        #expect(config.retentionKeepReports)
    }
}
