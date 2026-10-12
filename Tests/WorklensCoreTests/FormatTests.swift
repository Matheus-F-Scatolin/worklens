import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let brazil = Locale(identifier: "pt_BR")
private let britain = Locale(identifier: "en_GB")
/// 2026-09-10 15:07 UTC, a Thursday afternoon — late enough in the day that a 12-hour clock has
/// to say PM, which is the whole point of the `en_GB`/`pt_BR` cases.
private let afternoon = Date(timeIntervalSince1970: 1_757_516_820)

@Suite("Format: the numbers and dates a person reads (#157)")
struct FormatTests {
    // MARK: The fixed locale is the one every fixture and golden file is written in

    @Test("the default locale reproduces the strings this repository already ships")
    func fixedIsUnchanged() {
        #expect(Format.money(0) == "$0.00")
        #expect(Format.money(0.0042) == "$0.0042")
        #expect(Format.money(0.19) == "$0.19")
        #expect(Format.money(12.5) == "$12.50")
        #expect(Format.money(1234.5) == "$1234.50")
        #expect(Format.clock(afternoon, timeZone: utc) == "15:07")
        #expect(Format.shortDate(afternoon, timeZone: utc) == "10 Sep")
        #expect(Format.cadence(60) == "60 s")
        #expect(Format.cadence(300) == "5 min")
        #expect(Format.cadence(150) == "2.5 min")
    }

    @Test("a NumberFormatter set to en_US_POSIX would not: it writes a space after the symbol")
    func fixedIsNotTheFormatter() {
        // The reason `Format` hand-rolls the fixed branch. If this ever starts failing,
        // `Format.money`'s fixed branch may finally be deleted.
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Format.fixed
        formatter.currencyCode = "USD"
        #expect(formatter.string(from: 1.5 as NSNumber) != Format.money(1.5))
    }

    // MARK: The user's own locale

    @Test("money is always dollars, written the way the region writes dollars")
    func moneyAbroad() {
        // pt-BR puts a non-breaking space after the symbol, which is what keeps `US$` and
        // the number on one line in a menu row.
        #expect(Format.money(0.19, locale: brazil) == "US$\u{00A0}0,19")
        #expect(Format.money(1.5, locale: brazil) == "US$\u{00A0}1,50")
        #expect(Format.money(0.0042, locale: brazil) == "US$\u{00A0}0,0042")
        #expect(Format.money(1.5, locale: britain) == "US$1.50")
    }

    @Test("the clock follows the region, not a hard-coded HH:mm")
    func clockAbroad() {
        // `en_GB` is a 24-hour region and `pt_BR` is too, so both read 15:07 — what is being
        // asserted is that the pattern comes from the locale rather than from a literal.
        #expect(Format.clock(afternoon, timeZone: utc, locale: britain) == "15:07")
        #expect(Format.clock(afternoon, timeZone: utc, locale: brazil) == "15:07")
        // A 12-hour region says so, which the old fixed `HH:mm` never could.
        let american = Format.clock(afternoon, timeZone: utc, locale: Locale(identifier: "en_US"))
        #expect(american.contains("3:07"))
        #expect(american.uppercased().contains("PM"))
    }

    @Test("dates are spelt in the region's own words")
    func datesAbroad() {
        #expect(Format.shortDate(afternoon, timeZone: utc, locale: britain) == "10 Sep")
        #expect(Format.shortDate(afternoon, timeZone: utc, locale: brazil).contains("10"))
        #expect(Format.shortDate(afternoon, timeZone: utc, locale: brazil).contains("set"))
    }

    @Test("today and yesterday are named; anything older is dated")
    func dayNames() {
        let yesterday = afternoon.addingTimeInterval(-86_400)
        let lastWeek = afternoon.addingTimeInterval(-7 * 86_400)
        #expect(Format.day(afternoon, now: afternoon, timeZone: utc) == "Today")
        #expect(Format.day(yesterday, now: afternoon, timeZone: utc) == "Yesterday")
        #expect(Format.day(lastWeek, now: afternoon, timeZone: utc) == "3 Sep")
    }

    @Test("a fractional cadence uses the region's decimal separator")
    func cadenceAbroad() {
        #expect(Format.cadence(150, locale: brazil) == "2,5 min")
        #expect(Format.cadence(150, locale: britain) == "2.5 min")
        #expect(Format.cadence(300, locale: brazil) == "5 min")
    }
}

@Suite("The menu in someone else's locale (#157)")
struct MenuLocaleTests {
    /// The guard the whole design rests on: a `MenuState` nobody gave a locale to is written in
    /// the fixed one, so every other test in this target is the same on every machine.
    @Test("a MenuState defaults to the fixed locale")
    func defaultsFixed() {
        #expect(MenuState().locale == Format.fixed)
        #expect(MenuModel.money(0.19) == "$0.19")
        #expect(MenuModel.cadence(300) == "5 min")
    }

    @Test("the counts row is written in the locale the state carries")
    func countsRowAbroad() {
        var counts = MenuCounts.zero
        counts.captures = 4
        counts.described = 4
        counts.spendUSD = 0.27
        let row = MenuModel.countsRow(counts, budget: 1.5, level: .nominal, locale: brazil)
        #expect(row.text.contains("US$\u{00A0}0,27 of US$\u{00A0}1,50"))
        let fixed = MenuModel.countsRow(counts, budget: 1.5, level: .nominal)
        #expect(fixed.text.contains("$0.27 of $1.50"))
    }

    @Test("a paused status row reads its deadline in the user's clock")
    func pausedClockAbroad() {
        var state = MenuState(scheduler: .paused(until: afternoon))
        state.locale = Locale(identifier: "en_US")
        let row = MenuModel.statusRow(state, timeZone: utc)
        #expect(row.text.uppercased().contains("PM"))
    }
}
