import Foundation

/// Where a range of days went, project by project and day by day (#323): what `span` with
/// `by: "project"` returns.
///
/// Pure: the days' project spans (#322), their accounting (#320) and the agents' working
/// stretches in, minutes out. Every project the spans named is a row; nothing is cut to a top
/// few and nothing folds into `other`. A row's totals are rounded once from its summed seconds,
/// so three 40-second days total 2 minutes, not 3; a day's cells are rounded together across
/// the rows, so they add up to the day however many rows split it.
///
/// Project keys, names and minutes only: no title, URL, attendee or summary reaches here.
public struct Timesheet: Codable, Sendable, Equatable {
    /// One day of one row. A zero is left out of the JSON.
    public struct Cell: Codable, Sendable, Equatable {
        public var screen = 0
        public var meeting = 0
        public var agent = 0

        public init(screen: Int = 0, meeting: Int = 0, agent: Int = 0) {
            self.screen = screen
            self.meeting = meeting
            self.agent = agent
        }

        enum CodingKeys: String, CodingKey { case screen, meeting, agent }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            screen = try container.decodeIfPresent(Int.self, forKey: .screen) ?? 0
            meeting = try container.decodeIfPresent(Int.self, forKey: .meeting) ?? 0
            agent = try container.decodeIfPresent(Int.self, forKey: .agent) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if screen != 0 { try container.encode(screen, forKey: .screen) }
            if meeting != 0 { try container.encode(meeting, forKey: .meeting) }
            if agent != 0 { try container.encode(agent, forKey: .agent) }
        }

        var isEmpty: Bool { screen == 0 && meeting == 0 && agent == 0 }
    }

    /// One project over the range. `minutes` is screen plus meeting, which never overlap, so a
    /// screenshot taken during a call counts once. Agent minutes are never added in.
    public struct Row: Codable, Sendable, Equatable {
        public var key: String
        public var name: String
        /// The catalog's kind (house, company, side); nil for a name the catalog does not hold.
        public var kind: ProjectKind?
        public var minutes: Int
        public var screenMinutes: Int
        public var meetingMinutes: Int
        public var agentMinutes: Int
        public var daysSeen: Int
        public var perDay: [String: Cell]
        /// Minutes per allocator rule (#322, #324), whatever rules it has.
        public var byRule: [String: Int]
    }

    /// Recorded time no project claimed, split by why.
    public struct Unattributed: Codable, Sendable, Equatable {
        public var minutes: Int
        public var screenMinutes: Int
        public var meetingMinutes: Int
        public var agentMinutes: Int
        public var daysSeen: Int
        public var perDay: [String: Cell]
        /// `screenNoProject`, `meetingNoCompany` and `agentNoProject`.
        public var breakdown: [String: Int]
        /// Screen and meeting minutes by the allocator's reason (`ProjectSpan.Reason`).
        public var reasons: [String: Int]
    }

    public struct Totals: Codable, Sendable, Equatable {
        public var screen: Int
        public var meeting: Int
        /// The agents' stretches over the whole range, overlapping ones counted once.
        public var agent: Int
    }

    /// An agent at work: one turn's stretch inside one day, with the project its repo names.
    public struct Agent: Sendable, Equatable {
        public var project: String?
        public var start: Date
        public var end: Date

        public init(project: String?, start: Date, end: Date) {
            self.project = project
            self.start = start
            self.end = end
        }
    }

    public var from: String
    public var to: String
    public var by = "project"
    public var projects: [Row]
    public var unattributed: Unattributed
    /// The window's DayAccounting minutes that are not screen or meeting time, by bucket name.
    public var notRecorded: [String: Int]
    public var totals: Totals

    /// The accounting buckets `notRecorded` passes through: everything but recorded time.
    public static let notRecordedBuckets: [DayAccounting.Bucket] = DayAccounting.Bucket.allCases
        .filter { ![.meeting, .screen, .batterySparse].contains($0) }

    // MARK: Build

    private struct Tally {
        var screen: [String: Double] = [:]
        var meeting: [String: Double] = [:]
        var agent: [String: [DateInterval]] = [:]
        var rules: [String: Double] = [:]
        var reasons: [String: Double] = [:]
        var name: String?

        mutating func add(_ kind: ProjectSpan.Kind, _ seconds: Double, day: String) {
            switch kind {
            case .screen: screen[day, default: 0] += seconds
            case .meeting: meeting[day, default: 0] += seconds
            }
        }

        func agentSeconds(_ day: String) -> Double {
            PromptWindows.union(agent[day] ?? []).reduce(0) { $0 + $1.duration }
        }

        func sums(_ days: [String]) -> (screen: Double, meeting: Double, agent: Double, seen: Int) {
            var out = (screen: 0.0, meeting: 0.0, agent: 0.0, seen: 0)
            for day in days {
                let s = screen[day] ?? 0, m = meeting[day] ?? 0, a = agentSeconds(day)
                out.screen += s
                out.meeting += m
                out.agent += a
                if s + m + a > 0 { out.seen += 1 }
            }
            return out
        }
    }

    /// Each day's cells for every row, the unattributed one under `nil`. A day's screen and
    /// meeting seconds across all rows are rounded together by largest remainder, as
    /// `DayAccounting.Minutes` does, so the day's cells add up to its rounded recorded time
    /// however many rows split it. Agent minutes are rounded per cell; they are outside that sum.
    private static func cells(_ tallies: [(key: String?, tally: Tally)], days: [String]) -> [String?: [String: Cell]] {
        var out: [String?: [String: Cell]] = [:]
        for day in days {
            let seconds: [Double] = tallies.flatMap { entry -> [Double] in
                [entry.tally.screen[day] ?? 0, entry.tally.meeting[day] ?? 0]
            }
            let minutes = apportion(seconds)
            for (index, entry) in tallies.enumerated() {
                let cell = Cell(
                    screen: minutes[2 * index], meeting: minutes[2 * index + 1],
                    agent: StatsAggregator.minutes(entry.tally.agentSeconds(day))
                )
                if !cell.isEmpty { out[entry.key, default: [:]][day] = cell }
            }
        }
        return out
    }

    /// Seconds as whole minutes adding up to the rounded whole: each gets its floor, and the
    /// minutes left over go to the largest remainders, earlier entries first on a tie.
    static func apportion(_ seconds: [Double]) -> [Int] {
        let exact = seconds.map { max(0, $0) / 60 }
        var out = exact.map { Int($0.rounded(.down)) }
        let left = Int((seconds.reduce(0) { $0 + max(0, $1) } / 60).rounded()) - out.reduce(0, +)
        let byRemainder = exact.indices.sorted {
            let a = exact[$0] - exact[$0].rounded(.down), b = exact[$1] - exact[$1].rounded(.down)
            return a == b ? $0 < $1 : a > b
        }
        for index in byRemainder.prefix(max(0, left)) { out[index] += 1 }
        return out
    }

    /// - Parameters:
    ///   - days: the range, in order.
    ///   - spans: each day's project spans; a day with none is a day with no recorded time.
    ///   - accounting: each day's accounting, for `notRecorded`.
    ///   - agent: each day's agent stretches.
    ///   - projects: the catalog, for each row's name and kind.
    ///   - only: a project key; the answer then holds that one row, even an empty one.
    public static func build(
        days: [String], spans: [String: [ProjectSpan]], accounting: [String: DayAccounting],
        agent: [String: [Agent]] = [:], projects: [ProjectEntry], only: String? = nil
    ) -> Timesheet {
        var rows: [String: Tally] = [:]
        var none = Tally()
        var all = Tally()
        for day in days {
            for span in spans[day] ?? [] {
                let seconds = span.seconds
                guard seconds > 0 else { continue }
                if let key = span.project {
                    rows[key, default: Tally()].add(span.kind, seconds, day: day)
                    rows[key]?.rules.merge(span.secondsByRule, uniquingKeysWith: +)
                    if rows[key]?.name == nil { rows[key]?.name = span.name }
                } else {
                    none.add(span.kind, seconds, day: day)
                    none.reasons[(span.unattributed ?? .noEvidence).rawValue, default: 0] += seconds
                }
                all.add(span.kind, seconds, day: day)
            }
            for stretch in agent[day] ?? [] where stretch.end > stretch.start {
                let interval = DateInterval(start: stretch.start, end: stretch.end)
                if let key = stretch.project {
                    rows[key, default: Tally()].agent[day, default: []].append(interval)
                } else {
                    none.agent[day, default: []].append(interval)
                }
                all.agent[day, default: []].append(interval)
            }
        }
        if let only, rows[only] == nil { rows[only] = Tally() }

        let ordered = rows.sorted { $0.key < $1.key }.map { (key: Optional($0.key), tally: $0.value) }
            + [(key: nil, tally: none)]
        let perDay = cells(ordered, days: days)
        let catalog = Dictionary(projects.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let built = rows
            .filter { only == nil || $0.key == only }
            .map { key, tally -> Row in
                let sums = tally.sums(days)
                return Row(
                    key: key,
                    name: catalog[key]?.name ?? tally.name ?? key,
                    kind: catalog[key]?.kind,
                    minutes: StatsAggregator.minutes(sums.screen + sums.meeting),
                    screenMinutes: StatsAggregator.minutes(sums.screen),
                    meetingMinutes: StatsAggregator.minutes(sums.meeting),
                    agentMinutes: StatsAggregator.minutes(sums.agent),
                    daysSeen: sums.seen,
                    perDay: perDay[key] ?? [:],
                    byRule: minutes(tally.rules)
                )
            }
            .sorted { ($0.minutes, $0.agentMinutes, $1.key) > ($1.minutes, $1.agentMinutes, $0.key) }

        let unclaimed = none.sums(days)
        let everything = all.sums(days)
        let window = DayAccounting.Totals(days.compactMap { accounting[$0] }).window
        return Timesheet(
            from: days.first ?? "",
            to: days.last ?? "",
            projects: built,
            unattributed: Unattributed(
                minutes: StatsAggregator.minutes(unclaimed.screen + unclaimed.meeting),
                screenMinutes: StatsAggregator.minutes(unclaimed.screen),
                meetingMinutes: StatsAggregator.minutes(unclaimed.meeting),
                agentMinutes: StatsAggregator.minutes(unclaimed.agent),
                daysSeen: unclaimed.seen,
                perDay: perDay[.none] ?? [:],
                breakdown: [
                    "screenNoProject": StatsAggregator.minutes(unclaimed.screen),
                    "meetingNoCompany": StatsAggregator.minutes(unclaimed.meeting),
                    "agentNoProject": StatsAggregator.minutes(unclaimed.agent),
                ],
                reasons: minutes(none.reasons)
            ),
            notRecorded: Dictionary(uniqueKeysWithValues: notRecordedBuckets.map { ($0.rawValue, window[$0]) }),
            totals: Totals(
                screen: StatsAggregator.minutes(everything.screen),
                meeting: StatsAggregator.minutes(everything.meeting),
                agent: StatsAggregator.minutes(everything.agent)
            )
        )
    }

    /// Seconds by name as minutes, leaving out what rounds to nothing.
    private static func minutes(_ seconds: [String: Double]) -> [String: Int] {
        seconds.mapValues(StatsAggregator.minutes).filter { $0.value > 0 }
    }
}
