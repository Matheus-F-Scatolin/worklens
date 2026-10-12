import Foundation
import Testing
@testable import WorklensCore

// #324: a rule or an assignment, previewed through the allocator and then saved.

private let utc = TimeZone(identifier: "UTC")!
private let yesterday = "2026-09-09"
private let dayStart = DayBoundaries.range(day: yesterday, timeZone: utc)!.start
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}
/// Noon the day after: yesterday is whole and every assignment in it has passed.
private let today = at(36, 0)

/// A data directory with a taxonomy and a database, yesterday holding ten unhinted frames on
/// `app.acme.com` from 9:00 and a 30-minute call with someone at acme.com from 11:00.
private struct Fixture {
    let dir: URL
    let db: Database
    let taxonomy: TaxonomyStore

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("worklens-corrections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try Database(dataDir: dir)
        taxonomy = try TaxonomyStore(dataDir: dir)
        var seeded = taxonomy.current
        seeded.projects = [
            ProjectEntry(key: "acme", name: "Acme Secret"),
            ProjectEntry(key: "beta", name: "Beta Hidden"),
            ProjectEntry(key: "halyard", name: "Halyard", kind: .house, domains: ["halyard.example"]),
        ]
        try taxonomy.save(seeded)

        for offset in 0..<10 {
            let capture = Capture(
                capturedAt: at(9, offset), appName: "Safari", windowTitle: "Deal room",
                browserUrl: "https://app.acme.com/deal/\(offset)?token=secret", intervalSeconds: 60,
                describeStatus: .described
            )
            try CaptureStore(db).insert(capture)
            try DescriptionStore(db).insert(Description(
                captureId: capture.id, provider: "gemini", model: "test", appKey: "safari",
                taskKey: "reading", summaryMd: "Reads a page.", detailsJson: nil
            ))
        }
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: yesterday, startAt: at(9, 0), endAt: at(9, 10), appKey: "safari", taskKey: "reading",
            captureCount: 10, source: .screen
        ))
        try ContextEventStore(db).upsert(ContextEvent(
            id: "call", source: .calendar, externalId: "call", startAt: at(11, 0), endAt: at(11, 30),
            title: "Weekly sync",
            participantsJson: ContextEvent.encodeParticipants(["ana@acme.com", "you@halyard.example"]),
            isMeeting: true, rawJson: #"{"attendees":[{"email":"you@halyard.example","self":true}]}"#
        ))
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: yesterday, startAt: at(11, 0), endAt: at(11, 30), appKey: "calendar", taskKey: "meeting",
            source: .calendar
        ))
    }

    var corrector: ProjectCorrector { ProjectCorrector(db: db, taxonomy: taxonomy, timeZone: utc, now: { today }) }

    var spans: [ProjectSpan] {
        get throws {
            let service = ProjectSpanService(db, timeZone: utc, projects: { taxonomy.projects }, now: { today })
            return try service.spans(day: yesterday) ?? []
        }
    }

    func minutes(on project: String?) throws -> Int {
        Int((try spans.filter { $0.project == project }.reduce(0) { $0 + $1.seconds } / 60).rounded())
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Project corrections (#324)")
struct ProjectCorrectionsTests {
    @Test("a domain rule moves yesterday's screen and meeting minutes; the dry run writes nothing and saving reports the same")
    func domainRuleMovesYesterday() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.minutes(on: "acme") == 0)

        let dry = try fixture.corrector.addRule(.domain, "www.acme.com", project: "Acme Secret", dryRun: true)
        #expect(dry.saved == false)
        #expect(dry.change == .init(action: "rule add", project: "acme", kind: .domain, value: "acme.com"))
        #expect(dry.preview.minutesMoved == 40)
        #expect(dry.preview.days == [yesterday])
        #expect(dry.preview.daysChecked == 2)
        #expect(dry.preview.to == [.init(project: "acme", name: "Acme Secret", minutes: 40)])
        #expect(dry.preview.from.reduce(0) { $0 + $1.minutes } == 40)
        #expect(dry.preview.from.contains(.init(project: nil, name: "Unattributed", minutes: 10)))
        // Nothing written: the catalog and the spans are as they were.
        #expect(fixture.taxonomy.projects.first { $0.key == "acme" }?.domains == nil)
        #expect(try fixture.minutes(on: "acme") == 0)
        let text = ProjectCorrections.lines(dry, timeZone: utc)
        #expect(text.first == "rule      --domain acme.com on acme")
        #expect(text.contains("minutes   would move 40 min on 1 day, of 2 checked"))
        #expect(text.contains("to        Acme Secret  40 min"))
        #expect(text.last == "status    dry run, nothing written")
        #expect(!text.contains { $0.hasPrefix("agent") })
        // A repo rule also moves the timesheet's agent column, which the preview does not count.
        let repo = ProjectCorrections.Report(
            change: .init(action: "rule add", project: "acme", kind: .repo, value: "me/widgets"),
            preview: dry.preview, saved: false
        )
        #expect(ProjectCorrections.lines(repo, timeZone: utc).contains(
            "agent     agent minutes in this repo move with it too; not counted above"))

        let saved = try fixture.corrector.addRule(.domain, "www.acme.com", project: "Acme Secret", dryRun: false)
        #expect(saved.saved)
        #expect(saved.preview == dry.preview)
        #expect(ProjectCorrections.lines(saved, timeZone: utc).last == "status    saved")
        #expect(fixture.taxonomy.projects.first { $0.key == "acme" }?.domains == ["acme.com"])
        #expect(try fixture.minutes(on: "acme") == 40)
        let rules = Set(try fixture.spans.filter { $0.project == "acme" }.map(\.rule))
        #expect(rules.isSubset(of: [.ruleDomain, .meetingCompany]))

        // The same rule again moves nothing; removing it moves the minutes back.
        #expect(try fixture.corrector.addRule(.domain, "acme.com", project: "acme", dryRun: true).preview.minutesMoved == 0)
        let removal = try fixture.corrector.removeRule(.domain, "acme.com", dryRun: false)
        #expect(removal.preview.minutesMoved == 40)
        #expect(try fixture.minutes(on: "acme") == 0)
    }

    @Test("a domain rule written after forgetting that company still moves its meetings")
    func domainRuleAfterForget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var seeded = fixture.taxonomy.current
        seeded.projects = (seeded.projects ?? []) + [ProjectEntry(key: "company:acme.com", name: "Acme.com", kind: .company)]
        try fixture.taxonomy.save(seeded)
        try ProjectCatalog(db: fixture.db, taxonomy: fixture.taxonomy, timeZone: utc).forget(key: "company:acme.com")
        #expect(fixture.taxonomy.current.ignoredDomains == ["acme.com"])

        let dry = try fixture.corrector.addRule(.domain, "acme.com", project: "acme", dryRun: true)
        #expect(dry.preview.minutesMoved == 40)
        _ = try fixture.corrector.addRule(.domain, "acme.com", project: "acme", dryRun: false)
        let service = ProjectSpanService(
            fixture.db, timeZone: utc, projects: { fixture.taxonomy.projects },
            ignoredDomains: { fixture.taxonomy.current.ignoredDomains ?? [] }, now: { today }
        )
        let meeting = try (service.spans(day: yesterday) ?? []).filter { $0.start >= at(11, 0) && $0.end <= at(11, 30) }
        #expect(!meeting.isEmpty)
        #expect(meeting.allSatisfy { $0.project == "acme" && $0.rule == .ruleDomain })
    }

    @Test("a URL prefix rule keeps no query, and moves only the frames it covers")
    func urlPrefixRule() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try fixture.corrector.addRule(
            .urlPrefix, "https://app.acme.com/deal/3?token=secret", project: "beta", dryRun: false
        )
        #expect(report.change.value == "app.acme.com/deal/3")
        #expect(report.preview.minutesMoved == 1)
        #expect(!String(decoding: try fixture.taxonomy.encodedForTest(), as: UTF8.self).contains("token"))
    }

    @Test("an assignment beats a rule, and the newer overlapping one wins")
    func assignmentBeatsRule() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.corrector.addRule(.domain, "acme.com", project: "acme", dryRun: false)

        let first = try fixture.corrector.assign(from: at(9, 0), to: at(9, 6), project: "beta", dryRun: false)
        #expect(first.preview.minutesMoved == 6)
        #expect(first.preview.from == [.init(project: "acme", name: "Acme Secret", minutes: 6)])
        #expect(try fixture.minutes(on: "beta") == 6)
        #expect(try fixture.spans.first { $0.project == "beta" }?.rule == .assignment)

        let second = try fixture.corrector.assign(from: at(9, 4), to: at(9, 8), project: "acme", dryRun: false)
        #expect(second.preview.minutesMoved == 2)
        #expect(try fixture.minutes(on: "beta") == 4)
        #expect(try fixture.minutes(on: "acme") == 36)

        let back = try fixture.corrector.unassign(id: second.change.assignment!.id, dryRun: true)
        #expect(back.preview.minutesMoved == 2)
        #expect(try ProjectAssignmentStore(fixture.db).all().count == 2)
    }

    @Test("idle, locked and asleep minutes never move: an assignment over the whole morning moves only what was covered")
    func uncoveredTimeNeverMoves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dry = try fixture.corrector.assign(from: at(7, 0), to: at(12, 0), project: "beta", dryRun: true)
        #expect(dry.preview.minutesMoved == 40)
        #expect(dry.preview.days == [yesterday])
        #expect(dry.preview.daysChecked == 1)
        #expect(dry.change.assignment?.id == 1)
        #expect(try ProjectAssignmentStore(fixture.db).all().isEmpty)
        let text = ProjectCorrections.lines(dry, timeZone: utc)
        #expect(text.first == "assign    2026-09-09 07:00 to 2026-09-09 12:00 on beta")

        let saved = try fixture.corrector.assign(from: at(7, 0), to: at(12, 0), project: "beta", dryRun: false)
        #expect(saved.preview == dry.preview)
        #expect(ProjectCorrections.lines(saved, timeZone: utc).first?.hasSuffix("on beta (id 1)") == true)
    }

    @Test("an empty or future range, an unknown project and an unknown id are refused before anything is written")
    func refusals() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corrector = fixture.corrector
        #expect(throws: ProjectCorrectionError.emptyRange) {
            try corrector.assign(from: at(9, 0), to: at(9, 0), project: "acme", dryRun: false)
        }
        #expect(throws: ProjectCorrectionError.futureEnd) {
            try corrector.assign(from: at(9, 0), to: today.addingTimeInterval(60), project: "acme", dryRun: false)
        }
        #expect(throws: ProjectCatalogError.unknownProject("gamma")) {
            try corrector.assign(from: at(9, 0), to: at(10, 0), project: "gamma", dryRun: false)
        }
        #expect(throws: ProjectCorrectionError.unknownAssignment(7)) { try corrector.unassign(id: 7, dryRun: false) }
        _ = try corrector.addRule(.domain, "acme.com", project: "acme", dryRun: false)
        #expect(throws: ProjectCatalogError.ruleTaken("acme.com", "acme")) {
            try corrector.addRule(.domain, "acme.com", project: "beta", dryRun: true)
        }
        #expect(try ProjectAssignmentStore(fixture.db).all().isEmpty)
    }

    @Test("rule list prints every rule and assignment, and a hint when there are none")
    func ruleList() throws {
        let empty = ProjectCorrections.lines(ProjectCorrections.ruleList([], assignments: []), timeZone: utc)
        #expect(empty.count == 5)
        #expect(empty[1].contains("rule add --domain"))
        let list = ProjectCorrections.ruleList(
            [
                ProjectEntry(key: "beta", name: "Beta", rules: ProjectRules(repos: ["beta/api"])),
                ProjectEntry(key: "acme", name: "Acme", domains: ["acme.com"], rules: ProjectRules(urlPrefixes: ["notion.so/acme"])),
            ],
            assignments: [ProjectAssignment(id: 3, from: at(9, 0), to: at(10, 0), projectKey: "acme", createdAt: today)]
        )
        #expect(list.rules.map(\.value) == ["acme.com", "notion.so/acme", "beta/api"])
        #expect(ProjectCorrections.lines(list, timeZone: utc) == [
            "Rules",
            "  acme  --domain acme.com",
            "  acme  --url-prefix notion.so/acme",
            "  beta  --repo beta/api",
            "",
            "Assignments",
            "  3  2026-09-09 09:00 to 2026-09-09 10:00  acme",
        ])
    }

    @Test("the preview counts a slice only when its project changes, in whole minutes")
    func previewDiff() {
        func span(_ project: String?, _ from: Int, _ to: Int) -> ProjectSpan {
            ProjectSpan(
                start: at(9, from), end: at(9, to), kind: .screen, project: project,
                name: project.map { $0.uppercased() }, rule: project == nil ? nil : .projectHint,
                unattributed: project == nil ? .noEvidence : nil
            )
        }
        let preview = ProjectCorrections.preview([
            .init(day: yesterday, before: [span("a", 0, 10), span(nil, 10, 20)], after: [span("a", 0, 5), span("b", 5, 20)]),
            .init(day: "2026-09-10", before: [span("a", 0, 10)], after: [span("a", 0, 10)]),
        ])
        #expect(preview.minutesMoved == 15)
        #expect(preview.days == [yesterday])
        #expect(preview.daysChecked == 2)
        #expect(preview.from == [
            .init(project: nil, name: "Unattributed", minutes: 10), .init(project: "a", name: "A", minutes: 5),
        ])
        #expect(preview.to == [.init(project: "b", name: "B", minutes: 15)])
    }

    @Test("the minutes moved are the sum of the rounded shares they went to")
    func previewTotalMatchesShares() {
        func span(_ project: String?, _ from: Double, _ to: Double) -> ProjectSpan {
            ProjectSpan(
                start: at(9, 0).addingTimeInterval(from), end: at(9, 0).addingTimeInterval(to), kind: .screen,
                project: project, name: project?.uppercased(), rule: project == nil ? nil : .projectHint,
                unattributed: project == nil ? .noEvidence : nil
            )
        }
        // 40 s to each of two projects: each share rounds to 1 min, so the headline is 2, not 1.
        let preview = ProjectCorrections.preview([
            .init(day: yesterday, before: [span(nil, 0, 80)], after: [span("a", 0, 40), span("b", 40, 80)]),
        ])
        #expect(preview.to.map(\.minutes) == [1, 1])
        #expect(preview.minutesMoved == 2)
    }
}

private extension TaxonomyStore {
    func encodedForTest() throws -> Data { try Taxonomy.encoder().encode(current) }
}
