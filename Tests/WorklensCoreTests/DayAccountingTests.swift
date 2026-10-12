import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-10"
private let dayRange = DayBoundaries.range(day: day, timeZone: utc)!
/// A moment long after the day, so nothing is cut at now.
private let later = dayRange.end.addingTimeInterval(86_400)

private func at(_ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
    dayRange.start.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60 + second)
}

private func screen(_ from: Date, _ to: Date, task: String = "coding") -> ActivityBlock {
    ActivityBlock(day: day, startAt: from, endAt: to, appKey: "xcode", taskKey: task, source: .screen)
}

private func row(
    _ time: Date, skip: SkipReason? = nil, interval: Int? = nil, meeting: Bool = false
) -> Capture {
    Capture(
        capturedAt: time, isIdle: skip != nil, isMeeting: meeting, intervalSeconds: interval,
        skipReason: skip
    )
}

private func account(
    range: (start: Date, end: Date) = dayRange,
    now: Date = later,
    blocks: [ActivityBlock] = [],
    captures: [Capture] = [],
    carryIn: Capture? = nil,
    sessions: [ForegroundSession] = [],
    events: [CoverageEvent] = [],
    gaps: [CoverageGap] = []
) -> DayAccounting {
    DayAccounting.compute(
        range: range, now: now, blocks: blocks, captures: captures, carryIn: carryIn,
        sessions: sessions, coverageEvents: events, gaps: gaps, baseIntervals: .shipped
    )
}

/// Every bucket's minutes add up to the total.
private func sums(_ minutes: DayAccounting.Minutes) -> Bool {
    DayAccounting.Bucket.allCases.reduce(0) { $0 + minutes[$1] } == minutes.total
}

@Suite("Day accounting (#320)")
struct DayAccountingTests {
    // MARK: Totals

    @Test("a day is 1,440 minutes, and an empty one is all unexplained with no window")
    func emptyDay() {
        let result = account()
        #expect(result.day.total == 1440)
        #expect(result.day.unexplained == 1440)
        #expect(sums(result.day))
        #expect(result.window == nil)
        #expect(result.firstEvidence == nil)
        #expect(result.spans == [DayAccounting.Span(start: dayRange.start, end: dayRange.end, bucket: .unexplained)])
    }

    @Test("New York's 2026 clock changes make 1,380 and 1,500 minute days")
    func daylightSaving() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        for (day, minutes) in [("2026-03-08", 1380), ("2026-11-01", 1500)] {
            let range = try #require(DayBoundaries.range(day: day, timeZone: newYork))
            let result = account(range: range, now: range.end.addingTimeInterval(86_400))
            #expect(result.day.total == minutes)
            #expect(result.day.unexplained == minutes)
        }
    }

    @Test("the window runs exactly from the first evidence to the last, fractional seconds and all")
    func windowIsExact() throws {
        let first = at(9, 0, 0.25)
        let last = at(9, 10, 40.5)
        let result = account(blocks: [screen(first, last)], captures: [row(first)])
        #expect(result.firstEvidence == first)
        #expect(result.lastEvidence == last)
        let window = try #require(result.window)
        // 10 min 40.25 s rounds to 11; the buckets still add up to it.
        #expect(window.total == 11)
        #expect(window.screen == 11)
        #expect(sums(window))
        #expect(result.day.total == 1440)
        #expect(sums(result.day))
    }

    // MARK: Holds

    @Test("locked at 12:00 and a frame at 13:00 is 60 locked minutes")
    func lockHolds() {
        let result = account(
            blocks: [screen(at(13, 0), at(13, 5))],
            captures: [row(at(12, 0), skip: .locked), row(at(13, 0), interval: 60)]
        )
        #expect(result.day.locked == 60)
        #expect(result.day.screen == 5)
        #expect(sums(result.day))
    }

    @Test("a stopped transition ends a hold")
    func stoppedEndsHold() {
        let result = account(
            blocks: [screen(at(13, 0), at(13, 5))],
            captures: [row(at(12, 0), skip: .locked), row(at(13, 0), interval: 60)],
            events: [CoverageEvent(at: at(12, 20), kind: .stopped), CoverageEvent(at: at(13, 0), kind: .started)],
            gaps: [CoverageGap(start: at(12, 20), end: at(13, 0), reason: .notRunning)]
        )
        #expect(result.day.locked == 20)
        #expect(result.day.notRunning == 40)
    }

    @Test("the last row before midnight carries its hold into the day")
    func carryIn() {
        let result = account(
            blocks: [screen(at(7, 0), at(7, 30))],
            captures: [row(at(7, 0), interval: 60)],
            carryIn: row(dayRange.start.addingTimeInterval(-3600), skip: .locked)
        )
        #expect(result.day.locked == 420)
        // The window starts at the first thing recorded today, not at the carried hold.
        #expect(result.firstEvidence == at(7, 0))
        #expect(result.window?.locked == 0)
    }

    @Test("asleep, then locked, splits between the two")
    func asleepThenLocked() {
        let result = account(captures: [
            row(at(1, 0), skip: .asleep), row(at(3, 0), skip: .locked), row(at(4, 0), interval: 60),
        ])
        #expect(result.day.asleep == 120)
        #expect(result.day.locked == 60)
    }

    @Test("an idle block outside every hold is idle")
    func idleBlock() {
        let idle = ActivityBlock(
            day: day, startAt: at(15, 0), endAt: at(15, 20), appKey: "idle", taskKey: "idle", source: .screen
        )
        #expect(account(blocks: [idle]).day.idle == 20)
    }

    @Test("a locked or asleep block outside every hold keeps its bucket; a screensaver is idle")
    func inactiveBlockKeys() {
        func block(_ key: String, _ hour: Int) -> ActivityBlock {
            ActivityBlock(
                day: day, startAt: at(hour, 0), endAt: at(hour, 10), appKey: key, taskKey: key, source: .screen
            )
        }
        let result = account(blocks: [block("locked", 15), block("asleep", 16), block("screensaver", 17)])
        #expect(result.day.locked == 10)
        #expect(result.day.asleep == 10)
        #expect(result.day.idle == 10)
        #expect(sums(result.day))
    }

    // MARK: Ranks

    @Test("a meeting over screen time counts once, and outranks not running")
    func meetingOutranks() {
        let call = ActivityBlock(
            day: day, startAt: at(10, 30), endAt: at(11, 30), appKey: "calendar", taskKey: "meeting",
            source: .calendar
        )
        let result = account(
            blocks: [screen(at(10, 0), at(11, 0)), call],
            gaps: [CoverageGap(start: at(11, 0), end: at(12, 0), reason: .notRunning)]
        )
        #expect(result.day.meeting == 60)
        #expect(result.day.screen == 30)
        #expect(result.day.notRunning == 30)
        #expect(sums(result.day))
    }

    @Test("a meeting frame inside an unlabelled block is meeting time, as meetingMinutes counts it")
    func meetingFrame() {
        let result = account(
            blocks: [screen(at(10, 0), at(11, 0), task: "talking")],
            captures: [row(at(10, 0), interval: 60), row(at(10, 20), interval: 60, meeting: true), row(at(10, 40), interval: 60)]
        )
        #expect(result.day.meeting == 20)
        #expect(result.day.screen == 40)
        #expect(sums(result.day))
    }

    @Test("a calendar event that says you were away is away")
    func away() {
        let lunch = ActivityBlock(
            day: day, startAt: at(12, 0), endAt: at(13, 0), appKey: "away", taskKey: "lunch",
            source: .calendar
        )
        let result = account(blocks: [lunch])
        #expect(result.day.away == 60)
        #expect(result.day.meeting == 0)
    }

    // MARK: Battery cadence

    @Test("a 300 s frame outside a meeting is the battery cadence")
    func batterySparse() {
        let result = account(
            blocks: [screen(at(10, 0), at(10, 30))], captures: [row(at(10, 0), interval: 300)]
        )
        #expect(result.day.batterySparse == 30)
        #expect(result.day.screen == 0)
    }

    @Test("a 300 s meeting frame and a frame with no interval are not")
    func notSparse() {
        let meeting = account(
            blocks: [screen(at(10, 0), at(10, 30), task: "talking")],
            captures: [row(at(10, 0), interval: 300, meeting: true)]
        )
        #expect(meeting.day.batterySparse == 0)
        #expect(meeting.day.meeting == 30)
        let unknown = account(blocks: [screen(at(10, 0), at(10, 30))], captures: [row(at(10, 0))])
        #expect(unknown.day.batterySparse == 0)
        #expect(unknown.day.screen == 30)
    }

    // MARK: Sessions and gaps

    @Test("a foreground session with no block over it is screen time")
    func sessionWithoutBlock() {
        let session = ForegroundSession(startAt: at(14, 0), endAt: at(14, 30))
        let result = account(sessions: [session])
        #expect(result.day.screen == 30)
        #expect(result.firstEvidence == at(14, 0))
    }

    @Test("each gap reason has its bucket, and budget changes nothing")
    func gapReasons() {
        let result = account(gaps: [
            CoverageGap(start: at(1, 0), end: at(2, 0), reason: .paused),
            CoverageGap(start: at(2, 0), end: at(3, 0), reason: .permissionMissing),
            CoverageGap(start: at(3, 0), end: at(4, 0), reason: .notRunning),
            CoverageGap(start: at(4, 0), end: at(5, 0), reason: .budget),
        ])
        #expect(result.day.paused == 60)
        #expect(result.day.permissionMissing == 60)
        #expect(result.day.notRunning == 60)
        #expect(result.day.unexplained == 1440 - 180)
    }

    // MARK: Today and spans

    @Test("today stops at now, and an open session counts up to it")
    func todayStopsAtNow() {
        let open = ForegroundSession(startAt: at(15, 0))
        let today = account(now: at(15, 30), sessions: [open])
        #expect(today.through == at(15, 30))
        #expect(today.day.total == 930)
        #expect(today.day.screen == 30)
        #expect(today.spans?.last?.end == at(15, 30))
        // The same open row on a past day says nothing.
        #expect(account(sessions: [open]).day.screen == 0)
    }

    @Test("spans are contiguous, cover the day and merge equal neighbours")
    func spansContiguous() throws {
        let result = account(
            blocks: [screen(at(10, 0), at(11, 0)), screen(at(11, 0), at(12, 0))],
            captures: [row(at(12, 30), skip: .locked), row(at(13, 0), interval: 300)],
            sessions: [ForegroundSession(startAt: at(13, 0), endAt: at(13, 10))]
        )
        let spans = try #require(result.spans)
        #expect(spans.first?.start == dayRange.start)
        #expect(spans.last?.end == dayRange.end)
        for (left, right) in zip(spans, spans.dropFirst()) {
            #expect(left.end == right.start)
            #expect(left.bucket != right.bucket)
        }
        #expect(spans.contains(DayAccounting.Span(start: at(10, 0), end: at(12, 0), bucket: .screen)))
        #expect(spans.map(\.bucket) == [.unexplained, .screen, .unexplained, .locked, .screen, .unexplained])
    }

    @Test("minutes round by largest remainder, so they always add up")
    func largestRemainder() {
        let minutes = DayAccounting.Minutes(
            seconds: [.screen: 40, .idle: 40, .locked: 40], totalSeconds: 120
        )
        #expect(minutes.total == 2)
        #expect(sums(minutes))
        #expect(minutes.screen == 1 && minutes.locked == 1 && minutes.idle == 0)
    }
}
