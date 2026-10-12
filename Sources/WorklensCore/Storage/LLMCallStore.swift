import Foundation
import GRDB

/// Reads and writes `llm_calls` — the ledger every model call goes through.
public struct LLMCallStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    /// Inserts a call, stamping `pricing_version` when the caller left it nil — which every
    /// caller does, so the six sites that record calls do not each have to remember.
    public func insert(_ call: LLMCall) throws {
        var call = call
        if call.pricingVersion == nil { call.pricingVersion = ModelPricing.pricingVersion }
        try db.writer.write { try call.insert($0) }
    }

    /// Total USD spent in `[from, to)`.
    public func spend(from: Date, to: Date) throws -> Double {
        try db.writer.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(cost_usd), 0) FROM llm_calls WHERE created_at >= ? AND created_at < ?",
                arguments: [from, to]
            ) ?? 0
        }
    }

    /// Total USD spent on one purpose in `[from, to)`.
    public func spend(purpose: LLMPurpose, from: Date, to: Date) throws -> Double {
        try db.writer.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(cost_usd), 0) FROM llm_calls
                    WHERE purpose = ? AND created_at >= ? AND created_at < ?
                    """,
                arguments: [purpose.rawValue, from, to]
            ) ?? 0
        }
    }

    /// Spend per **local** day for the last `days` days, newest day first, split by purpose.
    ///
    /// Grouped in Swift rather than in SQL: `created_at` is stored UTC and a local day is not a
    /// fixed offset from it (DST), so `substr(created_at, 1, 10)` would put the last hours of an
    /// evening on tomorrow and disagree with the menu's "Today". `DayBoundaries` stays the only
    /// place that conversion happens. Thirty days is a few thousand rows.
    public func summary(days: Int, timeZone: TimeZone = .current, now: Date = Date()) throws -> [DailySpend] {
        guard days > 0, let window = LLMCallStore.window(days: days, timeZone: timeZone, now: now) else {
            return []
        }
        let (start, end) = window

        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT created_at, purpose, cost_usd, error
                FROM llm_calls
                WHERE created_at >= ? AND created_at < ?
                """, arguments: [start, end])
        }

        // day -> purpose -> tally, so an absent purpose stays absent rather than becoming a zero.
        var byDay: [String: (cost: Double, calls: Int, failures: Int, purposes: [LLMPurpose: PurposeSpend])] = [:]
        for row in rows {
            let createdAt: Date = row["created_at"]
            let day = DayBoundaries.dayString(createdAt, timeZone: timeZone)
            let cost: Double = row["cost_usd"] ?? 0
            let failed = (row["error"] as String?) != nil
            guard let purpose = LLMPurpose(rawValue: row["purpose"] ?? "") else { continue }

            var entry = byDay[day] ?? (0, 0, 0, [:])
            entry.cost += cost
            entry.calls += 1
            if failed { entry.failures += 1 }
            var slice = entry.purposes[purpose] ?? PurposeSpend(purpose: purpose)
            slice.costUsd += cost
            slice.calls += 1
            if failed { slice.failures += 1 }
            entry.purposes[purpose] = slice
            byDay[day] = entry
        }

        return byDay
            .map { day, entry in
                DailySpend(
                    day: day,
                    costUsd: entry.cost,
                    calls: entry.calls,
                    failures: entry.failures,
                    // Stable order, so the Settings table's columns never move between refreshes.
                    purposes: LLMPurpose.allCases.compactMap { entry.purposes[$0] }
                )
            }
            .sorted { $0.day > $1.day }
    }

    /// Mean cost of a *successful* call for one purpose over the last `days` days, or nil when
    /// there has never been one. Failures are excluded: they cost nothing and would drag the
    /// estimate towards zero exactly when the provider is unhappy.
    public func averageCost(
        purpose: LLMPurpose, days: Int, timeZone: TimeZone = .current, now: Date = Date()
    ) throws -> Double? {
        guard days > 0, let window = LLMCallStore.window(days: days, timeZone: timeZone, now: now) else {
            return nil
        }
        let (start, end) = window
        return try db.writer.read { db in
            try Double.fetchOne(db, sql: """
                SELECT AVG(cost_usd) FROM llm_calls
                WHERE purpose = ? AND error IS NULL AND created_at >= ? AND created_at < ?
                """, arguments: [purpose.rawValue, start, end])
        }
    }

    /// The half-open instant range covering the last `days` **local** days, ending at tomorrow's
    /// midnight. Calendar arithmetic rather than `days * 86 400`, so the oldest day is whole
    /// across a daylight-saving change.
    static func window(days: Int, timeZone: TimeZone, now: Date) -> (start: Date, end: Date)? {
        let today = DayBoundaries.dayString(now, timeZone: timeZone)
        guard let end = DayBoundaries.range(day: today, timeZone: timeZone)?.end else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let todayStart = DayBoundaries.range(day: today, timeZone: timeZone)?.start,
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart)
        else { return nil }
        return (start, end)
    }
}
