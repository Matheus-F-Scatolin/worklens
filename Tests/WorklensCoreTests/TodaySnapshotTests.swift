import Foundation
import Testing
@testable import WorklensCore

/// #159: the numbers and the strings behind the popover's "Today" card, which the SwiftUI view
/// only draws.
@Suite("Today snapshot")
struct TodaySnapshotTests {
    private let zone = TimeZone(identifier: "UTC")!
    private let day = "2026-09-16"

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 16
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components)!
    }

    private func block(
        _ id: String,
        from: Date,
        to: Date,
        app: String = "Xcode",
        task: String = "code",
        title: String? = nil,
        source: ActivitySource = .screen,
        day: String? = nil
    ) -> ActivityBlock {
        ActivityBlock(
            id: id,
            day: day ?? self.day,
            startAt: from,
            endAt: to,
            appKey: app,
            taskKey: task,
            title: title,
            source: source
        )
    }

    @Test("active minutes skip idle and locked time")
    func activeMinutes() {
        let snapshot = TodaySnapshot.make(
            day: day,
            blocks: [
                block("a", from: at(9, 0), to: at(10, 0)),
                block("b", from: at(10, 0), to: at(10, 30), app: "idle", task: "idle"),
                block("c", from: at(10, 30), to: at(11, 0), app: "locked", task: "locked"),
                block("d", from: at(11, 0), to: at(11, 15)),
            ],
            spendUSD: 0,
            budgetUSD: 0,
            now: at(12, 0),
            timeZone: zone
        )
        #expect(snapshot.activeMinutes == 75)
        #expect(snapshot.activeLine == "1h 15m")
        #expect(!snapshot.isEmpty)
    }

    /// A calendar meeting block sits on top of the screen blocks it contains, so the two are a
    /// union rather than a sum — the same rule `StatsAggregator.daily` follows.
    @Test("a meeting over screen time is counted once")
    func meetingUnion() {
        let snapshot = TodaySnapshot.make(
            day: day,
            blocks: [
                block("screen", from: at(14, 0), to: at(15, 0)),
                block("call", from: at(14, 0), to: at(15, 0), app: "Zoom", task: "meeting", source: .calendar),
            ],
            spendUSD: 0,
            budgetUSD: 0,
            now: at(16, 0),
            timeZone: zone
        )
        #expect(snapshot.activeMinutes == 60)
        #expect(snapshot.meetingMinutes == 60)
    }

    /// The calendar sync writes the whole day's meetings up front. At 10:30 a call that runs to
    /// 11:00 has had thirty minutes, and the 14:00 one has had none.
    @Test("meetings count only up to now")
    func meetingsClippedToNow() {
        let snapshot = TodaySnapshot.make(
            day: day,
            blocks: [
                block("screen", from: at(9, 0), to: at(10, 30)),
                block("call", from: at(10, 0), to: at(11, 0), app: "Zoom", task: "meeting", source: .calendar),
                block("later", from: at(14, 0), to: at(15, 0), app: "Zoom", task: "meeting", source: .calendar),
            ],
            spendUSD: 0,
            budgetUSD: 0,
            now: at(10, 30),
            timeZone: zone
        )
        #expect(snapshot.activeMinutes == 90)
        #expect(snapshot.meetingMinutes == 30)
    }

    @Test("first activity is the earliest active block, and never an idle one")
    func firstActivity() {
        let snapshot = TodaySnapshot.make(
            day: day,
            blocks: [
                block("idle", from: at(7, 30), to: at(9, 12), app: "idle", task: "idle"),
                block("work", from: at(9, 12), to: at(9, 45)),
            ],
            spendUSD: 0,
            budgetUSD: 0,
            now: at(10, 0),
            timeZone: zone
        )
        #expect(snapshot.firstActivity == at(9, 12))
        #expect(snapshot.firstActivityLine == "09:12")
    }

    @Test("an untracked day says so rather than drawing dashes everywhere")
    func emptyDay() {
        let snapshot = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 0, budgetUSD: 2, now: at(9, 0), timeZone: zone
        )
        #expect(snapshot.isEmpty)
        #expect(snapshot.activeLine == "0m")
        #expect(snapshot.firstActivityLine == "not yet")
    }

    /// The budget meter uses the bands `SpendLevel` already defines; nothing here re-derives a
    /// threshold, and the fraction is clamped so an over-budget day draws a full bar.
    @Test("the budget meter comes from SpendLevel and clamps at full")
    func budget() {
        let nominal = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 0.50, budgetUSD: 2, now: at(9, 0), timeZone: zone
        )
        #expect(nominal.spendLevel == .nominal)
        #expect(nominal.budgetFraction == 0.25)
        #expect(nominal.budgetLine == "$0.50 of $2.00")

        let warning = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 1.70, budgetUSD: 2, now: at(9, 0), timeZone: zone
        )
        #expect(warning.spendLevel == .warning)

        let over = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 3.10, budgetUSD: 2, now: at(9, 0), timeZone: zone
        )
        #expect(over.spendLevel == .over)
        #expect(over.budgetFraction == 1)
    }

    /// `make` takes a locale so the popover can draw money the way the Mac does; it is dropped
    /// silently if it is not forwarded to the initializer, and no other test would notice.
    @Test("make forwards its locale to the money on the card")
    func makeLocale() {
        let snapshot = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 0.50, budgetUSD: 2, now: at(9, 0), timeZone: zone,
            locale: Locale(identifier: "pt_BR")
        )
        #expect(snapshot.budgetLine.contains("0,50"))
        #expect(snapshot.budgetLine.contains("2,00"))
    }

    @Test("with no budget set the meter is empty and the line is just the spend")
    func noBudget() {
        let snapshot = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 0.12, budgetUSD: 0, now: at(9, 0), timeZone: zone
        )
        #expect(snapshot.budgetFraction == 0)
        #expect(snapshot.budgetLine == "$0.12")
    }

    /// The whole point of the cache: the 30 s refresh loop never recomputes this, and a person
    /// opening the popover twice in a minute pays for one query.
    @Test("a snapshot is reused for a minute and then goes stale")
    func staleness() {
        let snapshot = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 0, budgetUSD: 0, now: at(9, 0), timeZone: zone
        )
        #expect(!snapshot.isStale(now: at(9, 0)))
        #expect(!snapshot.isStale(now: at(9, 0).addingTimeInterval(59)))
        #expect(snapshot.isStale(now: at(9, 0).addingTimeInterval(TodaySnapshot.cacheSeconds)))
        // A clock that went backwards (a time-zone change, a sleep) must not pin a stale card.
        #expect(snapshot.isStale(now: at(8, 0)))
    }

    @Test("blocks from another day do not move today's numbers")
    func otherDays() {
        let snapshot = TodaySnapshot.make(
            day: day,
            blocks: [
                block("yesterday", from: at(-4, 0), to: at(-1, 0), day: "2026-09-15"),
                block("today", from: at(9, 0), to: at(9, 20)),
            ],
            spendUSD: 0,
            budgetUSD: 0,
            now: at(10, 0),
            timeZone: zone
        )
        #expect(snapshot.activeMinutes == 20)
        #expect(snapshot.firstActivity == at(9, 0))
    }

    /// #231: the menu's one tally row. Each clause is one of the card's own lines, a clause with
    /// nothing to say is left out, and a day with nothing tracked yet has no row at all.
    @Test("the tally line joins the clauses that have something to say")
    func tallyLine() {
        let working = TodaySnapshot.make(
            day: day,
            blocks: [block("a", from: at(9, 0), to: at(11, 5))],
            spendUSD: 0.5,
            budgetUSD: 2,
            now: at(12, 0),
            timeZone: zone
        )
        #expect(working.tallyLine == "2h 05m active · $0.50 of $2.00")

        let meeting = TodaySnapshot.make(
            day: day,
            blocks: [
                block("a", from: at(9, 0), to: at(10, 0)),
                block("call", from: at(14, 0), to: at(14, 30), app: "Zoom", task: "meeting", source: .calendar),
            ],
            spendUSD: 0.5,
            budgetUSD: 2,
            now: at(15, 0),
            timeZone: zone
        )
        // Active time counts the meeting too — the card's own arithmetic, not this line's.
        #expect(meeting.tallyLine == "1h 30m active · 30m in meetings · $0.50 of $2.00")

        let nothing = TodaySnapshot.make(
            day: day, blocks: [], spendUSD: 0, budgetUSD: 2, now: at(9, 0), timeZone: zone
        )
        #expect(nothing.tallyLine.isEmpty)
    }
}
