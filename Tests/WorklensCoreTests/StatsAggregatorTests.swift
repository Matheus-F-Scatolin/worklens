import Foundation
import Testing
@testable import WorklensCore

// MARK: - Helpers

/// Fixed timezone so a block that starts at "09:00" starts at 09:00 wherever the test runs.
private let zone = TimeZone(identifier: "UTC")!

private func at(_ day: String, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = day.split(separator: "-").map { Int($0)! }
    return calendar.date(from: DateComponents(
        timeZone: zone, year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute
    ))!
}

private func block(
    _ day: String,
    _ from: (Int, Int),
    _ to: (Int, Int),
    _ appKey: String,
    _ taskKey: String = "working",
    title: String? = nil,
    source: ActivitySource = .screen
) -> ActivityBlock {
    ActivityBlock(
        day: day,
        startAt: at(day, from.0, from.1),
        endAt: at(day, to.0, to.1),
        appKey: appKey,
        taskKey: taskKey,
        title: title,
        source: source
    )
}

private func capture(
    _ day: String,
    _ hour: Int,
    _ minute: Int,
    id: String = Identifiers.new(),
    bundle: String? = nil,
    app: String? = nil,
    title: String? = nil,
    host: String? = nil,
    redacted: Bool = false,
    meeting: Bool = false,
    status: DescribeStatus = .described
) -> Capture {
    Capture(
        id: id,
        capturedAt: at(day, hour, minute),
        appBundleId: bundle,
        appName: app,
        windowTitle: title,
        urlHost: host,
        isRedacted: redacted,
        isMeeting: meeting,
        describeStatus: status
    )
}

/// One foreground interval (#46). `to` nil leaves it open.
private func session(
    _ day: String,
    _ from: (Int, Int),
    _ to: (Int, Int)?,
    _ bundle: String?,
    blocked: Bool = false
) -> ForegroundSession {
    ForegroundSession(
        startAt: at(day, from.0, from.1),
        endAt: to.map { at(day, $0.0, $0.1) },
        appBundleId: bundle,
        appName: bundle,
        isBlocked: blocked
    )
}

private let day = "2026-09-04"

private func stats(
    _ blocks: [ActivityBlock],
    _ captures: [Capture] = [],
    sessions: [ForegroundSession] = [],
    llmCost: Double = 0
) -> DailyStats {
    StatsAggregator.daily(
        day: day, blocks: blocks, captures: captures, sessions: sessions,
        llmCost: llmCost, timeZone: zone
    )
}

// MARK: - Totals

@Suite("StatsAggregator totals")
struct StatsTotalsTests {
    @Test("tracked is everything, active excludes idle, and the parts add up")
    func totals() {
        let result = stats([
            block(day, (9, 0), (10, 30), "vscode", "coding"),
            block(day, (10, 30), (11, 0), "idle", "idle"),
            block(day, (11, 0), (11, 45), "slack", "reading"),
        ])
        #expect(result.trackedMinutes == 165)
        #expect(result.activeMinutes == 135)
        #expect(result.idleMinutes == 30)
        #expect(result.activeMinutes + result.idleMinutes == result.trackedMinutes)
        #expect(result.firstActivity == at(day, 9, 0))
        #expect(result.lastActivity == at(day, 11, 45))
        #expect(result.distinctApps == 2)
    }

    @Test("a locked block is idle even when its app key is an app")
    func lockedIsIdle() {
        let result = stats([
            block(day, (9, 0), (9, 30), "vscode", "coding"),
            block(day, (9, 30), (10, 0), "vscode", "locked"),
        ])
        #expect(result.activeMinutes == 30)
        #expect(result.idleMinutes == 30)
    }

    @Test("meeting time counts blocks the timeline labelled and frames flagged inside other blocks")
    func meetings() {
        let result = stats(
            [
                block(day, (9, 0), (9, 40), "zoom", "meeting"),
                block(day, (10, 0), (10, 30), "browser", "reading"),
                block(day, (11, 0), (11, 30), "granola", "notes", source: .granola),
            ],
            [
                capture(day, 10, 5, meeting: true),
                capture(day, 10, 20, meeting: true),
            ]
        )
        // 40 (zoom) + 30 (granola) + the whole browser block, both of whose frames were a meeting.
        #expect(result.meetingMinutes == 100)
    }

    @Test("an empty day is all zeroes with 24 empty hour buckets")
    func emptyDay() {
        let result = stats([])
        #expect(result.isEmpty)
        #expect(result.trackedMinutes == 0)
        #expect(result.activeMinutes == 0)
        #expect(result.hourly.count == 24)
        #expect(result.hourly.allSatisfy { $0.activeMinutes == 0 && $0.dominantApp == nil })
        #expect(result.byApp.isEmpty)
        #expect(result.longestFocusBlock == nil)
        #expect(result.switchesPerActiveHour == 0)
    }

    @Test("zero-length and reversed blocks are dropped rather than counted")
    func degenerateBlocks() {
        var reversed = block(day, (9, 0), (9, 30), "vscode")
        reversed.endAt = at(day, 8, 0)
        let result = stats([
            block(day, (9, 0), (9, 0), "slack"),
            reversed,
            block(day, (10, 0), (10, 20), "vscode", "coding"),
        ])
        #expect(result.activeMinutes == 20)
        #expect(result.distinctApps == 1)
    }
}

// MARK: - Breakdowns

@Suite("StatsAggregator breakdowns")
struct StatsBreakdownTests {
    @Test("shares are relative to active minutes")
    func shares() {
        let result = stats([
            block(day, (9, 0), (10, 0), "vscode", "coding"),
            block(day, (10, 0), (10, 30), "slack", "reading"),
            block(day, (10, 30), (11, 0), "idle", "idle"),
        ])
        #expect(result.byApp.map(\.key) == ["vscode", "slack"])
        #expect(result.byApp[0].share == 0.667)
        #expect(result.byApp[1].share == 0.333)
        #expect(result.byTask.map(\.key) == ["vscode/coding", "slack/reading"])
    }

    @Test("everything past the top N folds into one \"other\" row that keeps the minutes")
    func foldsIntoOther() {
        // 14 apps, each 10 minutes: 12 kept, 2 folded.
        let blocks = (0..<14).map { index in
            block(day, (9 + index / 6, (index % 6) * 10), (9 + index / 6, (index % 6) * 10 + 10), "app\(index)")
        }
        let result = stats(blocks)
        #expect(result.byApp.count == StatsAggregator.appLimit + 1)
        #expect(result.byApp.last?.key == StatsAggregator.otherKey)
        #expect(result.byApp.last?.minutes == 20)
        #expect(result.byApp.reduce(0) { $0 + $1.minutes } == result.activeMinutes)
    }

    @Test("hosts and redacted time come from the frames, split across the block they sit in")
    func hostsAndRedaction() {
        let result = stats(
            [block(day, (9, 0), (10, 0), "browser", "email")],
            [
                capture(day, 9, 5, host: "mail.google.com"),
                capture(day, 9, 20, host: "mail.google.com", redacted: true),
                capture(day, 9, 40, host: "github.com"),
                capture(day, 9, 55, host: "github.com"),
            ]
        )
        #expect(result.byHost.map(\.key) == ["github.com", "mail.google.com"])
        #expect(result.byHost.reduce(0) { $0 + $1.minutes } == 60)
        #expect(result.redactedMinutes == 15)
    }

    @Test("frames outside every block carry no minutes")
    func orphanFrames() {
        let result = stats(
            [block(day, (9, 0), (10, 0), "browser", "email")],
            [capture(day, 9, 30, host: "a.com"), capture(day, 20, 0, host: "b.com")]
        )
        #expect(result.byHost.count == 1)
        #expect(result.byHost[0].minutes == 60)
    }

    @Test("described and inherited frames are counted separately")
    func frameCounts() {
        let result = stats(
            [block(day, (9, 0), (10, 0), "vscode", "coding")],
            [
                capture(day, 9, 0, status: .described),
                capture(day, 9, 10, status: .inherited),
                capture(day, 9, 20, status: .inherited),
                capture(day, 9, 30, status: .skipped),
            ]
        )
        #expect(result.framesDescribed == 1)
        #expect(result.framesInherited == 2)
    }

    @Test("the category resolver decides byCategory; without one everything is uncategorized")
    func categories() {
        let blocks = [
            block(day, (9, 0), (10, 0), "vscode", "coding"),
            block(day, (10, 0), (10, 30), "slack", "reading"),
        ]
        #expect(stats(blocks).byCategory.map(\.key) == ["uncategorized"])

        let resolved = StatsAggregator.daily(
            day: day, blocks: blocks,
            category: { $0 == "vscode" ? "build" : "communicate" },
            timeZone: zone
        )
        #expect(resolved.byCategory.map(\.key) == ["build", "communicate"])
        #expect(resolved.byCategory[0].minutes == 60)
    }
}

// MARK: - Fragmentation

@Suite("StatsAggregator fragmentation")
struct StatsFragmentationTests {
    @Test("idle blocks are not switch boundaries")
    func idleIsNotASwitch() {
        let result = stats([
            block(day, (9, 0), (10, 0), "vscode", "coding"),
            block(day, (10, 0), (10, 30), "idle", "idle"),
            block(day, (10, 30), (11, 0), "vscode", "coding"),
            block(day, (11, 0), (11, 30), "slack", "reading"),
        ])
        // vscode → vscode across the idle gap is not a switch; vscode → slack is.
        #expect(result.contextSwitches == 1)
        #expect(result.topSwitchPairs == [SwitchPair(from: "vscode", to: "slack", count: 1)])
    }

    @Test("switch pairs are counted per direction and ordered by frequency")
    func switchPairs() {
        var blocks: [ActivityBlock] = []
        for index in 0..<6 {
            blocks.append(block(day, (9 + index, 0), (9 + index, 30), "slack"))
            blocks.append(block(day, (9 + index, 30), (10 + index, 0), "vscode"))
        }
        let result = stats(blocks)
        #expect(result.contextSwitches == 11)
        #expect(result.topSwitchPairs.first == SwitchPair(from: "slack", to: "vscode", count: 6))
        #expect(result.topSwitchPairs.last == SwitchPair(from: "vscode", to: "slack", count: 5))
    }

    @Test("switches per active hour is switches over active time, not over wall clock")
    func switchRate() {
        let result = stats([
            block(day, (9, 0), (10, 0), "vscode"),
            block(day, (10, 0), (11, 0), "slack"),
            block(day, (11, 0), (14, 0), "idle", "idle"),
        ])
        #expect(result.activeMinutes == 120)
        #expect(result.switchesPerActiveHour == 0.5)
    }

    @Test("longest focus needs ten minutes; shorter days report none")
    func longestFocus() {
        let short = stats([block(day, (9, 0), (9, 8), "vscode", "coding", title: "a.swift")])
        #expect(short.longestFocusBlock == nil)

        let long = stats([
            block(day, (9, 0), (9, 20), "slack", "reading"),
            block(day, (10, 0), (11, 5), "vscode", "coding", title: "SessionStitcher.swift"),
        ])
        let focus = long.longestFocusBlock
        #expect(focus?.minutes == 65)
        #expect(focus?.appKey == "vscode")
        #expect(focus?.title == "SessionStitcher.swift")
        #expect(long.focusBlocksOver25Min == 1)
    }

    @Test("median block minutes ignores idle")
    func medianBlock() {
        let result = stats([
            block(day, (9, 0), (9, 10), "a"),
            block(day, (9, 10), (9, 30), "b"),
            block(day, (9, 30), (10, 30), "c"),
            block(day, (10, 30), (14, 0), "idle", "idle"),
        ])
        #expect(result.medianBlockMinutes == 20)
    }

    @Test("a block spanning two hours splits across both buckets")
    func hourlySplit() {
        let result = stats([block(day, (9, 45), (10, 15), "vscode", "coding")])
        #expect(result.hourly[9].activeMinutes == 15)
        #expect(result.hourly[10].activeMinutes == 15)
        #expect(result.hourly[9].dominantApp == "vscode")
        #expect(result.hourly[8].activeMinutes == 0)
        #expect(result.hourly[8].dominantApp == nil)
        #expect(result.hourly.reduce(0) { $0 + $1.activeMinutes } == result.activeMinutes)
    }

    @Test("the dominant app of an hour is the one with the most minutes in it")
    func hourlyDominance() {
        let result = stats([
            block(day, (9, 0), (9, 20), "slack"),
            block(day, (9, 20), (10, 0), "vscode"),
        ])
        #expect(result.hourly[9].dominantApp == "vscode")
        #expect(result.hourly[9].activeMinutes == 60)
    }
}

// MARK: - Weekly

@Suite("StatsAggregator weekly")
struct StatsWeeklyTests {
    private func daily(_ day: String, active: Int, switches: Int = 4, meetings: Int = 30) -> DailyStats {
        DailyStats(
            day: day,
            trackedMinutes: active + 30,
            activeMinutes: active,
            idleMinutes: 30,
            meetingMinutes: meetings,
            byApp: [Slice(key: "vscode", name: "vscode", minutes: active, share: 1)],
            contextSwitches: switches,
            focusBlocksOver25Min: 3,
            llmCostUSD: 0.2
        )
    }

    @Test("totals sum, averages divide by tracked days, and the seven-day array keeps gaps")
    func totals() {
        let week = StatsAggregator.weekly(
            days: [
                daily("2026-08-31", active: 400),
                daily("2026-09-01", active: 300),
                daily("2026-09-02", active: 500),
                DailyStats(day: "2026-09-03"),
            ],
            timeZone: zone
        )
        #expect(week.isoWeek == "2026-W36")
        #expect(week.weekStart == "2026-08-31")
        #expect(week.weekEnd == "2026-09-06")
        #expect(week.totals.daysTracked == 3)
        #expect(week.totals.activeMinutes == 1200)
        #expect(week.totals.averageActiveMinutesPerDay == 400)
        #expect(week.totals.meetingMinutes == 90)
        #expect(week.perDayActiveMinutes == [400, 300, 500, 0, 0, 0, 0])
        #expect(week.totals.byApp.first?.minutes == 1200)
        #expect(abs(week.totals.llmCostUSD - 0.6) < 1e-9)
    }

    @Test("deltas are relative, and a metric that was zero last week is omitted")
    func deltas() {
        let last = StatsAggregator.weekly(
            days: [daily("2026-08-24", active: 400, switches: 4, meetings: 0)], timeZone: zone
        )
        let this = StatsAggregator.weekly(
            days: [daily("2026-08-31", active: 500, switches: 6, meetings: 60)],
            previous: last,
            timeZone: zone
        )
        let deltas = try! #require(this.deltaVsPreviousWeek)
        #expect(deltas["activeMinutes"] == 0.25)
        #expect(deltas["contextSwitches"] == 0.5)
        #expect(deltas["meetingMinutes"] == nil, "last week had no meetings, so there is no ratio")
    }

    @Test("no previous week means no deltas rather than zeroes")
    func noPrevious() {
        let week = StatsAggregator.weekly(days: [daily("2026-08-31", active: 400)], timeZone: zone)
        #expect(week.deltaVsPreviousWeek == nil)
    }

    @Test("a week with nothing tracked still names its week")
    func emptyWeek() {
        let week = StatsAggregator.weekly(days: [DailyStats(day: "2026-08-31")], timeZone: zone)
        #expect(week.totals.daysTracked == 0)
        #expect(week.isoWeek == "2026-W36")
        #expect(week.perDayActiveMinutes == [0, 0, 0, 0, 0, 0, 0])
    }
}

// MARK: - Rendering

@Suite("StatsAggregator rendering")
struct StatsRenderingTests {
    @Test("durations read as hours and minutes")
    func durations() {
        #expect(StatsAggregator.duration(0) == "0m")
        #expect(StatsAggregator.duration(7) == "7m")
        #expect(StatsAggregator.duration(60) == "1h 00m")
        #expect(StatsAggregator.duration(125) == "2h 05m")
    }
}

// MARK: - ISO weeks

@Suite("ISOWeek")
struct ISOWeekTests {
    @Test("parses YYYY-Www and spans Monday to Sunday")
    func parses() throws {
        let week = try #require(ISOWeek.parse("2026-W36", timeZone: zone))
        #expect(week.start == "2026-08-31")
        #expect(week.end == "2026-09-06")
        #expect(week.days.count == 7)
        #expect(week.identifier == "2026-W36")
        #expect(ISOWeek.parse("2026W36", timeZone: zone)?.start == "2026-08-31")
    }

    @Test("rejects nonsense and week numbers a year does not have")
    func rejects() {
        #expect(ISOWeek.parse("nonsense") == nil)
        #expect(ISOWeek.parse("2026-W00") == nil)
        #expect(ISOWeek.parse("2026-W54") == nil)
        #expect(ISOWeek.parse("26-W36") == nil)
        // 2026 has 53 ISO weeks, 2025 has 52.
        #expect(ISOWeek.parse("2026-W53", timeZone: zone) != nil)
        #expect(ISOWeek.parse("2025-W53", timeZone: zone) == nil)
    }

    @Test("the ISO year is not the calendar year at a year boundary")
    func yearBoundary() throws {
        // 2027-01-01 is a Friday, so it belongs to the last week of 2026.
        let week = try #require(ISOWeek.containing(dayString: "2027-01-01", timeZone: zone))
        #expect(week.identifier == "2026-W53")
        #expect(week.start == "2026-12-28")
        #expect(week.end == "2027-01-03")

        // 2026-01-01 is a Thursday, so it belongs to 2026-W01.
        let january = try #require(ISOWeek.containing(dayString: "2026-01-01", timeZone: zone))
        #expect(january.identifier == "2026-W01")
        #expect(january.start == "2025-12-29")
    }

    @Test("previous week steps back across a year boundary")
    func previousWeek() throws {
        let week = try #require(ISOWeek.parse("2026-W01", timeZone: zone))
        #expect(week.previous(timeZone: zone)?.identifier == "2025-W52")
        #expect(ISOWeek.parse("2026-W36", timeZone: zone)?.previous(timeZone: zone)?.identifier == "2026-W35")
    }
}

// MARK: - Exact per-app time from foreground sessions (#46)

private let chrome = "com.google.Chrome"
private let xcodeBundle = "com.apple.dt.Xcode"
/// The recorder tiles — one interval closes when the next one opens — so a day it watched has no
/// holes in it. Slack fills the stretch between the Chrome and Xcode intervals in the cases below;
/// without it the day would be only *partly* covered, which #61 deliberately treats differently
/// and `partlyCoveredDayKeepsUncoveredBlocks` pins down.
private let slackBundle = "com.tinyspeck.slackmacgap"
private let claudeBundle = "com.anthropic.claudefordesktop"

/// A morning in Chrome (Gmail then Sheets) followed by Xcode, with one frame inside each block
/// so the blocks can be attributed to a bundle.
private let splitBlocks = [
    block(day, (9, 0), (9, 30), "gmail"),
    block(day, (9, 30), (10, 0), "gsheets"),
    block(day, (10, 0), (10, 30), "xcode"),
]

private let splitCaptures = [
    capture(day, 9, 10, bundle: chrome),
    capture(day, 9, 40, bundle: chrome),
    capture(day, 10, 10, bundle: xcodeBundle),
]

@Suite("StatsAggregator with foreground sessions")
struct StatsSessionTests {
    @Test("a bundle's exact total is split across the app keys its frames resolved to")
    func chromeSplitsBetweenItsKeys() {
        // Chrome was really in front for fifty minutes, not the sixty the tick interval implies.
        let result = stats(
            splitBlocks, splitCaptures,
            sessions: [
                session(day, (9, 0), (9, 50), chrome),
                session(day, (9, 50), (10, 5), slackBundle),
                session(day, (10, 5), (10, 30), xcodeBundle),
            ]
        )
        let byApp = Dictionary(uniqueKeysWithValues: result.byApp.map { ($0.key, $0.minutes) })
        // Fifty minutes, halved the way the block seconds were: 25 and 25.
        #expect(byApp["gmail"] == 25)
        #expect(byApp["gsheets"] == 25)
        #expect((byApp["gmail"] ?? 0) + (byApp["gsheets"] ?? 0) == 50)
        // Xcode is one key, so it simply gets its exact total instead of its block's thirty.
        #expect(byApp["xcode"] == 25)
    }

    @Test("the denominator is the adjusted per-key total, so the shares still add up")
    func sharesUseTheAdjustedTotal() {
        let result = stats(
            splitBlocks, splitCaptures,
            sessions: [
                session(day, (9, 0), (9, 50), chrome),
                session(day, (9, 50), (10, 5), slackBundle),
                session(day, (10, 5), (10, 30), xcodeBundle),
            ]
        )
        #expect(abs(result.byApp.reduce(0) { $0 + $1.share } - 1) < 0.005)
        // Not the ninety minutes of screen blocks: three equal keys out of 75 minutes.
        #expect(result.byApp.allSatisfy { abs($0.share - 1.0 / 3) < 0.005 })
    }

    @Test("byCategory derives from the same per-key seconds")
    func categoriesFollowTheAdjustedKeys() {
        let category: StatsAggregator.CategoryResolver = { key in
            key == "xcode" ? "deep work" : "communication"
        }
        let result = StatsAggregator.daily(
            day: day, blocks: splitBlocks, captures: splitCaptures,
            sessions: [
                session(day, (9, 0), (9, 50), chrome),
                session(day, (9, 50), (10, 5), slackBundle),
                session(day, (10, 5), (10, 30), xcodeBundle),
            ],
            category: category, timeZone: zone
        )
        let byCategory = Dictionary(uniqueKeysWithValues: result.byCategory.map { ($0.key, $0.minutes) })
        #expect(byCategory["communication"] == 50)
        #expect(byCategory["deep work"] == 25)
    }

    @Test("a bundle with no sessions keeps its block seconds")
    func bundleWithoutSessionsIsUntouched() {
        let result = stats(
            splitBlocks, splitCaptures,
            sessions: [
                session(day, (9, 0), (9, 50), chrome),
                session(day, (9, 50), (10, 30), slackBundle),
            ]
        )
        let byApp = Dictionary(uniqueKeysWithValues: result.byApp.map { ($0.key, $0.minutes) })
        #expect(byApp["gmail"] == 25)
        #expect(byApp["gsheets"] == 25)
        #expect(byApp["xcode"] == 30)
    }

    @Test("a day with no sessions at all reads exactly as it did before #46")
    func noSessionsIsTheOldBehaviour() {
        let before = stats(splitBlocks, splitCaptures)
        let byApp = Dictionary(uniqueKeysWithValues: before.byApp.map { ($0.key, $0.minutes) })
        #expect(byApp == ["gmail": 30, "gsheets": 30, "xcode": 30])
        #expect(before.sessionMinutes == 0)
    }

    @Test("sessionMinutes is how much of the active span the sessions cover")
    func sessionMinutesReported() {
        let result = stats(
            splitBlocks, splitCaptures,
            sessions: [
                session(day, (9, 0), (9, 50), chrome),
                session(day, (10, 5), (10, 30), xcodeBundle),
            ]
        )
        #expect(result.sessionMinutes == 75)
        #expect(result.activeMinutes == 90)
    }

    @Test("sessions are clipped to the day's active blocks, so idle time is never claimed")
    func sessionsAreClippedToActiveTime() {
        // The session runs to 11:00 but the blocks stop at 10:30 and the rest of the day is idle.
        let blocks = [
            block(day, (10, 0), (10, 30), "xcode"),
            block(day, (10, 30), (11, 0), "idle", "idle"),
        ]
        let result = stats(
            blocks, [capture(day, 10, 10, bundle: xcodeBundle)],
            sessions: [session(day, (10, 0), (11, 0), xcodeBundle)]
        )
        #expect(result.byApp.first { $0.key == "xcode" }?.minutes == 30)
        #expect(result.sessionMinutes == 30)
    }

    @Test("an interval still open is bounded by the day's blocks rather than running away")
    func openSessionIsBounded() {
        let result = stats(
            [block(day, (10, 0), (10, 30), "xcode")],
            [capture(day, 10, 10, bundle: xcodeBundle)],
            sessions: [session(day, (10, 0), nil, xcodeBundle)]
        )
        #expect(result.byApp.first { $0.key == "xcode" }?.minutes == 30)
        #expect(result.sessionMinutes == 30)
    }

    @Test("byTask, hourly and the focus metrics stay block-based")
    func blockDerivedMetricsAreUntouched() {
        let sessions = [
            session(day, (9, 0), (9, 50), chrome),
            session(day, (10, 5), (10, 30), xcodeBundle),
        ]
        let with = stats(splitBlocks, splitCaptures, sessions: sessions)
        let without = stats(splitBlocks, splitCaptures)
        #expect(with.byTask == without.byTask)
        #expect(with.hourly == without.hourly)
        #expect(with.longestFocusBlock == without.longestFocusBlock)
        #expect(with.contextSwitches == without.contextSwitches)
        #expect(with.medianBlockMinutes == without.medianBlockMinutes)
        #expect(with.activeMinutes == without.activeMinutes)
    }

    @Test("sessions covering part of the day leave the rest of the blocks alone")
    func partlyCoveredDayKeepsUncoveredBlocks() {
        // #61: the shape of 2026-09-08 — the recorder started at the end of a full day, so its
        // sessions cover the last hour of eight hours of Claude blocks. Before the guard, that
        // hour became Claude's whole total and the day's real 8h vanished from `byApp`.
        let blocks = [
            block(day, (9, 0), (12, 0), "claude_desktop"),
            block(day, (12, 0), (16, 0), "claude_desktop"),
            block(day, (16, 0), (17, 0), "claude_desktop"),
            block(day, (17, 0), (18, 0), "browser"),
        ]
        let captures = [
            capture(day, 9, 30, bundle: claudeBundle),
            capture(day, 13, 0, bundle: claudeBundle),
            capture(day, 16, 30, bundle: claudeBundle),
            capture(day, 17, 30, bundle: chrome),
        ]
        let result = stats(blocks, captures, sessions: [session(day, (16, 0), (17, 0), claudeBundle)])
        let byApp = Dictionary(uniqueKeysWithValues: result.byApp.map { ($0.key, $0.minutes) })
        // Seven uncovered hours of block seconds, plus the covered hour the sessions measured
        // exactly — eight hours, not the one hour the sessions saw.
        #expect(byApp["claude_desktop"] == 480)
        // Chrome has no session at all, so its block hour is untouched.
        #expect(byApp["browser"] == 60)
        // And the day says how much of itself is exact: one hour of nine.
        #expect(result.sessionMinutes == 60)
        #expect(abs(result.sessionCoverage - 60.0 / 540) < 0.005)
    }

    @Test("inside the covered stretch the sessions still win over the block seconds")
    func coveredStretchIsStillExact() {
        // Same day, but the hour the recorder watched was really forty minutes of Claude and
        // twenty of Chrome, which the one-frame-a-tick blocks missed. The covered part shrinks to
        // its exact total while the uncovered seven hours stand.
        let blocks = [
            block(day, (9, 0), (16, 0), "claude_desktop"),
            block(day, (16, 0), (17, 0), "claude_desktop"),
        ]
        let captures = [capture(day, 9, 30, bundle: claudeBundle), capture(day, 16, 30, bundle: claudeBundle)]
        let result = stats(blocks, captures, sessions: [
            session(day, (16, 0), (16, 40), claudeBundle),
            session(day, (16, 40), (17, 0), chrome),
        ])
        // 420 uncovered minutes + 40 exact ones, and the 20 minutes the recorder says Claude was
        // not in front are gone.
        #expect(result.byApp.first { $0.key == "claude_desktop" }?.minutes == 460)
    }

    @Test("a blocked interval carries no bundle, so it moves nobody's minutes")
    func blockedSessionAttributesNothing() {
        let sessions = [
            session(day, (9, 0), (9, 30), nil, blocked: true),
            session(day, (9, 30), (10, 0), chrome),
        ]
        let result = stats(splitBlocks, splitCaptures, sessions: sessions)
        let byApp = Dictionary(uniqueKeysWithValues: result.byApp.map { ($0.key, $0.minutes) })
        // Chrome's exact total is the thirty minutes it was named in, split by the block ratio.
        #expect((byApp["gmail"] ?? 0) + (byApp["gsheets"] ?? 0) == 30)
        // The blocked stretch still counts as covered: it is time, it is just anonymous time.
        #expect(result.sessionMinutes == 60)
    }
}

// MARK: - Time per project (#70)

/// A morning on two projects: two Claude blocks the describer said were worklens, one block it
/// said was the KPL trivia night, and one it said nothing about.
private let projectBlocks = [
    block(day, (9, 0), (9, 30), "claude_desktop"),
    block(day, (9, 30), (10, 0), "claude_desktop"),
    block(day, (10, 0), (10, 30), "browser"),
    block(day, (10, 30), (11, 0), "vscode"),
]

private let projectCaptures = [
    capture(day, 9, 10, id: "c1", bundle: claudeBundle, app: "Claude", title: "Claude"),
    capture(day, 9, 40, id: "c2", bundle: claudeBundle, app: "Claude", title: "Claude"),
    capture(day, 10, 10, id: "c3", bundle: chrome, app: "Chrome", title: "Rehearsal schedule"),
    capture(day, 10, 40, id: "c4", bundle: xcodeBundle, app: "Code", title: "StatsAggregator.swift"),
    capture(day, 10, 50, id: "c5", bundle: xcodeBundle, app: "Code", title: "StatsAggregator.swift"),
]

@Suite("StatsAggregator by project")
struct StatsProjectTests {
    private func byProject(_ hints: [String: String]) -> DailyStats {
        StatsAggregator.daily(
            day: day, blocks: projectBlocks, captures: projectCaptures,
            projectHints: hints, timeZone: zone
        )
    }

    @Test("the day's minutes land on the projects its frames named")
    func projectsGetTheirMinutes() {
        let result = byProject([
            "c1": "worklens", "c2": "Worklens",
            "c3": "KPL trivia night", "c4": "KPL", "c5": "KPL trivia night",
        ])
        let rows = Dictionary(uniqueKeysWithValues: result.byProject.map { ($0.key, $0.minutes) })
        let names = Dictionary(uniqueKeysWithValues: result.byProject.map { ($0.key, $0.name) })
        #expect(rows["worklens"] == 60)
        // Two spellings, one project; the commoner spelling — here the tie-breaker — is shown.
        #expect(names["worklens"] == "Worklens")
        // "KPL" merges into the fuller spelling, so the trivia night is one project of 60 minutes.
        #expect(rows["kpl trivia night"] == 60)
        #expect(names["kpl trivia night"] == "KPL trivia night")
        #expect(rows[StatsAggregator.unattributedProjectKey] == nil)
        #expect(result.byProject.count == 2)
    }

    @Test("the canonical list decides the row's key and name (#90)")
    func canonicalProjects() {
        let result = StatsAggregator.daily(
            day: day, blocks: projectBlocks, captures: projectCaptures,
            projectHints: [
                "c1": "worklens", "c2": "Worklens",
                "c3": "KPL", "c4": "Trivia Night", "c5": "KPL trivia night",
            ],
            projects: [
                ProjectEntry(key: "worklens", name: "Worklens"),
                ProjectEntry(key: "kpl", name: "KPL trivia night", aliases: ["Trivia Night"]),
            ],
            timeZone: zone
        )
        let rows = Dictionary(uniqueKeysWithValues: result.byProject.map { ($0.key, $0.minutes) })
        #expect(rows["worklens"] == 60)
        #expect(rows["kpl"] == 60)
        #expect(result.byProject.allSatisfy { $0.key != "kpl trivia night" })
    }

    @Test("each project row names the apps its time was spent in (#90)")
    func projectRowsCarryTheirApps() throws {
        let result = byProject([
            "c1": "worklens", "c2": "worklens",
            "c3": "worklens", "c4": "worklens", "c5": "worklens",
        ])
        let row = try #require(result.byProject.first { $0.key == "worklens" })
        let apps = try #require(row.parts)
        #expect(apps.map(\.key) == ["claude_desktop", "browser", "vscode"])
        #expect(apps.map(\.minutes) == [60, 30, 30])
        // Shares are of the project, not of the day: half of it was Claude Desktop.
        #expect(abs(apps[0].share - 0.5) < 0.005)
    }

    @Test("frames with no hint become an explicit unattributed row, so the shares add up")
    func unattributedIsExplicit() {
        let result = byProject(["c1": "worklens", "c2": "worklens", "c3": ""])
        let rows = Dictionary(uniqueKeysWithValues: result.byProject.map { ($0.key, $0.minutes) })
        #expect(rows["worklens"] == 60)
        // The empty hint and the two frames with no row at all: one hour between them.
        #expect(rows[StatsAggregator.unattributedProjectKey] == 60)
        #expect(abs(result.byProject.reduce(0) { $0 + $1.share } - 1) < 0.005)
    }

    @Test("a hint that only repeats the frame's window title is not a project")
    func windowTitleIsNotAProject() {
        let result = byProject(["c3": "Rehearsal schedule", "c4": "worklens", "c5": "worklens"])
        let rows = Dictionary(uniqueKeysWithValues: result.byProject.map { ($0.key, $0.minutes) })
        #expect(rows["rehearsal schedule"] == nil)
        #expect(rows["worklens"] == 30)
        // The browser half-hour the hint was dropped on, plus the two Claude blocks.
        #expect(rows[StatsAggregator.unattributedProjectKey] == 90)
    }

    @Test("a day with no hints has no by-project rows")
    func noHintsNoTable() {
        let without = StatsAggregator.daily(
            day: day, blocks: projectBlocks, captures: projectCaptures, timeZone: zone
        )
        #expect(without.byProject.isEmpty)
    }

    @Test("idle and meeting time is not attributed to a project")
    func onlyScreenActiveTimeCounts() {
        let blocks = projectBlocks + [
            block(day, (11, 0), (11, 30), "idle", "idle"),
            block(day, (9, 0), (10, 0), ContextBlocks.appKey, StatsAggregator.meetingTaskKey,
                  source: .calendar),
        ]
        let captures = projectCaptures + [capture(day, 11, 10, id: "idle1", bundle: claudeBundle)]
        let result = StatsAggregator.daily(
            day: day, blocks: blocks, captures: captures,
            projectHints: ["c1": "worklens", "idle1": "worklens"], timeZone: zone
        )
        // The idle frame carried a hint too; only the thirty screen-active minutes count.
        #expect(result.byProject.first { $0.key == "worklens" }?.minutes == 30)
    }

    @Test("the week merges projects the way it merges hosts")
    func weeklyMergesProjects() {
        let monday = byProject(["c1": "worklens", "c2": "worklens", "c3": "KPL trivia night"])
        let tuesday = byProject(["c1": "Worklens", "c3": "KPL trivia night"])
        var second = tuesday
        second.day = "2026-09-05"
        let week = StatsAggregator.weekly(days: [monday, second], timeZone: zone)
        let rows = Dictionary(uniqueKeysWithValues: week.totals.byProject.map { ($0.key, $0.minutes) })
        // Monday's 60 + Tuesday's 30: the rows key on the folded label, so `Worklens` and
        // `worklens` are one project across the week rather than two.
        #expect(rows["worklens"] == 90)
        #expect(rows["kpl trivia night"] == 60)
        // Monday's half-hour in vscode, and Tuesday's vscode plus its second Claude block.
        #expect(rows[StatsAggregator.unattributedProjectKey] == 90)
    }
}

// MARK: - Threads (#91)

/// A morning that leaves the lyrics doc and comes back to it: worklens, then the trivia night,
/// then worklens again.
private let threadBlocks = [
    block(day, (9, 0), (9, 30), "claude_desktop"),
    block(day, (9, 30), (10, 0), "browser"),
    block(day, (10, 0), (10, 45), "claude_desktop"),
]

private let threadCaptures = [
    capture(day, 9, 10, id: "t1", bundle: claudeBundle, app: "Claude", title: "Claude"),
    capture(day, 9, 40, id: "t2", bundle: chrome, app: "Chrome", title: "Rehearsal schedule"),
    capture(day, 10, 10, id: "t3", bundle: claudeBundle, app: "Claude", title: "Claude"),
]

@Suite("StatsAggregator threads")
struct StatsThreadTests {
    private func threads(
        blocks: [ActivityBlock] = threadBlocks,
        captures: [Capture] = threadCaptures,
        hints: [String: String] = [:],
        documents: [String: String] = [:],
        projects: [ProjectEntry] = []
    ) -> [ThreadStat] {
        StatsAggregator.daily(
            day: day, blocks: blocks, captures: captures,
            projectHints: hints, frameDocuments: documents, projects: projects, timeZone: zone
        ).threads
    }

    @Test("A, B, A is one thread visited twice, not two pieces of work")
    func reentry() throws {
        let result = threads(hints: [
            "t1": "worklens", "t2": "KPL trivia night", "t3": "worklens",
        ])
        let worklens = try #require(result.first { $0.key == "worklens" })
        #expect(worklens.visits == 2)
        #expect(worklens.reentries == 1)
        // The two visits are 30 and 45 minutes; the total is both, the longest run only the second.
        #expect(worklens.totalMinutes == 75)
        #expect(worklens.longestRunMinutes == 45)
        // The trivia night sat between them for half an hour.
        #expect(worklens.medianGapMinutes == 30)
        #expect(worklens.firstAt == at(day, 9, 0))
        #expect(worklens.lastAt == at(day, 10, 45))

        let show = try #require(result.first { $0.key == "kpl trivia night" })
        #expect(show.visits == 1)
        #expect(show.reentries == 0)
        #expect(show.medianGapMinutes == 0)
    }

    @Test("one uninterrupted block is one visit and its own longest run")
    func singleRun() {
        let result = threads(
            blocks: [block(day, (9, 0), (9, 45), "claude_desktop")],
            captures: [capture(day, 9, 10, id: "t1", bundle: claudeBundle, app: "Claude", title: "Claude")],
            hints: ["t1": "worklens"]
        )
        #expect(result.count == 1)
        #expect(result[0].longestRunMinutes == 45)
        #expect(result[0].totalMinutes == 45)
        #expect(result[0].visits == 1)
        #expect(result[0].reentries == 0)
    }

    @Test("blocks with no project fall back to app plus document")
    func documentFallback() throws {
        let result = threads(documents: [
            "t1": "Trivia night lyrics", "t2": "Rehearsal schedule", "t3": "Trivia night lyrics",
        ])
        // Named after the app the block was in and the document on screen, not after a project.
        let lyrics = try #require(result.first { $0.key == "claude_desktop/trivia night lyrics" })
        #expect(lyrics.project == "Claude: Trivia night lyrics")
        #expect(lyrics.visits == 2)
        #expect(lyrics.totalMinutes == 75)
        #expect(result.contains { $0.key == "browser/rehearsal schedule" })
    }

    @Test("a project beats the document on the same frame, and the day's projects group as one")
    func projectWinsOverDocument() throws {
        let result = threads(
            hints: ["t1": "worklens", "t3": "Worklens"],
            documents: ["t1": "StatsAggregator.swift", "t2": "Rehearsal schedule", "t3": "DailyStats.swift"]
        )
        // Two spellings of one project, two different documents: still one thread, visited twice.
        let worklens = try #require(result.first { $0.key == "worklens" })
        #expect(worklens.visits == 2)
        #expect(worklens.totalMinutes == 75)
        // The frame that named no project keeps its document thread.
        #expect(result.contains { $0.key == "browser/rehearsal schedule" })
    }

    @Test("a block nothing was said about ends a visit rather than being skipped over")
    func unnameableBlockInterrupts() throws {
        let result = threads(hints: ["t1": "worklens", "t3": "worklens"])
        let worklens = try #require(result.first { $0.key == "worklens" })
        #expect(worklens.visits == 2)
        #expect(result.count == 1)
    }

    @Test("an idle stretch ends a visit: coming back to a thread is the thing being counted")
    func idleEndsAVisit() throws {
        let result = threads(
            blocks: [
                block(day, (9, 0), (9, 30), "claude_desktop"),
                block(day, (9, 30), (10, 0), "idle", "idle"),
                block(day, (10, 0), (10, 45), "claude_desktop"),
            ],
            captures: [
                capture(day, 9, 10, id: "t1", bundle: claudeBundle, app: "Claude", title: "Claude"),
                capture(day, 10, 10, id: "t3", bundle: claudeBundle, app: "Claude", title: "Claude"),
            ],
            hints: ["t1": "worklens", "t3": "worklens"]
        )
        let worklens = try #require(result.first { $0.key == "worklens" })
        #expect(worklens.visits == 2)
        // The idle half hour is the gap, and it is not part of the thread's minutes.
        #expect(worklens.medianGapMinutes == 30)
        #expect(worklens.totalMinutes == 75)
    }

    @Test("a meeting block laid over the screen does not break the thread underneath it")
    func meetingDoesNotInterrupt() throws {
        let result = threads(
            blocks: threadBlocks + [
                block(day, (9, 0), (10, 45), "granola", "meeting", source: .calendar),
            ],
            hints: ["t1": "worklens", "t2": "KPL trivia night", "t3": "worklens"]
        )
        #expect(try #require(result.first { $0.key == "worklens" }).visits == 2)
    }

    @Test("a day whose frames named neither a project nor a document has no threads")
    func nothingNamed() {
        #expect(threads().isEmpty)
    }
}

// MARK: - Weekly project ledger (#91)

@Suite("StatsAggregator project ledger")
struct StatsProjectLedgerTests {
    private func day(_ date: String, _ projects: [(String, Int)]) -> DailyStats {
        DailyStats(
            day: date,
            trackedMinutes: projects.reduce(0) { $0 + $1.1 },
            activeMinutes: projects.reduce(0) { $0 + $1.1 },
            byProject: projects.map { Slice(key: $0.0, name: $0.0, minutes: $0.1, share: 0) }
        )
    }

    @Test("a day's column adds up to exactly that day's by-project table")
    func totalsMatchByProject() {
        let days = [
            day("2026-08-31", [("worklens", 120), ("kpl trivia night", 45), ("unattributed", 20)]),
            day("2026-09-01", [("worklens", 60), ("unattributed", 15)]),
        ]
        let week = StatsAggregator.weekly(days: days, timeZone: zone)
        for stats in days {
            let fromLedger = week.projectLedger.reduce(0) { $0 + ($1.minutesPerDay[stats.day] ?? 0) }
            #expect(fromLedger == stats.byProject.reduce(0) { $0 + $1.minutes })
        }
    }

    @Test("a project's row carries its week, its total and the days it ran on")
    func rowShape() throws {
        let week = StatsAggregator.weekly(
            days: [
                day("2026-08-31", [("worklens", 120), ("kpl trivia night", 45)]),
                day("2026-09-01", [("worklens", 60)]),
                day("2026-09-02", [("kpl trivia night", 200)]),
            ],
            timeZone: zone
        )
        // Ordered by the week's total: the trivia night's 245 minutes beat worklens's 180.
        #expect(week.projectLedger.map(\.key) == ["kpl trivia night", "worklens"])
        let worklens = try #require(week.projectLedger.first { $0.key == "worklens" })
        #expect(worklens.totalMinutes == 180)
        #expect(worklens.daysSeen == 2)
        #expect(worklens.minutesPerDay == ["2026-08-31": 120, "2026-09-01": 60])
        // A day it got nothing on is absent rather than zero.
        #expect(worklens.minutesPerDay["2026-09-02"] == nil)
    }

    @Test("a tracked week whose days named no project has no ledger")
    func noProjects() {
        var tracked = day("2026-08-31", [])
        tracked.trackedMinutes = 240
        tracked.activeMinutes = 240
        let week = StatsAggregator.weekly(days: [tracked], timeZone: zone)
        #expect(week.totals.daysTracked == 1)
        #expect(week.projectLedger.isEmpty)
    }
}

// MARK: - Calendar blocks and the current time

/// #19 writes the whole day's meetings at sync time. Observed 2026-09-23 at 10:38: the menu read
/// "4h 21m active · 4h 15m in meetings" about ninety minutes into the day.
@Suite("StatsAggregator calendar blocks and now")
struct StatsNowTests {
    /// Screen 09:00-10:30, a call 10:00-11:00 still running at 10:30, and one at 14:00.
    private let blocks = [
        block(day, (9, 0), (10, 30), "vscode", "coding"),
        block(day, (10, 0), (11, 0), "zoom", "meeting", source: .calendar),
        block(day, (14, 0), (15, 0), "zoom", "meeting", source: .calendar),
    ]

    @Test("today counts a running meeting up to now and an upcoming one not at all")
    func today() {
        let result = StatsAggregator.daily(
            day: day, blocks: blocks, timeZone: zone, now: at(day, 10, 30)
        )
        #expect(result.trackedMinutes == 90)
        #expect(result.activeMinutes == 90)
        #expect(result.meetingMinutes == 30)
        #expect(result.lastActivity == at(day, 10, 30))
    }

    @Test("a past day counts every meeting whole")
    func pastDay() {
        let result = StatsAggregator.daily(
            day: day, blocks: blocks, timeZone: zone, now: at(day, 23, 0).addingTimeInterval(86_400)
        )
        #expect(result.activeMinutes == 180)
        #expect(result.meetingMinutes == 120)
        #expect(result.lastActivity == at(day, 15, 0))
    }

    @Test("only calendar blocks are cut; without a now nothing is")
    func clipping() {
        let now = at(day, 10, 30)
        let granola = block(day, (10, 0), (11, 0), "granola", "notes", source: .granola)
        let clipped = StatsAggregator.clippedToNow(blocks + [granola], now: now)
        #expect(clipped.map(\.endAt) == [at(day, 10, 30), now, at(day, 11, 0)])
        #expect(clipped.map(\.source) == [.screen, .calendar, .granola])
        #expect(StatsAggregator.clippedToNow(blocks, now: nil) == blocks)
    }
}
