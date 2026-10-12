import Foundation

/// Where every minute of a local day went (#320): each second of `[from, through)` lands in
/// exactly one `Bucket`, so the minutes add up to the day — 1,440, or 1,380 and 1,500 on the
/// days the clocks change, or up to now for today — and a second set adds up to the stretch
/// from the first piece of evidence to the last.
///
/// Pure: blocks, captures, sessions, coverage rows and gaps in, buckets out. Timestamps and
/// durations only; nothing here reads a title, a URL or an app name.
public struct DayAccounting: Codable, Sendable, Equatable {
    /// The eleven places a second can go, highest rule first. `paused` and `permissionMissing`
    /// stay apart from `notRunning`, as `CoverageGapReason` keeps them: a pause filed as "not
    /// running" would be false.
    public enum Bucket: String, Codable, Sendable, CaseIterable {
        /// A meeting block: a call on the calendar, a Granola note, or the screen labelled one.
        case meeting
        /// A calendar event with other people said you were away from the machine (#94).
        case away
        /// A block of screen time, or a foreground session no block covers.
        case screen
        /// Screen time captured at the battery cadence, so the blocks in it are coarser.
        case batterySparse
        /// The Mac was asleep (#313). Sleep recorded before #313 reads as `locked`.
        case asleep
        case locked
        case idle
        case paused
        case permissionMissing
        case notRunning
        /// Nothing on record says what this time was.
        case unexplained
    }

    /// One contiguous stretch in one bucket. Neighbours always differ in bucket.
    public struct Span: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var bucket: Bucket

        public init(start: Date, end: Date, bucket: Bucket) {
            self.start = start
            self.end = end
            self.bucket = bucket
        }
    }

    /// Whole minutes per bucket. Rounded by largest remainder, so they always add up to `total`.
    public struct Minutes: Codable, Sendable, Equatable {
        public var meeting = 0
        public var away = 0
        public var screen = 0
        public var batterySparse = 0
        public var asleep = 0
        public var locked = 0
        public var idle = 0
        public var paused = 0
        public var permissionMissing = 0
        public var notRunning = 0
        public var unexplained = 0
        public var total = 0

        public init() {}

        public subscript(bucket: Bucket) -> Int {
            get {
                switch bucket {
                case .meeting: return meeting
                case .away: return away
                case .screen: return screen
                case .batterySparse: return batterySparse
                case .asleep: return asleep
                case .locked: return locked
                case .idle: return idle
                case .paused: return paused
                case .permissionMissing: return permissionMissing
                case .notRunning: return notRunning
                case .unexplained: return unexplained
                }
            }
            set {
                switch bucket {
                case .meeting: meeting = newValue
                case .away: away = newValue
                case .screen: screen = newValue
                case .batterySparse: batterySparse = newValue
                case .asleep: asleep = newValue
                case .locked: locked = newValue
                case .idle: idle = newValue
                case .paused: paused = newValue
                case .permissionMissing: permissionMissing = newValue
                case .notRunning: notRunning = newValue
                case .unexplained: unexplained = newValue
                }
            }
        }

        /// Seconds per bucket as whole minutes. `total` is the rounded whole; each bucket gets
        /// its floor, and the minutes left over go to the largest remainders.
        public init(seconds: [Bucket: Double], totalSeconds: Double) {
            total = Int((max(0, totalSeconds) / 60).rounded())
            let exact = Bucket.allCases.map { (bucket: $0, minutes: max(0, seconds[$0] ?? 0) / 60) }
            var left = total
            for entry in exact {
                let floor = Int(entry.minutes.rounded(.down))
                self[entry.bucket] = floor
                left -= floor
            }
            let byRemainder = exact.enumerated().sorted {
                let a = $0.element.minutes - $0.element.minutes.rounded(.down)
                let b = $1.element.minutes - $1.element.minutes.rounded(.down)
                return a == b ? $0.offset < $1.offset : a > b
            }
            for entry in byRemainder.prefix(max(0, left)) {
                self[entry.element.bucket] += 1
            }
        }

        /// Two sets added field by field — a range is the sum of its days.
        public static func + (lhs: Minutes, rhs: Minutes) -> Minutes {
            var sum = Minutes()
            for bucket in Bucket.allCases { sum[bucket] = lhs[bucket] + rhs[bucket] }
            sum.total = lhs.total + rhs.total
            return sum
        }
    }

    /// The configured capture intervals before any battery stretch: what a frame's own
    /// `interval_seconds` is compared with to tell the battery cadence apart.
    public struct BaseIntervals: Sendable, Equatable {
        public var capture: Int
        public var meeting: Int

        public init(capture: Int, meeting: Int) {
            self.capture = capture
            self.meeting = meeting
        }

        public init(config: Config) {
            self.init(capture: config.captureIntervalSeconds, meeting: config.meetingCaptureIntervalSeconds)
        }

        /// `CAPTURE_INTERVAL_SECONDS` and `MEETING_CAPTURE_INTERVAL_SECONDS` as shipped.
        public static let shipped = BaseIntervals(capture: 60, meeting: 300)

        /// True when the frame was taken at the battery cadence: its interval is at least
        /// `PowerPolicy.batteryIntervalMultiplier` times the base it was stretched from.
        func isSparse(_ capture: Capture) -> Bool {
            guard let interval = capture.intervalSeconds else { return false }
            let base = capture.isMeeting ? meeting : self.capture
            return base > 0 && interval >= base * PowerPolicy.batteryIntervalMultiplier
        }
    }

    /// A range's day and window minutes, each the sum of its days'.
    public struct Totals: Codable, Sendable, Equatable {
        public var day: Minutes
        public var window: Minutes

        public init(day: Minutes = Minutes(), window: Minutes = Minutes()) {
            self.day = day
            self.window = window
        }

        public init(_ days: [DayAccounting]) {
            self.init(
                day: days.reduce(Minutes()) { $0 + $1.day },
                window: days.reduce(Minutes()) { $0 + ($1.window ?? Minutes()) }
            )
        }
    }

    /// The start of the day.
    public var from: Date
    /// The end of the day, or now when the day is today.
    public var through: Date
    /// The first and last moment anything was recorded: a block, a frame, a foreground session.
    public var firstEvidence: Date?
    public var lastEvidence: Date?
    /// Every bucket over `[from, through)`.
    public var day: Minutes
    /// Every bucket over `[firstEvidence, lastEvidence)`. Nil on a day with no evidence.
    public var window: Minutes?
    /// The day, contiguous and merged. Only a one-day `stats` call carries it.
    public var spans: [Span]?

    public init(
        from: Date, through: Date, firstEvidence: Date?, lastEvidence: Date?,
        day: Minutes, window: Minutes?, spans: [Span]?
    ) {
        self.from = from
        self.through = through
        self.firstEvidence = firstEvidence
        self.lastEvidence = lastEvidence
        self.day = day
        self.window = window
        self.spans = spans
    }

    /// The same accounting without its spans — what a week or a range carries per day.
    public var withoutSpans: DayAccounting {
        var copy = self
        copy.spans = nil
        return copy
    }

    // MARK: Compute

    /// One layer of the day: stretches in one bucket, at one rank. Lower ranks win.
    private struct Layer {
        var rank: Int
        var bucket: Bucket
        var stretches: [StatsAggregator.Stretch]
    }

    /// Puts every second of `range`, cut at `now`, in one bucket.
    ///
    /// - `blocks`: the day's `activity_blocks`; calendar ones are cut at `now` here.
    /// - `captures`: the day's rows, any order. `carryIn` is the last row before the day, whose
    ///   lock, sleep or idle hold carries over midnight.
    /// - `sessions`: `foreground_sessions` overlapping the day. One with no end counts only up
    ///   to `now`, and only on the day `now` is in.
    /// - `coverageEvents`: transitions; any of them ends a hold.
    /// - `gaps`: `CoverageEventStore.gaps` for the day. `budget` gaps are ignored: those frames
    ///   exist.
    public static func compute(
        range: (start: Date, end: Date),
        now: Date,
        blocks: [ActivityBlock],
        captures: [Capture],
        carryIn: Capture?,
        sessions: [ForegroundSession],
        coverageEvents: [CoverageEvent],
        gaps: [CoverageGap],
        baseIntervals: BaseIntervals = .shipped
    ) -> DayAccounting {
        let from = range.start
        let through = min(range.end, max(range.start, now))
        typealias Stretch = StatsAggregator.Stretch

        func clipped(_ start: Date, _ end: Date) -> Stretch? {
            let stretch = Stretch(start: max(start, from), end: min(end, through))
            return stretch.end > stretch.start ? stretch : nil
        }
        func union(_ stretches: [Stretch]) -> [Stretch] { StatsAggregator.union(stretches) }

        let dayBlocks = StatsAggregator.clippedToNow(blocks, now: now).filter { $0.endAt > $0.startAt }
        let rows = captures.sorted { $0.capturedAt < $1.capturedAt }
        let eventTimes = coverageEvents.map(\.at).sorted()

        // 1–3: meetings, away, then the rest of the active blocks, split by cadence.
        let meetings = dayBlocks.filter { StatsAggregator.isMeeting($0) && !StatsAggregator.isInactive($0) }
        let away = dayBlocks.filter(StatsAggregator.isAway)
        let active = dayBlocks.filter { !StatsAggregator.isInactive($0) }
        let idleBlocks = dayBlocks.filter { StatsAggregator.isInactive($0) && !StatsAggregator.isAway($0) }
        // A locked or asleep block outside any hold keeps its own bucket; idle and screensaver
        // stay idle.
        func inactiveBucket(_ block: ActivityBlock) -> Bucket {
            let keys = [block.appKey.lowercased(), block.taskKey.lowercased()]
            if keys.contains("asleep") { return .asleep }
            if keys.contains("locked") { return .locked }
            return .idle
        }
        func inactiveStretches(_ bucket: Bucket) -> [Stretch] {
            idleBlocks.filter { inactiveBucket($0) == bucket }.compactMap { clipped($0.startAt, $0.endAt) }
        }

        // Each frame stands for the time until the next row; the sparse ones mark that stretch.
        let framed = (carryIn.map { [$0] } ?? []) + rows
        var sparse: [Stretch] = []
        for (index, row) in framed.enumerated() where baseIntervals.isSparse(row) {
            let end = index + 1 < framed.count ? framed[index + 1].capturedAt : through
            if let stretch = clipped(row.capturedAt, end) { sparse.append(stretch) }
        }
        let activeUnion = union(active.compactMap { clipped($0.startAt, $0.endAt) })
        let sparseScreen = StatsAggregator.intersect(activeUnion, union(sparse))

        // A frame the screen called a meeting, inside an active block no meeting label covers:
        // `meetingMinutes` counts it, so the meeting bucket does too. It stands for the time
        // until the next row.
        var meetingFrames: [Stretch] = []
        for (index, row) in framed.enumerated() where row.isMeeting {
            let end = index + 1 < framed.count ? framed[index + 1].capturedAt : through
            if let stretch = clipped(row.capturedAt, end) { meetingFrames.append(stretch) }
        }
        let meetingScreen = StatsAggregator.intersect(activeUnion, union(meetingFrames))

        // 4: a lock, sleep or idle row holds until the next row, the next transition, or the end.
        var holds: [Bucket: [Stretch]] = [:]
        for (index, row) in framed.enumerated() {
            let bucket: Bucket
            switch row.skipReason {
            case .asleep: bucket = .asleep
            case .locked: bucket = .locked
            case .idle: bucket = .idle
            default: continue
            }
            var end = index + 1 < framed.count ? framed[index + 1].capturedAt : through
            if let event = eventTimes.first(where: { $0 > row.capturedAt }) { end = min(end, event) }
            if let stretch = clipped(row.capturedAt, end) { holds[bucket, default: []].append(stretch) }
        }

        // 5: foreground sessions. An open one is today's, up to now.
        let isToday = now >= range.start && now < range.end
        let sessionStretches: [Stretch] = sessions.compactMap { session in
            if let end = session.endAt { return clipped(session.startAt, end) }
            return isToday ? clipped(session.startAt, now) : nil
        }

        // 6: the gaps a running app could not have filled.
        func gapStretches(_ reason: CoverageGapReason) -> [Stretch] {
            gaps.filter { $0.reason == reason }.compactMap { clipped($0.start, $0.end) }
        }

        let layers: [Layer] = [
            Layer(rank: 0, bucket: .meeting, stretches: meetings.compactMap { clipped($0.startAt, $0.endAt) }),
            Layer(rank: 0, bucket: .meeting, stretches: meetingScreen),
            Layer(rank: 1, bucket: .away, stretches: away.compactMap { clipped($0.startAt, $0.endAt) }),
            Layer(rank: 2, bucket: .batterySparse, stretches: sparseScreen),
            Layer(rank: 3, bucket: .screen, stretches: activeUnion),
            Layer(rank: 4, bucket: .asleep, stretches: holds[.asleep] ?? []),
            Layer(rank: 4, bucket: .locked, stretches: holds[.locked] ?? []),
            Layer(rank: 4, bucket: .idle, stretches: holds[.idle] ?? []),
            Layer(rank: 5, bucket: .asleep, stretches: inactiveStretches(.asleep)),
            Layer(rank: 5, bucket: .locked, stretches: inactiveStretches(.locked)),
            Layer(rank: 5, bucket: .idle, stretches: inactiveStretches(.idle)),
            Layer(rank: 6, bucket: .screen, stretches: sessionStretches),
            Layer(rank: 7, bucket: .paused, stretches: gapStretches(.paused)),
            Layer(rank: 7, bucket: .permissionMissing, stretches: gapStretches(.permissionMissing)),
            Layer(rank: 7, bucket: .notRunning, stretches: gapStretches(.notRunning)),
        ]
        let spans = paint(from: from, through: through, layers: layers)

        // Evidence: anything the app or a source recorded inside the day.
        var evidence: [Date] = []
        for block in dayBlocks {
            if let stretch = clipped(block.startAt, block.endAt) { evidence += [stretch.start, stretch.end] }
        }
        evidence += rows.map(\.capturedAt).filter { $0 >= from && $0 <= through }
        for stretch in sessionStretches { evidence += [stretch.start, stretch.end] }
        let first = evidence.min()
        let last = evidence.max()

        let window = first.flatMap { first in
            last.map { last in
                minutes(of: spans, from: first, to: last)
            }
        }
        return DayAccounting(
            from: from, through: through, firstEvidence: first, lastEvidence: last,
            day: minutes(of: spans, from: from, to: through), window: window, spans: spans
        )
    }

    /// The layers flattened: each elementary stretch goes to the lowest-ranked layer covering
    /// it, else to `unexplained`, and equal neighbours are merged.
    private static func paint(from: Date, through: Date, layers: [Layer]) -> [Span] {
        guard through > from else { return [] }
        var points: Set<Date> = [from, through]
        for layer in layers {
            for stretch in layer.stretches {
                points.insert(stretch.start)
                points.insert(stretch.end)
            }
        }
        let cuts = points.sorted()
        // A layer's stretches merged first: a day of foreground sessions is hundreds of rows.
        let ordered = layers.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { Layer(rank: $0.element.rank, bucket: $0.element.bucket, stretches: StatsAggregator.union($0.element.stretches)) }
        var spans: [Span] = []
        for index in 0..<(cuts.count - 1) {
            let start = cuts[index], end = cuts[index + 1]
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let bucket = ordered.first { layer in
                layer.stretches.contains { $0.start <= middle && middle < $0.end }
            }?.bucket ?? .unexplained
            if var previous = spans.last, previous.bucket == bucket, previous.end == start {
                previous.end = end
                spans[spans.count - 1] = previous
            } else {
                spans.append(Span(start: start, end: end, bucket: bucket))
            }
        }
        return spans
    }

    /// The spans' seconds inside `[start, end)`, as minutes that add up to that stretch.
    private static func minutes(of spans: [Span], from start: Date, to end: Date) -> Minutes {
        var seconds: [Bucket: Double] = [:]
        for span in spans {
            let overlap = min(span.end, end).timeIntervalSince(max(span.start, start))
            if overlap > 0 { seconds[span.bucket, default: 0] += overlap }
        }
        return Minutes(seconds: seconds, totalSeconds: max(0, end.timeIntervalSince(start)))
    }
}
