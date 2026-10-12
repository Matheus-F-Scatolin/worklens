import Foundation
import Testing
@testable import WorklensCore

/// #137: the one-day budget raise — what it outranks, how long it lasts, and what it puts back
/// in the describe queue.
private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start
private let noon = dayStart.addingTimeInterval(12 * 3600)

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

private func tracker(budget: Double, clock: Clock, db: Database) -> CostTracker {
    var config = Config.defaults()
    config.dailyBudgetUSD = budget
    return CostTracker(db: db, config: config, timeZone: utc, now: { clock.now })
}

private func describeCall(_ at: Date, cost: Double) -> LLMCall {
    LLMCall(
        provider: "gemini", model: "gemini-3.5-flash-lite", purpose: .describe,
        costUsd: cost, createdAt: at
    )
}

@Suite("Budget override")
struct BudgetOverrideTests {
    @Test("a raise outranks the configured budget for the rest of the day")
    func overrideWins() async throws {
        let db = try Database.inMemory()
        let clock = Clock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 1.20))
        #expect(await cost.isOverBudget == true)
        #expect(await cost.allows(.describe) == false)

        try await cost.raiseBudgetToday(to: 2.50)
        #expect(await cost.budgetUSD == 2.50)
        #expect(await cost.configuredBudgetUSD == 1.00)
        #expect(await cost.overrideToday() == 2.50)
        #expect(await cost.isOverBudget == false)
        #expect(await cost.allows(.describe) == true)
        #expect(await cost.level() == .nominal)
    }

    @Test("a raise never lowers the configured budget or an earlier raise")
    func neverLowers() async throws {
        let db = try Database.inMemory()
        let clock = Clock(noon)
        let cost = tracker(budget: 2.00, clock: clock, db: db)

        try await cost.raiseBudgetToday(to: 0.25)
        #expect(await cost.budgetUSD == 2.00)
        try await cost.raiseBudgetToday(to: 3.00)
        try await cost.raiseBudgetToday(to: 2.50)
        #expect(await cost.budgetUSD == 3.00)
    }

    @Test("a raise stored for another day is ignored")
    func otherDayIgnored() async throws {
        let db = try Database.inMemory()
        let clock = Clock(noon)
        try AppStateStore(db).set(CostTracker.overrideKey(day: "2026-09-06"), "9.00")
        let cost = tracker(budget: 1.00, clock: clock, db: db)

        #expect(await cost.budgetUSD == 1.00)
        #expect(await cost.overrideToday() == nil)
    }

    @Test("the rollover forgets yesterday's raise and deletes its row")
    func rolloverClears() async throws {
        let db = try Database.inMemory()
        let clock = Clock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)

        try await cost.record(describeCall(noon, cost: 1.20))
        try await cost.raiseBudgetToday(to: 5.00)
        #expect(await cost.budgetUSD == 5.00)
        await cost.tick()

        clock.set(noon.addingTimeInterval(24 * 3600))
        await cost.tick()
        #expect(await cost.budgetUSD == 1.00)
        #expect(await cost.overrideToday() == nil)
        let leftovers = try AppStateStore(db).keys(withPrefix: CostTracker.overrideKeyPrefix)
        #expect(leftovers == [])
    }

    @Test("the suggestion is the spend rounded up, plus fifty cents")
    func suggestion() {
        #expect(CostTracker.suggestedRaise(spend: 1.52) == 2.50)
        #expect(CostTracker.suggestedRaise(spend: 2.00) == 2.50)
        #expect(CostTracker.suggestedRaise(spend: 0.01) == 1.50)
    }

    // MARK: The requeue

    private func capture(_ db: Database, at: Date, status: DescribeStatus, reason: SkipReason?, image: String? = "a.jpg") throws -> Capture {
        let capture = Capture(
            capturedAt: at,
            imagePath: image,
            appBundleId: "com.apple.Safari",
            appName: "Safari",
            skipReason: reason,
            describeStatus: status
        )
        try CaptureStore(db).insert(capture)
        return capture
    }

    @Test("a raise requeues today's budget-skipped frames and nothing else")
    func requeue() async throws {
        let db = try Database.inMemory()
        let clock = Clock(noon)
        let cost = tracker(budget: 1.00, clock: clock, db: db)
        let store = CaptureStore(db)

        let todayBudget = try capture(db, at: noon, status: .skipped, reason: .budget)
        let yesterdayBudget = try capture(
            db, at: noon.addingTimeInterval(-24 * 3600), status: .skipped, reason: .budget
        )
        let unchanged = try capture(db, at: noon, status: .skipped, reason: .unchanged)
        let described = try capture(db, at: noon, status: .described, reason: nil)
        // Its pixels are gone, so there is nothing left to describe.
        let pruned = try capture(db, at: noon, status: .skipped, reason: .budget, image: nil)

        let requeued = try await cost.raiseBudgetToday(to: 5.00)
        #expect(requeued == 1)
        #expect(try store.fetch(id: todayBudget.id)?.describeStatus == .pending)
        #expect(try store.fetch(id: todayBudget.id)?.skipReason == nil)
        #expect(try store.fetch(id: yesterdayBudget.id)?.describeStatus == .skipped)
        #expect(try store.fetch(id: unchanged.id)?.skipReason == .unchanged)
        #expect(try store.fetch(id: described.id)?.describeStatus == .described)
        #expect(try store.fetch(id: pruned.id)?.describeStatus == .skipped)
    }
}
