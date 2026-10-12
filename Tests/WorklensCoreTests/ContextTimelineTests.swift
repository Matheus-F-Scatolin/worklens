import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

private func event(
    _ externalId: String,
    source: ContextSource = .calendar,
    from: Date,
    to: Date?,
    title: String?,
    body: String? = nil,
    meeting: Bool = true,
    participants: [String] = [],
    linkedTo calendarEventId: String? = nil
) -> ContextEvent {
    ContextEvent(
        source: source, externalId: externalId, startAt: from, endAt: to, title: title,
        participantsJson: ContextEvent.encodeParticipants(participants),
        bodyMd: body, isMeeting: meeting,
        // #318: a Granola note names the calendar event it was taken on.
        rawJson: calendarEventId.map { #"{"calendar_event":{"calendar_event_id":"\#($0)"}}"# }
    )
}

private func block(
    _ from: Date, _ to: Date, app: String, task: String, title: String? = nil,
    summary: String? = nil, source: ActivitySource = .screen, id: String = Identifiers.new()
) -> ActivityBlock {
    ActivityBlock(
        id: id, day: day, startAt: from, endAt: to, appKey: app, taskKey: task,
        title: title, summaryMd: summary, source: source
    )
}

// MARK: - Meeting detection

@Suite("MeetingDetector with calendar events")
@MainActor
struct MeetingDetectorContextTests {
    private func detector(_ now: Date) -> MeetingDetector {
        MeetingDetector(now: { now })
    }

    private let terminal = ForegroundContext(
        bundleID: "com.apple.Terminal", appName: "Terminal", pid: 1, windowTitle: "zsh"
    )

    @Test("a calendar meeting puts you in a meeting even in front of a terminal")
    func calendarWindow() {
        let meeting = event("m1", from: at(10, 0), to: at(11, 0), title: "Portfolio review")
        let detector = detector(at(10, 30))
        detector.update(context: terminal)
        #expect(!detector.isInMeeting)

        detector.setContextEvents([meeting])
        #expect(detector.isInMeeting)
        #expect(detector.currentMeeting?.title == "Portfolio review")
    }

    @Test("the window opens two minutes on each side, and not three")
    func tolerance() {
        let meeting = event("m1", from: at(10, 0), to: at(11, 0), title: "Standup")

        for (moment, expected) in [
            (at(9, 57), false), (at(9, 58), true), (at(10, 0), true),
            (at(11, 0), true), (at(11, 2), true), (at(11, 3), false),
        ] {
            let detector = detector(moment)
            detector.update(context: terminal)
            detector.setContextEvents([meeting])
            #expect(detector.isInMeeting == expected, "at \(moment)")
        }
    }

    @Test("a meeting with no end time is assumed to run 45 minutes")
    func openEnded() {
        let meeting = event("m1", from: at(10, 0), to: nil, title: "Ad hoc")
        let inside = detector(at(10, 40))
        inside.setContextEvents([meeting])
        #expect(inside.isInMeeting)

        let after = detector(at(10, 50))
        after.setContextEvents([meeting])
        #expect(!after.isInMeeting)
    }

    @Test("a non-meeting event never triggers the meeting cadence")
    func nonMeetingEvents() {
        let reminder = event("r1", from: at(10, 0), to: nil, title: "Send the term sheet", meeting: false)
        let detector = detector(at(10, 0))
        detector.update(context: terminal)
        detector.setContextEvents([reminder])
        #expect(!detector.isInMeeting)
        #expect(detector.currentMeeting == nil)
    }

    @Test("the foreground rule still stands on its own for an unscheduled huddle")
    func foregroundStillWins() {
        let detector = detector(at(15, 0))
        detector.setContextEvents([])
        detector.update(context: ForegroundContext(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", pid: 2,
            windowTitle: "Huddle in #deal-flow"
        ))
        #expect(detector.isInMeeting)
        #expect(detector.currentMeeting == nil, "nothing on the calendar names this one")
    }

    @Test("when two meetings overlap, the one that started most recently is the current one")
    func overlappingPrecedence() {
        let first = event("m1", from: at(10, 0), to: at(11, 0), title: "Long review")
        let second = event("m2", from: at(10, 45), to: at(11, 30), title: "Follow-up")
        let detector = detector(at(10, 50))
        detector.setContextEvents([first, second])
        #expect(detector.currentMeeting?.title == "Follow-up")
    }

    @Test("leaving the window clears both the flag and the current meeting")
    func clears() {
        let meeting = event("m1", from: at(10, 0), to: at(10, 30), title: "Standup")
        let detector = detector(at(12, 0))
        detector.update(context: terminal)
        detector.setContextEvents([meeting])
        #expect(!detector.isInMeeting)
        #expect(detector.currentMeeting == nil)
    }
}

// MARK: - Blocks

@Suite("ContextBlocks")
struct ContextBlocksTests {
    @Test("a meeting becomes one block, clamped to the day")
    func basicBlock() {
        let blocks = ContextBlocks.meetingBlocks(
            day: day,
            events: [event("m1", from: at(10, 0), to: at(11, 0), title: "Portfolio review",
                           body: "Discussed the Q3 marks.")],
            timeZone: utc
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].appKey == "meeting")
        #expect(blocks[0].taskKey == "video_call")
        #expect(blocks[0].source == .calendar)
        #expect(blocks[0].title == "Portfolio review")
        #expect(blocks[0].summaryMd == "Discussed the Q3 marks.")
    }

    @Test("a meeting spanning midnight is clipped to the day being rendered")
    func clamped() {
        let blocks = ContextBlocks.meetingBlocks(
            day: day,
            events: [event("m1", from: at(-1, 30), to: at(0, 30), title: "Late call")],
            timeZone: utc
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].startAt == dayStart)
        #expect(blocks[0].endAt == at(0, 30))
    }

    @Test("a zero-length calendar hold is not time spent")
    func skipsInstantHolds() {
        let blocks = ContextBlocks.meetingBlocks(
            day: day,
            events: [event("hold", from: at(9, 0), to: at(9, 0), title: "Focus block")],
            timeZone: utc
        )
        #expect(blocks.isEmpty)
    }

    @Test("the same call in Granola and in the calendar collapses to the Granola copy")
    func deduplicates() {
        let blocks = ContextBlocks.meetingBlocks(
            day: day,
            events: [
                event("cal-1", source: .calendar, from: at(10, 0), to: at(11, 0), title: "Portfolio review"),
                event("gr-1", source: .granola, from: at(10, 2), to: at(10, 58),
                      title: "Portfolio review", body: "Notes.", linkedTo: "cal-1"),
            ],
            timeZone: utc
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].source == .granola)
        #expect(blocks[0].summaryMd == "Notes.")
    }

    @Test("a note linked to an event it does not overlap stays its own meeting (#318)")
    func linkedWithoutOverlapStaysTwo() {
        let kept = ContextBlocks.deduplicate([
            event("cal-1", source: .calendar, from: at(10, 0), to: at(11, 0), title: "Review"),
            event("gr-1", source: .granola, from: at(14, 0), to: at(14, 30), title: "Review",
                  linkedTo: "cal-1"),
        ])
        #expect(kept.map(\.externalId) == ["cal-1", "gr-1"])
    }

    @Test("a double booking in the calendar stays two meetings (#318)")
    func calendarDoubleBookingStaysTwo() {
        let kept = ContextBlocks.deduplicate([
            event("cal-1", source: .calendar, from: at(10, 0), to: at(11, 0), title: "Review"),
            event("cal-2", source: .calendar, from: at(10, 0), to: at(11, 0), title: "Other call"),
        ])
        #expect(kept.count == 2)
    }

    @Test("two genuinely different calls both survive")
    func keepsDistinctMeetings() {
        let blocks = ContextBlocks.meetingBlocks(
            day: day,
            events: [
                event("a", from: at(10, 0), to: at(10, 30), title: "One"),
                event("b", from: at(10, 30), to: at(11, 0), title: "Two"),
            ],
            timeZone: utc
        )
        #expect(blocks.map(\.title) == ["One", "Two"])
    }

    @Test("the same event always produces the same block id, so rebuilds do not churn")
    func stableBlockIds() {
        let source = event("m1", from: at(10, 0), to: at(11, 0), title: "Standup")
        let first = ContextBlocks.meetingBlocks(day: day, events: [source], timeZone: utc)
        let second = ContextBlocks.meetingBlocks(day: day, events: [source], timeZone: utc)
        #expect(first[0].id == second[0].id)
    }

    // MARK: Away from the machine (#94)

    /// The `raw_json` `CalendarSource` stores, with the flags the away test reads: whether the
    /// entry is all-day, whether you declined it, and who else is on it.
    private func calendarRaw(allDay: Bool = false, declined: Bool = false, others: Int = 2) -> String {
        let start = allDay ? "{\"date\":\"2026-09-07\"}" : "{\"dateTime\":\"2026-09-07T12:00:00Z\"}"
        let me = "{\"email\":\"you@example.com\",\"self\":true,\"responseStatus\":"
            + (declined ? "\"declined\"}" : "\"accepted\"}")
        let rest = (0 ..< others).map {
            "{\"email\":\"colleague\($0)@example.com\",\"responseStatus\":\"accepted\"}"
        }
        return "{\"start\":\(start),\"attendees\":[\(([me] + rest).joined(separator: ","))]}"
    }

    /// Lunch: 12:00-13:00, two colleagues, no conferencing link, so `isMeeting` is false.
    private func lunch(raw: String? = nil) -> ContextEvent {
        ContextEvent(
            source: .calendar, externalId: "lunch", startAt: at(12, 0), endAt: at(13, 0),
            title: "Lunch at bem",
            participantsJson: ContextEvent.encodeParticipants(
                ["you@example.com", "ana@example.com", "bruno@example.com"]
            ),
            isMeeting: false, rawJson: raw ?? calendarRaw()
        )
    }

    /// One non-idle frame a minute across `minutes`, starting at 12:00.
    private func frames(minutes: Int) -> [TimelineFrame] {
        (0 ..< minutes).map { index in
            TimelineFrame(
                captureId: "f\(index)", at: at(12, index), appKey: "vscode", taskKey: "coding",
                title: "Worklens", summary: "Editing."
            )
        }
    }

    @Test("a lunch with colleagues and a quiet screen becomes one Away block")
    func lunchBecomesAway() {
        let event = lunch()
        let blocks = ContextBlocks.awayBlocks(
            day: day, events: [event], frames: [], timeZone: utc
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].appKey == "away")
        #expect(blocks[0].taskKey == "calendar")
        #expect(blocks[0].source == .calendar)
        #expect(blocks[0].title == "Lunch at bem")
        #expect(blocks[0].startAt == at(12, 0))
        #expect(blocks[0].endAt == at(13, 0))
        // Stable across rebuilds, and never the id the same event would get as a meeting.
        #expect(blocks[0].id == ContextBlocks.awayBlocks(
            day: day, events: [event], frames: [], timeZone: utc
        )[0].id)
        #expect(blocks[0].id != ContextBlocks.blockId(for: event))
    }

    @Test("the same event worked through is not away")
    func workedThroughIsNotAway() {
        // Half the hour has frames — far past the 20 % the test allows.
        let blocks = ContextBlocks.awayBlocks(
            day: day, events: [lunch()], frames: frames(minutes: 30), timeZone: utc
        )
        #expect(blocks.isEmpty)
        // A couple of glances at the screen still count as away.
        let glances = ContextBlocks.awayBlocks(
            day: day, events: [lunch()], frames: frames(minutes: 5), timeZone: utc
        )
        #expect(glances.count == 1)
    }

    @Test("an all-day entry is a label on the day, not an hour away")
    func allDayIsNotAway() {
        let event = ContextEvent(
            source: .calendar, externalId: "offsite", startAt: dayStart,
            endAt: dayStart.addingTimeInterval(86400), title: "Team offsite week",
            isMeeting: false, rawJson: calendarRaw(allDay: true)
        )
        #expect(ContextBlocks.awayBlocks(day: day, events: [event], frames: [], timeZone: utc).isEmpty)
    }

    @Test("an event you declined, or one nobody else is on, is not away")
    func declinedOrSoloIsNotAway() {
        let declined = lunch(raw: calendarRaw(declined: true))
        #expect(ContextBlocks.awayBlocks(day: day, events: [declined], frames: [], timeZone: utc).isEmpty)
        let solo = lunch(raw: calendarRaw(others: 0))
        #expect(ContextBlocks.awayBlocks(day: day, events: [solo], frames: [], timeZone: utc).isEmpty)
    }

    @Test("a conference event is still a meeting and never an away block")
    func conferenceStaysAMeeting() {
        let call = event("m1", from: at(12, 0), to: at(13, 0), title: "Portfolio review",
                         participants: ["you@example.com", "ana@example.com"])
        #expect(ContextBlocks.meetingBlocks(day: day, events: [call], timeZone: utc).count == 1)
        #expect(ContextBlocks.awayBlocks(day: day, events: [call], frames: [], timeZone: utc).isEmpty)
    }

    @Test("away time is tracked, is not active, and is not meeting time")
    func awayCountsAsAwayMinutes() {
        let blocks = ContextBlocks.awayBlocks(
            day: day, events: [lunch()], frames: [], timeZone: utc
        )
        let stats = StatsAggregator.daily(day: day, blocks: blocks, timeZone: utc)
        #expect(stats.awayMinutes == 60)
        #expect(stats.meetingMinutes == 0)
        #expect(stats.activeMinutes == 0)
        #expect(stats.trackedMinutes == 60)
    }
}

// MARK: - Rendering

@Suite("TimelineRenderer with context")
struct TimelineContextRenderingTests {
    private func goldenFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func compareToGolden(_ actual: String, _ name: String) throws {
        let url = goldenFile(name)
        if ProcessInfo.processInfo.environment["WORKLENS_UPDATE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(actual.utf8).write(to: url, options: .atomic)
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "\(name) drifted; re-record with WORKLENS_UPDATE_FIXTURES=1")
    }

    /// A meeting from 10:00 to 11:00 with a spreadsheet open through the middle of it.
    private func fixture() -> (blocks: [ActivityBlock], frames: [TimelineFrame], events: [ContextEvent]) {
        let meeting = ContextBlocks.meetingBlocks(
            day: day,
            events: [event("gr-1", source: .granola, from: at(10, 0), to: at(11, 0),
                           title: "Portfolio review", body: "Walked through the Q3 marks.",
                           participants: ["ana@example.com", "you@example.com"])],
            timeZone: utc
        )
        let screen = [
            block(at(9, 30), at(10, 0), app: "gmail", task: "triaging", title: "Inbox – Gmail",
                  summary: "Clearing the overnight thread.", id: "screen-before"),
            block(at(10, 10), at(10, 40), app: "sheets", task: "editing", title: "Q3 marks.xlsx",
                  summary: "Updating the marks tab while the call runs.", id: "screen-during"),
        ]
        let frames = [
            TimelineFrame(captureId: "f1", at: at(9, 30), appKey: "gmail", taskKey: "triaging",
                          title: "Inbox – Gmail", summary: "Clearing the overnight thread."),
            TimelineFrame(captureId: "f2", at: at(10, 10), appKey: "sheets", taskKey: "editing",
                          title: "Q3 marks.xlsx", summary: "Updating the marks tab while the call runs."),
        ]
        let events = [
            event("gr-1", source: .granola, from: at(10, 0), to: at(11, 0), title: "Portfolio review",
                  body: "Walked through the Q3 marks.", participants: ["ana@example.com"]),
            // A calendar entry that is not a call: it is context, and it is not a meeting.
            event("cal-focus", source: .calendar, from: at(11, 15), to: at(12, 0),
                  title: "Focus: redline", meeting: false),
        ]
        return (meeting + screen, frames, events)
    }

    @Test("a day with a meeting and context events renders like the checked-in fixture")
    func golden() throws {
        let fixture = fixture()
        let markdown = TimelineRenderer.render(
            day: day, blocks: fixture.blocks, frames: fixture.frames,
            contextEvents: fixture.events, labels: TimelineLabels.from(Taxonomy.seed), timeZone: utc
        )
        try compareToGolden(markdown, "timeline-context-golden.md")
    }

    @Test("screen time inside a meeting is nested under it, not listed beside it")
    func nesting() {
        let fixture = fixture()
        let markdown = TimelineRenderer.render(
            day: day, blocks: fixture.blocks, frames: fixture.frames,
            contextEvents: fixture.events, labels: TimelineLabels.from(Taxonomy.seed), timeZone: utc
        )
        #expect(markdown.contains("- During the call:"))
        #expect(markdown.contains("  - 10:10-10:40 "))
        // The spreadsheet is nested, so it must not also appear as its own H2.
        #expect(!markdown.contains("## 10:10-10:40"))
        // …and the block that started before the call still gets its own heading.
        #expect(markdown.contains("## 09:30-10:00"))
    }

    @Test("the Context section lists the day's meetings and nothing else")
    func contextSection() {
        let lines = TimelineRenderer.contextSection(fixture().events, timeZone: utc)
            .joined(separator: "\n")
        #expect(lines.contains("Meetings (1):"))
        #expect(lines.contains("[granola] Portfolio review: Walked through the Q3 marks."))
        #expect(!lines.contains("Focus: redline"))
        // #285: the sent-mail and Slack lines went with their sources.
        #expect(!lines.contains("Emails sent"))
        #expect(!lines.contains("Slack:"))
    }

    @Test("a meeting's next steps and decisions add at most five nested lines (#316)")
    func contextSectionOutcomes() {
        var meeting = fixture().events[0]
        let steps = (1...7).map { MeetingOutcomes.Item(text: "Step \($0)") }
        meeting.outcomesJson = MeetingOutcomes(
            nextSteps: [MeetingOutcomes.Item(text: String(repeating: "x", count: 300))] + steps,
            decisions: [MeetingOutcomes.Item(text: "Ship it")]
        ).encoded
        let before = TimelineRenderer.contextSection(fixture().events, timeZone: utc)
        let after = TimelineRenderer.contextSection([meeting], timeZone: utc)

        #expect(after.count == before.count + TimelineRenderer.maxOutcomeLines)
        let added = after.filter { $0.hasPrefix("  - ") }
        #expect(added.count == 5)
        #expect(added.allSatisfy { $0.hasPrefix("  - Next step: ") })
        #expect(added[0].count <= "  - Next step: ".count + 160)
        #expect(added[1] == "  - Next step: Step 1")

        var few = fixture().events[0]
        few.outcomesJson = MeetingOutcomes(
            nextSteps: [MeetingOutcomes.Item(text: "Send the deck")],
            decisions: [MeetingOutcomes.Item(text: "Ship it")]
        ).encoded
        #expect(TimelineRenderer.contextSection([few], timeZone: utc).suffix(2)
            == ["  - Next step: Send the deck", "  - Decision: Ship it"])
    }

    @Test("a day with no outcomes renders its Context section as before")
    func contextSectionWithoutOutcomes() {
        var empty = fixture().events
        empty[0].outcomesJson = MeetingOutcomes().encoded
        #expect(TimelineRenderer.contextSection(empty, timeZone: utc)
            == TimelineRenderer.contextSection(fixture().events, timeZone: utc))
    }

    @Test("a day whose only context is not a meeting gets no empty Context heading")
    func noMeetingsNoSection() {
        let focus = event("cal-focus", from: at(11, 15), to: at(12, 0), title: "Focus", meeting: false)
        #expect(TimelineRenderer.contextSection([focus], timeZone: utc).isEmpty)
    }

    @Test("a day with no context events renders exactly as it did before #19")
    func noContextNoSection() {
        let markdown = TimelineRenderer.render(
            day: day,
            blocks: [block(at(9, 0), at(9, 30), app: "gmail", task: "triaging", summary: "Triage.")],
            frames: [], contextEvents: [], timeZone: utc
        )
        #expect(!markdown.contains("## Context"))
        #expect(!markdown.contains("During the call"))
    }
}

// MARK: - Stats

@Suite("StatsAggregator with context")
struct StatsContextTests {
    @Test("meeting minutes come from the meeting block, counted once")
    func meetingMinutes() {
        let meeting = block(at(10, 0), at(11, 0), app: "meeting", task: "video_call",
                            title: "Portfolio review", source: .calendar, id: "m")
        let during = block(at(10, 10), at(10, 40), app: "sheets", task: "editing", id: "s")

        let stats = StatsAggregator.daily(day: day, blocks: [meeting, during], timeZone: utc)
        #expect(stats.meetingMinutes == 60)
        // 10:00-11:00 covered once, not 60 + 30.
        #expect(stats.trackedMinutes == 60)
        #expect(stats.activeMinutes == 60)
        // Breakdowns stay screen-side: the 30 minutes are attributed to the spreadsheet.
        #expect(stats.byApp.map(\.key) == ["sheets"])
        #expect(stats.byApp[0].minutes == 30)
    }

    @Test("the meeting count reaches the stats, deduplicated")
    func contextCounts() {
        let events = [
            event("cal-1", source: .calendar, from: at(10, 0), to: at(11, 0), title: "Review"),
            event("gr-1", source: .granola, from: at(10, 1), to: at(10, 59), title: "Review",
                  linkedTo: "cal-1"),
            event("cal-2", source: .calendar, from: at(11, 5), to: nil, title: "Reminder", meeting: false),
        ]
        let stats = StatsAggregator.daily(
            day: day,
            blocks: [block(at(9, 0), at(9, 30), app: "gmail", task: "triaging")],
            contextEvents: events,
            timeZone: utc
        )
        #expect(stats.meetingsCount == 1, "the same call twice is one meeting")
    }

    @Test("counts survive a day with no activity blocks at all")
    func countsOnAnEmptyDay() {
        let stats = StatsAggregator.daily(
            day: day, blocks: [],
            contextEvents: [event("gr-1", source: .granola, from: at(11, 5), to: at(11, 35),
                                  title: "Standup")],
            timeZone: utc
        )
        #expect(stats.meetingsCount == 1)
        #expect(stats.isEmpty)
    }

    @Test("overlapping blocks never make a day longer than it was")
    func unionSeconds() {
        let blocks = [
            block(at(9, 0), at(10, 0), app: "a", task: "t", id: "1"),
            block(at(9, 30), at(11, 0), app: "b", task: "t", id: "2"),
            block(at(12, 0), at(12, 30), app: "c", task: "t", id: "3"),
        ]
        #expect(StatsAggregator.unionSeconds(blocks) == 2 * 3600 + 30 * 60)
    }
}
