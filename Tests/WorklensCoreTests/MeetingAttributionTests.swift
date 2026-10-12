import Foundation
import Testing
@testable import WorklensCore

// #318: which company each meeting counts toward, and the rule that said so.

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

/// `raw_json` the way the two sources store it: the calendar's `self` attendee, Granola's owner
/// and the calendar event a note was taken on.
private func calendarRaw(me: String = "you@halyard.example") -> String {
    #"{"attendees":[{"email":"\#(me)","self":true}]}"#
}

private func granolaRaw(me: String = "you@halyard.example", linkedTo: String? = nil) -> String {
    let link = linkedTo.map { #","calendar_event":{"calendar_event_id":"\#($0)"}"# } ?? ""
    return #"{"owner":{"email":"\#(me)"}\#(link)}"#
}

private func meeting(
    _ externalId: String,
    source: ContextSource = .calendar,
    from: Date = at(10),
    to: Date = at(11),
    title: String? = "Weekly sync",
    participants: [String] = [],
    linkedTo: String? = nil,
    isMeeting: Bool = true
) -> ContextEvent {
    ContextEvent(
        id: externalId, source: source, externalId: externalId, startAt: from, endAt: to, title: title,
        participantsJson: ContextEvent.encodeParticipants(participants),
        isMeeting: isMeeting,
        rawJson: source == .calendar ? calendarRaw() : granolaRaw(linkedTo: linkedTo)
    )
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-meetings-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let house = ProjectEntry(key: "halyard", name: "Halyard", kind: .house, domains: ["halyardcapital.example"])

// MARK: - Parsing

@Suite("Meeting participants and links (#318)")
struct MeetingFieldsTests {
    @Test("addresses come out of both participant shapes, and a bare name is skipped")
    func participantEmails() {
        let event = meeting("c1", participants: [
            "Ana@Acme.example (accepted)", "Bruno Lima <bruno@beta.example>", "carol@gamma.example", "Dana",
        ])
        #expect(event.participantEmails == ["ana@acme.example", "bruno@beta.example", "carol@gamma.example"])
    }

    @Test("a Granola note names its calendar event; a calendar row never does")
    func linkedEvent() {
        #expect(meeting("g1", source: .granola, linkedTo: "cal-9").linkedCalendarEventId == "cal-9")
        #expect(meeting("g2", source: .granola).linkedCalendarEventId == nil)
        #expect(meeting("c1").linkedCalendarEventId == nil)
    }
}

// MARK: - Rules

@Suite("MeetingAttribution rules (#318)")
struct MeetingAttributionRuleTests {
    private func answer(
        _ event: ContextEvent, catalog: [ProjectEntry] = [house], ignored: [String] = [],
        others: [ContextEvent] = []
    ) -> MeetingCompany? {
        MeetingAttribution.resolve([event] + others, catalog: catalog, ignoredDomains: ignored)[event.id]
    }

    @Test("one external domain names a company:<domain>, called by its first label")
    func domainRule() {
        let result = answer(meeting("c1", participants: ["you@halyard.example (accepted)", "ana@acme.example"]))
        #expect(result == MeetingCompany(key: "company:acme.example", name: "Acme", rule: .domain))
    }

    @Test("a written company entry lends its name to the domain rule")
    func domainRuleUsesTheEntryName() {
        let entry = ProjectEntry(key: "company:acme.example", name: "Acme Corp", kind: .company)
        let result = answer(meeting("c1", participants: ["ana@acme.example"]), catalog: [house, entry])
        #expect(result == MeetingCompany(key: "company:acme.example", name: "Acme Corp", rule: .domain))
    }

    @Test("a domain you put on an entry beats the domain rule, even beside another company")
    func yoursBeatsDomain() {
        let deal = ProjectEntry(key: "acme-deal", name: "Acme deal", kind: .company, domains: ["acme.example"])
        let alone = answer(meeting("c1", participants: ["ana@acme.example"]), catalog: [house, deal])
        #expect(alone == MeetingCompany(key: "acme-deal", name: "Acme deal", rule: .yours))
        let withLawyers = answer(
            meeting("c2", participants: ["ana@acme.example", "lee@lawfirm.example"]), catalog: [house, deal]
        )
        #expect(withLawyers?.rule == .yours)
        #expect(withLawyers?.key == "acme-deal")
    }

    @Test("your own, house, ignored, personal and room domains never count")
    func excludedDomainsNeverCount() {
        let event = meeting("c1", title: nil, participants: [
            "you@halyard.example (accepted)",
            "partner@halyardcapital.example",
            "friend@gmail.com",
            "c_123@resource.calendar.google.com",
            "someone@ignored.example",
        ])
        let result = answer(event, ignored: ["ignored.example"])
        #expect(result == MeetingCompany(key: nil, name: nil, rule: .noCompanyDomain))
    }

    @Test("subdomains count as their registrable domain, so one company is one company")
    func subdomainsCollapse() {
        let result = answer(meeting("c1", participants: ["ana@mail.acme.example", "bo@acme.example"]))
        #expect(result == MeetingCompany(key: "company:acme.example", name: "Acme", rule: .domain))
        let br = answer(meeting("c2", participants: ["ana@rio.acme.com.br"]))
        #expect(br?.key == "company:acme.com.br")
        #expect(MeetingAttribution.registrableDomain("acme.co.uk") == "acme.co.uk")
        #expect(MeetingAttribution.registrableDomain("a.b.acme.com") == "acme.com")
    }

    @Test("a note someone else owns hides their domain only on that note, never on other meetings")
    func ownerDomainIsPerEvent() {
        let shared = ContextEvent(
            id: "g1", source: .granola, externalId: "g1", startAt: at(14), endAt: at(15), title: nil,
            participantsJson: ContextEvent.encodeParticipants(["ana@acme.example"]), isMeeting: true,
            rawJson: granolaRaw(me: "ana@acme.example")
        )
        let call = meeting("c1", participants: ["ana@acme.example"])
        let result = answer(call, others: [shared])
        #expect(result == MeetingCompany(key: "company:acme.example", name: "Acme", rule: .domain))
    }

    @Test("two company domains and no title match give no answer")
    func severalCompanies() {
        let result = answer(meeting("c1", participants: ["ana@acme.example", "bo@beta.example"]))
        #expect(result == MeetingCompany(key: nil, name: nil, rule: .severalCompanies))
    }

    @Test("the title names one entry as whole words; two matches, short spellings and the house do not")
    func titleRule() {
        let riverbend = ProjectEntry(key: "riverbend", name: "Riverbend Capital", aliases: ["RB"])
        let meridian = ProjectEntry(key: "meridian", name: "Meridian")
        let catalog = [house, riverbend, meridian]
        let one = answer(meeting("c1", title: "Riverbend Capital: Q3 review"), catalog: catalog)
        #expect(one == MeetingCompany(key: "riverbend", name: "Riverbend Capital", rule: .title))
        #expect(answer(meeting("c2", title: "Riverbend Capital x Meridian"), catalog: catalog)?.key == nil)
        // "RB" is under three characters; "Riverbendy" is not the whole word.
        #expect(answer(meeting("c3", title: "RB sync"), catalog: catalog)?.key == nil)
        #expect(answer(meeting("c4", title: "Riverbendy Capitals"), catalog: catalog)?.key == nil)
        #expect(answer(meeting("c5", title: "Halyard offsite"), catalog: catalog)?.key == nil)
    }

    @Test("an unsettled Granola note takes its linked calendar event's company")
    func calendarEventRule() {
        let calendar = meeting("cal-1", participants: ["ana@acme.example"])
        let note = meeting("g1", source: .granola, title: "Untitled", linkedTo: "cal-1")
        let result = answer(note, others: [calendar])
        #expect(result == MeetingCompany(key: "company:acme.example", name: "Acme", rule: .calendarEvent))
        // A note with no link and no event under it keeps its own reason.
        let later = meeting("g2", source: .granola, from: at(14), to: at(15), title: "Untitled")
        #expect(answer(later, others: [calendar])?.rule == .noCompanyDomain)
    }

    @Test("an unlinked note takes the company of the event it is merged with (#340)")
    func unlinkedNoteTakesMergedEvent() {
        let calendar = meeting("cal-1", participants: ["ana@acme.example"])
        let note = meeting("g1", source: .granola, from: at(10, 15), to: at(10, 45), title: "Untitled")
        #expect(answer(note, others: [calendar])
            == MeetingCompany(key: "company:acme.example", name: "Acme", rule: .calendarEvent))
        // Half an overlap is not a merge.
        let half = meeting("g2", source: .granola, from: at(10, 30), to: at(11, 30), title: "Untitled")
        #expect(answer(half, others: [calendar])?.rule == .noCompanyDomain)
        // An event another note names is that note's, never a guess's.
        let linked = meeting("g3", source: .granola, title: "Untitled", linkedTo: "cal-1")
        #expect(answer(note, others: [calendar, linked])?.rule == .noCompanyDomain)
        // Two merged events with different companies give no company, and say why.
        let other = meeting("cal-2", participants: ["bo@beta.example"])
        #expect(answer(note, others: [calendar, other])
            == MeetingCompany(key: nil, name: nil, rule: .severalCompanies))
        // A declined invite or an all-day row is not a meeting dedupe reads: it neither names
        // the note nor blocks the company of a meeting dedupe does merge.
        let declined = meeting("cal-3", participants: ["cy@gamma.example"], isMeeting: false)
        let allDay = meeting("cal-4", from: at(0), to: at(23, 59), participants: ["di@delta.example"],
                             isMeeting: false)
        #expect(answer(note, others: [declined, allDay])?.rule == .noCompanyDomain)
        #expect(ContextBlocks.deduplicate([note, other, declined, allDay].filter(\.isMeeting)).map(\.id)
            == ["g1"])
        #expect(answer(note, others: [other, declined, allDay])
            == MeetingCompany(key: "company:beta.example", name: "Beta", rule: .calendarEvent))
    }

    @Test("non-meetings get no answer")
    func nonMeetingsAreSkipped() {
        let reminder = meeting("c1", participants: ["ana@acme.example"], isMeeting: false)
        #expect(answer(reminder) == nil)
    }
}

// MARK: - Catalog

@Suite("Meeting companies in the catalog (#318)")
struct MeetingCatalogTests {
    private func catalog() throws -> (ProjectCatalog, TaxonomyStore, Database, URL) {
        let dir = tempDir()
        let db = try Database(dataDir: dir)
        let store = try TaxonomyStore(dataDir: dir)
        var taxonomy = store.current
        taxonomy.projects = [house]
        try store.save(taxonomy)
        let events = ContextEventStore(db)
        try events.upsert(meeting("c1", participants: ["you@halyard.example", "ana@acme.example"]))
        try events.upsert(meeting("c2", from: at(14), to: at(15), title: "Intro",
                                  participants: ["ana@beta.example", "lee@gamma.example"]))
        return (ProjectCatalog(db: db, taxonomy: store, timeZone: utc), store, db, dir)
    }

    @Test("learn --dry-run adds a company from a single-domain meeting only, and writes nothing")
    func learnAddsCompanies() throws {
        let (catalog, store, _, dir) = try catalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let change = try catalog.preview(upTo: day)
        #expect(change.addedProjects == [
            ProjectEntry(key: "company:acme.example", name: "Acme", kind: .company),
        ])
        #expect(store.projects == [house])
        try catalog.learn(upTo: day)
        #expect(store.projects.map(\.key) == ["halyard", "company:acme.example"])
        #expect(try catalog.preview(upTo: day).isEmpty)
    }

    @Test("a domain whose name a project already answers to is suggested as a merge, not added")
    func learnSuggestsMergeIntoExistingEntry() throws {
        let (catalog, store, db, dir) = try catalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        var taxonomy = store.current
        taxonomy.projects = [house, ProjectEntry(key: "acme", name: "Acme")]
        try store.save(taxonomy)
        let change = try catalog.preview(upTo: day)
        #expect(change.addedProjects.isEmpty)
        #expect(change.suggestedMerges == [ProjectCatalog.SuggestedMerge(key: "company:acme.example", into: "acme")])
        try catalog.learn(upTo: day)
        #expect(store.projects.map(\.key) == ["halyard", "acme"])

        // The suggested merge works though no company:acme.example entry was written.
        try catalog.merge(key: "company:acme.example", into: "acme")
        #expect(store.projects.first { $0.key == "acme" }?.domains == ["acme.example"])
        let events = try ContextEventStore(db).fetch(from: at(0), to: at(23, 59))
        #expect(MeetingAttribution.resolve(events, taxonomy: store.current)["c1"]
            == MeetingCompany(key: "acme", name: "Acme", rule: .yours))
        #expect(try catalog.preview(upTo: day).suggestedMerges.isEmpty)
    }

    @Test("a domain that only compacts to a memo-created entry's spelling is suggested as a merge")
    func learnSuggestsMergeIntoMemoEntry() throws {
        let (catalog, store, db, dir) = try catalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ContextEventStore(db).upsert(meeting("c3", from: at(16), to: at(17), title: "Catch-up",
                                                 participants: ["you@halyard.example", "bo@acmecorp.example"]))
        var taxonomy = store.current
        taxonomy.projects = [
            house, ProjectEntry(key: "acme", name: "Acme"),
            ProjectEntry(key: "acme corp", name: "Acme Corp", aliases: ["acme-corp"], kind: .company),
        ]
        try store.save(taxonomy)
        let change = try catalog.preview(upTo: day)
        #expect(change.addedProjects.isEmpty)
        #expect(change.suggestedMerges.contains(
            ProjectCatalog.SuggestedMerge(key: "company:acmecorp.example", into: "acme corp")
        ))
    }

    @Test("merge makes a company's domain yours; forget stops it counting and learning")
    func mergeAndForget() throws {
        let (catalog, store, db, dir) = try catalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        try catalog.learn(upTo: day)
        var taxonomy = store.current
        taxonomy.projects = (taxonomy.projects ?? []) + [ProjectEntry(key: "acme-deal", name: "Acme deal")]
        try store.save(taxonomy)

        try catalog.merge(key: "company:acme.example", into: "acme-deal")
        #expect(store.projects.first { $0.key == "acme-deal" }?.domains == ["acme.example"])
        let events = try ContextEventStore(db).fetch(from: at(0), to: at(23, 59))
        let merged = MeetingAttribution.resolve(events, taxonomy: store.current)
        #expect(merged["c1"] == MeetingCompany(key: "acme-deal", name: "Acme deal", rule: .yours))

        // A fresh company entry, forgotten: its domain is ignored from then on.
        var reset = store.current
        reset.projects = [house, ProjectEntry(key: "company:acme.example", name: "Acme", kind: .company)]
        try store.save(reset)
        try catalog.forget(key: "company:acme.example")
        #expect(store.current.ignoredDomains == ["acme.example"])
        let forgotten = MeetingAttribution.resolve(events, taxonomy: store.current)
        #expect(forgotten["c1"]?.rule == .noCompanyDomain)
        #expect(try catalog.preview(upTo: day).addedProjects.isEmpty)
    }

    @Test("an old taxonomy.json decodes; domains round-trip; a domain claimed twice is refused")
    func schema() throws {
        let old = #"{"version": 1, "apps": [], "universal_tasks": [], "projects": [{"key": "acme", "name": "Acme"}]}"#
        let decoded = try Taxonomy.decode(Data(old.utf8))
        #expect(decoded.ignoredDomains == nil)
        #expect(decoded.projectList.first?.domains == nil)

        var taxonomy = Taxonomy.seed
        taxonomy.projects = [ProjectEntry(key: "acme", name: "Acme", domains: ["acme.example"])]
        taxonomy.ignoredDomains = ["noise.example"]
        let data = try Taxonomy.encoder().encode(taxonomy)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""ignored_domains""#))
        #expect(try Taxonomy.decode(data) == taxonomy)
        #expect(taxonomy.validationProblems().isEmpty)

        taxonomy.projects?.append(ProjectEntry(key: "beta", name: "Beta", domains: ["ACME.example"]))
        #expect(taxonomy.validationProblems().contains {
            $0 == #"domain "acme.example" is claimed by both "acme" and "beta""#
        })
    }
}

// MARK: - Stats

@Suite("Meeting minutes by project (#318)")
struct MeetingStatsTests {
    private let blocks = [
        ActivityBlock(day: day, startAt: at(9), endAt: at(10), appKey: "code", taskKey: "working", source: .screen),
    ]
    private let captures = [
        Capture(id: "f1", capturedAt: at(9, 10), appName: "Code", describeStatus: .described),
        Capture(id: "f2", capturedAt: at(9, 40), appName: "Code", describeStatus: .described),
    ]
    private let hints = ["f1": "worklens", "f2": "worklens"]

    private func stats(_ events: [ContextEvent]) -> DailyStats {
        StatsAggregator.daily(
            day: day, blocks: blocks, captures: captures, contextEvents: events,
            projectHints: hints, projects: [house], timeZone: utc
        )
    }

    @Test("a company with no frames gets a row at minutes 0, and existing rows do not move")
    func meetingOnlyCompany() {
        let before = stats([])
        let after = stats([
            meeting("c1", participants: ["ana@acme.example"]),
            meeting("c2", from: at(12), to: at(12, 30), title: nil, participants: ["a@b1.example", "c@d2.example"]),
            meeting("c3", from: at(13), to: at(13, 15), title: nil),
        ])
        let acme = after.byProject.first { $0.key == "company:acme.example" }
        #expect(acme?.minutes == 0)
        #expect(acme?.share == 0)
        #expect(acme?.meetingMinutes == 60)
        #expect(acme?.meetingRules == ["domain": 60])
        let worklens = after.byProject.first { $0.key == "worklens" }
        #expect(worklens == before.byProject.first { $0.key == "worklens" })
        let unattributed = after.byProject.first { $0.key == StatsAggregator.unattributedProjectKey }
        #expect(unattributed?.minutes == 0)
        #expect(unattributed?.meetingRules == ["several_companies": 30, "no_company_domain": 15])
        #expect(unattributed?.meetingMinutes == 45)
    }

    @Test("a double booking is counted once, and every row's rules sum to its meeting minutes")
    func unionNotSum() {
        let after = stats([
            meeting("c1", participants: ["ana@acme.example"]),
            meeting("c2", from: at(10, 30), to: at(11, 30), participants: ["bo@beta.example"]),
            meeting("g1", source: .granola, from: at(10, 2), to: at(10, 58), linkedTo: "c1"),
        ])
        let rows = Dictionary(uniqueKeysWithValues: after.byProject.map { ($0.key, $0) })
        // The note joins its event and wins (10:02-10:58), taking the event's company; the
        // double-booked call keeps only the 32 minutes the note did not already cover.
        #expect(rows["company:acme.example"]?.meetingRules == ["calendar_event": 56])
        #expect(rows["company:beta.example"]?.meetingMinutes == 32)
        let total = after.byProject.compactMap(\.meetingMinutes).reduce(0, +)
        #expect(total == 88, "the union of 10:02-11:30")
        for row in after.byProject where row.meetingMinutes != nil {
            #expect(row.meetingRules?.values.reduce(0, +) == row.meetingMinutes)
        }
    }

    @Test("a day with meetings and no project-named frames still counts its screen time as unattributed")
    func unattributedWithoutNamedFrames() {
        let result = StatsAggregator.daily(
            day: day, blocks: blocks, captures: captures,
            contextEvents: [meeting("c1", from: at(12), to: at(13), participants: ["ana@acme.example"])],
            projectHints: [:], projects: [house], timeZone: utc
        )
        let unattributed = result.byProject.first { $0.key == StatsAggregator.unattributedProjectKey }
        #expect(unattributed?.minutes == 60)
        #expect(result.byProject.first { $0.key == "company:acme.example" }?.meetingMinutes == 60)
    }

    @Test("span adds the meeting fields up across days")
    func spanSums() {
        let first = [Slice(key: "acme", name: "Acme", minutes: 10, share: 1, meetingMinutes: 30,
                           meetingRules: ["domain": 30])]
        let second = [Slice(key: "acme", name: "Acme", minutes: 0, share: 0, meetingMinutes: 20,
                            meetingRules: ["domain": 5, "title": 15])]
        let merged = StatsService.merge([first, second])
        #expect(merged.first?.minutes == 10)
        #expect(merged.first?.meetingMinutes == 50)
        #expect(merged.first?.meetingRules == ["domain": 35, "title": 15])
        let week = StatsAggregator.merge([first, second], limit: 8, total: 10)
        #expect(week.first?.meetingMinutes == 50)
        #expect(week.first?.meetingRules == ["domain": 35, "title": 15])
    }
}

// MARK: - MCP

@Suite("context_events companies (#318)")
struct MeetingCompanyMCPTests {
    private func call(_ extra: [String: JSONValue] = [:]) throws -> String {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(dataDir: dir)
        let store = try TaxonomyStore(dataDir: dir)
        var taxonomy = store.current
        taxonomy.projects = [house, ProjectEntry(key: "company:acme.example", name: "Acme", kind: .company)]
        try store.save(taxonomy)
        let events = ContextEventStore(db)
        try events.upsert(meeting("c1", title: "Acme intro", participants: ["ana@acme.example"]))
        try events.upsert(meeting("c2", from: at(14), to: at(15), title: "Team", participants: []))
        var arguments: [String: JSONValue] = ["from": .string(day), "to": .string(day)]
        arguments.merge(extra) { $1 }
        return try WorklensMCPTools.contextEventsTool(db: db, taxonomy: store, timeZone: utc)
            .handler(.object(arguments))
    }

    @Test("each meeting says its company and rule")
    func showsCompany() throws {
        let out = try call()
        #expect(out.contains("  company: Acme · rule: domain"))
        #expect(out.contains("  company: none · rule: no_company_domain"))
    }

    @Test("the company filter takes a key, a name, a domain or none")
    func filters() throws {
        for filter in ["company:acme.example", "acme", "acme.example"] {
            let out = try call(["company": .string(filter)])
            #expect(out.contains("Acme intro"))
            #expect(!out.contains("Team"))
        }
        let none = try call(["company": .string("none")])
        #expect(none.contains("Team"))
        #expect(!none.contains("Acme intro"))
        #expect(try call(["company": .string("beta")]).hasPrefix("No meetings counted toward beta"))
    }

    @Test("an empty none reads as meetings without a company")
    func emptyNone() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(dataDir: dir)
        let store = try TaxonomyStore(dataDir: dir)
        try ContextEventStore(db).upsert(meeting("c1", participants: ["ana@acme.example"]))
        let out = try WorklensMCPTools.contextEventsTool(db: db, taxonomy: store, timeZone: utc)
            .handler(.object(["from": .string(day), "to": .string(day), "company": .string("none")]))
        #expect(out.hasPrefix("No meetings without a company between"))
    }

    @Test("a domain filter finds meetings settled by the yours rule after a merge")
    func domainFilterAfterMerge() {
        let acme = ProjectEntry(key: "acme", name: "Acme", domains: ["acme.example"])
        let company = MeetingCompany(key: "acme", name: "Acme", rule: .yours)
        #expect(WorklensMCPTools.companyMatches(company, "acme.example", projects: [house, acme]))
        #expect(WorklensMCPTools.companyMatches(company, "ACME.example", projects: [house, acme]))
        #expect(!WorklensMCPTools.companyMatches(company, "beta.example", projects: [house, acme]))
    }
}
