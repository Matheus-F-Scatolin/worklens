import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayRange = DayBoundaries.range(day: day, timeZone: utc)!
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayRange.start.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

@Suite("Coverage spans (#146)")
struct CoverageSpansTests {
    // MARK: Deriving spans

    @Test("a day Worklens watched from end to end has no spans")
    func wholeDay() {
        // The only thing the table knows is that the app was already running yesterday.
        let events = [CoverageEvent(at: at(-4, 0), kind: .started)]
        #expect(CoverageSpans.gaps(events: events, start: dayRange.start, end: dayRange.end).isEmpty)
    }

    @Test("a day with no coverage rows at all claims nothing")
    func unknownDay() {
        // Days from before the table existed are unknown, and unknown is not "not watching".
        #expect(CoverageSpans.gaps(events: [], start: dayRange.start, end: dayRange.end).isEmpty)
    }

    @Test("a day that is entirely uncovered is one span, and says so in words")
    func entirelyUncovered() {
        let events = [CoverageEvent(at: at(-6, 0), kind: .stopped)]
        let gaps = CoverageSpans.gaps(events: events, start: dayRange.start, end: dayRange.end)
        #expect(gaps.count == 1)
        #expect(gaps.first?.reason == .notRunning)
        #expect(gaps.first?.start == dayRange.start)
        #expect(gaps.first?.end == dayRange.end)
        #expect(
            CoverageSpans.sentence(gaps, within: dayRange, timeZone: utc)
                == "Worklens was not running all day"
        )
    }

    @Test("a pause and an evening quit read as the day's two gaps")
    func pauseAndQuit() {
        let events = [
            CoverageEvent(at: at(-6, 0), kind: .stopped),
            CoverageEvent(at: at(9, 12), kind: .started),
            CoverageEvent(at: at(14, 0), kind: .paused, reason: .user),
            CoverageEvent(at: at(15, 20), kind: .resumed),
            CoverageEvent(at: at(18, 4), kind: .stopped),
        ]
        let gaps = CoverageSpans.gaps(events: events, start: dayRange.start, end: dayRange.end)
        #expect(gaps.map(\.reason) == [.notRunning, .paused, .notRunning])
        #expect(
            CoverageSpans.sentence(gaps, within: dayRange, timeZone: utc)
                == "Worklens was not running until 09:12, paused 14:00-15:20, not running from 18:04"
        )
    }

    @Test("a revoked Screen Recording grant is its own kind of gap")
    func permissionGap() {
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(11, 0), kind: .paused, reason: .permissionMissing),
            CoverageEvent(at: at(12, 30), kind: .resumed),
        ]
        let gaps = CoverageSpans.gaps(events: events, start: dayRange.start, end: dayRange.end)
        #expect(gaps.count == 1)
        #expect(
            CoverageSpans.sentence(gaps, within: dayRange, timeZone: utc)
                == "Worklens was without Screen Recording permission 11:00-12:30"
        )
    }

    // MARK: Merging

    @Test("spans shorter than a minute are dropped")
    func dropsShortSpans() {
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(10, 0), kind: .stopped),
            CoverageEvent(at: at(10, 0).addingTimeInterval(20), kind: .started),
        ]
        #expect(CoverageSpans.gaps(events: events, start: dayRange.start, end: dayRange.end).isEmpty)
    }

    @Test("two spans of the same kind less than a minute apart are one span")
    func mergesNeighbours() {
        let first = CoverageGap(start: at(10, 0), end: at(10, 30), reason: .notRunning)
        let blink = CoverageGap(
            start: at(10, 30).addingTimeInterval(30), end: at(11, 0), reason: .notRunning
        )
        let merged = CoverageSpans.merge([blink, first])
        #expect(merged.count == 1)
        #expect(merged.first?.start == at(10, 0))
        #expect(merged.first?.end == at(11, 0))
    }

    @Test("two spans of different kinds stay two spans")
    func keepsDifferentReasonsApart() {
        let paused = CoverageGap(start: at(10, 0), end: at(10, 30), reason: .paused)
        let stopped = CoverageGap(start: at(10, 30), end: at(11, 0), reason: .notRunning)
        #expect(CoverageSpans.merge([paused, stopped]).count == 2)
    }

    // MARK: The budget's own rows

    @Test("a budget stretch is read off the capture rows it already writes")
    func budgetSpans() {
        let rows: [(at: Date, skipReason: SkipReason?)] = [
            (at(9, 0), nil),
            (at(16, 0), .budget),
            (at(16, 1), .budget),
            (at(17, 30), .budget),
            (at(18, 0), .idle),
        ]
        let gaps = CoverageSpans.budgetGaps(rows: rows, end: dayRange.end)
        #expect(gaps.count == 1)
        #expect(gaps.first?.start == at(16, 0))
        #expect(gaps.first?.end == at(18, 0))
        #expect(
            CoverageSpans.sentence(gaps, within: dayRange, timeZone: utc)
                == "Worklens was over the daily budget 16:00-18:00"
        )
    }

    @Test("a budget stretch stops where the app did, so the evening is told once")
    func budgetStopsWithTheApp() throws {
        let db = try Database.inMemory()
        let coverage = CoverageEventStore(db)
        try coverage.insert(CoverageEvent(at: at(9, 0), kind: .started))
        try coverage.insert(CoverageEvent(at: at(18, 0), kind: .stopped))

        let captures = CaptureStore(db)
        try captures.insert(Capture(capturedAt: at(16, 0), skipReason: .budget, describeStatus: .skipped))
        try captures.insert(Capture(capturedAt: at(17, 55), skipReason: .budget, describeStatus: .skipped))

        let gaps = try coverage.gaps(day: day, timeZone: utc, now: dayRange.end)
        #expect(
            CoverageSpans.sentence(gaps, within: dayRange, timeZone: utc)
                == "Worklens was over the daily budget 16:00-18:00, not running from 18:00"
        )
    }

    // MARK: Proof that Worklens was running (#313)

    @Test("a capture five minutes after a stopped ends the gap there")
    func proofEndsGap() {
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(12, 0), kind: .stopped),
        ]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(12, 5), at(12, 10)], start: dayRange.start, end: dayRange.end
        )
        #expect(gaps == [CoverageGap(start: at(12, 0), end: at(12, 5), reason: .notRunning)])
    }

    @Test("a capture thirty seconds after a stopped is a straggler, not proof")
    func stragglerIsNotProof() {
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(12, 0), kind: .stopped),
        ]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(12, 0).addingTimeInterval(30)],
            start: dayRange.start, end: dayRange.end
        )
        #expect(gaps == [CoverageGap(start: at(12, 0), end: dayRange.end, reason: .notRunning)])
    }

    @Test("a stopped carried in from yesterday, then a capture before midnight, leaves no gap")
    func carriedStoppedIsClosedBeforeMidnight() {
        let events = [CoverageEvent(at: at(-10, 0), kind: .stopped)]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(-1, 0)], start: dayRange.start, end: dayRange.end
        )
        #expect(gaps.isEmpty)
    }

    @Test("proofs never end a pause or a missing permission")
    func proofsLeavePausesAlone() {
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(10, 0), kind: .paused, reason: .user),
            CoverageEvent(at: at(11, 0), kind: .resumed),
            CoverageEvent(at: at(13, 0), kind: .paused, reason: .permissionMissing),
        ]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(10, 30), at(14, 0), at(20, 0)],
            start: dayRange.start, end: dayRange.end
        )
        #expect(gaps == [
            CoverageGap(start: at(10, 0), end: at(11, 0), reason: .paused),
            CoverageGap(start: at(13, 0), end: dayRange.end, reason: .permissionMissing),
        ])
    }

    @Test("proofs with no coverage rows claim nothing")
    func proofsAloneClaimNothing() {
        let gaps = CoverageSpans.gaps(
            events: [], proofs: [at(9, 0), at(10, 0)], start: dayRange.start, end: dayRange.end
        )
        #expect(gaps.isEmpty)
    }

    @Test("a run closed at its last frame is not reopened by that frame")
    func closedRunKeepsItsGap() {
        // `closeUnfinishedRun` dates the `stopped` to the last frame the crashed run wrote.
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(17, 0), kind: .stopped),
            CoverageEvent(at: at(20, 0), kind: .started),
        ]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(16, 55), at(17, 0), at(20, 1)],
            start: dayRange.start, end: dayRange.end
        )
        #expect(gaps == [CoverageGap(start: at(17, 0), end: at(20, 0), reason: .notRunning)])
    }

    @Test("a restart after a span a proof ended is a gap from the last proof")
    func restartAfterProofKeepsDowntime() {
        // The stray `stopped` outranks the crash's own: `closeUnfinishedRun` sees a `stopped` as
        // the latest row and writes none, so the restart is the only sign the run ended.
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(12, 0), kind: .stopped),
            CoverageEvent(at: at(14, 0), kind: .started),
        ]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(12, 5), at(12, 30), at(14, 1)],
            start: dayRange.start, end: dayRange.end
        )
        #expect(gaps == [
            CoverageGap(start: at(12, 0), end: at(12, 5), reason: .notRunning),
            CoverageGap(start: at(12, 30), end: at(14, 0), reason: .notRunning),
        ])
    }

    @Test("a restart within a minute of the last proof is not a gap")
    func quickRestartAfterProof() {
        let events = [
            CoverageEvent(at: at(9, 0), kind: .started),
            CoverageEvent(at: at(12, 0), kind: .stopped),
            CoverageEvent(at: at(12, 31), kind: .started),
        ]
        let gaps = CoverageSpans.gaps(
            events: events, proofs: [at(12, 5), at(12, 30).addingTimeInterval(30)],
            start: dayRange.start, end: dayRange.end
        )
        #expect(gaps == [CoverageGap(start: at(12, 0), end: at(12, 5), reason: .notRunning)])
    }

    @Test("a stray stopped from a second copy does not erase the week after it")
    func strayStoppedWeek() throws {
        let db = try Database.inMemory()
        let coverage = CoverageEventStore(db)
        let captures = CaptureStore(db)
        let sessions = ForegroundSessionStore(db)
        try coverage.insert(CoverageEvent(at: at(8, 0), kind: .started))
        // The second copy's `stopped`, written while the first copy kept capturing.
        let stray = at(13, 51).addingTimeInterval(52)
        try coverage.insert(CoverageEvent(at: stray, kind: .stopped))
        for dayIndex in 0..<8 {
            let base = dayIndex * 24
            for hour in [9, 12, 13, 14, 17] {
                try captures.insert(Capture(capturedAt: at(base + hour, 55), describeStatus: .pending))
            }
            try sessions.insert(ForegroundSession(startAt: at(base + 10, 0), endAt: at(base + 11, 0)))
        }
        // The next row the table holds is a restart a week later.
        try coverage.insert(CoverageEvent(at: at(7 * 24 + 23, 21), kind: .started))

        func dayString(_ offset: Int) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = utc
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: at(offset * 24, 0))
        }

        // The stray day keeps only the minutes before the next frame.
        let first = try coverage.gaps(day: day, timeZone: utc, now: at(24, 0))
        #expect(first == [CoverageGap(start: stray, end: at(13, 55), reason: .notRunning)])
        // The menu's line measures from the 08:00 start; without the proofs it would run from the
        // stray row to midnight.
        #expect(
            try coverage.uncoveredSinceStart(day: day, timeZone: utc, now: at(24, 0))
                == at(13, 55).timeIntervalSince(stray)
        )

        for offset in 1...6 {
            let middle = dayString(offset)
            let gaps = try coverage.gaps(day: middle, timeZone: utc, now: at(9 * 24, 0))
            #expect(!gaps.contains { $0.reason == .notRunning }, "day \(middle)")
            #expect(
                try coverage.uncoveredSinceStart(day: middle, timeZone: utc, now: at(9 * 24, 0)) == 0,
                "day \(middle)"
            )
        }

        // The restart says the run ended after its last frame that day, at 17:55.
        let last = try coverage.gaps(day: dayString(7), timeZone: utc, now: at(9 * 24, 0))
        #expect(last == [CoverageGap(start: at(7 * 24 + 17, 55), end: at(7 * 24 + 23, 21), reason: .notRunning)])
    }

    // MARK: The store

    @Test("the store answers a day from its rows, transitions and budget together")
    func storeGaps() throws {
        let db = try Database.inMemory()
        let coverage = CoverageEventStore(db)
        try coverage.insert(CoverageEvent(at: at(-5, 0), kind: .stopped))
        try coverage.insert(CoverageEvent(at: at(9, 0), kind: .started))
        try coverage.insert(CoverageEvent(at: at(13, 0), kind: .paused, reason: .user))
        try coverage.insert(CoverageEvent(at: at(14, 0), kind: .resumed))

        let captures = CaptureStore(db)
        try captures.insert(Capture(capturedAt: at(16, 0), skipReason: .budget, describeStatus: .skipped))
        try captures.insert(Capture(capturedAt: at(17, 0), skipReason: .budget, describeStatus: .skipped))
        try captures.insert(Capture(capturedAt: at(17, 30), describeStatus: .pending))

        let gaps = try coverage.gaps(day: day, timeZone: utc, now: at(18, 0))
        #expect(gaps.map(\.reason) == [.notRunning, .paused, .budget])
        #expect(gaps.last?.end == at(17, 30))
    }

    @Test("the menu's figure ignores the night before Worklens was started")
    func uncoveredSinceStart() throws {
        let db = try Database.inMemory()
        let coverage = CoverageEventStore(db)
        try coverage.insert(CoverageEvent(at: at(-5, 0), kind: .stopped))
        try coverage.insert(CoverageEvent(at: at(9, 0), kind: .started))
        try coverage.insert(CoverageEvent(at: at(13, 0), kind: .paused, reason: .user))
        try coverage.insert(CoverageEvent(at: at(14, 30), kind: .resumed))

        // Nine hours of night before the launch, ninety minutes of pause after it.
        #expect(
            try coverage.uncoveredSinceStart(day: day, timeZone: utc, now: at(17, 0)) == 90 * 60
        )
    }

    @Test("a gap still open at midnight counts from midnight")
    func countsAGapCarriedIntoTheDay() throws {
        let db = try Database.inMemory()
        let coverage = CoverageEventStore(db)
        // Screen Recording went last night and has not come back: no transition today at all.
        try coverage.insert(CoverageEvent(at: at(-1, 0), kind: .paused, reason: .permissionMissing))
        #expect(
            try coverage.uncoveredSinceStart(day: day, timeZone: utc, now: at(14, 0)) == 14 * 3600
        )
    }

    @Test("today is never said to be uncovered in the future")
    func clipsAtNow() throws {
        let db = try Database.inMemory()
        let coverage = CoverageEventStore(db)
        try coverage.insert(CoverageEvent(at: at(9, 0), kind: .started))
        try coverage.insert(CoverageEvent(at: at(11, 0), kind: .paused, reason: .user))
        let gaps = try coverage.gaps(day: day, timeZone: utc, now: at(11, 30))
        #expect(gaps.first?.end == at(11, 30))
    }

    // MARK: The menu

    @Test("the counts line says nothing about coverage on an ordinary day")
    func menuSaysNothingWhenWatched() {
        let counts = MenuCounts(captures: 300, described: 140, uncoveredSeconds: 5 * 60)
        let row = MenuModel.countsRow(counts, budget: 1.5, level: .nominal)
        #expect(!row.text.contains("not watched"))
    }

    @Test("the counts line names a materially incomplete day")
    func menuSaysSoWhenMaterial() {
        let counts = MenuCounts(captures: 300, described: 140, uncoveredSeconds: 80 * 60)
        let row = MenuModel.countsRow(counts, budget: 1.5, level: .nominal)
        #expect(row.text.contains("1h 20m not watched"))
    }

    // MARK: Nothing else moves (#94's discipline)

    @Test("a day that gained coverage rows has byte-identical stats, accounting aside")
    func statsDoNotMove() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        for minute in 0..<10 {
            try captures.insert(Capture(capturedAt: at(9, minute), describeStatus: .pending))
        }
        let stats = StatsService(db, timeZone: utc)
        let before = try stats.daily(day: day)
        let countsBefore = try MenuCounts.load(db: db, day: day, timeZone: utc, now: at(12, 0))

        let coverage = CoverageEventStore(db)
        try coverage.insert(CoverageEvent(at: at(8, 0), kind: .started))
        try coverage.insert(CoverageEvent(at: at(9, 30), kind: .paused, reason: .user))
        try coverage.insert(CoverageEvent(at: at(11, 0), kind: .resumed))

        var after = try stats.daily(day: day)
        // #320: the day's accounting is the one field that reads coverage rows, and it moves.
        #expect(after.accounting?.day.paused == 90)
        #expect(before.accounting?.day.paused == 0)
        after.accounting = before.accounting
        let countsAfter = try MenuCounts.load(db: db, day: day, timeZone: utc, now: at(12, 0))
        // Byte for byte, with the key order pinned: a dictionary's natural order is not stable
        // between two encodes of the same value, and this test is about the values.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(after) == (try encoder.encode(before)))
        #expect(countsAfter.captures == countsBefore.captures)
        // The one number that is allowed to move is the new one.
        #expect(countsAfter.uncoveredSeconds == 90 * 60)
    }
}
