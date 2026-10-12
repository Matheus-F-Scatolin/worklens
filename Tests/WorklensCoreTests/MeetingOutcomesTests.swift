import Foundation
import Testing
@testable import WorklensCore

private func parse(_ markdown: String, owner: String? = "Oat Benson") -> MeetingOutcomes {
    MeetingOutcomes.parse(summaryMarkdown: markdown, youName: owner)
}

/// A summary whose next steps start well past `body_md`'s 2,000 characters, as most do.
private let longSummary: String = {
    let filler = (1...40).map { "- Discussion point \($0): the team walked through the numbers again." }
    return (["# Quarterly review", "", "## Notes"] + filler + [
        "", "## Next steps", "- Oat sends the revised deck by Friday", "- Ana books the follow-up call",
        "", "Chat with meeting transcript: https://notes.granola.ai/d/abc",
    ]).joined(separator: "\n")
}()

// MARK: - Parser

@Suite("MeetingOutcomes parser")
struct MeetingOutcomesParserTests {
    @Test("an English H1 Next steps section becomes one item per bullet")
    func englishH1() {
        let outcomes = parse("""
            # Next steps
            - Send the deck to Ana
            - Book the follow-up call
            """)
        #expect(outcomes.nextSteps.map(\.text) == ["Send the deck to Ana", "Book the follow-up call"])
        #expect(outcomes.decisions.isEmpty)
        #expect(outcomes.v == MeetingOutcomes.parserVersion)
    }

    @Test("a pt-BR H3 Próximos passos section is found, whatever its emphasis and colon")
    func portugueseH3() {
        let outcomes = parse("""
            ### Resumo
            - Revisamos o orçamento
            ### **Próximos Passos:**
            - Ana revisa os números
            - Bruno envia o contrato
            """)
        #expect(outcomes.nextSteps.map(\.text) == ["Ana revisa os números", "Bruno envia o contrato"])
    }

    @Test("a section that starts past character 2,000 is still read in full")
    func pastTheCut() {
        #expect(longSummary.count > ContextBody.inlineLimit + 200)
        #expect(!(ContextBody.inline(longSummary) ?? "").contains("revised deck"))
        let outcomes = parse(longSummary)
        #expect(outcomes.nextSteps.map(\.text)
            == ["Oat sends the revised deck by Friday", "Ana books the follow-up call"])
    }

    @Test("continuation lines and nested bullets go into detail")
    func continuation() {
        let outcomes = parse("""
            ## Next steps
            - Send the deck
              by Friday, with the Q3 tab
              - Include the cohort chart
            - Book a call
            """)
        #expect(outcomes.nextSteps.count == 2)
        #expect(outcomes.nextSteps[0].text == "Send the deck")
        #expect(outcomes.nextSteps[0].detail == "by Friday, with the Q3 tab; Include the cohort chart")
        #expect(outcomes.nextSteps[1].detail == nil)
    }

    @Test("a deeper heading stays inside the section and names its items")
    func deeperHeading() {
        let outcomes = parse("""
            ## Next steps
            ### Oat
            - Send the deck
            ### Ana
            - Review the model
            ## Notes
            - Not a next step
            """)
        #expect(outcomes.nextSteps.map(\.text) == ["Oat: Send the deck", "Ana: Review the model"])
        #expect(outcomes.nextSteps.map(\.namesYou) == [true, false])
    }

    @Test("a flush line that is not a bullet ends the section")
    func footer() {
        let outcomes = parse("""
            ## Next steps
            - Send the deck

            Chat with meeting transcript: [link](https://notes.granola.ai/d/abc)
            - Not a next step
            """)
        #expect(outcomes.nextSteps.map(\.text) == ["Send the deck"])
    }

    @Test("a bare Name: bullet turns its children into items")
    func nameBullets() {
        let outcomes = parse("""
            ## Action items
            - **Oat:**
              - Send the deck
                - with the appendix
              - Book the call
            - Ana:
              - Review the numbers
            """)
        #expect(outcomes.nextSteps.map(\.text)
            == ["Oat: Send the deck", "Oat: Book the call", "Ana: Review the numbers"])
        #expect(outcomes.nextSteps[0].detail == "with the appendix")
        #expect(outcomes.nextSteps.map(\.namesYou) == [true, true, false])
    }

    @Test("decisions are their own list")
    func decisions() {
        let outcomes = parse("""
            ## Decisions
            - Ship the strawberry tier.
            ## Next steps
            - Tell the team
            #### Decisões
            1. Manter o preço
            """)
        #expect(outcomes.decisions.map(\.text) == ["Ship the strawberry tier.", "Manter o preço"])
        #expect(outcomes.nextSteps.map(\.text) == ["Tell the team"])
    }

    @Test("a heading that only starts with \"decision\" is not a decisions section")
    func decisionMakers() {
        let outcomes = parse("""
            ## Decision makers
            - Ana, the CFO
            ## Decision-making process
            - Board sign-off
            ## Decisions made
            - Keep the price
            """)
        #expect(outcomes.decisions.map(\.text) == ["Keep the price"])
    }

    @Test("a deeper heading that reads like a section stays a group inside the open one")
    func nestedMatchingHeading() {
        let outcomes = parse("""
            ## Next steps
            ### Follow-up with Ana
            - Ana books the room
            ### Oat
            - Oat sends the deck
            ## Notes
            - Not a step
            """)
        #expect(outcomes.nextSteps.map(\.text)
            == ["Follow-up with Ana: Ana books the room", "Oat: Oat sends the deck"])
    }

    @Test("a summary with no heading gives empty arrays, not nil")
    func noHeading() throws {
        let outcomes = parse("# Weekly sync\n- We talked about the budget.")
        #expect(outcomes.isEmpty)
        #expect(MeetingOutcomes.parse(summaryMarkdown: nil, youName: nil).isEmpty)
        let json = try #require(outcomes.encoded)
        #expect(json.contains(#""nextSteps":[]"#))
        #expect(MeetingOutcomes.decode(json) == outcomes)
    }

    @Test("an item names you by your first name, full name, \"you\" or \"você\", as whole words")
    func namesYou() {
        let outcomes = parse("""
            ## Next steps
            - Você manda o contrato
            - You send the deck
            - Oat Benson books the room
            - Ana sends your notes to Youssef
            - Oatmeal for everyone
            """)
        #expect(outcomes.nextSteps.map(\.namesYou) == [true, true, true, false, false])
        let noOwner = parse("## Next steps\n- Oat books the room", owner: nil)
        #expect(noOwner.nextSteps.map(\.namesYou) == [false])
    }

    @Test("items, text and detail are capped")
    func caps() {
        let bullets = (1...20).map { "- Step \($0)" }.joined(separator: "\n")
        let long = String(repeating: "a", count: 500)
        let detail = String(repeating: "b", count: 1000)
        let outcomes = parse("## Next steps\n- \(long)\n  \(detail)\n" + bullets)
        #expect(outcomes.nextSteps.count == MeetingOutcomes.maxItems)
        #expect(outcomes.nextSteps[0].text.count == MeetingOutcomes.textLimit)
        #expect(outcomes.nextSteps[0].text.hasSuffix("…"))
        #expect(outcomes.nextSteps[0].detail?.count == MeetingOutcomes.detailLimit)
    }
}

// MARK: - Backfill

@Suite("refreshMeetingOutcomes")
struct MeetingOutcomesRefreshTests {
    private let syncedAt = Date(timeIntervalSince1970: 1_788_000_000)

    private func granola(_ id: String, raw: String?, outcomes: String? = nil) -> ContextEvent {
        ContextEvent(
            source: .granola, externalId: id, startAt: syncedAt, title: "Review",
            bodyMd: "cut", isMeeting: true, rawJson: raw, syncedAt: syncedAt, outcomesJson: outcomes
        )
    }

    private func raw(_ summary: String, owner: String = "Oat Benson") -> String {
        GranolaSource.encode(.object([
            "id": "n", "owner": .object(["name": .string(owner)]), "summary_markdown": .string(summary),
        ]))!
    }

    @Test("on a note a colleague owns, an item naming them does not name you")
    func colleagueOwnedNote() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.upsert(granola("mine1", raw: raw("# Sync")))
        try store.upsert(granola("mine2", raw: raw("## Next steps\n- Oat sends the deck")))
        try store.upsert(granola("shared", raw: raw("## Next steps\n- Ana sends the memo\n- Oat reviews it",
                                                    owner: "Ana Lima")))
        #expect(try store.granolaYouName() == "Oat Benson")

        #expect(try store.refreshMeetingOutcomes() == 3)
        let shared = try #require(try store.find(source: .granola, externalId: "shared"))
        #expect(shared.outcomes?.nextSteps.map(\.namesYou) == [false, true])
        let mine = try #require(try store.find(source: .granola, externalId: "mine2"))
        #expect(mine.outcomes?.nextSteps.map(\.namesYou) == [true])
    }

    @Test("fills NULL rows, re-derives an older version, leaves calendar rows and synced_at alone")
    func backfill() throws {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.upsert(granola("fresh", raw: raw(longSummary)))
        try store.upsert(granola("stale", raw: raw("## Next steps\n- You send the deck"),
                                 outcomes: #"{"decisions":[],"nextSteps":[],"v":0}"#))
        try store.upsert(granola("plain", raw: raw("# Weekly sync\n- Talked.")))
        try store.upsert(granola("bare", raw: nil))
        try store.upsert(ContextEvent(source: .calendar, externalId: "c1", startAt: syncedAt,
                                      title: "Standup", syncedAt: syncedAt))

        #expect(try store.refreshMeetingOutcomes() == 4)

        let fresh = try #require(try store.find(source: .granola, externalId: "fresh"))
        #expect(fresh.outcomes?.nextSteps.count == 2)
        #expect(fresh.outcomes?.nextSteps.first?.namesYou == true)
        #expect(fresh.syncedAt == syncedAt)
        #expect(fresh.bodyMd == "cut")

        let stale = try #require(try store.find(source: .granola, externalId: "stale"))
        #expect(stale.outcomes?.v == MeetingOutcomes.parserVersion)
        #expect(stale.outcomes?.nextSteps.map(\.text) == ["You send the deck"])

        #expect(try store.find(source: .granola, externalId: "plain")?.outcomes?.isEmpty == true)
        #expect(try store.find(source: .granola, externalId: "bare")?.outcomes?.isEmpty == true)
        #expect(try store.find(source: .calendar, externalId: "c1")?.outcomesJson == nil)

        #expect(try store.refreshMeetingOutcomes() == 0)
    }
}

// MARK: - MCP

@Suite("context_events outcomes")
struct ContextEventsOutcomesTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let day = "2026-09-07"
    private var nine: Date { DayBoundaries.range(day: day, timeZone: utc)!.start.addingTimeInterval(9 * 3600) }

    private func call(_ db: Database, _ extra: [String: JSONValue] = [:]) throws -> String {
        var arguments: [String: JSONValue] = ["from": .string(day), "to": .string(day)]
        arguments.merge(extra) { $1 }
        return try WorklensMCPTools.contextEventsTool(db: db, timeZone: utc).handler(.object(arguments))
    }

    private func seed() throws -> Database {
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        try store.upsert(ContextEvent(
            source: .granola, externalId: "g1", startAt: nine, endAt: nine.addingTimeInterval(3600),
            title: "Quarterly review", bodyMd: ContextBody.inline(longSummary), isMeeting: true,
            syncedAt: nine,
            outcomesJson: MeetingOutcomes.parse(summaryMarkdown: longSummary, youName: "Oat Benson").encoded
        ))
        try store.upsert(ContextEvent(
            source: .granola, externalId: "g2", startAt: nine.addingTimeInterval(7200), title: "Coffee",
            bodyMd: "Small talk.", isMeeting: true, syncedAt: nine,
            outcomesJson: MeetingOutcomes().encoded
        ))
        try store.upsert(ContextEvent(
            source: .calendar, externalId: "c1", startAt: nine.addingTimeInterval(120),
            title: "Ship review", bodyMd: "shipped it", syncedAt: nine
        ))
        return db
    }

    @Test("next steps past both cuts are printed under the meeting")
    func printsNextSteps() throws {
        let out = try call(try seed())
        #expect(out.contains("""
              next steps (2, 1 names you):
              - Oat sends the revised deck by Friday
              - Ana books the follow-up call
            """))
        // The body itself is still cut at 400.
        #expect(!out.contains("Discussion point 40"))
    }

    @Test("outcomes_only keeps the meetings with items and drops the body line")
    func outcomesOnly() throws {
        let db = try seed()
        let out = try call(db, ["outcomes_only": true])
        #expect(out.hasPrefix("1 event(s)"))
        #expect(out.contains("Quarterly review"))
        #expect(out.contains("next steps (2, 1 names you):"))
        #expect(!out.contains("Discussion point"))
        #expect(!out.contains("Coffee"))
        #expect(!out.contains("Ship review"))

        let none = try call(db, ["outcomes_only": true, "sources": .array(["calendar"])])
        #expect(none.contains("No meetings with next steps or decisions"))
    }

    @Test("the count says \"name you\" for more than one item")
    func pluralNamesYou() {
        let outcomes = MeetingOutcomes(nextSteps: [
            .init(text: "You send the deck", namesYou: true),
            .init(text: "You book the room", namesYou: true),
            .init(text: "Ana reviews it"),
        ])
        #expect(WorklensMCPTools.outcomeLines(outcomes).first == "  next steps (3, 2 name you):")
    }

    @Test("calendar output is byte-identical")
    func calendarUnchanged() throws {
        let out = try call(try seed(), ["sources": .array(["calendar"])])
        #expect(out == """
            1 event(s) between 2026-09-07 and 2026-09-07.

            2026-09-07 09:02 · calendar · note · Ship review
              shipped it
            """)
    }
}
