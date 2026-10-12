import Foundation

/// The Weeks page: seven days, usually from 08:00 to 20:00, coloured by the app that filled each
/// stretch, with meetings drawn as chips on top (reader redesign). A week with something drawn
/// before 08:00 or after 20:00 widens its window to the whole hour that holds it.
///
/// The grouping is the mock's, and it lives here rather than in the view so a test can hold it:
///
/// 1. cut the day into 30-minute slots and colour each by the category — one of the week's top
///    `topAppCount` apps, or Others — that filled most of it, counting only the minutes no
///    meeting covers (the meeting's chip already stands for those);
/// 2. skip a slot at least half covered by a meeting, and a slot with under 8 active minutes;
/// 3. merge adjacent slots of the same category;
/// 4. clip blocks at meeting edges, then drop any block under 15 minutes.
///
/// Every time here is minutes after local midnight, so the arithmetic is the same on the day the
/// clocks change and a test can write `9 * 60`.
public enum WeekCalendar {
    public static let slotMinutes = 30.0
    /// The window a week shows when nothing falls outside it.
    public static let windowStart = 8.0 * 60
    public static let windowEnd = 20.0 * 60
    public static let dayMinutes = 24.0 * 60
    /// A slot with less active time than this is left empty.
    public static let minimumSlotMinutes = 8.0
    /// A block shorter than this, after clipping, is not drawn.
    public static let minimumBlockMinutes = 15.0
    /// How many apps keep their own colour and a place in the legend; the rest are Others.
    /// Three, as on every real week: the sample is drawn the way your own weeks are (#357).
    public static let topAppCount = 3

    /// One stretch of one app on screen.
    public struct Span: Sendable, Equatable {
        public var app: String
        public var start: Double
        public var end: Double

        public init(app: String, start: Double, end: Double) {
            self.app = app
            self.start = start
            self.end = end
        }
    }

    /// The week's top apps by name, each with the colour its key picks.
    public struct TopApp: Sendable, Equatable, Hashable {
        public var name: String
        public var colorHex: UInt32

        public init(name: String, colorHex: UInt32) {
            self.name = name
            self.colorHex = colorHex
        }
    }

    public struct Meeting: Sendable, Equatable, Identifiable {
        public var title: String
        public var start: Double
        public var end: Double
        public var id: String { "\(start)-\(end)-\(title)" }

        public init(title: String, start: Double, end: Double) {
            self.title = title
            self.start = start
            self.end = end
        }

        public var minutes: Int { Int((end - start).rounded()) }
    }

    public enum Category: Sendable, Hashable {
        case app(String)
        case others

        public var name: String {
            switch self {
            case let .app(name): return name
            case .others: return ReaderShellCopy.others
            }
        }
    }

    public struct Block: Sendable, Equatable, Identifiable {
        public var category: Category
        public var start: Double
        public var end: Double
        /// The apps inside the block and their minutes, most first — the tooltip's list.
        public var apps: [Waterfall.Item]
        public var id: String { "\(start)-\(category.name)" }
        public var minutes: Double { end - start }
    }

    // MARK: Grouping

    public static func blocks(
        spans: [Span],
        meetings: [Meeting],
        top: [String],
        end: Double = dayMinutes
    ) -> [Block] {
        let topSet = Set(top)
        let categoryOf: (String) -> Category = { topSet.contains($0) ? .app($0) : .others }
        struct Open {
            var category: Category
            var start: Double
            var end: Double
            var apps: [String: Double]
        }
        var open: [Open] = []
        var slot = 0.0
        while slot < dayMinutes {
            let slotEnd = slot + slotMinutes
            defer { slot = slotEnd }
            guard slot < end else { continue }
            let covered = meetings.reduce(0.0) { $0 + overlap(slot, slotEnd, $1.start, $1.end) }
            if covered >= slotMinutes / 2 { continue }
            var perCategory: [Category: Double] = [:]
            var perApp: [String: Double] = [:]
            var sum = 0.0
            for span in spans {
                // #357: the minutes a meeting covers are the meeting's. Counting the call's own
                // window there let a standup's last ten minutes paint the slot after it as Zoom.
                let inside = overlap(slot, slotEnd, span.start, span.end)
                    - meetingCover(max(slot, span.start), min(slotEnd, span.end), meetings)
                guard inside > 0.001 else { continue }
                perCategory[categoryOf(span.app), default: 0] += inside
                perApp[span.app, default: 0] += inside
                sum += inside
            }
            if sum < minimumSlotMinutes { continue }
            // Ties go to the top app over Others, then by name, so a slot never flickers.
            let winner = perCategory.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return rank(lhs.key) > rank(rhs.key)
            }!.key
            if var last = open.last, last.category == winner, last.end == slot {
                last.end = slotEnd
                for (app, minutes) in perApp { last.apps[app, default: 0] += minutes }
                open[open.count - 1] = last
            } else {
                open.append(Open(category: winner, start: slot, end: slotEnd, apps: perApp))
            }
        }
        return open.compactMap { block -> Block? in
            var start = block.start
            var stop = block.end
            for meeting in meetings where meeting.start < stop && meeting.end > start {
                if meeting.start <= start {
                    start = meeting.end
                } else if meeting.end >= stop {
                    stop = meeting.start
                }
            }
            stop = min(stop, end)
            guard stop - start >= minimumBlockMinutes else { return nil }
            let items: [Waterfall.Item] = block.apps.map { app, minutes in
                Waterfall.Item(name: app, minutes: Int(minutes.rounded()))
            }
            let apps = items.filter { $0.minutes > 0 }.sorted(by: mostFirst)
            return Block(category: block.category, start: start, end: stop, apps: apps)
        }
    }

    static func mostFirst(_ lhs: Waterfall.Item, _ rhs: Waterfall.Item) -> Bool {
        lhs.minutes == rhs.minutes ? lhs.name < rhs.name : lhs.minutes > rhs.minutes
    }

    private static func rank(_ category: Category) -> String {
        switch category {
        case let .app(name): return "0" + name
        case .others: return "1"
        }
    }

    static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// The minutes of `start..<end` that at least one meeting covers, overlaps counted once.
    static func meetingCover(_ start: Double, _ end: Double, _ meetings: [Meeting]) -> Double {
        guard end > start else { return 0 }
        var covered = 0.0
        var reached = start
        for meeting in meetings.sorted(by: { $0.start < $1.start }) where meeting.end > reached {
            let from = max(reached, meeting.start)
            let to = min(end, meeting.end)
            if to > from { covered += to - from }
            reached = max(reached, to)
            if reached >= end { break }
        }
        return covered
    }

    /// The week's top apps, by the minutes they were on screen outside every meeting: the ones
    /// that can colour a block. Ranking by the stats' minutes named the call app (Zoom, Meet) for
    /// time its own chips covered, and the legend showed a colour the grid never drew.
    static func topApps(_ minutes: [String: Double], count: Int = topAppCount) -> [String] {
        minutes.filter { $0.value >= minimumSlotMinutes }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(count)
            .map(\.key)
    }

    // MARK: The week

    public struct Day: Sendable, Equatable, Identifiable {
        public var day: String
        /// `Mon 21`.
        public var label: String
        /// Nil for a day still to come.
        public var activeMinutes: Int?
        public var isToday: Bool
        public var blocks: [Block]
        public var meetings: [Meeting]
        /// Where the now-line sits, on today only.
        public var nowMinute: Double?
        public var id: String { day }

        /// `6h 12m`, `No activity`, or nothing for a day still to come.
        public var subtitle: String {
            guard let activeMinutes else { return "" }
            return activeMinutes > 0 ? Waterfall.duration(activeMinutes) : ReaderShellCopy.noActivity
        }

        public var hasData: Bool { (activeMinutes ?? 0) > 0 }
    }

    public struct Week: Sendable, Equatable {
        public var monday: String
        /// `21–27 September`.
        public var title: String
        /// `Active time 12h 15m so far · Meetings 5h 32m`.
        public var line: String
        /// The week's top `topAppCount` apps, most minutes first — the legend and the block colours.
        public var top: [TopApp]
        public var days: [Day]
        /// The hours the grid spans: 08:00 to 20:00, or wider to take in every block and chip.
        public var windowStart: Double = WeekCalendar.windowStart
        public var windowEnd: Double = WeekCalendar.windowEnd

        public var isEmpty: Bool { !days.contains(where: \.hasData) }

        public func colorHex(_ category: Category) -> UInt32 {
            switch category {
            case let .app(name):
                return top.first { $0.name == name }?.colorHex ?? AppPalette.hex(forApp: name)
            case .others:
                return AppPalette.others
            }
        }
    }

    /// The whole week from what the store holds: the screen blocks for the colours and the top
    /// apps, the calendar's meeting blocks for the chips, the weekly stats for the numbers.
    public static func build(
        week: ISOWeek,
        stats: WeeklyStats?,
        blocksByDay: [String: [ActivityBlock]],
        labels: TimelineLabels,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> Week {
        let today = DayBoundaries.dayString(now, timeZone: timeZone)
        let perDay = stats?.perDayActiveMinutes ?? []
        struct Read {
            var day: String
            var range: (start: Date, end: Date)
            var spans: [Span]
            var meetings: [Meeting]
        }
        var reads: [Read] = []
        var keyOf: [String: String] = [:]
        var outside: [String: Double] = [:]
        for day in week.days {
            guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { continue }
            let blocks = day > today ? [] : (blocksByDay[day] ?? [])
            let minute: (Date) -> Double = { $0.timeIntervalSince(range.start) / 60 }
            let end = day == today ? minute(now) : dayMinutes
            let screen = blocks.filter { $0.source == .screen && !StatsAggregator.isInactive($0) }
            let spans = screen.map { block -> Span in
                let name = labels.app(block.appKey)
                if keyOf[name] == nil { keyOf[name] = block.appKey }
                return Span(app: name, start: minute(block.startAt), end: min(end, minute(block.endAt)))
            }
            let meetingBlocks = blocks.filter { $0.source != .screen && StatsAggregator.isMeeting($0) }
            let meetings = meetingChips(meetingBlocks.map { block -> Meeting in
                let title = block.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Meeting(
                    title: title.isEmpty ? ReaderShellCopy.meeting : title,
                    start: minute(block.startAt), end: minute(block.endAt)
                )
            })
            for span in spans where span.end > span.start {
                outside[span.app, default: 0] += (span.end - span.start)
                    - meetingCover(span.start, span.end, meetings)
            }
            reads.append(Read(day: day, range: (range.start, range.end), spans: spans, meetings: meetings))
        }
        let topNames = topApps(outside.filter { keyOf[$0.key] != StatsAggregator.otherKey })
        let top = topNames.map { TopApp(name: $0, colorHex: AppPalette.hex(forApp: $0, key: keyOf[$0])) }
        var days: [Day] = []
        for (index, read) in reads.enumerated() {
            let isToday = read.day == today
            let isFuture = read.day > today
            let nowMinute = isToday ? now.timeIntervalSince(read.range.start) / 60 : nil
            let active = isFuture ? nil : (perDay.indices.contains(index) ? perDay[index] : 0)
            days.append(Day(
                day: read.day,
                label: dayLabel(read.range.start, timeZone: timeZone, locale: locale),
                activeMinutes: active,
                isToday: isToday,
                blocks: isFuture ? [] : WeekCalendar.blocks(
                    spans: read.spans, meetings: read.meetings, top: topNames, end: nowMinute ?? dayMinutes
                ),
                meetings: isFuture ? [] : read.meetings,
                nowMinute: nowMinute
            ))
        }
        let includesToday = week.days.contains(today)
        let window = window(days)
        return Week(
            monday: week.start,
            title: title(week, timeZone: timeZone, locale: locale),
            line: line(
                active: stats?.totals.activeMinutes ?? 0,
                meetings: stats?.totals.meetingMinutes ?? 0,
                soFar: includesToday
            ),
            top: top,
            days: days,
            windowStart: window.start,
            windowEnd: window.end
        )
    }

    /// 08:00 to 20:00, widened to the whole hour around anything drawn outside it.
    static func window(_ days: [Day]) -> (start: Double, end: Double) {
        let starts = days.flatMap { $0.blocks.map(\.start) + $0.meetings.map(\.start) }
        let ends = days.flatMap { $0.blocks.map(\.end) + $0.meetings.map(\.end) }
        let start = min(windowStart, ((starts.min() ?? windowStart) / 60).rounded(.down) * 60)
        let end = max(windowEnd, ((ends.max() ?? windowEnd) / 60).rounded(.up) * 60)
        return (max(0, start), min(dayMinutes, end))
    }

    /// The same call can reach the calendar twice — two invitations, or a Granola note beside it.
    /// Chips that start and end within a minute of each other are one chip, keeping the title.
    static func meetingChips(_ meetings: [Meeting]) -> [Meeting] {
        var kept: [Meeting] = []
        for meeting in meetings.sorted(by: { $0.start < $1.start }) where meeting.end > meeting.start {
            if let index = kept.firstIndex(where: {
                abs($0.start - meeting.start) < 1 && abs($0.end - meeting.end) < 1
            }) {
                if kept[index].title == ReaderShellCopy.meeting { kept[index].title = meeting.title }
                continue
            }
            kept.append(meeting)
        }
        return kept
    }

    // MARK: Labels (#357)

    /// Where a day's chips and labels are drawn so a meeting and an app block never hide each
    /// other's name.
    ///
    /// A fifteen-minute standup is a few points tall on the grid, too short for its title, and the
    /// block after it starts where it ends. So a chip shorter than `chipMinutes` is drawn that
    /// tall (never into the next meeting, and never more than `maxStretchMinutes` past its end),
    /// and a block's label starts below every chip that sits
    /// over its top. A block with no room for its label clear of every chip draws none.
    ///
    /// #357 second pass: a block under a stretched chip is drawn from the chip's bottom, never
    /// behind it. Drawn behind, a twenty-minute block after a standup showed as a coloured
    /// sliver under the chip's edge, which read as a rendering fault.
    ///
    /// A chip stops growing down where the block after it would keep less than
    /// `minimumBlockVisibleMinutes`, and grows up by what it gave back instead, over the empty
    /// time or the longer block before it. So a twenty-minute block after a standup keeps its
    /// place and the standup keeps its line. Only when neither side has the room is the block
    /// left out of the drawing; `Placement.hidden` names it so the grid can still say it.
    public struct Placement: Sendable, Equatable {
        /// Each meeting's drawn top and bottom, by `Meeting.id`.
        public var meetings: [String: Span]
        /// Each block's drawn top and bottom, by `Block.id`; absent when a chip covers it.
        public var blocks: [String: Span] = [:]
        /// The blocks a chip covers, by `Block.id`: not drawn, but still there to be read out.
        public var hidden: [String] = []
        /// Where each block's label starts, by `Block.id`; absent when it has no room.
        public var labels: [String: Double]

        /// A drawn stretch, minutes after midnight.
        public struct Span: Sendable, Equatable {
            public var start: Double
            public var end: Double

            public init(start: Double, end: Double) {
                self.start = start
                self.end = end
            }
        }
    }

    /// - Parameters:
    ///   - chipMinutes: the least height a meeting chip is drawn at, in the grid's minutes: what
    ///     one line of its title needs.
    ///   - labelMinutes: what a block's label needs, in the same minutes.
    ///   - maxStretchMinutes: the most a chip grows past its meeting's real end, unless the
    ///     meeting is longer than this, when it may grow by its own length. On a grid widened to
    ///     the hours a real day covers, one line of title is forty-odd minutes, and a standup
    ///     drawn that tall looks three times its length and hides the block under it.
    ///   - minimumBlockVisibleMinutes: the least of a block a chip may leave showing; less, and
    ///     the block is not drawn rather than drawn as a sliver.
    ///   - windowStart / windowEnd: the hours the grid draws; a chip is kept inside them.
    public static func placement(
        _ day: Day, chipMinutes: Double, labelMinutes: Double, maxStretchMinutes: Double = 15,
        minimumBlockVisibleMinutes: Double = 8,
        windowStart: Double = WeekCalendar.windowStart, windowEnd: Double = WeekCalendar.windowEnd
    ) -> Placement {
        let meetings = day.meetings.sorted { $0.start < $1.start }
        var drawn: [String: Placement.Span] = [:]
        for (index, meeting) in meetings.enumerated() {
            let top = max(windowStart, meeting.start)
            let end = min(windowEnd, meeting.end)
            let length = max(0, end - top)
            let tall = max(length, min(chipMinutes, length + max(length, maxStretchMinutes)))
            var bottom = top + tall
            // Never over the next meeting's title, but never shorter than the meeting itself.
            if let next = meetings.dropFirst(index + 1).first(where: { $0.start > top }) {
                bottom = max(end, min(bottom, next.start))
            }
            // Never so far that a block starting under the chip is squeezed out of sight: what
            // the chip gives back below, it takes above, down to the chip or block before it.
            var start = top
            // Only a block the meeting itself leaves enough of: one it covers is lost either way.
            let squeezed = day.blocks.filter {
                $0.start >= top - 0.001 && $0.start < bottom && $0.end - minimumBlockVisibleMinutes >= end - 0.001
            }
            if let limit = squeezed.map({ $0.end - minimumBlockVisibleMinutes }).min(), bottom > limit {
                let wanted = bottom - max(end, limit)
                bottom = max(end, limit)
                var floor = windowStart
                for other in meetings.prefix(index) {
                    if let chip = drawn[other.id] { floor = max(floor, chip.end) }
                }
                for above in day.blocks where above.end <= top + 0.001 && above.end > top - wanted {
                    floor = max(floor, above.start + minimumBlockVisibleMinutes)
                }
                start = max(min(floor, top), top - wanted)
            }
            // Against the bottom of the grid, it grows upwards instead.
            if bottom > windowEnd { start = max(windowStart, windowEnd - (bottom - start)) }
            drawn[meeting.id] = Placement.Span(start: start, end: min(bottom, windowEnd))
        }
        let chips = Array(drawn.values).sorted { $0.start < $1.start }
        var labels: [String: Double] = [:]
        var blocks: [String: Placement.Span] = [:]
        var hidden: [String] = []
        for block in day.blocks {
            // Below every chip over the block's top, chained: a chip that ends where the next begins.
            var start = block.start
            for chip in chips where chip.start <= start + 0.001 && chip.end > start {
                start = chip.end
            }
            guard block.end - start >= minimumBlockVisibleMinutes - 0.001 else {
                hidden.append(block.id)
                continue
            }
            blocks[block.id] = Placement.Span(start: start, end: block.end)
            let candidates = ([start] + chips.map(\.end).filter { $0 > start && $0 < block.end })
                .sorted()
            let top = candidates.first { start in
                let end = start + labelMinutes
                guard end <= block.end + 0.001 else { return false }
                return !chips.contains { overlap(start, end, $0.start, $0.end) > 0.001 }
            }
            if let top { labels[block.id] = top }
        }
        return Placement(meetings: drawn, blocks: blocks, hidden: hidden, labels: labels)
    }

    // MARK: Words

    public static func dayLabel(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEd")
        return formatter.string(from: date)
    }

    /// `21-27 September`, or `28 September - 4 October` across a month.
    public static func title(_ week: ISOWeek, timeZone: TimeZone, locale: Locale) -> String {
        guard let first = DayBoundaries.range(day: week.start, timeZone: timeZone)?.start,
              let last = DayBoundaries.range(day: week.end, timeZone: timeZone)?.start
        else { return "\(week.start) to \(week.end)" }
        let formatter = DateIntervalFormatter()
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateTemplate = "dMMMM"
        var span = NoEmDash.range(formatter.string(from: first, to: last))
        // `21 - 27 September` is how Foundation spaces a same-month range; the design sets it
        // tight, `21-27 September`, and keeps the spaced one for `28 September - 4 October`.
        if let dash = span.range(of: " - "), span[..<dash.lowerBound].allSatisfy(\.isNumber) {
            span.replaceSubrange(dash, with: "-")
        }
        return span
    }

    public static func line(active: Int, meetings: Int, soFar: Bool) -> String {
        let activeText = soFar
            ? L10n.format("Active time %@ so far", Waterfall.duration(active))
            : L10n.format("Active time %@", Waterfall.duration(active))
        guard meetings > 0 else { return activeText }
        return activeText + " · " + L10n.format("Meetings %@", Waterfall.duration(meetings))
    }

    /// `09:30-11:00`, in the viewer's clock.
    public static func range(_ start: Double, _ end: Double) -> String {
        "\(clock(start))-\(clock(end))"
    }

    public static func clock(_ minute: Double) -> String {
        let total = Int(minute.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
