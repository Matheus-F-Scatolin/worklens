import Foundation

/// Settings → Usage (#286): today's spend against the budget, and the 30-day bar chart. The page
/// draws bars; which days there are, what each is made of and where the axis stops are here.
public enum UsageSummary {
    /// One bar: a local day, what summaries and reports cost on it, and anything else.
    public struct Day: Sendable, Equatable, Identifiable {
        public let day: String
        public let summariesUSD: Double
        public let reportsUSD: Double
        public let otherUSD: Double
        public var id: String { day }
        public var totalUSD: Double { summariesUSD + reportsUSD + otherUSD }

        public init(day: String, summariesUSD: Double, reportsUSD: Double, otherUSD: Double) {
            self.day = day
            self.summariesUSD = summariesUSD
            self.reportsUSD = reportsUSD
            self.otherUSD = otherUSD
        }
    }

    /// `count` consecutive local days ending with `today`, oldest first. A day the ledger has no
    /// row for is a zero bar, so the chart's spacing is the calendar's and a quiet weekend shows
    /// as a gap rather than disappearing.
    public static func days(
        _ history: [DailySpend], today: String, count: Int = 30, timeZone: TimeZone = .current
    ) -> [Day] {
        let byDay = Dictionary(history.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        return (0..<count).reversed().compactMap { back in
            guard let day = DayBoundaries.shift(day: today, by: -back, timeZone: timeZone) else { return nil }
            guard let spend = byDay[day] else {
                return Day(day: day, summariesUSD: 0, reportsUSD: 0, otherUSD: 0)
            }
            // `costUsd` is the ledger's total; whatever no named purpose accounts for is "other",
            // so the three always add up to the day.
            let other = max(0, spend.costUsd - spend.describeUSD - spend.reportsUSD)
            return Day(day: day, summariesUSD: spend.describeUSD, reportsUSD: spend.reportsUSD, otherUSD: other)
        }
    }

    /// The axis stops: 0 and three more at a round step, the top one at or above the tallest
    /// bar. `[0, 0.5, 1, 1.5]` for a month that peaked at $1.42. The step is never under a cent,
    /// so a month of fractions of a cent still labels its axis in whole cents that fit.
    public static func ticks(for days: [Day]) -> [Double] {
        let peak = days.map(\.totalUSD).max() ?? 0
        guard peak > 0 else { return [0, 0.25, 0.5, 0.75] }
        let raw = peak / 3
        let magnitude = pow(10, floor(log10(raw)))
        let step = max(0.01, [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw)
        return (0...3).map { Double($0) * step }
    }

    /// Under the big figure: `of a $2.00 daily budget · $1.58 left`, or what is over, or that no
    /// budget is set.
    public static func budgetLine(spent: Double, budget: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard budget > 0 else { return L10n.string("spent today · no daily budget") }
        let money = { Format.money($0, locale: locale) }
        if spent > budget {
            return L10n.format("spent today of a %@ daily budget · over budget", money(budget))
        }
        return L10n.format("spent today of a %@ daily budget · %@ left", money(budget), money(budget - spent))
    }

    /// How full the meter is: 0 with no budget, never past 1.
    public static func fraction(spent: Double, budget: Double) -> Double {
        guard budget > 0 else { return 0 }
        return min(1, max(0, spent / budget))
    }

    /// The chart's hover heading: `Today`, or `Wed 17 Sep`.
    public static func label(
        day: String, today: String, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent
    ) -> String {
        if day == today { return L10n.string("Today") }
        guard let date = DayBoundaries.range(day: day, timeZone: timeZone)?.start else { return day }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date)
    }

    // MARK: Per provider

    /// One summarizer's line under "Summaries today": `Claude` and `48 calls · 192 screenshots`,
    /// with dollars only for a summarizer that costs money, since a plan call is always $0.
    public struct ProviderRow: Sendable, Equatable, Identifiable {
        /// The ledger's `provider`.
        public let provider: String
        public let name: String
        public let detail: String
        public var id: String { provider }
    }

    /// One row per summarizer in `order`, then any other that summarized today (one taken out of
    /// the order since), in the ledger's order.
    public static func providerRows(
        order: [SummaryProvider], usage: [String: ProviderUsage], locale: Locale = .autoupdatingCurrent
    ) -> [ProviderRow] {
        let known = order.map(\.rawValue)
        let extra = usage.filter { !known.contains($0.key) && $0.value.calls > 0 }.keys.sorted()
        return (known + extra).map { key in
            let provider = SummaryProvider(rawValue: key)
            let name = provider.map(SummaryConnection.name) ?? DescribeHealth.providerName(key)
            let paid = provider?.tool == nil
            let line = usage[key] ?? ProviderUsage()
            guard line.calls > 0 else {
                return ProviderRow(provider: key, name: name, detail: L10n.string("Nothing summarized today"))
            }
            var parts = [
                L10n.plural(count: line.calls, one: "%lld call", other: "%lld calls"),
                L10n.plural(count: line.screenshots, one: "%lld screenshot", other: "%lld screenshots"),
            ]
            if paid { parts.append(Format.money(line.costUSD, locale: locale)) }
            return ProviderRow(provider: key, name: name, detail: parts.joined(separator: " · "))
        }
    }
}
