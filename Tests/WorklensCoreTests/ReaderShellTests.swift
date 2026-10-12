import Foundation
import Testing

@testable import WorklensCore

/// The Today waterfall and the Weeks grid (reader redesign). Both are drawn in SwiftUI; every
/// number they draw is decided here.
@Suite("Today waterfall")
struct WaterfallTests {
    private let apps: [Waterfall.Item] = [
        .init(name: "Gmail", minutes: 52),
        .init(name: "Claude Desktop", minutes: 154),
        .init(name: "Terminal", minutes: 21),
        .init(name: "Google Calendar", minutes: 66),
        .init(name: "Google Meet", minutes: 38),
    ]

    @Test func barsFloatBiggestFirstThenTotal() {
        let chart = Waterfall(apps: apps, activeMinutes: 331, longestFocusMinutes: 108, contextSwitches: 38)
        #expect(chart.steps.map(\.name) == ["Claude Desktop", "Google Calendar", "Others", "Gmail", "Total"])
        #expect(chart.steps.map(\.from) == [0, 154, 220, 279, 0])
        #expect(chart.steps.map(\.to) == [154, 220, 279, 331, 331])
        #expect(chart.others.map(\.name) == ["Google Meet", "Terminal"])
    }

    @Test func activeTimeNoAppAccountsForIsItsOwnMeetingsBar() {
        let chart = Waterfall(apps: apps, activeMinutes: 431, longestFocusMinutes: nil, contextSwitches: 0)
        let meetings = chart.steps.first { $0.kind == .meetings }
        #expect(meetings?.from == 154)
        #expect(meetings?.to == 254)
        #expect(chart.steps.map(\.kind) == [.app, .meetings, .app, .others, .app, .total])
        #expect(chart.steps.last?.kind == .total)
        #expect(chart.steps.last?.to == 431)
    }

    @Test func aRoundingGapDrawsNoMeetingsBar() {
        let chart = Waterfall(apps: apps, activeMinutes: 333, longestFocusMinutes: nil, contextSwitches: 0)
        #expect(!chart.steps.contains { $0.kind == .meetings })
    }

    @Test func axisIsHoursWithHeadroomAndTicksEveryTwo() {
        let chart = Waterfall(apps: apps, activeMinutes: 372, longestFocusMinutes: 108, contextSwitches: 38)
        #expect(chart.scaleMinutes == 420)
        #expect(chart.ticks == [0, 120, 240, 360])
    }

    @Test func tooltipsSayWhatEachBarIs() {
        let chart = Waterfall(
            apps: [
                .init(name: "Claude Desktop", minutes: 154),
                .init(name: "Google Calendar", minutes: 66),
                .init(name: "Gmail", minutes: 52),
                .init(name: "Google Meet", minutes: 38),
                .init(name: "Terminal", minutes: 21),
                .init(name: "GitHub", minutes: 17),
                .init(name: "Google Slides", minutes: 14),
                .init(name: "Granola", minutes: 10),
            ],
            activeMinutes: 372,
            longestFocusMinutes: 108,
            contextSwitches: 38
        )
        let claude = chart.steps[0]
        #expect(chart.sentence(for: claude) == "41% of your active time")
        let others = chart.steps.first { $0.kind == .others }!
        #expect(chart.rows(for: others).map(\.label) == ["Google Meet", "Terminal", "GitHub", "Google Slides", "Granola"])
        let total = chart.steps.last!
        #expect(chart.rows(for: total).map(\.value) == ["6h 12m", "1h 48m", "38"])
    }

    @Test func statsNameAppsThroughLabelsAndTheTailRow() {
        let stats = DailyStats(
            day: "2026-09-22",
            activeMinutes: 200,
            byApp: [
                Slice(key: "claude_desktop", name: "claude_desktop", minutes: 120, share: 0.6),
                Slice(key: "gcal", name: "gcal", minutes: 40, share: 0.2),
                Slice(key: "gmail", name: "gmail", minutes: 20, share: 0.1),
                Slice(key: "github", name: "github", minutes: 12, share: 0.06),
                Slice(key: "other", name: "other (2 more)", minutes: 8, share: 0.04),
            ],
            contextSwitches: 12
        )
        let labels = TimelineLabels(apps: ["claude_desktop": "Claude Desktop", "gcal": "Google Calendar"])
        let chart = Waterfall.of(stats, labels: labels)!
        #expect(chart.steps.prefix(3).map(\.name) == ["Claude Desktop", "Google Calendar", "Gmail"])
        #expect(chart.others.map(\.name) == ["Github", "2 more apps"])
        #expect(chart.longestFocusMinutes == nil)
        #expect(chart.facts[1].value == "none")
    }

    @Test func aDayWithNoActiveTimeHasNoChart() {
        #expect(Waterfall.of(DailyStats(day: "2026-09-22"), labels: TimelineLabels()) == nil)
    }
}

@Suite("Weeks grid")
struct WeekCalendarTests {
    private func h(_ hour: Double, _ minute: Double = 0) -> Double { hour * 60 + minute }
    private let top = ["Claude Desktop", "Google Calendar", "Gmail"]

    @Test func slotsTakeTheirMajorityCategoryAndMerge() {
        let spans = [
            WeekCalendar.Span(app: "Claude Desktop", start: h(9), end: h(10)),
            WeekCalendar.Span(app: "Terminal", start: h(10), end: h(10, 20)),
            WeekCalendar.Span(app: "Gmail", start: h(10, 20), end: h(10, 30)),
        ]
        let blocks = WeekCalendar.blocks(spans: spans, meetings: [], top: top)
        #expect(blocks.map(\.category) == [.app("Claude Desktop"), .others])
        #expect(blocks[0].start == h(9))
        #expect(blocks[0].end == h(10))
        #expect(blocks[1].start == h(10))
        #expect(blocks[1].end == h(10, 30))
        #expect(blocks[1].apps.map(\.name) == ["Terminal", "Gmail"])
        #expect(blocks[1].apps.map(\.minutes) == [20, 10])
    }

    @Test func thinSlotsAndMeetingSlotsAreSkipped() {
        let spans = [
            WeekCalendar.Span(app: "Gmail", start: h(9), end: h(9, 7)),
            WeekCalendar.Span(app: "Claude Desktop", start: h(11), end: h(12)),
        ]
        let meetings = [WeekCalendar.Meeting(title: "Team call", start: h(11), end: h(11, 20))]
        let blocks = WeekCalendar.blocks(spans: spans, meetings: meetings, top: top)
        // 09:00 has 7 minutes: under the floor. 11:00-11:30 is two-thirds meeting: skipped.
        #expect(blocks.count == 1)
        #expect(blocks[0].start == h(11, 30))
        #expect(blocks[0].end == h(12))
    }

    @Test func blocksClipAtMeetingEdgesAndShortOnesDrop() {
        let spans = [WeekCalendar.Span(app: "Claude Desktop", start: h(13), end: h(15))]
        let meetings = [
            WeekCalendar.Meeting(title: "Founder call", start: h(12, 50), end: h(13, 10)),
            WeekCalendar.Meeting(title: "1:1", start: h(14, 50), end: h(15, 30)),
        ]
        let blocks = WeekCalendar.blocks(spans: spans, meetings: meetings, top: top)
        #expect(blocks.count == 1)
        #expect(blocks[0].start == h(13, 10))
        #expect(blocks[0].end == h(14, 50))

        let short = WeekCalendar.blocks(
            spans: [WeekCalendar.Span(app: "Gmail", start: h(16), end: h(16, 30))],
            meetings: [WeekCalendar.Meeting(title: "Call", start: h(16, 10), end: h(16, 40))],
            top: top
        )
        // Clipped to 16:00-16:10, which is under fifteen minutes.
        #expect(short.isEmpty)
    }

    @Test func nothingIsDrawnPastNowButEarlyHoursAre() {
        let spans = [
            WeekCalendar.Span(app: "Gmail", start: h(6), end: h(7)),
            WeekCalendar.Span(app: "Gmail", start: h(15), end: h(18)),
        ]
        let blocks = WeekCalendar.blocks(spans: spans, meetings: [], top: top, end: h(16, 20))
        #expect(blocks.map(\.start) == [h(6), h(15)])
        #expect(blocks.map(\.end) == [h(7), h(16, 20)])
    }

    @Test func theWindowWidensOnlyForWhatIsDrawnOutsideIt() {
        func day(_ blocks: [(Double, Double)], meetings: [(Double, Double)] = []) -> WeekCalendar.Day {
            WeekCalendar.Day(
                day: "2026-09-22", label: "Tue 22", activeMinutes: 60, isToday: false,
                blocks: WeekCalendar.blocks(
                    spans: blocks.map { WeekCalendar.Span(app: "Gmail", start: $0.0, end: $0.1) },
                    meetings: [], top: top
                ),
                meetings: meetings.map { WeekCalendar.Meeting(title: "Call", start: $0.0, end: $0.1) }
            )
        }
        let usual = WeekCalendar.window([day([(h(9), h(17))])])
        #expect(usual.start == h(8) && usual.end == h(20))
        #expect(WeekCalendar.window([]).start == h(8))
        // Five stray minutes are under the slot minimum, so they draw nothing and widen nothing.
        let stray = WeekCalendar.window([day([(h(7, 40), h(7, 45)), (h(9), h(10))])])
        #expect(stray.start == h(8))
        let wide = WeekCalendar.window([
            day([(h(6, 30), h(9))]),
            day([(h(10), h(11))], meetings: [(h(21), h(21, 45))]),
        ])
        #expect(wide.start == h(6) && wide.end == h(22))
    }

    @Test func duplicateMeetingsCollapseKeepingATitle() {
        let chips = WeekCalendar.meetingChips([
            .init(title: ReaderShellCopy.meeting, start: h(9), end: h(10)),
            .init(title: "IC meeting", start: h(9), end: h(10, 0.5)),
            .init(title: "Later", start: h(11), end: h(11, 30)),
        ])
        #expect(chips.map(\.title) == ["IC meeting", "Later"])
    }

    @Test func weekWordsAndDays() throws {
        let zone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let week = try #require(ISOWeek.containing(dayString: "2026-09-22", timeZone: zone))
        #expect(WeekCalendar.title(week, timeZone: zone, locale: locale) == "21-27 September")
        #expect(WeekCalendar.line(active: 735, meetings: 332, soFar: true)
            == "Active time 12h 15m so far · Meetings 5h 32m")

        let start = DayBoundaries.range(day: "2026-09-22", timeZone: zone)!.start
        func block(_ app: String, _ from: Double, _ to: Double, source: ActivitySource = .screen, title: String? = nil) -> ActivityBlock {
            ActivityBlock(
                id: UUID().uuidString, day: "2026-09-22",
                startAt: start.addingTimeInterval(from * 60), endAt: start.addingTimeInterval(to * 60),
                appKey: app, taskKey: source == .screen ? "work" : "meeting", title: title,
                captureCount: 1, source: source
            )
        }
        let stats = WeeklyStats(
            weekStart: week.start, weekEnd: week.end, isoWeek: week.identifier, days: [],
            totals: WeeklyTotals(
                activeMinutes: 180,
                byApp: [Slice(key: "claude_desktop", name: "claude_desktop", minutes: 120, share: 0.6)]
            ),
            perDayActiveMinutes: [0, 180, 0, 0, 0, 0, 0]
        )
        let calendar = WeekCalendar.build(
            week: week, stats: stats,
            blocksByDay: ["2026-09-22": [
                block("claude_desktop", h(9), h(11)),
                block("meeting", h(12), h(13), source: .calendar, title: "Portfolio review"),
            ]],
            labels: TimelineLabels(apps: ["claude_desktop": "Claude Desktop"]),
            now: start.addingTimeInterval(h(16, 20) * 60), timeZone: zone, locale: locale
        )
        #expect(calendar.top.map(\.name) == ["Claude Desktop"])
        #expect(calendar.top.first?.colorHex == 0xD97757)
        let tuesday = calendar.days[1]
        #expect(tuesday.label == "Tue 22")
        #expect(tuesday.isToday)
        #expect(tuesday.nowMinute == h(16, 20))
        #expect(tuesday.subtitle == "3h 00m")
        #expect(tuesday.blocks.map(\.category) == [.app("Claude Desktop")])
        #expect(tuesday.meetings.map(\.title) == ["Portfolio review"])
        #expect(calendar.days[0].subtitle == ReaderShellCopy.noActivity)
        #expect(calendar.days[2].activeMinutes == nil)
    }

    @Test func appColoursAreFixedOrStable() {
        #expect(AppPalette.hex(forApp: "Claude Desktop") == 0xD97757)
        #expect(AppPalette.hex(forApp: "Google Calendar") == 0x039BE5)
        #expect(AppPalette.hex(forApp: "Terminal") == AppPalette.hex(forApp: "Terminal"))
        // A taxonomy that renames the app keeps its colour: the key decides.
        #expect(AppPalette.hex(forApp: "Web browser / Google Calendar", key: "gcal") == 0x039BE5)
        #expect(AppPalette.family.contains(AppPalette.hex(forApp: "Terminal")))
    }

    /// #357: a 15-minute standup's chip was a few points tall and the block after it began where
    /// it ended, so neither name showed.
    @Test func aShortMeetingAndTheBlockBesideItBothKeepTheirNames() throws {
        func block(_ start: Double, _ end: Double) -> WeekCalendar.Block {
            WeekCalendar.Block(category: .app("Gmail"), start: start, end: end, apps: [])
        }
        let standup = WeekCalendar.Meeting(title: "Standup", start: h(9, 25), end: h(9, 40))
        let review = WeekCalendar.Meeting(title: "Review", start: h(9, 50), end: h(10, 30))
        let day = WeekCalendar.Day(
            day: "2026-10-07", label: "Wed 7", activeMinutes: 200, isToday: false,
            blocks: [block(h(9, 40), h(11)), block(h(9, 0), h(9, 25)), block(h(13), h(13, 10))],
            meetings: [standup, review]
        )
        let placed = WeekCalendar.placement(day, chipMinutes: 20, labelMinutes: 15)
        let chip = try #require(placed.meetings[standup.id])
        #expect(chip.start == h(9, 25))
        #expect(chip.end - chip.start >= 20, "the standup is drawn tall enough for its title")
        // A chip grows only up to the next meeting's start.
        #expect(chip.end <= review.start)
        // The block under both chips starts its label below the review, not under a chip.
        let label = try #require(placed.labels[block(h(9, 40), h(11)).id])
        #expect(label >= placed.meetings[review.id]!.end)
        #expect(placed.labels[block(h(9, 0), h(9, 25)).id] == h(9, 0))
        // Ten minutes is too short for a label: none rather than one under a chip.
        #expect(placed.labels[block(h(13), h(13, 10)).id] == nil)
        // At the bottom of the grid a chip grows upwards.
        let late = WeekCalendar.Meeting(title: "Late", start: h(19, 55), end: h(20))
        let end = WeekCalendar.placement(
            WeekCalendar.Day(day: "2026-10-07", label: "Wed 7", activeMinutes: 10, isToday: false,
                             blocks: [], meetings: [late]),
            chipMinutes: 20, labelMinutes: 15, windowStart: h(8), windowEnd: h(20)
        )
        #expect(end.meetings[late.id] == .init(start: h(19, 40), end: h(20)))
    }

    /// #357 review: on a day the grid widens to 06:00–23:00, one line of title is about 43
    /// minutes, and a 15-minute meeting stretched that far looked three times its length.
    @Test func aWidenedGridCapsHowFarAShortMeetingStretches() throws {
        let chipMinutes = 20.0 / (480.0 / (17 * 60))  // 20 pt on a 480 pt grid of 17 hours
        let standup = WeekCalendar.Meeting(title: "Standup", start: h(9), end: h(9, 15))
        let ping = WeekCalendar.Meeting(title: "Ping", start: h(13), end: h(13, 5))
        let call = WeekCalendar.Meeting(title: "Call", start: h(15), end: h(16))
        let late = WeekCalendar.Meeting(title: "Late", start: h(22, 50), end: h(23))
        let day = WeekCalendar.Day(
            day: "2026-10-07", label: "Wed 7", activeMinutes: 200, isToday: false,
            blocks: [], meetings: [standup, ping, call, late]
        )
        let placed = WeekCalendar.placement(
            day, chipMinutes: chipMinutes, labelMinutes: 15, windowStart: h(6), windowEnd: h(23))
        #expect(chipMinutes > 40)
        #expect(placed.meetings[standup.id] == .init(start: h(9), end: h(9, 30)))
        #expect(placed.meetings[ping.id] == .init(start: h(13), end: h(13, 20)))
        // A meeting already taller than one line is drawn at its real length.
        #expect(placed.meetings[call.id] == .init(start: h(15), end: h(16)))
        // At the bottom it grows upwards by the same capped amount.
        #expect(placed.meetings[late.id] == .init(start: h(22, 35), end: h(23)))
    }

    // MARK: #357 second pass

    /// The sample's Wednesday drew a Zoom block from 09:40 to 10:00, under the standup's chip:
    /// the call's own ten minutes in the 09:30 slot coloured it, and nothing else was there.
    @Test func aCallsOwnMinutesNeverColourTheSlotAfterIt() {
        let standup = WeekCalendar.Meeting(title: "Team standup", start: h(9, 25), end: h(9, 40))
        let pilot = WeekCalendar.Meeting(title: "Pilot customer call", start: h(10), end: h(10, 45))
        let spans = [
            WeekCalendar.Span(app: "Slack", start: h(9), end: h(9, 20)),
            WeekCalendar.Span(app: "Zoom", start: h(9, 25), end: h(9, 40)),
            WeekCalendar.Span(app: "Zoom", start: h(10), end: h(10, 45)),
        ]
        let blocks = WeekCalendar.blocks(spans: spans, meetings: [standup, pilot], top: ["Zoom"])
        #expect(!blocks.contains { $0.category == .app("Zoom") })
        #expect(!blocks.contains { $0.end > h(9, 40) && $0.start < h(10) })
        // What you did in the slot outside the call still counts.
        let after = WeekCalendar.blocks(
            spans: spans + [WeekCalendar.Span(app: "Codex", start: h(9, 40), end: h(10))],
            meetings: [standup, pilot], top: ["Zoom", "Codex"]
        )
        #expect(after.contains { $0.category == .app("Codex") && $0.start == h(9, 40) })
        // Two meetings over the same minutes cover them once.
        #expect(WeekCalendar.meetingCover(h(9), h(10), [standup, standup, pilot]) == 15)
        #expect(WeekCalendar.meetingCover(h(9, 30), h(10, 15), [standup, pilot]) == 25)
    }

    /// The legend named Zoom for minutes its own chips covered, then drew no Zoom anywhere.
    @Test func theTopAppsAreRankedByMinutesOutsideMeetings() throws {
        let zone = TimeZone(identifier: "UTC")!
        let week = try #require(ISOWeek.containing(dayString: "2026-09-22", timeZone: zone))
        let start = DayBoundaries.range(day: "2026-09-22", timeZone: zone)!.start
        func block(_ app: String, _ from: Double, _ to: Double, source: ActivitySource = .screen) -> ActivityBlock {
            ActivityBlock(
                id: UUID().uuidString, day: "2026-09-22",
                startAt: start.addingTimeInterval(from * 60), endAt: start.addingTimeInterval(to * 60),
                appKey: app, taskKey: source == .screen ? "work" : "meeting",
                title: source == .screen ? nil : "Planning", captureCount: 1, source: source
            )
        }
        let calendar = WeekCalendar.build(
            week: week, stats: nil,
            blocksByDay: ["2026-09-22": [
                block("zoom", h(9), h(11)),
                block("meeting", h(9), h(11), source: .calendar),
                block("vscode", h(11), h(12)),
                block("claude_code", h(13), h(15)),
                block("slack", h(15), h(15, 5)),
            ]],
            labels: TimelineLabels(apps: ["vscode": "VS Code", "claude_code": "Claude Code"]),
            now: start.addingTimeInterval(h(18) * 60), timeZone: zone
        )
        // Claude Code first, by minutes; Zoom's are all under the chip; Slack's five are too few.
        #expect(calendar.top.map(\.name) == ["Claude Code", "VS Code"])
        #expect(calendar.top.map(\.colorHex) == [
            AppPalette.hex(forApp: "Claude Code", key: "claude_code"), AppPalette.hex(forApp: "VS Code", key: "vscode"),
        ])
        #expect(WeekCalendar.topApps(["A": 30, "B": 90, "C": 30, "D": 5], count: 2) == ["B", "A"])
    }

    /// A stretched chip used to be drawn over the top of the block after it, which showed as a
    /// coloured sliver under the chip's edge.
    @Test func aBlockUnderAStretchedChipStartsBelowItOrIsNotDrawn() throws {
        func block(_ start: Double, _ end: Double) -> WeekCalendar.Block {
            WeekCalendar.Block(category: .app("Codex"), start: start, end: end, apps: [])
        }
        func day(_ blocks: [WeekCalendar.Block], _ meetings: [WeekCalendar.Meeting]) -> WeekCalendar.Day {
            WeekCalendar.Day(
                day: "2026-10-07", label: "Wed 7", activeMinutes: 200, isToday: false,
                blocks: blocks, meetings: meetings
            )
        }
        let standup = WeekCalendar.Meeting(title: "Team standup", start: h(9, 25), end: h(9, 40))
        let pilot = WeekCalendar.Meeting(title: "Pilot customer call", start: h(10), end: h(10, 45))
        let squeezed = block(h(9, 40), h(10))
        let later = block(h(10, 45), h(12))
        // A twenty-minute block after a fifteen-minute standup: the chip stops where the block
        // keeps fifteen minutes, and takes the rest of its line from the empty time above.
        let placed = WeekCalendar.placement(
            day([squeezed, later], [standup, pilot]),
            chipMinutes: 30, labelMinutes: 33, minimumBlockVisibleMinutes: 15
        )
        #expect(placed.meetings[standup.id] == .init(start: h(9, 15), end: h(9, 45)))
        #expect(placed.blocks[squeezed.id] == .init(start: h(9, 45), end: h(10)))
        #expect(placed.hidden.isEmpty)
        #expect(placed.blocks[later.id] == .init(start: h(10, 45), end: h(12)))
        #expect(placed.labels[later.id] == h(10, 45))

        // A block just before the standup keeps its own fifteen minutes, so the chip grows up
        // only as far as that allows.
        let before = block(h(9, 10), h(9, 25))
        let tight = WeekCalendar.placement(
            day([before, squeezed], [standup]),
            chipMinutes: 30, labelMinutes: 33, minimumBlockVisibleMinutes: 15
        )
        #expect(tight.meetings[standup.id] == .init(start: h(9, 25), end: h(9, 45)))
        #expect(tight.blocks[before.id] == .init(start: h(9, 10), end: h(9, 25)))
        #expect(tight.blocks[squeezed.id] == .init(start: h(9, 45), end: h(10)))

        // A block the meeting itself covers all but a sliver of is left out of the drawing,
        // and named in `hidden` so the grid still reads it out.
        let covered = block(h(9, 30), h(9, 50))
        let lost = WeekCalendar.placement(
            day([covered], [standup]), chipMinutes: 30, labelMinutes: 33, minimumBlockVisibleMinutes: 15
        )
        #expect(lost.meetings[standup.id] == .init(start: h(9, 25), end: h(9, 55)))
        #expect(lost.blocks[covered.id] == nil)
        #expect(lost.labels[covered.id] == nil)
        #expect(lost.hidden == [covered.id])

        let work = block(h(9, 40), h(10, 30))
        let roomy = WeekCalendar.placement(
            day([work], [standup]), chipMinutes: 30, labelMinutes: 33, minimumBlockVisibleMinutes: 15
        )
        let drawn = try #require(roomy.blocks[work.id])
        #expect(drawn == .init(start: h(9, 55), end: h(10, 30)))
        #expect(drawn.start >= roomy.meetings[standup.id]!.end)
        #expect(roomy.labels[work.id] == h(9, 55))
    }

    /// #357 third pass: the palette is main's, byte for byte, so a real week draws exactly the
    /// colours it drew before the onboarding work. The five fixed apps, the muted family hashed
    /// by name, and Others.
    @Test func thePaletteIsMainsPalette() {
        #expect(AppPalette.fixed == [
            "claude desktop": 0xD97757, "claude_desktop": 0xD97757,
            "google calendar": 0x039BE5, "gcal": 0x039BE5,
            "gmail": 0x33B679,
            "google meet": 0x7986CB, "gmeet": 0x7986CB,
            "zoom": 0x9E69AF,
        ])
        #expect(AppPalette.family == [0xC9A45C, 0x6BA7A0, 0xC08497, 0x8FA86A, 0x7E9CC0, 0xB8876A])
        #expect(AppPalette.others == 0x8E8B82)
        // The names a fresh taxonomy gives the apps of a developer's week, hashed as on main.
        let labels = TimelineLabels.from(Taxonomy.seed)
        let hashed: [String: UInt32] = [
            "browser": 0x6BA7A0, "slack": 0x6BA7A0, "codex_desktop": 0xC9A45C,
            "vscode": 0xB8876A, "terminal": 0xB8876A, "claude": 0xC08497, "gdocs": 0xC08497,
        ]
        for (key, colour) in hashed {
            #expect(AppPalette.hex(forApp: labels.app(key), key: key) == colour, "\(key)")
        }
        #expect(AppPalette.hex(forApp: "Linear") == AppPalette.hex(forApp: "linear"))
    }

    /// A real week's three named apps take the palette's own colours, nothing reassigned per
    /// week, and every other app is Others, as on main.
    @Test func aRealWeekIsColouredByThePaletteAlone() throws {
        let zone = TimeZone(identifier: "UTC")!
        let week = try #require(ISOWeek.containing(dayString: "2026-09-22", timeZone: zone))
        let start = DayBoundaries.range(day: "2026-09-22", timeZone: zone)!.start
        func block(_ app: String, _ from: Double, _ to: Double) -> ActivityBlock {
            ActivityBlock(
                id: UUID().uuidString, day: "2026-09-22",
                startAt: start.addingTimeInterval(from * 60), endAt: start.addingTimeInterval(to * 60),
                appKey: app, taskKey: "work", captureCount: 1, source: .screen
            )
        }
        let calendar = WeekCalendar.build(
            week: week, stats: nil,
            blocksByDay: ["2026-09-22": [
                block("claude_desktop", h(9), h(11)),
                block("browser", h(11), h(12, 30)),
                block("slack", h(12, 30), h(13, 30)),
                block("vscode", h(13, 30), h(14)),
            ]],
            labels: TimelineLabels.from(Taxonomy.seed),
            now: start.addingTimeInterval(h(18) * 60), timeZone: zone
        )
        #expect(WeekCalendar.topAppCount == 3)
        #expect(calendar.top.map(\.name) == ["Claude Desktop", "Web browser", "Slack"])
        // Slack and the browser share a hashed colour on main too: no per-week reassignment.
        #expect(calendar.top.map(\.colorHex) == [0xD97757, 0x6BA7A0, 0x6BA7A0])
        #expect(calendar.days[1].blocks.last?.category == .others)
        #expect(calendar.colorHex(.others) == AppPalette.others)
    }
}

