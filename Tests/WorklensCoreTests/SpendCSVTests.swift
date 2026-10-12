import Foundation
import Testing

@testable import WorklensCore

/// "Copy as CSV" under the 30-day table (#133). The button is SwiftUI; the string it puts on
/// the clipboard is this.
@Suite("Spend CSV")
struct SpendCSVTests {
    private func day(
        _ day: String,
        describe: Double = 0,
        reports: Double = 0,
        other: Double = 0,
        calls: Int = 0,
        failures: Int = 0
    ) -> DailySpend {
        var purposes: [PurposeSpend] = []
        if describe > 0 { purposes.append(PurposeSpend(purpose: .describe, costUsd: describe, calls: calls)) }
        if reports > 0 { purposes.append(PurposeSpend(purpose: .reportDaily, costUsd: reports, calls: 1)) }
        if other > 0 { purposes.append(PurposeSpend(purpose: .verify, costUsd: other, calls: 1)) }
        return DailySpend(
            day: day,
            costUsd: describe + reports + other,
            calls: calls,
            failures: failures,
            purposes: purposes
        )
    }

    /// The header is the contract: a spreadsheet built on it reads the same columns every time.
    @Test("the header names the expected columns")
    func header() {
        #expect(SpendCSV.columns == ["day", "describe", "reports", "other", "total", "calls", "failures"])
        let first = SpendCSV.render([]).split(separator: "\n").first.map(String.init)
        #expect(first == "day,describe,reports,other,total,calls,failures")
    }

    @Test("one row per day, in the order it was given")
    func rows() {
        let csv = SpendCSV.render([
            day("2026-09-15", describe: 0.1234, reports: 1, calls: 12, failures: 2),
            day("2026-09-14"),
        ])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1] == "2026-09-15,0.1234,1.0000,0.0000,1.1234,12,2")
        #expect(lines[2] == "2026-09-14,0.0000,0.0000,0.0000,0.0000,0,0")
        #expect(csv.hasSuffix("\n"))
    }

    /// Four decimals, not two: a described frame costs a fraction of a cent, and rounding for
    /// display in a file meant for adding up is how a total stops matching the table above it.
    @Test("money keeps four decimals and carries no dollar sign")
    func money() {
        #expect(SpendCSV.money(0.00004) == "0.0000")
        #expect(SpendCSV.money(0.12345) == "0.1235")
        #expect(!SpendCSV.money(1).contains("$"))
    }

    /// Nothing Worklens writes here needs quoting today — a day is `YYYY-MM-DD` — which is
    /// exactly why the escaping is worth a test rather than an assumption.
    @Test("a field with a comma, a quote or a newline is quoted")
    func escaping() {
        #expect(SpendCSV.escape("2026-09-15") == "2026-09-15")
        #expect(SpendCSV.escape("a,b") == "\"a,b\"")
        #expect(SpendCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(SpendCSV.escape("two\nlines") == "\"two\nlines\"")
    }

    @Test("an empty history is a header and nothing else")
    func empty() {
        #expect(SpendCSV.render([]) == "day,describe,reports,other,total,calls,failures\n")
    }
}
