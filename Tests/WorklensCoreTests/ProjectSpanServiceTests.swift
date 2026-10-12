import Foundation
import Testing
@testable import WorklensCore

// #322: the storage side of project spans, and what `byProject`, the threads, the timeline and
// `projects coverage` read from them.

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-09"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

private let catalog = [
    ProjectEntry(key: "acme", name: "Acme Secret"),
    ProjectEntry(key: "beta", name: "Beta Hidden"),
    ProjectEntry(key: "halyard", name: "Halyard", kind: .house, domains: ["halyard.example"]),
]

/// An in-memory store with screen frames hinted as `hints` (nil: described, no hint), one a
/// minute from `hour:minute`, inside one Xcode block.
private struct Store {
    let db: Database

    init() throws { db = try Database.inMemory() }

    func screen(
        from hour: Int, _ minute: Int, hints: [String?], title: String = "Quarterly secret plan", url: String? = nil
    ) throws {
        for (offset, hint) in hints.enumerated() {
            let capture = Capture(
                capturedAt: at(hour, minute + offset), appName: "Xcode", windowTitle: title,
                browserUrl: url ?? "https://example.com/private/\(offset)", intervalSeconds: 60,
                describeStatus: .described
            )
            try CaptureStore(db).insert(capture)
            let details = hint.map { #"{"project_hint":"\#($0)"}"# }
            try DescriptionStore(db).insert(Description(
                captureId: capture.id, provider: "gemini", model: "test", appKey: "xcode",
                taskKey: "coding", summaryMd: "Edits code.", detailsJson: details
            ))
        }
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: day, startAt: at(hour, minute), endAt: at(hour, minute + hints.count),
            appKey: "xcode", taskKey: "coding", captureCount: hints.count, source: .screen
        ))
    }

    /// A calendar call with `participants`, as a meeting block and its event.
    func meeting(from hour: Int, _ minute: Int, minutes: Int, participants: [String]) throws {
        let event = ContextEvent(
            id: "c\(hour)\(minute)", source: .calendar, externalId: "c\(hour)\(minute)",
            startAt: at(hour, minute), endAt: at(hour, minute + minutes), title: "Weekly sync",
            participantsJson: ContextEvent.encodeParticipants(participants), isMeeting: true,
            rawJson: #"{"attendees":[{"email":"you@halyard.example","self":true}]}"#
        )
        try ContextEventStore(db).upsert(event)
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: day, startAt: at(hour, minute), endAt: at(hour, minute + minutes), appKey: "calendar", taskKey: "meeting",
            source: .calendar
        ))
    }

    func stats() throws -> DailyStats {
        try StatsService(db, timeZone: utc, projects: { catalog }, now: { at(23, 0) }).daily(day: day)
    }

    var service: ProjectSpanService {
        ProjectSpanService(db, timeZone: utc, projects: { catalog }, now: { at(23, 0) })
    }
}

@Suite("Project spans over the store (#322)")
struct ProjectSpanServiceTests {
    @Test("a one-frame detour lands on the project around it in byProject and the threads")
    func detourInStats() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: ["Acme Secret", "Acme Secret", "Beta Hidden", "Acme Secret", "Acme Secret"])
        let stats = try store.stats()
        let spans = try #require(stats.projectSpans)
        #expect(spans.map(\.project) == ["acme"])
        #expect(spans.first?.absorbed == 1)
        #expect(stats.byProject.map(\.key) == ["acme"])
        #expect(stats.byProject.first?.minutes == 5)
        #expect(stats.byProject.first?.share == 1)
        #expect(stats.threads.map(\.key) == ["acme"])
    }

    @Test("a day no frame names a project on keeps an empty byProject")
    func noProjectNoRows() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: [nil, nil, nil])
        let stats = try store.stats()
        #expect(stats.projectSpans?.map(\.unattributed) == [.noEvidence])
        #expect(stats.byProject.isEmpty)
        #expect(stats.threads.allSatisfy { !$0.key.contains("acme") })
    }

    @Test("stats threads and timeline headings name the same project for every block")
    func statsAndTimelineAgree() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: ["Acme Secret", "Beta Hidden", "Acme Secret", "Acme Secret"])
        try store.screen(from: 10, 0, hints: ["Beta Hidden", "Beta Hidden", "Acme Secret"])
        try store.screen(from: 11, 0, hints: [nil, nil])
        let stats = try store.stats()
        let spans = try #require(try store.service.spans(day: day))
        #expect(stats.projectSpans == spans)

        let blocks = try ActivityBlockStore(store.db).fetch(day: day).sorted { $0.startAt < $1.startAt }
        let frames = try TimelineQueries(store.db).frames(day: day, timeZone: utc)
        let byBlock = StatsAggregator.spanProjects(blocks, spans: spans)
        let headings = TimelineRenderer.HeadingProjects(named: [:], spans: spans)
        for block in blocks {
            let suffix = TimelineRenderer.projectSuffix(of: block, frames: frames, named: headings)
            #expect(suffix == (byBlock[block.id].map { " · \($0.label)" } ?? ""))
        }
        #expect(blocks.map { byBlock[$0.id]?.key } == ["acme", "beta", nil])

        let text = TimelineRenderer.render(
            day: day, blocks: blocks, frames: frames, projects: catalog, projectSpans: spans, timeZone: utc
        )
        #expect(text.contains(" · Acme Secret"))
        #expect(text.contains(" · Beta Hidden"))
        #expect(Set(stats.threads.map(\.project)) == ["Acme Secret", "Beta Hidden"])
    }

    @Test("a company meeting over hinted frames counts once, as the meeting, with #318's rule")
    func meetingCountsOnce() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: Array(repeating: "Acme Secret", count: 10))
        try store.meeting(from: 9, 5, minutes: 30, participants: ["ana@globex.example", "you@halyard.example"])
        let stats = try store.stats()
        let spans = try #require(stats.projectSpans)
        #expect(spans.map(\.kind) == [.screen, .meeting])
        let call = try #require(spans.last)
        #expect(call.project == "company:globex.example")
        #expect(call.rule == .meetingCompany)
        #expect(call.overridden == ["acme"])
        #expect(call.seconds == 30 * 60)

        let acme = try #require(stats.byProject.first { $0.key == "acme" })
        #expect(acme.minutes == 5)
        #expect(acme.meetingMinutes == nil)
        let globex = try #require(stats.byProject.first { $0.key == "company:globex.example" })
        #expect(globex.minutes == 0)
        #expect(globex.meetingRules == ["domain": 30])
        let shares = stats.byProject.reduce(0) { $0 + $1.share }
        #expect(abs(shares - 1) < 0.01)
    }

    @Test("a meeting with no company domain stays unattributed, split by #318's reason")
    func meetingWithoutCompany() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: ["Acme Secret", "Acme Secret"])
        try store.meeting(from: 10, 0, minutes: 20, participants: ["you@halyard.example"])
        let stats = try store.stats()
        #expect(stats.projectSpans?.last?.unattributed == .meetingWithoutCompany)
        let row = try #require(stats.byProject.first { $0.key == StatsAggregator.unattributedProjectKey })
        #expect(row.minutes == 0)
        #expect(row.meetingRules == ["no_company_domain": 20])
    }

    @Test("coverage --json names no project, title or address, only minutes and fixed words")
    func coverageCarriesNoNames() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: ["Acme Secret", "Beta Hidden", "Acme Secret", nil, nil])
        let report = ProjectSpanService.CoverageReport(try store.service.coverage(from: day, to: day))
        #expect(report.days == 1)
        #expect(report.spans.screenMinutes == 5)
        #expect(report.spans.screenAttributedMinutes == 3)
        #expect(report.spans.screenUnattributed == ["no_evidence": 2])
        #expect(report.spans.absorbed == 1)
        #expect(report.perFrame.screenAttributedMinutes == 3)
        #expect(report.perFrame.absorbed == 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(report), as: UTF8.self).lowercased()
        for secret in ["acme", "beta", "secret", "hidden", "quarterly", "example.com", "private", "xcode"] {
            #expect(!json.contains(secret), "\(secret)")
        }
    }

    @Test("a GitHub page whose repo is a catalog entry is resource-key evidence")
    func resourceKeyThroughRepo() {
        let frame = TimelineFrame(
            captureId: "f1", at: at(9, 0), appKey: "chrome", taskKey: "reviewing",
            url: "https://github.com/someone/acme-secret/pull/12"
        )
        let rows = ProjectSpanService.resourceEvidence(
            [frame], documentURLs: [:], claims: [:], catalog: catalog
        )
        #expect(rows == [ProjectSpans.Evidence(scope: .frame("f1"), project: "acme", name: "Acme Secret", rule: .resourceKey)])
        let claimed = ProjectSpanService.resourceEvidence(
            [frame], documentURLs: [:], claims: ["github.com/someone/acme-secret/pull/12": "beta"], catalog: catalog
        )
        #expect(claimed.map(\.project) == ["beta"])
    }

    @Test("a prompt you typed in a repo the catalog claims is agent_repo evidence and beats a hint")
    func agentRepoBeatsHint() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: Array(repeating: "Beta Hidden", count: 5))
        var write = AgentWrite()
        write.sessions = [AgentSession(
            id: "claude-1", tool: AgentStoreParsers.claudeCode, host: "claude-desktop",
            startAt: at(9, 0), endAt: at(9, 30), cwd: "/Users/me/code/acme", vcsRepo: "me/acme"
        )]
        write.prompts = [AgentPrompt(recordId: "p1", sessionId: "claude-1", at: at(9, 1))]
        _ = try AgentSessionStore(store.db).apply(write)
        _ = try AgentSessionStore(store.db).resolveRepos()
        try ForegroundSessionStore(store.db).insert(ForegroundSession(
            startAt: at(9, 0), endAt: at(9, 10), appBundleId: "com.anthropic.claudefordesktop"
        ))
        let spans = try #require(try store.stats().projectSpans)
        // The five hinted minutes; the Claude app's other five in front have no frame to cover.
        #expect(spans.first?.project == "acme")
        #expect(spans.first?.seconds == 300)
        #expect(spans.first?.rule == .agentRepo)
        #expect(spans.first?.overridden == ["beta"])
    }

    @Test("a shipped row's resource and project claim the page on screen, and two rows that disagree claim nothing")
    func resourceKeyThroughOutputs() throws {
        let store = try Store()
        let pull = "https://github.com/someone/widgets/pull/12"
        try store.screen(from: 9, 0, hints: Array(repeating: "Acme Secret", count: 3), url: pull)
        func shipped(_ id: String, project: String) throws {
            try OutputStore(store.db).upsert(Output(
                kind: .prMerged, at: at(8, 0), repo: "someone/widgets", number: 12, url: pull,
                title: "Fix the thing", resourceKey: "github.com/someone/widgets/pull/12", externalId: id,
                projectKey: project, provenance: "gh search prs", syncedAt: at(8, 0)
            ))
        }
        try shipped("pr12", project: "beta")
        let spans = try #require(try store.stats().projectSpans)
        #expect(spans.map(\.project) == ["beta"])
        #expect(spans.first?.rule == .resourceKey)

        try shipped("pr12-memo", project: "halyard")
        #expect(try store.stats().projectSpans?.map(\.rule) == [.projectHint])
    }

    @Test("a repo two entries match goes to the lowest key")
    func repoTieByKey() {
        let entries = [ProjectEntry(key: "zeta", name: "Widgets"), ProjectEntry(key: "alpha", name: "widgets")]
        #expect(ProjectSpanService.project(forRepo: "someone/widgets", in: entries)?.key == "alpha")
    }

    @Test("a week's and a range's project shares are of screen and meeting minutes, like a day's")
    func weekSharesCountMeetings() throws {
        let store = try Store()
        try store.screen(from: 9, 0, hints: Array(repeating: "Acme Secret", count: 10))
        try store.meeting(from: 11, 0, minutes: 30, participants: ["ana@globex.example", "you@halyard.example"])
        let service = StatsService(store.db, timeZone: utc, projects: { catalog }, now: { at(23, 0) })
        let daily = try service.daily(day: day).byProject
        let week = try service.weekly(try #require(ISOWeek.containing(dayString: day, timeZone: utc))).totals.byProject
        let range = try service.span(from: day, to: day).byProject
        for rows in [daily, week, range] {
            #expect(rows.first { $0.key == "acme" }.map { abs($0.share - 0.25) < 0.001 } == true)
            #expect(rows.first { $0.key == "company:globex.example" }.map { abs($0.share - 0.75) < 0.001 } == true)
        }
    }

    @Test("meeting time no synced meeting covers is meeting_without_company, not #318's reason")
    func unsyncedMeetingTime() {
        let span = ProjectSpan(start: at(9, 0), end: at(9, 30), kind: .meeting, unattributed: .meetingWithoutCompany)
        let synced = StatsAggregator.MeetingShare(
            company: MeetingCompany(key: nil, name: nil, rule: .noCompanyDomain), seconds: 1200,
            stretch: StatsAggregator.Stretch(start: at(9, 0), end: at(9, 20))
        )
        #expect(StatsAggregator.splitUnnamed(span, among: [synced]) == [
            "no_company_domain": 1200, "meeting_without_company": 600,
        ])
        #expect(StatsAggregator.splitUnnamed(span, among: []) == ["meeting_without_company": 1800])
    }
}
