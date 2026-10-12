import Foundation
import Testing
@testable import WorklensCore

// #323: the project timesheet `span` returns with `by: "project"`.

private let utc = TimeZone(identifier: "UTC")!
private let days = ["2026-09-08", "2026-09-09", "2026-09-10"]
private func start(_ day: String) -> Date { DayBoundaries.range(day: day, timeZone: utc)!.start }
private func at(_ day: String, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    start(day).addingTimeInterval(Double(hour * 3600 + minute * 60 + second))
}

private let catalog = [
    ProjectEntry(key: "acme", name: "Acme Secret", kind: .company),
    ProjectEntry(key: "beta", name: "Beta Hidden", kind: .side),
    ProjectEntry(key: "halyard", name: "Halyard", kind: .house, domains: ["halyard.example"]),
]

private func span(
    _ day: String, _ hour: Int, _ minute: Int, seconds: Double, project: String? = nil,
    kind: ProjectSpan.Kind = .screen, rule: ProjectSpan.Rule = .projectHint, reason: ProjectSpan.Reason? = nil
) -> ProjectSpan {
    let from = at(day, hour, minute)
    return ProjectSpan(
        start: from, end: from.addingTimeInterval(seconds), kind: kind, project: project, name: project,
        rule: project == nil ? nil : rule, secondsByRule: project == nil ? [:] : [rule.rawValue: seconds],
        unattributed: project == nil ? (reason ?? .noEvidence) : nil
    )
}

@Suite("Timesheet (#323)")
struct TimesheetTests {
    @Test("nine projects on one day all come back, with no other row")
    func nineProjectsUncut() {
        let keys = (1...9).map { "p\($0)" }
        let spans = keys.enumerated().map { span(days[0], 9, $0.offset * 10, seconds: 300, project: $0.element) }
        let sheet = Timesheet.build(days: [days[0]], spans: [days[0]: spans], accounting: [:], projects: catalog)
        #expect(sheet.projects.map(\.key).sorted() == keys)
        #expect(!sheet.projects.contains { $0.key == StatsAggregator.otherKey })
        #expect(sheet.projects.allSatisfy { $0.minutes == 5 && $0.daysSeen == 1 })
    }

    @Test("40 seconds on each of three days totals 2 minutes, rounded once")
    func roundsOnce() throws {
        let spans = Dictionary(uniqueKeysWithValues: days.map { ($0, [span($0, 9, 0, seconds: 40, project: "acme")]) })
        let sheet = Timesheet.build(days: days, spans: spans, accounting: [:], projects: catalog)
        let acme = try #require(sheet.projects.first)
        #expect(acme.minutes == 2)
        #expect(acme.screenMinutes == 2)
        #expect(acme.daysSeen == 3)
        #expect(acme.perDay.count == 3)
        #expect(acme.perDay[days[0]] == Timesheet.Cell(screen: 1))
        #expect(acme.byRule == ["project_hint": 2])
        #expect(acme.name == "Acme Secret")
        #expect(acme.kind == .company)
        #expect(sheet.totals.screen == 2)
    }

    @Test("overlapping agent stretches count once and stay out of minutes")
    func agentUnion() throws {
        let day = days[1]
        let agent = [
            Timesheet.Agent(project: "acme", start: at(day, 10, 0), end: at(day, 10, 30)),
            Timesheet.Agent(project: "acme", start: at(day, 10, 15), end: at(day, 10, 45)),
            Timesheet.Agent(project: nil, start: at(day, 11, 0), end: at(day, 11, 10)),
        ]
        let sheet = Timesheet.build(
            days: [day], spans: [day: [span(day, 10, 0, seconds: 600, project: "acme")]], accounting: [:],
            agent: [day: agent], projects: catalog
        )
        let acme = try #require(sheet.projects.first)
        #expect(acme.agentMinutes == 45)
        #expect(acme.minutes == 10)
        #expect(acme.perDay[day] == Timesheet.Cell(screen: 10, agent: 45))
        #expect(sheet.unattributed.agentMinutes == 10)
        #expect(sheet.unattributed.minutes == 0)
        #expect(sheet.totals.agent == 55)
    }

    @Test("each unattributed reason has its own key, and the house entry is a row")
    func unattributedAndHouse() throws {
        let day = days[0]
        let spans = [
            span(day, 9, 0, seconds: 600, project: "halyard", kind: .meeting, rule: .meetingCompany),
            span(day, 10, 0, seconds: 1200, kind: .meeting, reason: .meetingWithoutCompany),
            span(day, 11, 0, seconds: 300, reason: .noEvidence),
            span(day, 11, 5, seconds: 120, reason: .redacted),
        ]
        let agent = [Timesheet.Agent(project: nil, start: at(day, 12, 0), end: at(day, 12, 7))]
        let sheet = Timesheet.build(
            days: [day], spans: [day: spans], accounting: [:], agent: [day: agent], projects: catalog
        )
        let house = try #require(sheet.projects.first { $0.key == "halyard" })
        #expect(house.kind == .house)
        #expect(house.meetingMinutes == 10)
        #expect(house.byRule == ["meeting_company": 10])
        #expect(sheet.unattributed.breakdown == ["screenNoProject": 7, "meetingNoCompany": 20, "agentNoProject": 7])
        #expect(sheet.unattributed.reasons == ["meeting_without_company": 20, "no_evidence": 5, "redacted": 2])
        #expect(sheet.unattributed.minutes == 27)
        #expect(sheet.totals.meeting == 30)
        #expect(sheet.totals.screen == 7)
    }

    @Test("notRecorded is the window's accounting summed, under the bucket names")
    func notRecordedPassesThrough() {
        func accounting(_ day: String, idle: Int, locked: Int, screen: Int) -> DayAccounting {
            var window = DayAccounting.Minutes()
            window.idle = idle
            window.locked = locked
            window.screen = screen
            window.total = idle + locked + screen
            var whole = window
            whole.notRunning = 1_000
            return DayAccounting(
                from: start(day), through: start(day).addingTimeInterval(86_400), firstEvidence: nil,
                lastEvidence: nil, day: whole, window: window, spans: nil
            )
        }
        let books = [days[0]: accounting(days[0], idle: 12, locked: 30, screen: 100),
                     days[1]: accounting(days[1], idle: 3, locked: 0, screen: 50)]
        let sheet = Timesheet.build(days: days, spans: [:], accounting: books, projects: catalog)
        let window = DayAccounting.Totals(Array(books.values)).window
        #expect(Set(sheet.notRecorded.keys) == Set(Timesheet.notRecordedBuckets.map(\.rawValue)))
        for bucket in Timesheet.notRecordedBuckets {
            #expect(sheet.notRecorded[bucket.rawValue] == window[bucket])
        }
        #expect(sheet.notRecorded["idle"] == 15)
        #expect(sheet.notRecorded["notRunning"] == 0)
        #expect(sheet.notRecorded["screen"] == nil && sheet.notRecorded["meeting"] == nil)
    }

    @Test("only narrows to one row, an empty one when the project had no time")
    func onlyNarrows() {
        let day = days[0]
        let spans = [
            span(day, 9, 0, seconds: 600, project: "acme"), span(day, 10, 0, seconds: 600, project: "beta"),
            span(day, 11, 0, seconds: 300),
        ]
        let sheet = Timesheet.build(days: [day], spans: [day: spans], accounting: [:], projects: catalog, only: "beta")
        #expect(sheet.projects.map(\.key) == ["beta"])
        // On purpose: `project` narrows the rows only; totals and unattributed stay whole-range.
        #expect(sheet.totals.screen == 25)
        #expect(sheet.unattributed.screenMinutes == 5)
        let empty = Timesheet.build(days: [day], spans: [day: spans], accounting: [:], projects: catalog, only: "halyard")
        #expect(empty.projects.map(\.key) == ["halyard"])
        #expect(empty.projects.first?.minutes == 0)
        #expect(empty.projects.first?.perDay.isEmpty == true)
    }

    @Test("a day split into many sub-minute rows still adds up to its accounting", arguments: [(4, 30.0), (5, 20.0), (7, 50.0)])
    func subMinuteRowsAddUp(rows: Int, seconds: Double) {
        let day = days[0]
        let spans = (0..<rows).map { span(day, 9, $0, seconds: seconds, project: "p\($0)") }
            + [span(day, 10, 0, seconds: seconds), span(day, 10, 5, seconds: seconds, kind: .meeting)]
        let recorded = seconds * Double(rows + 2)
        let minutes = DayAccounting.Minutes(seconds: [.screen: seconds * Double(rows + 1), .meeting: seconds], totalSeconds: recorded)
        let accounting = DayAccounting(
            from: start(day), through: start(day).addingTimeInterval(86_400), firstEvidence: nil,
            lastEvidence: nil, day: minutes, window: minutes, spans: nil
        )
        let sheet = Timesheet.build(days: [day], spans: [day: spans], accounting: [day: accounting], projects: catalog)
        let cells = sheet.projects.compactMap { $0.perDay[day] } + [sheet.unattributed.perDay[day]].compactMap { $0 }
        let sum = cells.reduce(0) { $0 + $1.screen + $1.meeting }
        #expect(abs(sum - (minutes.screen + minutes.batterySparse + minutes.meeting)) <= 1)
        #expect(sum == Int((recorded / 60).rounded()))
    }

    @Test("a cell leaves its zeros out of the JSON")
    func cellOmitsZeros() throws {
        let text = String(decoding: try JSONEncoder().encode(Timesheet.Cell(screen: 40)), as: UTF8.self)
        #expect(text == #"{"screen":40}"#)
    }
}

// MARK: - Over the store

/// Screen frames and a calendar call, as `ProjectSpanServiceTests` lays them down.
private struct Store {
    let db: Database
    let day = days[1]

    init() throws { db = try Database.inMemory() }

    func screen(from hour: Int, _ minute: Int, hints: [String?]) throws {
        for (offset, hint) in hints.enumerated() {
            let capture = Capture(
                capturedAt: at(day, hour, minute + offset), appName: "Xcode", windowTitle: "Quarterly secret plan",
                intervalSeconds: 60, describeStatus: .described
            )
            try CaptureStore(db).insert(capture)
            try DescriptionStore(db).insert(Description(
                captureId: capture.id, provider: "gemini", model: "test", appKey: "xcode",
                taskKey: "coding", summaryMd: "Edits code.", detailsJson: hint.map { #"{"project_hint":"\#($0)"}"# }
            ))
        }
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: day, startAt: at(day, hour, minute), endAt: at(day, hour, minute + hints.count),
            appKey: "xcode", taskKey: "coding", captureCount: hints.count, source: .screen
        ))
    }

    func meeting(from hour: Int, _ minute: Int, minutes: Int, participants: [String]) throws {
        let event = ContextEvent(
            id: "c\(hour)\(minute)", source: .calendar, externalId: "c\(hour)\(minute)",
            startAt: at(day, hour, minute), endAt: at(day, hour, minute + minutes), title: "Weekly sync",
            participantsJson: ContextEvent.encodeParticipants(participants), isMeeting: true,
            rawJson: #"{"attendees":[{"email":"you@halyard.example","self":true}]}"#
        )
        try ContextEventStore(db).upsert(event)
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: day, startAt: at(day, hour, minute), endAt: at(day, hour, minute + minutes),
            appKey: "calendar", taskKey: "meeting", source: .calendar
        ))
    }

    var service: StatsService {
        StatsService(db, timeZone: utc, projects: { catalog }, now: { at(days[2], 23, 0) })
    }
}

@Suite("Timesheet over the store (#323)")
struct TimesheetServiceTests {
    @Test("per day, the rows' screen and meeting minutes match the accounting, and a screenshot in a call counts once")
    func matchesAccounting() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: Array(repeating: "Acme Secret", count: 20))
        try store.screen(from: 11, 0, hints: Array(repeating: nil, count: 7))
        // A call over the last ten screen minutes of the Acme stretch.
        try store.meeting(from: 9, 10, minutes: 30, participants: ["ana@halyard.example", "bob@other.example"])
        let sheet = try store.service.timesheet(from: days[0], to: days[2])
        let accounting = try #require(try store.service.daily(day: store.day).accounting)
        let rows = sheet.projects.compactMap { $0.perDay[store.day] } + [sheet.unattributed.perDay[store.day]].compactMap { $0 }
        let recorded = rows.reduce(0) { $0 + $1.screen + $1.meeting }
        let expected = accounting.day.screen + accounting.day.batterySparse + accounting.day.meeting
        #expect(abs(recorded - expected) <= 1)
        #expect(sheet.totals.meeting == 30)
        #expect(sheet.totals.screen + sheet.totals.meeting == 47)
        #expect(sheet.projects.first { $0.key == "acme" }?.screenMinutes == 10)
        #expect(sheet.unattributed.breakdown["screenNoProject"] == 7)
        #expect(sheet.from == days[0] && sheet.to == days[2])
        let window = DayAccounting.Totals(
            try days.compactMap { try store.service.daily(day: $0).accounting }
        ).window
        for bucket in Timesheet.notRecordedBuckets {
            #expect(sheet.notRecorded[bucket.rawValue] == window[bucket])
        }
    }

    @Test("two agent sessions in one repo overlap and count once, out of minutes")
    func agentTurnsFromTheStore() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: Array(repeating: "Acme Secret", count: 5))
        var write = AgentWrite()
        write.sessions = [
            AgentSession(
                id: "s1", tool: AgentStoreParsers.claudeCode, host: "cli",
                startAt: at(store.day, 10, 0), endAt: at(store.day, 11, 0), cwd: "/Users/me/code/acme", vcsRepo: "me/acme"
            ),
            AgentSession(
                id: "s2", tool: AgentStoreParsers.claudeCode, host: "cli",
                startAt: at(store.day, 10, 0), endAt: at(store.day, 11, 0), cwd: "/Users/me/code/acme", vcsRepo: "me/acme"
            ),
            AgentSession(
                id: "s3", tool: AgentStoreParsers.claudeCode, host: "cli",
                startAt: at(store.day, 12, 0), endAt: at(store.day, 13, 0), cwd: "/Users/me/code/elsewhere"
            ),
        ]
        write.turns = [
            AgentTurn(sessionId: "s1", startAt: at(store.day, 10, 0), endAt: at(store.day, 10, 30)),
            AgentTurn(sessionId: "s2", startAt: at(store.day, 10, 20), endAt: at(store.day, 10, 40)),
            AgentTurn(sessionId: "s3", startAt: at(store.day, 12, 0), endAt: at(store.day, 12, 6)),
        ]
        _ = try AgentSessionStore(store.db).apply(write)
        _ = try AgentSessionStore(store.db).resolveRepos()
        let sheet = try store.service.timesheet(from: store.day, to: store.day)
        let acme = try #require(sheet.projects.first { $0.key == "acme" })
        #expect(acme.agentMinutes == 40)
        #expect(acme.minutes == 5)
        #expect(sheet.unattributed.breakdown["agentNoProject"] == 6)
        #expect(sheet.totals.agent == 46)
    }
    @Test("a repo rule you wrote puts that repo's agent minutes on the rule's project")
    func agentRepoRule() throws {
        let store = try Store()
        var write = AgentWrite()
        write.sessions = [
            AgentSession(
                id: "r1", tool: AgentStoreParsers.claudeCode, host: "cli",
                startAt: at(store.day, 10, 0), endAt: at(store.day, 11, 0), cwd: "/Users/me/code/widgets", vcsRepo: "me/widgets"
            ),
        ]
        write.turns = [AgentTurn(sessionId: "r1", startAt: at(store.day, 10, 0), endAt: at(store.day, 10, 25))]
        _ = try AgentSessionStore(store.db).apply(write)
        _ = try AgentSessionStore(store.db).resolveRepos()
        var ruled = catalog
        ruled[1].rules = ProjectRules(repos: ["me/widgets"])
        let service = StatsService(store.db, timeZone: utc, projects: { ruled }, now: { at(days[2], 23, 0) })
        let sheet = try service.timesheet(from: store.day, to: store.day)
        #expect(sheet.projects.first { $0.key == "beta" }?.agentMinutes == 25)
        #expect(sheet.unattributed.breakdown["agentNoProject"] ?? 0 == 0)
    }
}
