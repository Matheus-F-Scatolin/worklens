import Foundation

/// The Today page's chart: where the day's active time went, as a waterfall (reader redesign).
///
/// The three apps with the most minutes and everything else as **Others**, biggest bar first, each
/// floating from where the one before it ended, and a **Total** bar that rises from zero to the day's active
/// time. When the day has active time no app on screen accounts for — a call taken away from the
/// Mac, which the calendar still counts — a **Meetings** bar carries it, so the stack always lands
/// on the total rather than stopping short of it for no stated reason.
///
/// Measured facts only: minutes, a share of the day, three numbers. No bar is better than another.
public struct Waterfall: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case app, others, meetings, total
    }

    /// One app, or one row inside Others, with its minutes.
    public struct Item: Sendable, Equatable, Hashable {
        public var name: String
        public var minutes: Int
        /// The app key the stats counted it under (`gcal`), which is what picks its colour: a
        /// taxonomy can name an app anything, and the colour must not move when it does.
        public var key: String?

        public init(name: String, minutes: Int, key: String? = nil) {
            self.name = name
            self.minutes = minutes
            self.key = key
        }

        public var colorHex: UInt32 { AppPalette.hex(forApp: name, key: key) }
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var name: String
        /// Where the bar starts and ends on the minute axis.
        public var from: Int
        public var to: Int
        /// Set on app bars only.
        public var colorHex: UInt32?
        /// The app key the bar was counted under, on app bars only: what its summary is found by.
        public var key: String? = nil
        public var id: String { "\(kind.rawValue):\(name)" }
        public var minutes: Int { to - from }
    }

    /// The bars, left to right: the top apps, Others and Meetings (when there is any), biggest
    /// first, then Total.
    public var steps: [Step]
    /// What Others is made of, most minutes first.
    public var others: [Item]
    public var activeMinutes: Int
    public var longestFocusMinutes: Int?
    public var contextSwitches: Int
    /// What you were doing in each app, by app key: the summary of its longest stretch that day
    /// (#357). The tooltip says it under the bar's heading. Empty when the day's blocks were not
    /// read, and then the tooltip carries the share alone.
    public var summaries: [String: String] = [:]

    /// Below this, the gap between the apps and the active time is rounding, not a meeting.
    public static let meetingsFloor = 5

    public init(
        apps: [Item],
        activeMinutes: Int,
        longestFocusMinutes: Int?,
        contextSwitches: Int,
        topCount: Int = 3
    ) {
        let sorted = apps.filter { $0.minutes > 0 }
            .sorted { $0.minutes == $1.minutes ? $0.name < $1.name : $0.minutes > $1.minutes }
        let top = Array(sorted.prefix(topCount))
        let rest = Array(sorted.dropFirst(topCount))
        // Every bar but Total, biggest first, so a Meetings bar or Others can open the chart.
        var bars: [(kind: Kind, name: String, minutes: Int, colorHex: UInt32?, key: String?)] = top.map {
            (.app, $0.name, $0.minutes, $0.colorHex, $0.key)
        }
        let othersMinutes = rest.reduce(0) { $0 + $1.minutes }
        bars.append((.others, ReaderShellCopy.others, othersMinutes, nil, nil))
        let gap = activeMinutes - (top.reduce(0) { $0 + $1.minutes } + othersMinutes)
        if gap >= Waterfall.meetingsFloor {
            bars.append((.meetings, ReaderShellCopy.meetings, gap, nil, nil))
        }
        let ordered = bars.enumerated()
            .sorted { a, b in
                a.element.minutes == b.element.minutes ? a.offset < b.offset : a.element.minutes > b.element.minutes
            }
            .map(\.element)
        var steps: [Step] = []
        var cumulative = 0
        for bar in ordered {
            steps.append(Step(
                kind: bar.kind, name: bar.name, from: cumulative, to: cumulative + bar.minutes,
                colorHex: bar.colorHex, key: bar.key
            ))
            cumulative += bar.minutes
        }
        steps.append(Step(kind: .total, name: ReaderShellCopy.total, from: 0, to: activeMinutes))
        self.steps = steps
        self.others = rest
        self.activeMinutes = activeMinutes
        self.longestFocusMinutes = longestFocusMinutes
        self.contextSwitches = contextSwitches
    }

    /// The day's chart from its stats, apps named the way the rest of the reader names them.
    /// Nil for a day with no active time — there is nothing to draw.
    ///
    /// - Parameter blocks: the day's blocks, for what each bar's tooltip says you were doing.
    ///   A real day and the sample week both come through here, with the store's blocks.
    public static func of(
        _ stats: DailyStats, labels: TimelineLabels, blocks: [ActivityBlock] = []
    ) -> Waterfall? {
        guard stats.activeMinutes > 0 else { return nil }
        let apps = stats.byApp.map { slice -> Item in
            Item(name: name(of: slice, labels: labels), minutes: slice.minutes, key: slice.key)
        }
        var chart = Waterfall(
            apps: apps,
            activeMinutes: stats.activeMinutes,
            longestFocusMinutes: stats.longestFocusBlock?.minutes,
            contextSwitches: stats.contextSwitches
        )
        chart.summaries = summaries(of: blocks)
        return chart
    }

    /// For each app key, the summary of the longest screen block with one, the earlier of two
    /// the same length. Away and idle blocks say nothing about an app and are left out.
    public static func summaries(of blocks: [ActivityBlock]) -> [String: String] {
        var best: [String: ActivityBlock] = [:]
        for block in blocks where block.source == .screen && !StatsAggregator.isInactive(block) {
            guard let text = block.summaryMd?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            let length = block.endAt.timeIntervalSince(block.startAt)
            if let kept = best[block.appKey] {
                let keptLength = kept.endAt.timeIntervalSince(kept.startAt)
                if keptLength > length || (keptLength == length && kept.startAt <= block.startAt) {
                    continue
                }
            }
            best[block.appKey] = block
        }
        return best.compactMapValues { block in
            block.summaryMd?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// What you were doing in an app bar's app, or nil for any other bar or an app with no summary.
    public func summary(for step: Step) -> String? {
        guard step.kind == .app, let key = step.key else { return nil }
        return summaries[key]
    }

    /// The bar the tour's moment stop opens (#357): the biggest app bar that says what you were
    /// doing, else the biggest app bar, else the first. Bars are biggest first, so on a scattered
    /// evening Others or Meetings can lead, and the stop promises an app with a sentence in it.
    /// Nil only for a chart with no bars.
    public var momentIndex: Int? {
        guard !steps.isEmpty else { return nil }
        return steps.firstIndex { summary(for: $0) != nil }
            ?? steps.firstIndex { $0.kind == .app } ?? 0
    }

    /// `StatsAggregator` folds the apps past its limit into one `other (N more)` row; that row is
    /// named here as what it is.
    static func name(of slice: Slice, labels: TimelineLabels) -> String {
        if slice.key == StatsAggregator.otherKey, slice.name.hasPrefix("other (") {
            let digits = slice.name.filter(\.isNumber)
            return ReaderShellCopy.moreApps(Int(digits) ?? 0)
        }
        return labels.app(slice.key)
    }

    // MARK: The axis

    /// The top of the axis: the tallest bar plus a little headroom, rounded up to an hour.
    public var scaleMinutes: Int {
        let tallest = max(steps.map(\.to).max() ?? 0, activeMinutes)
        return max(60, Int((Double(tallest) / 60 + 0.4).rounded(.up)) * 60)
    }

    /// Gridlines every two hours, zero included.
    public var ticks: [Int] { Array(stride(from: 0, through: scaleMinutes, by: 120)) }

    // MARK: Words

    public static func duration(_ minutes: Int) -> String {
        minutes > 0 ? StatsAggregator.duration(minutes) : "0m"
    }

    public static func hours(_ minutes: Int) -> String { "\(minutes / 60)h" }

    /// `Active time`, `Longest focus block`, `Context switches` and their values.
    public var facts: [(label: String, value: String)] {
        [
            (ReaderShellCopy.activeTime, Waterfall.duration(activeMinutes)),
            (ReaderShellCopy.longestFocus, longestFocusMinutes.map(Waterfall.duration) ?? L10n.string("none")),
            (ReaderShellCopy.contextSwitches, String(contextSwitches)),
        ]
    }

    /// A whole percentage of the day's active time.
    public func percent(_ step: Step) -> Int {
        guard activeMinutes > 0 else { return 0 }
        return Int((Double(step.minutes) / Double(activeMinutes) * 100).rounded())
    }

    /// What a bar's tooltip lists under its heading: Others its apps, Total the three facts.
    /// App and Meetings bars carry a sentence instead — see `sentence(for:)`.
    public func rows(for step: Step) -> [(label: String, value: String)] {
        switch step.kind {
        case .others: return others.map { ($0.name, Waterfall.duration($0.minutes)) }
        case .total: return facts
        case .app, .meetings: return []
        }
    }

    public func sentence(for step: Step) -> String? {
        switch step.kind {
        case .app, .meetings: return ReaderShellCopy.share(percent(step))
        case .others, .total: return nil
        }
    }
}
