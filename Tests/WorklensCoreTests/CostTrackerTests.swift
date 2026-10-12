import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private let noon = dayStart.addingTimeInterval(12 * 3600)

/// A clock the tests move by hand. `CostTracker` caches today's spend for a minute, so nothing
/// about the rollover can be tested against a real one.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

private func tracker(
    budget: Double, clock: FakeClock, db: Database
) -> CostTracker {
    var config = Config.defaults()
    config.dailyBudgetUSD = budget
    return CostTracker(db: db, config: config, timeZone: utc, now: { clock.now })
}

private func describeCall(_ at: Date, cost: Double, error: String? = nil) -> LLMCall {
    LLMCall(
        provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
        costUsd: cost, error: error, createdAt: at
    )
}

@Suite("CostTracker budget")
struct CostTrackerBudgetTests {
    @Test("under budget, everything is allowed")
    func underBudget() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 1.50, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 0.20))
        #expect(await cost.spendToday() == 0.20)
        #expect(await cost.isOverBudget == false)
        for purpose in LLMPurpose.allCases {
            #expect(await cost.allows(purpose))
        }
    }

    /// A spend of exactly the budget is over it: "reached" is what the issue says, and a float
    /// sum of cents never lands on a round number anyway.
    @Test("the boundary is inclusive — spend == budget is over")
    func boundary() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 0.999_999))
        #expect(await cost.isOverBudget == false)
        try await cost.record(describeCall(noon, cost: 0.000_001))
        #expect(await cost.isOverBudget == true)
    }

    @Test("over budget, describing stops and nothing brings it back but a bigger budget")
    func describeIsHardStopped() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 0.01, clock: clock, db: db)
        try await cost.record(describeCall(noon, cost: 0.05))

        #expect(await cost.allows(.describe) == false)
        #expect(await cost.allows(.describe, userInitiated: true) == false)
    }

    @Test("over budget, a scheduled report stops and one the user asked for does not")
    func reportsAreAdvisory() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 0.01, clock: clock, db: db)
        try await cost.record(describeCall(noon, cost: 0.05))

        for purpose in [LLMPurpose.reportDaily, .reportWeekly, .chat, .rangeResolve, .taxonomy] {
            #expect(await cost.allows(purpose) == false)
            #expect(await cost.allows(purpose, userInitiated: true) == true)
        }
    }

    @Test("a budget of zero means no budget at all, not a budget of nothing")
    func zeroBudget() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 0, clock: clock, db: db)
        try await cost.record(describeCall(noon, cost: 5.00))
        #expect(await cost.isOverBudget == false)
        #expect(await cost.allows(.describe))
    }

    @Test("the policy is the same shape wherever it is asked")
    func policy() {
        #expect(CostPolicy.allowsOverdraft(.describe, userInitiated: false) == false)
        #expect(CostPolicy.allowsOverdraft(.describe, userInitiated: true) == false)
        #expect(CostPolicy.allowsOverdraft(.reportDaily, userInitiated: false) == false)
        #expect(CostPolicy.allowsOverdraft(.reportDaily, userInitiated: true) == true)
        #expect(CostPolicy.allowsOverdraft(.chat, userInitiated: true) == true)
        #expect(CostPolicy.allowsOverdraft(.taxonomy, userInitiated: false) == false)
    }

    /// The default gate implementation is what the stub gates in the other suites rely on, and
    /// it must agree with the tracker's own cached answer.
    @Test("a gate that only answers isOverBudget still gets the policy right")
    func defaultGateImplementation() async {
        struct Broke: CostGate {
            var isOverBudget: Bool { get async { true } }
        }
        #expect(await Broke().allows(.describe) == false)
        #expect(await Broke().allows(.reportDaily, userInitiated: true) == true)
        #expect(await AlwaysAllowCostGate().allows(.describe) == true)
    }
}

@Suite("CostTracker rollover")
struct CostTrackerRolloverTests {
    @Test("at local midnight the total resets to the new day's spend")
    func midnightRollover() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 0.10, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 0.20))
        #expect(await cost.isOverBudget == true)

        // Same instant tomorrow. Yesterday's calls are still in the ledger and no longer count.
        clock.set(noon.addingTimeInterval(86_400))
        #expect(await cost.spendToday() == 0)
        #expect(await cost.isOverBudget == false)
        #expect(await cost.allows(.describe) == true)

        // And the ledger did not lose anything on the way.
        #expect(try LLMCallStore(db).spend(
            from: dayStart, to: dayStart.addingTimeInterval(86_400)
        ) == 0.20)
    }

    @Test("the cached total is re-read after the refresh interval, so another process shows up")
    func cacheExpires() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)
        #expect(await cost.spendToday() == 0)

        // Written behind the tracker's back, the way the CLI does it.
        try LLMCallStore(db).insert(describeCall(noon, cost: 0.40))
        #expect(await cost.spendToday() == 0)

        clock.advance(CostTracker.refreshInterval + 1)
        #expect(await cost.spendToday() == 0.40)
    }

    @Test("a call recorded by this process counts immediately, and only once")
    func recordIsImmediate() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 0.10))
        #expect(await cost.spendToday() == 0.10)
        try await cost.record(describeCall(noon, cost: 0.10))
        #expect(await cost.spendToday() == 0.20)

        // ledgerChanged is how a stage that wrote its own row tells the gate; it must not
        // double-count either.
        try LLMCallStore(db).insert(describeCall(noon, cost: 0.10))
        await cost.ledgerChanged()
        #expect(abs(await cost.spendToday() - 0.30) < 1e-9)
    }

    @Test("frames still pending a day later are retired rather than described on today's budget")
    func stalePendingRetired() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)
        let captures = CaptureStore(db)

        // Two days ago, one hour ago, and one still to come.
        let stale = Capture(capturedAt: noon.addingTimeInterval(-2 * 86_400), describeStatus: .pending)
        let recent = Capture(capturedAt: noon.addingTimeInterval(-3600), describeStatus: .pending)
        let described = Capture(capturedAt: noon.addingTimeInterval(-2 * 86_400), describeStatus: .described)
        for capture in [stale, recent, described] { try captures.insert(capture) }

        let marked = try await cost.markStalePending()
        #expect(marked == 1)

        let after = try captures.fetch(id: stale.id)
        #expect(after?.describeStatus == .skipped)
        #expect(after?.skipReason == .budget)
        // The row itself stays, so the timeline still shows the time.
        #expect(after != nil)
        #expect(try captures.fetch(id: recent.id)?.describeStatus == .pending)
        #expect(try captures.fetch(id: described.id)?.describeStatus == .described)
    }

    @Test("the rollover runs once per local day, however often it is ticked")
    func rolloverRunsOnce() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)
        let captures = CaptureStore(db)
        try captures.insert(Capture(
            capturedAt: noon.addingTimeInterval(-2 * 86_400), describeStatus: .pending
        ))

        #expect(await cost.tick() == 1)
        #expect(await cost.tick() == 0)
        clock.advance(3600)
        #expect(await cost.tick() == 0)

        // A new day looks again — and finds the backlog it retired yesterday already retired.
        clock.set(noon.addingTimeInterval(86_400))
        try captures.insert(Capture(
            capturedAt: noon.addingTimeInterval(-86_400), describeStatus: .pending
        ))
        #expect(await cost.tick() == 1)
    }
}

@Suite("CostTracker estimates")
struct CostTrackerEstimateTests {
    @Test("an estimate is the mean of the successful calls of that kind")
    func averages() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 10, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 0.10))
        try await cost.record(describeCall(noon, cost: 0.30))
        clock.advance(CostTracker.refreshInterval + 1)  // past the estimate cache
        #expect(abs(await cost.estimate(purpose: .describe) - 0.20) < 1e-9)
    }

    @Test("a failed call is not evidence of what a call costs")
    func failuresExcluded() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 10, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 0.20))
        try await cost.record(describeCall(noon, cost: 0, error: "rate limited"))
        clock.advance(CostTracker.refreshInterval + 1)
        #expect(abs(await cost.estimate(purpose: .describe) - 0.20) < 1e-9)
    }

    /// The first confirmation a user ever sees has no history behind it, and "generate anyway?"
    /// without a number in it is not a real question.
    @Test("with no history, the estimate falls back to a plausible price")
    func firstGuess() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 10, clock: clock, db: db)

        #expect(await cost.estimate(purpose: .reportDaily) == CostTracker.firstGuess(.reportDaily))
        #expect(await cost.estimate(purpose: .describe) > 0)
        // Every purpose that can cost anything has a guess. `.verify` (#124) is the exception on
        // purpose: a models-list GET bills nothing, so 0 is the fact rather than a missing entry.
        for purpose in LLMPurpose.allCases where purpose != .verify {
            #expect(CostTracker.firstGuess(purpose) > 0)
        }
        #expect(CostTracker.firstGuess(.verify) == 0)
    }

    @Test("summary is grouped by purpose across every kind of call")
    func summaryByPurpose() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 10, clock: clock, db: db)
        let ledger = LLMCallStore(db)

        for (index, purpose) in LLMPurpose.allCases.enumerated() {
            try ledger.insert(LLMCall(
                provider: "anthropic", model: "claude-opus-5", purpose: purpose,
                costUsd: Double(index + 1) / 100, createdAt: noon
            ))
        }

        let summary = try await cost.summary(days: 1)
        let today = try #require(summary.first)
        #expect(today.day == day)
        #expect(today.purposes.count == LLMPurpose.allCases.count)
        // Ordered like LLMPurpose.allCases, so the Settings columns never move.
        #expect(today.purposes.map(\.purpose) == LLMPurpose.allCases)
        #expect(abs(today.usd(.describe) - 0.01) < 1e-9)
        #expect(abs(today.reportsUSD - (0.02 + 0.03)) < 1e-9)
        // `other` carries the retired purposes — taxonomy (0.05), chat (0.04), range_resolve
        // (0.06) — and #124's `verify` (0.07 here; always $0 in real life).
        #expect(abs(today.otherUSD - (0.05 + 0.04 + 0.06 + 0.07)) < 1e-9)
        #expect(abs(today.costUsd - 0.28) < 1e-9)
        #expect(today.calls == LLMPurpose.allCases.count)
        // The point of putting `verify` in `other`: the three columns still sum to the day.
        #expect(abs((today.describeUSD + today.reportsUSD + today.otherUSD) - today.costUsd) < 1e-9)
    }

    /// The acceptance criterion from #17: the table's totals are the ledger's totals.
    @Test("the summary total equals SUM(cost_usd) over the same window")
    func totalsAgreeWithTheLedger() async throws {
        let db = try Database.inMemory()
        let clock = FakeClock(noon)
        let cost = tracker(budget: 10, clock: clock, db: db)
        let ledger = LLMCallStore(db)

        for dayOffset in 0..<7 {
            for call in 0..<3 {
                try ledger.insert(describeCall(
                    noon.addingTimeInterval(-Double(dayOffset) * 86_400),
                    cost: Double(call + 1) / 1000
                ))
            }
        }

        let summary = try await cost.summary(days: 7)
        let fromSummary = summary.reduce(0) { $0 + $1.costUsd }
        let window = try #require(LLMCallStore.window(days: 7, timeZone: utc, now: noon))
        let fromLedger = try ledger.spend(from: window.start, to: window.end)
        #expect(abs(fromSummary - fromLedger) < 1e-9)
        #expect(summary.count == 7)
    }
}
