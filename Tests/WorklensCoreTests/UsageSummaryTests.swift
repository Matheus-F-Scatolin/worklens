import Foundation
import Testing

@testable import WorklensCore

/// Settings → Usage (#286): the 30 days the chart draws and the line under today's figure.
@Suite("Usage summary")
struct UsageSummaryTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test("thirty consecutive days ending today, with a zero bar for a day with no calls")
    func thirtyDays() {
        let history = [
            DailySpend(day: "2026-09-23", costUsd: 0.42, calls: 10, purposes: [
                PurposeSpend(purpose: .describe, costUsd: 0.34, calls: 9),
                PurposeSpend(purpose: .reportDaily, costUsd: 0.08, calls: 1),
            ]),
            DailySpend(day: "2026-09-01", costUsd: 1.00, calls: 3, purposes: [
                PurposeSpend(purpose: .describe, costUsd: 0.70, calls: 2),
            ]),
        ]
        let days = UsageSummary.days(history, today: "2026-09-23", timeZone: utc)
        #expect(days.count == 30)
        #expect(days.first?.day == "2026-08-25")
        #expect(days.last?.day == "2026-09-23")
        #expect(days.last?.summariesUSD == 0.34)
        #expect(days.last?.reportsUSD == 0.08)
        #expect(abs((days.last?.totalUSD ?? 0) - 0.42) < 1e-9)
        // What no named purpose covers is "other", so the bar is the ledger's total.
        let first = days.first { $0.day == "2026-09-01" }
        #expect(abs((first?.otherUSD ?? 0) - 0.30) < 1e-9)
        #expect(days.first { $0.day == "2026-09-10" }?.totalUSD == 0)
    }

    @Test("the axis stops at a round step at or above the tallest bar")
    func ticks() {
        let peak = UsageSummary.Day(day: "d", summariesUSD: 1.2, reportsUSD: 0.22, otherUSD: 0)
        #expect(UsageSummary.ticks(for: [peak]) == [0, 0.5, 1, 1.5])
        #expect(UsageSummary.ticks(for: []) == [0, 0.25, 0.5, 0.75])
        let small = UsageSummary.Day(day: "d", summariesUSD: 0.05, reportsUSD: 0, otherUSD: 0)
        #expect(UsageSummary.ticks(for: [small]).last! >= 0.05)
        let tiny = UsageSummary.Day(day: "d", summariesUSD: 0.0004, reportsUSD: 0, otherUSD: 0)
        #expect(UsageSummary.ticks(for: [tiny]) == [0, 0.01, 0.02, 0.03])
    }

    @Test("the budget line says what is left, what is over, or that there is no budget")
    func budgetLine() {
        let us = Locale(identifier: "en_US")
        #expect(UsageSummary.budgetLine(spent: 0.42, budget: 2, locale: us) == "spent today of a $2.00 daily budget · $1.58 left")
        #expect(UsageSummary.budgetLine(spent: 2.5, budget: 2, locale: us) == "spent today of a $2.00 daily budget · over budget")
        #expect(UsageSummary.budgetLine(spent: 1, budget: 0, locale: us) == "spent today · no daily budget")
        #expect(UsageSummary.fraction(spent: 3, budget: 2) == 1)
        #expect(UsageSummary.fraction(spent: 1, budget: 0) == 0)
    }

    @Test("the hover names today as Today and any other day by its weekday")
    func labels() {
        let gb = Locale(identifier: "en_GB")
        #expect(UsageSummary.label(day: "2026-09-23", today: "2026-09-23", timeZone: utc, locale: gb) == "Today")
        // The region's own shape — `Thu 17 Sept`, `Thu, 17 Sep` — so only the parts are pinned.
        let label = UsageSummary.label(day: "2026-09-17", today: "2026-09-23", timeZone: utc, locale: gb)
        #expect(label.hasPrefix("Thu"))
        #expect(label.contains("17"))
        #expect(label.contains("Sep"))
    }
}
