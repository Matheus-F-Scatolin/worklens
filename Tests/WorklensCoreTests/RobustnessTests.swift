import Foundation
import GRDB
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!

// MARK: - Log redaction

@Suite("Log redaction")
struct LogRedactionTests {
    /// The rule from `CLAUDE.md`: nothing above `.debug` may carry a window title, a URL or a
    /// summary. `redactForLog` is how a call site keeps the shape without the content.
    @Test("a URL keeps only its host")
    func urlsLoseEverythingButTheHost() {
        #expect(Log.redactForLog("https://mail.google.com/mail/u/0/#inbox/FMfcgz") == "mail.google.com/…")
        #expect(Log.redactForLog("https://bank.example.com/accounts/1234567890") == "bank.example.com/…")
        // Query strings are where the interesting leaks live, and they go with the path.
        #expect(Log.redactForLog("https://example.com/search?q=divorce+lawyer") == "example.com/…")
    }

    @Test("long text is truncated and its length reported instead")
    func longTextIsTruncated() {
        let title = "Re: Q3 compensation review for Dana — final numbers before Friday"
        let redacted = Log.redactForLog(title)
        #expect(redacted.count < title.count)
        #expect(redacted.hasSuffix("(\(title.count) chars)"))
        #expect(redacted.hasPrefix("Re: Q3 compensation revi"))
        #expect(!redacted.contains("Dana"))
    }

    @Test("something short and harmless survives intact")
    func shortTextSurvives() {
        #expect(Log.redactForLog("Slack") == "Slack")
        #expect(Log.redactForLog("#general") == "#general")
        #expect(Log.redactForLog(nil) == "(none)")
        #expect(Log.redactForLog("") == "(none)")
    }

    @Test("a secret is masked to its prefix, never printed")
    func secretsAreMasked() {
        let key = "sk-ant-api03-notarealkeybutlongenough"
        let masked = Log.redactSecret(key)
        #expect(!masked.contains("notarealkey"))
        #expect(masked == "sk-ant-****")
        #expect(Log.redactSecret(nil) == "(unset)")
    }
}

// MARK: - Log rotation

@Suite("FileLog rotation")
struct FileLogRotationTests {
    @Test("files older than the retention window are the ones pruned")
    func selectsAgedOutFiles() {
        let names = [
            "worklens-2026-09-07.log",  // today
            "worklens-2026-09-06.log",
            "worklens-2026-08-24.log",  // 14 days back — the boundary, kept
            "worklens-2026-08-23.log",  // 15 days back — gone
            "worklens-2026-01-01.log",
        ]
        let pruned = FileLog.logFilesToPrune(
            names: names, today: "2026-09-07", retentionDays: 14, timeZone: utc
        )
        #expect(pruned == ["worklens-2026-01-01.log", "worklens-2026-08-23.log"])
    }

    /// This function deletes files, and a name it cannot parse is not grounds for that.
    @Test("anything that is not a dated Worklens log is left alone")
    func leavesStrangersAlone() {
        let names = [
            "worklens-2026-01-01.log",
            "worklens-nonsense.log",
            "worklens-2026-13-45.log",   // parses as digits, is not a date
            "notes.txt",
            "worklens-2026-01-01.log.gz",
            "README",
        ]
        let pruned = FileLog.logFilesToPrune(
            names: names, today: "2026-09-07", retentionDays: 14, timeZone: utc
        )
        #expect(pruned == ["worklens-2026-01-01.log"])
    }

    @Test("a 15-day-old file is deleted at launch and today's is written to")
    func prunesAndWritesForReal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let today = Date(timeIntervalSince1970: 1_788_000_000)  // 2026-09-07T…
        let todayString = DayBoundaries.dayString(today, timeZone: utc)
        let old = today.addingTimeInterval(-15 * 86_400)
        let oldName = "worklens-\(DayBoundaries.dayString(old, timeZone: utc)).log"
        try Data("ancient\n".utf8).write(to: directory.appendingPathComponent(oldName))

        let log = FileLog(timeZone: utc, now: { today })
        let pruned = log.start(directory: directory)
        #expect(pruned == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(oldName).path))

        log.append(level: .info, category: "capture", message: "capture scheduler started")
        log.stop()

        let file = FileLog.fileURL(day: todayString, in: directory)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("INFO  capture capture scheduler started"))
        // The line's clock is local, so it agrees with the local day in the file's own name.
        #expect(contents.contains(todayString))
    }

    @Test("a line written after midnight lands in the new day's file, not the old one")
    func rollsOverAtMidnight() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        final class Clock: @unchecked Sendable {
            var value: Date
            init(_ start: Date) { value = start }
        }
        let start = DayBoundaries.range(day: "2026-09-07", timeZone: utc)!.start
        let clock = Clock(start.addingTimeInterval(23 * 3600))
        let log = FileLog(timeZone: utc, now: { clock.value })
        _ = log.start(directory: directory)

        log.append(level: .info, category: "ui", message: "before midnight")
        clock.value = start.addingTimeInterval(25 * 3600)
        log.append(level: .info, category: "ui", message: "after midnight")
        log.stop()

        let seventh = try String(
            contentsOf: FileLog.fileURL(day: "2026-09-07", in: directory), encoding: .utf8
        )
        let eighth = try String(
            contentsOf: FileLog.fileURL(day: "2026-09-08", in: directory), encoding: .utf8
        )
        #expect(seventh.contains("before midnight"))
        #expect(!seventh.contains("after midnight"))
        #expect(eighth.contains("after midnight"))
    }

    /// A UTC timestamp inside `worklens-2026-09-07.log` reads as an off-by-one bug every
    /// evening west of Greenwich, so the line carries the local clock and its offset.
    @Test("timestamps are local, with the offset spelled out")
    func timestampsAreLocal() {
        let instant = Date(timeIntervalSince1970: 1_788_000_000)
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let local = FileLog.timestamp(instant, timeZone: saoPaulo)
        #expect(local.hasSuffix("-03:00"))
        #expect(local.hasPrefix(DayBoundaries.dayString(instant, timeZone: saoPaulo)))
        // GMT still renders as Z, which is the same instant said the standard way.
        #expect(FileLog.timestamp(instant, timeZone: utc).hasSuffix("Z"))
    }

    @Test("with no directory set, lines are dropped rather than buffered forever")
    func noDirectoryMeansNoBuffer() {
        let log = FileLog(timeZone: utc, now: { Date() })
        for index in 0..<(FileLog.maxBufferedLines * 3) {
            log.append(level: .info, category: "ui", message: "line \(index)")
        }
        log.flush()  // must not crash, must not write anywhere
    }
}

// MARK: - Disk budget

@Suite("DiskBudget selection")
struct DiskBudgetSelectionTests {
    private func day(_ name: String, _ mib: Int) -> ScreenshotDay {
        ScreenshotDay(day: name, bytes: Int64(mib) * 1024 * 1024, files: mib)
    }

    private let budget100MiB = Int64(100) * 1024 * 1024

    @Test("under budget, nothing is swept")
    func underBudget() {
        let days = [day("2026-09-01", 20), day("2026-09-02", 20)]
        #expect(DiskBudget.daysToSweep(days: days, budgetBytes: budget100MiB, protecting: []).isEmpty)
    }

    @Test("the oldest whole day goes first, and only as many as it takes")
    func oldestFirst() {
        let days = [
            day("2026-09-05", 60), day("2026-09-01", 40),
            day("2026-09-03", 40), day("2026-09-02", 40),
        ]
        let swept = DiskBudget.daysToSweep(days: days, budgetBytes: budget100MiB, protecting: [])
        // 180 MiB total; dropping the 1st and 2nd leaves 100, which is not over budget.
        #expect(swept == ["2026-09-01", "2026-09-02"])
    }

    @Test("today and yesterday are never swept")
    func protectedDaysAreSkipped() {
        let days = [day("2026-09-07", 90), day("2026-09-06", 60), day("2026-09-01", 40)]
        let swept = DiskBudget.daysToSweep(
            days: days, budgetBytes: budget100MiB, protecting: ["2026-09-07", "2026-09-06"]
        )
        #expect(swept == ["2026-09-01"])
    }

    /// A protected day is skipped, not stopped at — a huge today must not shelter every ancient
    /// day behind it.
    @Test("a protected day does not stop the sweep reaching older ones")
    func protectedDayDoesNotBlock() {
        let days = [
            day("2026-09-07", 200),  // protected, and on its own over budget
            day("2026-09-01", 30), day("2026-08-30", 30),
        ]
        let swept = DiskBudget.daysToSweep(
            days: days, budgetBytes: budget100MiB, protecting: ["2026-09-07"]
        )
        #expect(swept == ["2026-08-30", "2026-09-01"])
    }

    @Test("an empty day folder is not worth a sweep entry")
    func emptyFoldersSkipped() {
        let days = [day("2026-09-01", 0), day("2026-09-02", 150)]
        let swept = DiskBudget.daysToSweep(days: days, budgetBytes: budget100MiB, protecting: [])
        #expect(swept == ["2026-09-02"])
    }

    @Test("bytes are named the way a Mac names them")
    func humanBytes() {
        #expect(DiskBudget.humanBytes(0) == "0 bytes")
        #expect(DiskBudget.humanBytes(2048) == "2 KB")
        #expect(DiskBudget.humanBytes(Int64(6) * 1024 * 1024) == "6 MB")
        #expect(DiskBudget.humanBytes(Int64(Double(DiskBudget.bytesPerGiB) * 6.3)) == "6.3 GB")
        #expect(DiskBudget.line(
            used: Int64(Double(DiskBudget.bytesPerGiB) * 6.3),
            budget: DiskBudget.bytesPerGiB * 20
        ) == "6.3 GB of 20.0 GB budget")
    }
}

@Suite("DiskBudget sweep")
struct DiskBudgetSweepTests {
    /// Files on disk plus rows in the database: the sweep has to leave the two agreeing.
    @Test("the oldest day's images go, the rows and descriptions stay")
    func sweepsForReal() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        var config = Config.defaults()
        config.dataDir = dataDir
        // Two 40 KiB days against a 50 KiB budget: the older one has to go. The config key is
        // in GiB, so the test says what it means in bytes and converts.
        config.screenshotDiskBudgetGB = 50.0 * 1024 / Double(DiskBudget.bytesPerGiB)

        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        let descriptions = DescriptionStore(db)
        let now = DayBoundaries.range(day: "2026-09-07", timeZone: utc)!.start
            .addingTimeInterval(12 * 3600)

        var ids: [String: [String]] = [:]
        for (offset, day) in [(4, "2026-09-03"), (0, "2026-09-07")] {
            let at = now.addingTimeInterval(-Double(offset) * 86_400)
            for _ in 0..<4 {
                var capture = Capture(capturedAt: at, describeStatus: .described)
                let url = try ScreenshotPaths.url(
                    for: at, id: capture.id, dataDir: dataDir, timeZone: utc
                )
                try Data(repeating: 0x41, count: 10 * 1024).write(to: url)
                capture.imagePath = ScreenshotPaths.relativePath(
                    for: at, id: capture.id, timeZone: utc
                )
                try captures.insert(capture)
                try descriptions.insert(Description(
                    captureId: capture.id, provider: "gemini", model: "m",
                    appKey: "slack", taskKey: "reading_messages",
                    summaryMd: "Reading #general.", createdAt: at
                ))
                ids[day, default: []].append(capture.id)
            }
        }

        let budget = DiskBudget(config: config, db: db, timeZone: utc, now: { now })
        #expect(budget.measure().map(\.day) == ["2026-09-03", "2026-09-07"])

        let sweep = try budget.sweep()

        #expect(sweep.daysDeleted == ["2026-09-03"])
        #expect(sweep.filesDeleted == 4)
        #expect(sweep.rowsCleared == 4)
        #expect(sweep.bytesAfter < sweep.bytesBefore)
        // The old day's folder is gone from disk…
        #expect(!FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("screenshots/2026-09-03").path
        ))
        // …its rows and descriptions are not, they have simply lost their pixels…
        for id in ids["2026-09-03"] ?? [] {
            #expect(try captures.fetch(id: id) != nil)
            #expect(try captures.fetch(id: id)?.imagePath == nil)
            #expect(try descriptions.fetch(captureId: id) != nil)
        }
        // …and today is untouched.
        for id in ids["2026-09-07"] ?? [] {
            #expect(try captures.fetch(id: id)?.imagePath != nil)
        }
    }

    @Test("a sweep with nothing to do reports so and writes nothing")
    func noOpSweep() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        var config = Config.defaults()
        config.dataDir = dataDir
        config.screenshotDiskBudgetGB = 20

        let budget = DiskBudget(config: config, db: try Database.inMemory(), timeZone: utc)
        let sweep = try budget.sweep()
        #expect(!sweep.didAnything)
        #expect(sweep.freedBytes == 0)
    }

    @Test("today and yesterday are the protected pair, in local time")
    func protectedPair() throws {
        var config = Config.defaults()
        let now = DayBoundaries.range(day: "2026-09-07", timeZone: utc)!.start
        config.dataDir = FileManager.default.temporaryDirectory
        let budget = DiskBudget(
            config: config, db: try Database.inMemory(), timeZone: utc, now: { now }
        )
        #expect(budget.protectedDays() == ["2026-09-07", "2026-09-06"])
    }
}

// MARK: - The instance lock

@Suite("InstanceLock")
struct InstanceLockTests {
    @Test("the first holder gets the lock and a second attempt is refused")
    func exclusive() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let first = try #require(InstanceLock.acquire(dataDir: dataDir))
        #expect(first.isHeld)
        #expect(FileManager.default.fileExists(atPath: first.url.path))

        // Same process, same file: `flock` is per open descriptor, so this is genuinely the
        // same question a second Worklens would ask.
        #expect(InstanceLock.acquire(dataDir: dataDir) == nil)
    }

    @Test("releasing the value releases the lock")
    func releasedOnDeinit() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        do {
            let held = try #require(InstanceLock.acquire(dataDir: dataDir))
            #expect(held.isHeld)
            #expect(InstanceLock.acquire(dataDir: dataDir) == nil)
        }
        let again = try #require(InstanceLock.acquire(dataDir: dataDir))
        #expect(again.isHeld)
    }

    @Test("two data directories are not each other's problem")
    func perDataDirectory() throws {
        let one = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-lock-\(UUID().uuidString)")
        let two = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-lock-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
        }
        let first = try #require(InstanceLock.acquire(dataDir: one))
        let second = try #require(InstanceLock.acquire(dataDir: two))
        #expect(first.isHeld)
        #expect(second.isHeld)
    }
}

// MARK: - Database hygiene

@Suite("Database hygiene")
struct DatabaseHygieneTests {
    /// #18's copy-aside half: a file that cannot be opened must not stop the app from starting,
    /// and must not be deleted either — it is still the only copy of a history.
    @Test("an unusable database is moved aside and replaced, not deleted")
    func corruptDatabaseIsSetAside() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // A file that is emphatically not SQLite, but is where SQLite will look.
        let path = dataDir.appendingPathComponent("worklens.sqlite")
        try Data(repeating: 0xFF, count: 4096).write(to: path)

        let db = try Database(dataDir: dataDir)

        #expect(db.recoveredFrom != nil)
        if case let .replacedCorrupt(movedTo, _)? = db.recoveredFrom {
            #expect(FileManager.default.fileExists(atPath: movedTo))
            #expect(movedTo.contains("worklens.sqlite.corrupt-"))
        } else {
            Issue.record("expected a replacedCorrupt recovery")
        }
        // The replacement is a working, migrated database.
        #expect(try db.integrityCheck() == "ok")
        try CaptureStore(db).insert(Capture(capturedAt: Date()))
        #expect(try CaptureStore(db).countToday() == 1)
    }

    @Test("a healthy database reports no recovery")
    func healthyDatabase() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-healthy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let db = try Database(dataDir: dataDir)
        #expect(db.recoveredFrom == nil)
        try CaptureStore(db).insert(Capture(capturedAt: Date()))

        // Reopening the same directory finds the same rows, and still says nothing was recovered.
        let reopened = try Database(dataDir: dataDir)
        #expect(reopened.recoveredFrom == nil)
        #expect(try CaptureStore(reopened).countToday() == 1)
    }

    @Test("checkpoint and vacuum both run on a real file")
    func checkpointAndVacuum() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-vacuum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let db = try Database(dataDir: dataDir)
        for _ in 0..<200 { try CaptureStore(db).insert(Capture(capturedAt: Date())) }
        #expect(db.fileBytes(dataDir: dataDir) > 0)

        try db.checkpoint()
        try db.vacuum()
        #expect(try db.integrityCheck() == "ok")
        #expect(try CaptureStore(db).countToday() == 200)
    }

    @Test("migration v2 gives llm_calls its pricing_version column")
    func migrationV2() throws {
        let db = try Database.inMemory()
        let columns: [String] = try db.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(llm_calls)").map { $0["name"] }
        }
        #expect(columns.contains("pricing_version"))
    }
}
