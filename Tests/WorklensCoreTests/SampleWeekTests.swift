import Foundation
import Testing
import GRDB
@testable import WorklensCore

/// #349: the sample week. Deterministic, dated from today, written in your voice, and never
/// reachable from Claude.
@Suite("Sample week")
struct SampleWeekTests {
    /// A Wednesday at 15:00 local time, so today is cut mid-afternoon.
    private static var wednesday: Date {
        let day = DayBoundaries.range(day: "2026-10-07", timeZone: .current)!.start
        return day.addingTimeInterval(15 * 3600)
    }

    private static func temporaryDataDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-sample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Determinism and dates

    @Test("the same moment always builds the same week")
    func deterministic() {
        let first = SampleWeek.content(now: Self.wednesday)
        let second = SampleWeek.content(now: Self.wednesday)
        #expect(first == second)
        #expect(!first.blocks.isEmpty)
        #expect(!first.captures.isEmpty)
        #expect(!first.events.isEmpty)
    }

    @Test("nothing on today, meetings included, runs past now")
    func todayStopsAtNow() {
        let start = DayBoundaries.range(day: "2026-10-07", timeZone: .current)!.start
        for quarter in stride(from: 48, through: 80, by: 1) {
            let now = start.addingTimeInterval(TimeInterval(quarter * 15 * 60))
            let content = SampleWeek.content(now: now)
            for event in content.events where event.startAt >= start {
                #expect((event.endAt ?? event.startAt) <= now, "a meeting runs past \(quarter / 4):\(quarter % 4 * 15)")
            }
            for block in content.blocks where block.startAt >= start {
                #expect(block.endAt <= now)
            }
        }
    }

    @Test("all of last week, then this week up to today")
    func lastWeekAndThisWeek() {
        let content = SampleWeek.content(now: Self.wednesday)
        // Monday 28 September to Wednesday 7 October.
        #expect(content.days.count == 10)
        #expect(content.days.last == "2026-10-07")
        #expect(content.days.first == "2026-09-28")
        #expect(content.days == content.days.sorted())
        // Every day has something on it.
        for day in content.days {
            #expect(content.blocks.contains { $0.day == day }, "\(day) has no blocks")
            #expect(content.captures.contains { DayBoundaries.dayString($0.capturedAt) == day })
        }
    }

    /// The shape of a build, with the dates taken out: which of the seven days, the clock, and
    /// what was on screen.
    private static func shape(_ content: SampleWeek.Content) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return content.blocks.map { block in
            let index = content.days.firstIndex(of: block.day) ?? -1
            return [
                "\(index)", formatter.string(from: block.startAt), formatter.string(from: block.endAt),
                block.appKey, block.taskKey, block.title ?? "", block.summaryMd ?? "", block.source.rawValue,
            ].joined(separator: "|")
        }
    }

    @Test("a week later, only the dates move")
    func onlyTheDatesMove() {
        let now = Self.wednesday
        let later = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let first = SampleWeek.content(now: now)
        let second = SampleWeek.content(now: later)
        #expect(second.days.last == "2026-10-14")
        #expect(Self.shape(first) == Self.shape(second))
        #expect(first.captures.count == second.captures.count)
        #expect(first.events.map(\.title) == second.events.map(\.title))
    }

    @Test("today stops at the later of now and noon")
    func todayIsCut() {
        let now = Self.wednesday
        let content = SampleWeek.content(now: now)
        let today = content.blocks.filter { $0.day == "2026-10-07" }
        #expect(!today.isEmpty)
        #expect(today.allSatisfy { $0.endAt <= now })
        #expect(content.captures.allSatisfy { $0.capturedAt < now })

        let early = DayBoundaries.range(day: "2026-10-07", timeZone: .current)!.start
            .addingTimeInterval(7 * 3600)
        let morning = SampleWeek.content(now: early).blocks.filter { $0.day == "2026-10-07" }
        let noon = early.addingTimeInterval(5 * 3600)
        #expect(!morning.isEmpty, "a sample opened at 07:00 still has a morning to look at")
        #expect(morning.allSatisfy { $0.endAt <= noon })
    }

    @Test("Today has something at 08:00 and 13:00 on every day of the week")
    func everyWeekdayHasAToday() {
        // 2026-10-04 is a Sunday; the seven days after it cover every weekday once.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for offset in 0..<7 {
            let start = DayBoundaries.range(day: "2026-10-04", timeZone: .current)!.start
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let day = DayBoundaries.dayString(date, timeZone: .current)
            for hour in [8, 13] {
                let now = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
                let today = SampleWeek.content(now: now).blocks.filter { $0.day == day }
                #expect(!today.isEmpty, "\(day) at \(hour):00 opens on an empty Today")
            }
        }
    }

    /// #357: on a Monday the sample used to be seven days ending today, and the Weeks page
    /// showed one morning and six empty columns. Now last week is always there in full.
    @Test("on every weekday, last week is whole and this week runs to today")
    func everyWeekdayHasLastWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // 2026-10-05 is a Monday; the seven days from it cover every weekday once.
        let monday = DayBoundaries.range(day: "2026-10-05", timeZone: .current)!.start
        let lastWeek = try #require(ISOWeek.containing(dayString: "2026-09-28"))
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: monday)!
            let now = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: date)!
            let today = DayBoundaries.dayString(date, timeZone: .current)
            let content = SampleWeek.content(now: now)
            #expect(content.days.count == 8 + offset)
            #expect(content.days.count == SampleWeek.dayCount(now: now))
            #expect(content.days.first == "2026-09-28", "\(today) starts on last week's Monday")
            #expect(content.days.last == today)
            #expect(Array(content.days.prefix(7)) == lastWeek.days)
            for day in content.days {
                #expect(content.blocks.contains { $0.day == day }, "\(today): \(day) is empty")
            }
            // Monday to Friday are full days (Friday is a quiet afternoon), the weekend is light.
            let minutes = lastWeek.days.map { day in
                content.blocks.filter { $0.day == day && $0.source == .screen }
                    .reduce(0.0) { $0 + $1.endAt.timeIntervalSince($1.startAt) / 60 }
            }
            for weekday in 0..<5 { #expect(minutes[weekday] >= 180, "\(lastWeek.days[weekday])") }
            for weekend in 5..<7 { #expect(minutes[weekend] < 60, "\(lastWeek.days[weekend])") }
        }
    }

    /// #357: the tour's Week stop opens on a week with something in most of its columns.
    @Test("the tour's Week stop always lands on a week with at least four whole days")
    func tourWeekIsFull() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(SampleWeek.tourWeekWholeDays == 4)
        let monday = DayBoundaries.range(day: "2026-10-05", timeZone: .current)!.start
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: monday)!
            for hour in [8, 13, 19] {
                let now = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
                let today = DayBoundaries.dayString(now, timeZone: .current)
                let content = SampleWeek.content(now: now)
                let week = try #require(SampleWeek.tourWeek(now: now))
                let whole = week.days.filter { day in
                    day < today && content.blocks.contains { $0.day == day }
                }
                #expect(whole.count >= 4, "\(today) \(hour):00 lands on \(week.start)")
                // Last week until this one is full enough, from Friday on this one.
                let thisWeek = try #require(ISOWeek.containing(now))
                #expect((week == thisWeek) == (offset >= 4), "\(today)")
                #expect(week.days.allSatisfy { $0 > today || content.days.contains($0) })
            }
        }
    }

    /// #357: the tour's second stop opens the first bar, and its tooltip says what you were
    /// doing there, read from the day's blocks the same way a real day's are.
    @Test("each app bar of a sample Today says what you were doing in that app")
    func barsSayWhatYouDid() throws {
        let dataDir = try Self.temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let now = Self.wednesday
        let db = try SampleWeek.rebuild(dataDir: dataDir, now: now)
        let stats = try StatsService(db, now: { now }).daily(day: "2026-10-07")
        let blocks = try ActivityBlockStore(db).fetch(day: "2026-10-07")
        let chart = try #require(Waterfall.of(stats, labels: TimelineLabels(), blocks: blocks))
        let first = try #require(chart.steps.first)
        #expect(first.kind == .app)
        let line = try #require(chart.summary(for: first))
        #expect(line.hasPrefix("You "))
        for step in chart.steps where step.kind == .app {
            #expect(chart.summary(for: step) != nil, "\(step.name) has nothing to say")
        }
        #expect(chart.summary(for: chart.steps.last!) == nil, "Total says no sentence")
    }

    /// #357 review: the moment stop opens one bar on whatever day today is, and promises what
    /// you were doing there. Bar 0 is the biggest, and on Monday and Thursday evenings that is
    /// Others, so the stop opens `momentIndex`: on every weekday and hour the tour can run, an app
    /// bar with something to say.
    @Test("on every weekday, the tour opens an app bar of a sample Today that says what you did")
    func everyWeekdayOpensOnAnAppBar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monday = DayBoundaries.range(day: "2026-10-05", timeZone: .current)!.start
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: monday)!
            for hour in [8, 13, 19] {
                let now = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
                let today = DayBoundaries.dayString(now, timeZone: .current)
                let dataDir = try Self.temporaryDataDir()
                defer { try? FileManager.default.removeItem(at: dataDir) }
                let db = try SampleWeek.rebuild(dataDir: dataDir, now: now)
                let stats = try StatsService(db, now: { now }).daily(day: today)
                let blocks = try ActivityBlockStore(db).fetch(day: today)
                let chart = try #require(
                    Waterfall.of(stats, labels: TimelineLabels(), blocks: blocks),
                    "\(today) \(hour):00 has no chart")
                let index = try #require(chart.momentIndex)
                let opened = chart.steps[index]
                #expect(opened.kind == .app, "\(today) \(hour):00 opens on \(opened.name)")
                #expect(chart.summary(for: opened) != nil, "\(today) \(hour):00: \(opened.name) is bare")
                if chart.steps.first?.kind == .app, chart.summary(for: chart.steps[0]) != nil {
                    #expect(index == 0, "the biggest bar is opened when it has a sentence")
                }
            }
        }
    }

    /// #357: the welcome window's drawing of the week.
    @Test("the miniature draws seven columns, five full workdays and a light weekend")
    func miniature() {
        let mini = SampleWeek.miniature
        #expect(mini.days.count == 7)
        #expect(mini.windowStart < mini.windowEnd)
        let minutes = mini.days.map { $0.reduce(0.0) { $0 + $1.end - $1.start } }
        for weekday in 0..<5 { #expect(minutes[weekday] >= 180, "\(weekday) \(minutes[weekday])") }
        // Drawn in whole half hours, as on the Weeks page: two of them at most on a weekend day.
        for weekend in 5..<7 { #expect(minutes[weekend] <= 60) }
        let all = mini.days.flatMap { $0 }
        #expect(all.contains { $0.isMeeting })
        for block in all {
            #expect(block.start >= mini.windowStart && block.end <= mini.windowEnd)
            #expect(block.end > block.start)
            if block.isMeeting { #expect(block.colorHex == nil) }
        }
        // The top apps keep their colour, each its own, and the rest are Others, as on the Weeks page.
        #expect(Set(all.compactMap(\.colorHex)).count == WeekCalendar.topAppCount)
        // No workday opens on a grey Others stripe: the tour's first look is the week's own colours.
        for weekday in 0..<5 {
            let first = mini.days[weekday].first { !$0.isMeeting }
            #expect(first?.colorHex != nil, "\(weekday)")
        }
    }

    @Test("Friday afternoon is quiet")
    func quietFriday() {
        let friday = SampleWeek.shape(weekday: 6)
        let afterThree = friday.runs.filter { $0.clock >= "15:00" }
        #expect(afterThree.isEmpty)
        #expect(SampleWeek.shape(weekday: 7).runs.count < SampleWeek.shape(weekday: 2).runs.count)
    }

    @Test("every row is marked as the sample's")
    func idsArePrefixed() {
        let content = SampleWeek.content(now: Self.wednesday)
        #expect(content.captures.allSatisfy { $0.id.hasPrefix(SampleWeek.idPrefix) })
        #expect(content.events.allSatisfy { $0.id.hasPrefix(SampleWeek.idPrefix) })
        #expect(content.blocks.allSatisfy { $0.id.contains(SampleWeek.idPrefix) })
        #expect(content.captures.allSatisfy { $0.describeStatus == .described && $0.imagePath == nil })
    }

    // MARK: Voice

    private static let banned = [
        "better", "worse", "score", "rank", "grade", "productive", "productivity", "than", "%",
        "the user", "frame", "\u{2014}", "\u{2013}",
    ]

    @Test("every sentence is yours: second person, no dashes, nothing judged")
    func voice() {
        let content = SampleWeek.content(now: Self.wednesday)
        let lines = Set(SampleWeek.everyLine + content.lines)
        #expect(lines.count > 40)
        for line in lines {
            let lower = line.lowercased()
            for word in Self.banned {
                #expect(!lower.contains(word), "\"\(line)\" contains \"\(word)\"")
            }
            let words = line.split { !$0.isLetter && $0 != "'" }.map(String.init)
            #expect(!words.contains("I"), "\"\(line)\" speaks as I")
            #expect(!words.contains { ["he", "she", "they", "his", "her", "their"].contains($0.lowercased()) },
                    "\"\(line)\" is in the third person")
        }
        let sentences = content.blocks.compactMap(\.summaryMd) + content.events.compactMap(\.bodyMd)
        #expect(!sentences.isEmpty)
        for sentence in sentences {
            #expect(sentence.hasPrefix("You "), "\"\(sentence)\" does not address you")
            #expect(sentence.hasSuffix("."), "\"\(sentence)\" is not a sentence")
        }
    }

    @Test("the copy around the sample follows the voice rules too")
    func copy() {
        let copy = [
            SampleWeekCopy.ribbon, SampleWeekCopy.leave, SampleWeekCopy.firstMoments,
            SampleWeekCopy.settingTitle, SampleWeekCopy.settingDetail, SampleWeekCopy.show,
            SampleWeekCopy.startedTitle, SampleWeekCopy.startedBody,
        ]
        for line in copy {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "\"\(line)\" has a dash")
            for word in ["score", "better", "worse", "productiv"] { #expect(!line.lowercased().contains(word)) }
        }
        #expect(SampleWeekCopy.ribbon == "Sample week: invented, not yours.")
    }

    // MARK: Through the real reading paths

    @Test("the sample reads through the same day index, stats and week grid as a real day")
    func readsLikeARealWeek() throws {
        let dataDir = try Self.temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let now = Self.wednesday
        let db = try SampleWeek.rebuild(dataDir: dataDir, now: now)
        #expect(SampleWeek.isSample(db))
        #expect(FileManager.default.fileExists(
            atPath: SampleWeek.directory(dataDir: dataDir).appendingPathComponent("worklens.sqlite").path
        ))

        let entries = try DayIndex(db, now: { now }).entries(limit: 30)
        #expect(entries.count == 10)
        #expect(entries.allSatisfy { $0.hasTimeline && $0.activeMinutes > 0 && $0.described == $0.frames })

        let stats = try StatsService(db, now: { now }).daily(day: "2026-10-07")
        #expect(stats.activeMinutes > 0)
        #expect(stats.meetingsCount >= 2)
        #expect(Waterfall.of(stats, labels: TimelineLabels()) != nil)

        let week = ISOWeek.containing(dayString: "2026-10-07")!
        let weekly = try StatsService(db, now: { now }).weekly(week, includePreviousWeek: false)
        var blocks: [String: [ActivityBlock]] = [:]
        for day in week.days { blocks[day] = try ActivityBlockStore(db).fetch(day: day) }
        let grid = WeekCalendar.build(week: week, stats: weekly, blocksByDay: blocks, labels: TimelineLabels(), now: now)
        #expect(grid.days.contains { !$0.meetings.isEmpty })
        #expect(grid.days.contains { !$0.blocks.isEmpty })
    }

    @Test("a rebuild replaces the folder rather than adding to it")
    func rebuildReplaces() throws {
        let dataDir = try Self.temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let total = { (db: WorklensCore.Database) in try db.writer.read { try Capture.fetchCount($0) } }
        let first = try SampleWeek.rebuild(dataDir: dataDir, now: Self.wednesday)
        let count = try total(first)
        #expect(count == SampleWeek.content(now: Self.wednesday).captures.count)
        let second = try SampleWeek.rebuild(dataDir: dataDir, now: Self.wednesday)
        #expect(try total(second) == count)
        SampleWeek.remove(dataDir: dataDir)
        #expect(!FileManager.default.fileExists(atPath: SampleWeek.directory(dataDir: dataDir).path))
        #expect(FileManager.default.fileExists(atPath: dataDir.path), "the data folder itself stays")
    }

    // MARK: Never real

    /// Every argument shape the tools take, filled in for each sample day.
    private static func argumentSets(days: [String]) -> [JSONValue] {
        var sets: [JSONValue] = [.object([:])]
        for day in days {
            sets.append(.object(["day": .string(day)]))
            sets.append(.object(["from": .string(day), "to": .string(day)]))
        }
        sets.append(.object(["from": .string(days.first!), "to": .string(days.last!)]))
        // Words the sample is full of, but not the markers themselves: a search that echoes its
        // query back must not look like a leak.
        for query in ["sync", "conflict", "offline", "review"] {
            sets.append(.object(["query": .string(query)]))
        }
        return sets
    }

    private static func everyAnswer(_ registry: MCPToolRegistry, days: [String]) -> [String] {
        var answers: [String] = []
        for tool in registry.tools {
            for arguments in argumentSets(days: days) {
                if let text = try? tool.handler(arguments) { answers.append(text) }
            }
        }
        return answers
    }

    @Test("no MCP tool can return a sample row, and the real ledger never holds one")
    func neverReachesClaude() throws {
        let dataDir = try Self.temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        var config = Config.defaults()
        config.dataDir = dataDir
        let taxonomy = try TaxonomyStore(dataDir: dataDir)

        // The real ledger first, as the app opens it, then the sample beside it.
        let real = try Database(dataDir: dataDir)
        let sample = try SampleWeek.rebuild(dataDir: dataDir)
        let days = SampleWeek.content().days

        // Exactly what `worklens mcp` builds: the registry over `DATA_DIR`'s own database.
        let registry = WorklensMCPTools.registry(config: config, db: real, taxonomy: taxonomy)
        let answers = Self.everyAnswer(registry, days: days)
        #expect(answers.count > registry.tools.count)
        let markers = [SampleWeek.projectName, SampleWeek.idPrefix, "harbor-app", "Team standup"]
        for answer in answers {
            for marker in markers {
                #expect(!answer.contains(marker), "an MCP answer carries the sample's \"\(marker)\"")
            }
        }

        // The control: the same calls over the sample's file do find it, so the check above is
        // looking at the right thing.
        let leaked = WorklensMCPTools.registry(config: config, db: sample, taxonomy: taxonomy)
        #expect(Self.everyAnswer(leaked, days: days).contains { $0.contains(SampleWeek.projectName) })

        // What the CLI opens (read-only and read-write) has none of it either.
        for ledger in [real, try Database.readOnly(dataDir: dataDir)] {
            #expect(!SampleWeek.isSample(ledger))
            let rows = try ledger.writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT (SELECT COUNT(*) FROM captures) + (SELECT COUNT(*) FROM activity_blocks)
                         + (SELECT COUNT(*) FROM context_events)
                    """) ?? 0
            }
            #expect(rows == 0)
        }
        #expect(SampleWeek.directory(dataDir: dataDir) != dataDir)
    }

    /// The test above checks the folders; this one checks the wiring. Only the reader's two files
    /// (and the stored property's declaration) may name the sample's database or folder, so the
    /// `mcp` command, the CLI and every other service cannot be pointed at it without failing
    /// here.
    @Test("only the reader's files name the sample's database or folder")
    func onlyTheReaderReachesTheSample() throws {
        let allowed: Set<String> = [
            "Sources/Worklens/App/AppModel+SampleWeek.swift",
            "Sources/Worklens/App/AppModel+Reader.swift",
        ]
        let names = ["sampleWeekDB", "readerDB", "SampleWeek.directory", "SampleWeek.rebuild"]
        var offenders: [String] = []
        for (path, text) in try NetworkDestinationsDocTests.swiftSources()
        where !allowed.contains(path) && !path.hasPrefix("Sources/WorklensCore/Sample/") {
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !line.hasPrefix("//") && line != "var sampleWeekDB: Database?" {
                for name in names where line.contains(name) { offenders.append("\(path): \(name)") }
            }
        }
        #expect(offenders.isEmpty, "the sample reaches past the reader: \(offenders)")
    }

    // MARK: The handoff (#350)

    @Test("at launch: show with nothing of yours, stay closed once you left, record an existing install")
    func launch() {
        typealias H = SampleWeekHandoff
        #expect(H.atLaunch(.init()) == .show)
        #expect(H.atLaunch(.init(left: true)) == .stayClosed)
        #expect(H.atLaunch(.init(hasSummaries: true)) == .recordSilently)
        #expect(H.atLaunch(.init(left: true, hasSummaries: true)) == .recordSilently)
        #expect(H.atLaunch(.init(handedOff: true)) == .nothing)
        #expect(H.atLaunch(.init(handedOff: true, hasSummaries: true)) == .nothing)
    }

    @Test("summaries from your first day, written while the app was closed, still hand over out loud")
    func launchAfterClosedFirstDay() {
        typealias H = SampleWeekHandoff
        let now = Self.wednesday
        let recent = H.Facts(hasSummaries: true, firstSummaryAt: now.addingTimeInterval(-3600))
        #expect(H.atLaunch(recent, now: now) == .handOver)
        var left = recent
        left.left = true
        #expect(H.atLaunch(left, now: now) == .handOver)
        let old = H.Facts(hasSummaries: true, firstSummaryAt: now.addingTimeInterval(-3 * 86_400))
        #expect(H.atLaunch(old, now: now) == .recordSilently)
        var done = recent
        done.handedOff = true
        #expect(H.atLaunch(done, now: now) == .nothing)
    }

    @Test("the first real summary leaves, notifies and records; nothing after that")
    func firstSummary() {
        typealias H = SampleWeekHandoff
        #expect(H.onSummary(provider: "gemini", isShowingSample: true, handedOff: false)
            == .init(leave: true, notify: true, record: true))
        // Left early: still the one notification.
        #expect(H.onSummary(provider: "gemini", isShowingSample: false, handedOff: false)
            == .init(leave: false, notify: true, record: true))
        // Re-opened from Settings after the handoff: never closed under you again.
        #expect(H.onSummary(provider: "gemini", isShowingSample: true, handedOff: true) == .none)
        #expect(H.onSummary(provider: "gemini", isShowingSample: false, handedOff: true) == .none)
        // The offline fake is not your day.
        #expect(H.onSummary(provider: FakeProvider.name, isShowingSample: true, handedOff: false) == .none)
    }

    @Test("the facts are read off the real ledger")
    func facts() throws {
        let db = try Database.inMemory()
        #expect(SampleWeekHandoff.Facts.read(db) == .init())
        try CaptureStore(db).insert(Capture(capturedAt: Self.wednesday, describeStatus: .pending))
        #expect(SampleWeekHandoff.Facts.read(db).hasSummaries == false)
        try CaptureStore(db).insert(Capture(capturedAt: Self.wednesday, describeStatus: .described))
        try AppStateStore(db).setDate(SampleWeekHandoff.Key.leftAt, Self.wednesday)
        #expect(SampleWeekHandoff.Facts.read(db) == .init(
            handedOff: false, left: true, hasSummaries: true, firstSummaryAt: Self.wednesday
        ))
        try AppStateStore(db).setDate(SampleWeekHandoff.Key.handedOffAt, Self.wednesday)
        #expect(SampleWeekHandoff.Facts.read(db).handedOff)
    }

    // MARK: What the one notification quotes

    private static func summarize(
        _ db: WorklensCore.Database, _ summary: String, provider: String = "gemini", at offset: TimeInterval,
        inherited: Bool = false, sensitive: Bool = false
    ) throws {
        let capture = Capture(
            capturedAt: wednesday.addingTimeInterval(offset),
            describeStatus: inherited ? .inherited : .described
        )
        try CaptureStore(db).insert(capture)
        try DescriptionStore(db).insert(Description(
            captureId: capture.id, provider: provider, model: "m", appKey: "other", taskKey: "other",
            summaryMd: summary, isSensitive: sensitive, isInherited: inherited,
            createdAt: wednesday.addingTimeInterval(offset)
        ))
    }

    @Test("summaries the offline fake wrote do not make an install look handed over at launch")
    func factsIgnoreFake() throws {
        let db = try WorklensCore.Database.inMemory()
        try Self.summarize(db, "Runs the offline fake.", provider: FakeProvider.name, at: 0)
        #expect(SampleWeekHandoff.Facts.read(db).hasSummaries == false)
        #expect(SampleWeekHandoff.atLaunch(SampleWeekHandoff.Facts.read(db), now: Self.wednesday) == .show)
        try Self.summarize(db, "Edits setup.sh in VS Code.", at: 60)
        #expect(SampleWeekHandoff.Facts.read(db).firstSummaryAt == Self.wednesday.addingTimeInterval(60))
    }

    @Test("the banner quotes your earliest real summary, never the fake's, an inherited one or nothing")
    func firstSummaryRead() throws {
        let db = try Database.inMemory()
        #expect(SampleWeekHandoff.firstSummary(db) == nil)
        try Self.summarize(db, "Runs the offline fake.", provider: FakeProvider.name, at: 0)
        #expect(SampleWeekHandoff.firstSummary(db) == nil)
        try Self.summarize(db, "Copied from the screenshot before.", at: 30, inherited: true)
        #expect(SampleWeekHandoff.firstSummary(db) == nil)
        try Self.summarize(db, "Edits setup.sh in VS Code.", at: 60)
        try Self.summarize(db, "Reads the README in Safari.", at: 120)
        #expect(SampleWeekHandoff.firstSummary(db) == "Edits setup.sh in VS Code.")
    }

    @Test("a first summary marked sensitive is not put on a banner")
    func firstSummarySensitive() throws {
        let db = try Database.inMemory()
        try Self.summarize(db, "Reads a bank statement.", at: 0, sensitive: true)
        try Self.summarize(db, "Edits setup.sh in VS Code.", at: 60)
        #expect(SampleWeekHandoff.firstSummary(db) == nil)
        #expect(SampleWeekCopy.startedBody(quoting: SampleWeekHandoff.firstSummary(db)) == SampleWeekCopy.startedBody)
    }

    @Test("the body quotes the summary in one plain line, and falls back without one")
    func startedBodyQuoting() {
        #expect(SampleWeekCopy.startedBody(quoting: "Edits setup.sh in VS Code.")
            == "Worklens summarized your first screenshot: “Edits setup.sh in VS Code.” Click to open the Today page.")
        #expect(SampleWeekCopy.startedBody(quoting: nil) == SampleWeekCopy.startedBody)
        #expect(SampleWeekCopy.startedBody(quoting: "  \n ") == SampleWeekCopy.startedBody)
        // A summary that names a web address is not put on a banner.
        #expect(SampleWeekCopy.quotable("Reads https://example.com/roadmap in Safari.") == nil)
        #expect(SampleWeekCopy.quotable("Reads WWW.example.com in Safari.") == nil)
        #expect(SampleWeekCopy.quotable("Edits **`setup.sh`**\nin  VS Code \u{2014} the installer.")
            == "Edits setup.sh in VS Code, the installer.")
        let long = Array(repeating: "Reviews", count: 40).joined(separator: " ") + "."
        let quoted = SampleWeekCopy.quotable(long)!
        #expect(quoted.count <= SampleWeekCopy.quoteLimit + 1)
        #expect(quoted.hasSuffix("Reviews…"))
        for body in [SampleWeekCopy.startedBody(quoting: long), SampleWeekCopy.startedBody] {
            #expect(!body.contains("\u{2014}") && !body.contains("\u{2013}"))
        }
    }

    @Test("the ribbon's status line names what is missing in the menu's words")
    func statusLine() {
        let done = SetupProgress(screenRecording: true, geminiKey: true, onboardedAt: Self.wednesday)
        let line = { (setup: SetupProgress, scheduler: SchedulerState) in
            SampleWeekHandoff.statusLine(
                setup: setup, handedOff: false, scheduler: scheduler, now: Self.wednesday, locale: Format.fixed
            )
        }
        #expect(line(SetupProgress(screenRecording: true, geminiKey: true), .running) == nil)
        #expect(line(done, .running) == SampleWeekCopy.firstMoments)
        #expect(line(done, .idle) == SampleWeekCopy.firstMoments)
        var noGrant = done
        noGrant.screenRecording = false
        #expect(line(noGrant, .running) == "Screen Recording permission needed")
        var noKey = done
        noKey.geminiKey = false
        #expect(line(noKey, .running) == MenuModel.firstRunText)
        #expect(line(done, .paused(until: nil)) == "Paused until you resume")
        #expect(line(done, .budgetExceeded) == "Budget reached: screenshots on hold")
        // Stopped: nothing is on its way, so no "in about a minute".
        #expect(line(done, .stopped) == "Stopped")
        // Opened from Settings after your own days have started: no "first moments" promise.
        let afterHandoff = SampleWeekHandoff.statusLine(
            setup: done, handedOff: true, scheduler: .running, now: Self.wednesday, locale: Format.fixed
        )
        #expect(afterHandoff == nil)
    }
}
