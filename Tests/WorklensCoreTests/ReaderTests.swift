import Foundation
import GRDB
import Testing
@testable import WorklensCore

/// The reader's model half (#134): the day index the sidebar is built from, the titles it
/// derives, and when an open page is rebuilt.
///
/// Days come from `DayBoundaries` in the machine's own timezone, exactly as the stores derive
/// them, so nothing here hard-codes a day string.
private let nine = DayBoundaries.range(day: "2026-09-09", timeZone: .current)!
    .start.addingTimeInterval(9 * 3600)
private var tuesday: String { DayBoundaries.dayString(nine) }
private var wednesday: String { DayBoundaries.dayString(nine.addingTimeInterval(24 * 3600)) }

private struct Harness {
    // Qualified: this file reads GRDB rows too (#244's query-plan assertion), and both modules
    // spell a type `Database`.
    let db: WorklensCore.Database

    init() throws { db = try WorklensCore.Database.inMemory() }

    func capture(_ at: Date, idle: Bool = false, described: Bool = true) throws {
        try CaptureStore(db).insert(Capture(
            capturedAt: at,
            appBundleId: "com.microsoft.VSCode",
            appName: "Code",
            windowTitle: "DayIndex.swift",
            isIdle: idle,
            describeStatus: described ? .described : .pending
        ))
    }

    func block(
        _ day: String,
        from: Date,
        minutes: Double,
        appKey: String = "code_editor",
        taskKey: String = "writing_code",
        source: ActivitySource = .screen
    ) throws {
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: day,
            startAt: from,
            endAt: from.addingTimeInterval(minutes * 60),
            appKey: appKey, taskKey: taskKey, title: "DayIndex.swift",
            captureCount: 4, source: source, createdAt: from, updatedAt: from
        ))
    }

    /// A row of the `reports` table, as a build from before the reports were cut (2026-10-05)
    /// wrote it. The table stays, and its headlines are still read.
    func report(kind: ReportKind, start: String, end: String, headline: String? = nil) throws {
        let report = Report(
            kind: kind, periodStart: start, periodEnd: end,
            provider: "anthropic", model: "claude-opus-5",
            contentMd: "---\nkind: \(kind.rawValue)\nmodel: claude-opus-5\n---\n\n## Your day\n\nYou wrote code.",
            headline: headline
        )
        try db.writer.write { try report.insert($0) }
    }
}

@Suite("DayIndex")
struct DayIndexTests {
    @Test("the MCP `days` answer is the day's counts and its sentence")
    func mcpShape() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.capture(nine.addingTimeInterval(60), described: false)

        let days = try MCPDayIndex(harness.db).days(limit: 10)
        #expect(days == [MCPDay(day: tuesday, frames: 2, described: 1)])

        // The Codable shape MCP serialises: the three counting keys plus #249's sentence, which
        // is an empty string on a day that has nothing to say.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(days[0]), as: UTF8.self)
        #expect(json == "{\"day\":\"\(tuesday)\",\"described\":1,\"frames\":2,"
            + "\"headline\":\"\"}")
    }

    @Test("entries carry the facts the reader needs and MCP never sees")
    func entries() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.capture(nine.addingTimeInterval(60))
        try harness.capture(nine.addingTimeInterval(120), idle: true)
        try harness.block(tuesday, from: nine, minutes: 90)

        let entries = try DayIndex(harness.db).entries(limit: 10)
        #expect(entries.count == 1)
        let day = try #require(entries.first)
        #expect(day.frames == 3)
        #expect(day.hasTimeline)
        #expect(day.activeMinutes == 90)
        // #249: the day's sentence is what its own blocks say about it.
        #expect(day.mcpDay == MCPDay(
            day: tuesday, frames: 3, described: 3,
            headline: "Mostly Code editor, 1h 30m on screen"
        ))
    }

    @Test("active minutes are the day's own active minutes, idle and meetings included")
    func activeMinutesAgreeWithTheStatsTab() throws {
        let harness = try Harness()
        try harness.capture(nine)
        // Four hours at the screen, an idle stretch after it, and a calendar meeting laid on top
        // of the screen blocks it contains — #19 keeps both rows, so the sum of the table is
        // neither the active time nor even a possible one.
        try harness.block(tuesday, from: nine, minutes: 240)
        try harness.block(
            tuesday, from: nine.addingTimeInterval(4 * 3600), minutes: 300,
            appKey: BlockBuilder.idleKey, taskKey: BlockBuilder.idleKey
        )
        try harness.block(
            tuesday, from: nine.addingTimeInterval(3600), minutes: 60,
            appKey: "zoom", taskKey: StatsAggregator.meetingTaskKey, source: .calendar
        )
        // And an hour the calendar says you were away from the machine (#94).
        try harness.block(
            tuesday, from: nine.addingTimeInterval(10 * 3600), minutes: 60,
            appKey: StatsAggregator.awayAppKey, taskKey: StatsAggregator.awayAppKey,
            source: .calendar
        )

        let entry = try #require(try DayIndex(harness.db).entries(limit: 10).first)
        #expect(entry.hasTimeline)
        #expect(entry.activeMinutes == 240)
        // The number the same window's Stats tab prints. Two surfaces, one day, one answer.
        #expect(entry.activeMinutes == (try StatsService(harness.db).daily(day: tuesday)).activeMinutes)
    }

    @Test("today's sidebar and Stats leave out the meetings not held yet")
    func upcomingMeetingsAreNotCountedYet() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.block(tuesday, from: nine, minutes: 120)
        try harness.block(
            tuesday, from: nine.addingTimeInterval(3600), minutes: 60,
            appKey: "zoom", taskKey: StatsAggregator.meetingTaskKey, source: .calendar
        )
        // Written by the calendar sync at 09:00, five hours before it happens.
        try harness.block(
            tuesday, from: nine.addingTimeInterval(5 * 3600), minutes: 60,
            appKey: "zoom", taskKey: StatsAggregator.meetingTaskKey, source: .calendar
        )
        let now = nine.addingTimeInterval(2 * 3600)

        let entry = try #require(try DayIndex(harness.db, now: { now }).entries(limit: 10).first)
        let stats = try StatsService(harness.db, now: { now }).daily(day: tuesday)
        #expect(entry.activeMinutes == 120)
        #expect(stats.activeMinutes == 120)
        #expect(stats.meetingMinutes == 60)
    }

    @Test("a day that was only ever idle still has a timeline, and no active minutes")
    func idleOnlyDay() throws {
        let harness = try Harness()
        try harness.capture(nine, idle: true)
        try harness.block(
            tuesday, from: nine, minutes: 45,
            appKey: BlockBuilder.idleKey, taskKey: BlockBuilder.idleKey
        )
        let day = try #require(try DayIndex(harness.db).entries(limit: 10).first)
        #expect(day.hasTimeline)
        #expect(day.activeMinutes == 0)
    }

    @Test("a day with frames but no blocks has no timeline to show")
    func noBlocks() throws {
        let harness = try Harness()
        try harness.capture(nine)
        let day = try #require(try DayIndex(harness.db).entries(limit: 10).first)
        #expect(!day.hasTimeline)
        #expect(day.activeMinutes == 0)
    }
}

@Suite("ReaderIndex")
struct ReaderIndexTests {
    @Test("days group under their ISO week, newest first")
    func grouping() throws {
        let week = try #require(ISOWeek.containing(dayString: tuesday))
        let entries = [
            DayIndexEntry(day: tuesday, frames: 40, described: 40,
                          hasTimeline: true, activeMinutes: 125),
            DayIndexEntry(day: wednesday, frames: 10, described: 4),
        ]
        let weeks = ReaderIndex.weeks(entries: entries)
        #expect(weeks.count == 1)
        let first = try #require(weeks.first)
        #expect(first.monday == week.start)
        #expect(first.identifier == week.identifier)
        // Newest first inside the week.
        #expect(first.days.map(\.day) == [wednesday, tuesday])
        #expect(first.days[1].subtitle == "2h 05m · 40 screenshots")
        #expect(first.days[0].subtitle == "10 screenshots")
    }

    @Test("a subtitle states facts and never compares two days")
    func subtitleIsNeverAVerdict() {
        let entry = DayIndexEntry(day: tuesday, frames: 1, described: 1,
                                  hasTimeline: true, activeMinutes: 3)
        let subtitle = ReaderIndex.subtitle(entry)
        #expect(subtitle == "3m · 1 screenshot")
        for banned in ["better", "worse", "score", "than", "%"] {
            #expect(!subtitle.contains(banned))
        }
    }
}

@Suite("DayTitle")
struct DayTitleTests {
    private let english = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    @Test("a day's title names the weekday, and a week's names both ends")
    func titles() {
        // The date itself is localized — `setLocalizedDateFormatFromTemplate` puts the comma and
        // the day/month order where the reader's own locale wants them — so the assertions are on
        // the words Worklens chose and the day it named, not on en_GB's punctuation.
        let day = DayTitle.of(kind: .daily, periodStart: "2026-09-08", periodEnd: "2026-09-08",
                              timeZone: utc, locale: english)
        #expect(day.hasPrefix("Your day: "))
        #expect(day.contains("Tuesday"))
        #expect(day.contains("8 September 2026"))

        let week = DayTitle.of(kind: .weekly, periodStart: "2026-08-31",
                               periodEnd: "2026-09-06", timeZone: utc, locale: english)
        #expect(week == "Your week: 31 August 2026 to 6 September 2026")
    }

    @Test("a title nothing can be parsed from is still the day it was given")
    func unparsable() {
        #expect(DayTitle.longDay("not-a-day") == "not-a-day")
    }
}

// MARK: - Reaching the whole history (#244)

/// A day `back` days before the fixture Tuesday, at nine in the morning.
private func daysBack(_ back: Int) -> Date {
    nine.addingTimeInterval(-Double(back) * 86_400)
}

@Suite("DayIndex windows (#244)")
struct DayIndexWindowTests {
    @Test("the unbounded call answers what it always did, and a window narrows it")
    func windowNarrows() throws {
        let harness = try Harness()
        for back in [0, 1, 40, 100] { try harness.capture(daysBack(back)) }
        let index = DayIndex(harness.db)

        let all = try index.entries(limit: 200)
        #expect(all.count == 4)
        // A window wide enough to hold every day is the unbounded answer, row for row — which is
        // what keeps the MCP `days` tool's frozen shape frozen.
        let oldest = try #require(all.last?.day)
        #expect(try index.entries(limit: 200, after: oldest) == all)

        let recent = try index.entries(limit: 200, after: DayBoundaries.dayString(daysBack(1)))
        #expect(recent.map(\.day) == all.prefix(2).map(\.day))
        let middle = try index.entries(
            limit: 200,
            after: DayBoundaries.dayString(daysBack(100)),
            before: DayBoundaries.dayString(daysBack(40))
        )
        #expect(middle.map(\.day) == [
            DayBoundaries.dayString(daysBack(40)), DayBoundaries.dayString(daysBack(100)),
        ])
    }

    @Test("a bounded read is served by the index; the unbounded one groups the whole table")
    func boundedIsNotAWholeTableGroup() throws {
        let harness = try Harness()
        for back in 0..<20 { try harness.capture(daysBack(back)) }

        // The shape `DayIndex.entries` runs, planned both ways. The `LIMIT` is applied after the
        // grouping and bounds nothing; the `WHERE` on `captured_at` is what SQLite can serve from
        // `idx_captures_captured_at`.
        func plan(_ clause: String, _ arguments: StatementArguments) throws -> String {
            let sql = """
                EXPLAIN QUERY PLAN
                SELECT date(captured_at, 'localtime') AS day,
                       COUNT(*) AS frames,
                       SUM(CASE WHEN describe_status IN (?, ?) THEN 1 ELSE 0 END) AS described,
                       SUM(CASE WHEN is_idle = 0 THEN 1 ELSE 0 END) AS active
                FROM captures
                WHERE \(clause)
                GROUP BY day
                ORDER BY day DESC
                LIMIT 60
                """
            var values: StatementArguments = [
                DescribeStatus.described.rawValue, DescribeStatus.inherited.rawValue,
            ]
            values.append(contentsOf: arguments)
            return try harness.db.writer.read { db in
                try Row.fetchAll(db, sql: sql, arguments: values)
            }
            .map { ($0["detail"] as String?) ?? "" }
            .joined(separator: " | ")
        }

        // The window is a range seek on the index…
        let bounded = try plan("captured_at >= ?", [daysBack(5)])
        #expect(bounded.contains("SEARCH captures USING INDEX idx_captures_captured_at"))
        // …and without it SQLite reads every row there has ever been, whatever the LIMIT says.
        let whole = try plan("1", [])
        #expect(whole.contains("SCAN captures"))
        #expect(!whole.contains("SEARCH captures"))
    }

    @Test("the recorded days in a window are counted without their facts")
    func recordedDays() throws {
        let harness = try Harness()
        for back in [0, 3, 70] { try harness.capture(daysBack(back)) }
        let index = DayIndex(harness.db)

        let window = try index.recordedDays(
            limit: 60, after: DayBoundaries.dayString(daysBack(10))
        )
        #expect(window == [
            DayBoundaries.dayString(daysBack(0)), DayBoundaries.dayString(daysBack(3)),
        ])
        #expect(try index.oldestDay() == DayBoundaries.dayString(daysBack(70)))
        #expect(try index.newestDay() == DayBoundaries.dayString(daysBack(0)))
    }

    @Test("an empty database has no ends to reach")
    func noDays() throws {
        let harness = try Harness()
        #expect(try DayIndex(harness.db).oldestDay() == nil)
        #expect(try DayIndex(harness.db).newestDay() == nil)
        #expect(try DayIndex(harness.db).recordedDays(limit: 60).isEmpty)
    }
}

@Suite("ReaderPaging (#244)")
struct ReaderPagingTests {
    @Test("a page is 60 days, and the page behind it starts where that one ends")
    func windows() {
        let first = ReaderPaging.firstWindow(newest: "2026-09-09")
        #expect(first.after == "2026-07-12")
        // No upper bound: a day recorded while the window is open belongs to the first page too.
        #expect(first.before == nil)

        let next = ReaderPaging.previousWindow(loadedFrom: "2026-07-12")
        #expect(next.before == "2026-07-11")
        #expect(next.after == "2026-05-13")
        // The two windows touch, and never overlap.
        #expect(ReaderPaging.day(next.before, offsetBy: 1) == first.after)
    }

    /// The first page's window has no upper bound, so it widens as days are recorded. The row
    /// limit is sized from the window, never from the page count, or the newest days would push
    /// the oldest days of the window out of a list that still says it covers them.
    @Test("a window that has outgrown its page still counts every day in it")
    func theLimitCoversTheWholeWindow() {
        #expect(ReaderPaging.dayCount(from: "2026-07-12", to: "2026-09-09") == 60)
        #expect(ReaderPaging.dayCount(from: "2026-09-09", to: "2026-09-09") == 1)
        // The window a page-one load opened, read after another 40 days of recording.
        #expect(ReaderPaging.dayCount(from: "2026-07-12", to: "2026-10-19") > ReaderPaging.pageDays)
        // A window running backwards is no window at all, not a negative limit.
        #expect(ReaderPaging.dayCount(from: "2026-09-09", to: "2026-07-12") == 0)
    }
}

@Suite("ReaderTick (#244)")
struct ReaderTickTests {
    private let today = "2026-09-18"

    @Test("the minute refresh rebuilds today and refreshes the day list")
    func minuteRefreshRebuildsToday() {
        // What `AppModel` asks once a minute while a reader page is open: nothing was written,
        // but today's counts move.
        let decision = ReaderTick.decide(open: .day(today), today: today)
        #expect(decision.rebuildDocument)
        #expect(decision.refreshIndex)
    }

    @Test("the minute refresh leaves an earlier day alone, and still refreshes the list")
    func minuteRefreshLeavesAnEarlierDay() {
        let decision = ReaderTick.decide(open: .day("2026-09-10"), today: today)
        #expect(!decision.rebuildDocument)
        // Today is one of the loaded rows, and its screenshot count moved.
        #expect(decision.refreshIndex)
    }

    @Test("the week holding today is rebuilt, and an earlier week is not")
    func minuteRefreshWeeks() throws {
        let thisWeek = try #require(ISOWeek.containing(dayString: today, timeZone: .current))
        #expect(ReaderTick.decide(open: .week(thisWeek.start), today: today)
            .rebuildDocument)
        #expect(!ReaderTick.decide(open: .week("2026-08-31"), today: today)
            .rebuildDocument)
    }

    @Test("nothing open, and today outside the loaded pages: nothing to do")
    func nothingToDo() {
        let nothing = ReaderTick.decide(
            open: nil, today: today, indexCoversToday: false
        )
        #expect(nothing == .nothing)
    }
}

// MARK: - The day's sentence (#249)

@Suite("DayHeadline")
struct DayHeadlineTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_GB")

    @Test("a report's lede becomes one line, and an unusable one becomes nothing")
    func fromReport() {
        let report = """
            ---
            kind: daily
            model: claude-opus-5
            ---

            # Your day

            You spent the morning on the loan tape and then answered mail. Then back to the tape.

            ## What you did
            """
        #expect(DayHeadline.fromReport(report)
            == "You spent the morning on the loan tape and then answered mail.")

        // A report that is only headings, only a bullet, or nothing at all stores no sentence.
        #expect(DayHeadline.fromReport("---\nkind: daily\n---\n\n# Your day\n\n## Sections") == nil)
        #expect(DayHeadline.fromReport("") == nil)
        #expect(DayHeadline.fromReport("- a bullet is not a lede") == nil)

        // A decimal or a file name carries a dot that ends no sentence.
        #expect(DayHeadline.fromReport("You spent 2.5 h on the loan tape in Preview.app today.")
            == "You spent 2.5 h on the loan tape in Preview.app today.")

        // A hard-wrapped lede is one paragraph, not two rows.
        #expect(DayHeadline.fromReport("You spent the morning on the loan\ntape and then mail.")
            == "You spent the morning on the loan tape and then mail.")

        // A bolded lede is the lede, not a bullet — the next section must not answer for it.
        #expect(DayHeadline.fromReport("**You spent the morning on the tape.**\n\n## What you did")
            == "You spent the morning on the tape.")
    }

    @Test("the stats sentence names apps the way the timeline names them")
    func statsHeadlineUsesTaxonomyNames() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.block(tuesday, from: nine, minutes: 90, appKey: "gcal")
        let labels = TimelineLabels(apps: ["gcal": "Web browser / Google Calendar"])

        let entry = try #require(
            try DayIndex(harness.db).entries(limit: 10, labels: labels).first)
        #expect(entry.headline == "Mostly Web browser / Google Calendar, 1h 30m on screen")
        // With no taxonomy to hand, the key still reads as words rather than a key.
        let bare = try #require(try DayIndex(harness.db).entries(limit: 10).first)
        #expect(bare.headline == "Mostly Gcal, 1h 30m on screen")
    }

    @Test("a long lede is cut at a word boundary, on one line")
    func truncation() throws {
        let long = String(repeating: "worklens ", count: 30) + "end."
        let headline = try #require(DayHeadline.fromReport(long))
        #expect(headline.count <= DayHeadline.textLimit + 1)
        #expect(headline.hasSuffix("…"))
        #expect(!headline.contains("\n"))
    }

    @Test("a day with no report says what its own apps and minutes say")
    func fromStats() throws {
        #expect(DayHeadline.fromStats(names: ["Code editor", "Email"], activeMinutes: 220)
            == "Mostly Code editor and Email, 3h 40m on screen")
        #expect(DayHeadline.fromStats(names: ["Code editor"], activeMinutes: 48)
            == "Mostly Code editor, 48m on screen")
        #expect(DayHeadline.fromStats(names: [], activeMinutes: 48) == "48m on screen")
        // Nothing to state, so nothing is stated.
        #expect(DayHeadline.fromStats(names: ["Code editor"], activeMinutes: 0) == nil)
        // Facts, never a verdict.
        let sentence = try #require(
            DayHeadline.fromStats(names: ["Code editor"], activeMinutes: 220))
        for banned in ["better", "worse", "score", "than", "%"] {
            #expect(!sentence.contains(banned))
        }
    }

    @Test("a report row written before the migration falls back rather than emptying the row")
    func nullHeadlineFallsBack() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.block(tuesday, from: nine, minutes: 90)
        // `headline` left nil is exactly the NULL every row written before #249 carries.
        try harness.report(kind: .daily, start: tuesday, end: tuesday)

        let entry = try #require(try DayIndex(harness.db).entries(limit: 10).first)
        #expect(entry.headline == "Mostly Code editor, 1h 30m on screen")
        let subtitle = ReaderIndex.subtitle(entry)
        #expect(subtitle == "1h 30m · 1 screenshot · Mostly Code editor, 1h 30m on screen")
    }

    @Test("a stored headline wins over the day's stats, and reaches the subtitle")
    func storedHeadlineWins() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.block(tuesday, from: nine, minutes: 90)
        try harness.report(
            kind: .daily, start: tuesday, end: tuesday, headline: "You rewrote the day index.")

        let entry = try #require(try DayIndex(harness.db).entries(limit: 10).first)
        #expect(entry.headline == "You rewrote the day index.")
        #expect(ReaderIndex.subtitle(entry).hasSuffix("· You rewrote the day index."))
        #expect(entry.mcpDay.headline == "You rewrote the day index.")
    }

    @Test("the `days` tool prints the day's sentence")
    func daysTool() throws {
        let harness = try Harness()
        try harness.capture(nine)
        try harness.block(tuesday, from: nine, minutes: 90)
        try harness.report(
            kind: .daily, start: tuesday, end: tuesday, headline: "You rewrote the day | index.")

        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-days-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let table = try WorklensMCPTools.daysTool(
            db: harness.db, taxonomy: TaxonomyStore(dataDir: dataDir)
        ).handler(.object([:]))
        #expect(table.contains("| day | frames | described | headline |"))
        // A pipe inside the sentence would split the row into two cells.
        #expect(table.contains("| \(tuesday) | 1 | 1 | You rewrote the day / index. |"))
    }
}
