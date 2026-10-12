import Foundation

/// A drawing of the sample week for the welcome window's tour page (#357): seven small columns,
/// Monday first, coloured the way the Weeks page colours them. Plain shapes from the same weekday
/// shapes the sample is built from, so it never needs a database, a date or a screenshot.
extension SampleWeek {
    public struct Miniature: Sendable, Equatable {
        /// One stretch in one column, minutes after midnight.
        public struct Block: Sendable, Equatable {
            public var start: Double
            public var end: Double
            /// The app's colour, or nil for Others (the Weeks page's grey).
            public var colorHex: UInt32?
            /// A meeting is drawn as an outlined chip on top of the column, as on the Weeks page.
            public var isMeeting: Bool
        }

        /// Monday to Sunday, each column's blocks in clock order.
        public var days: [[Block]]
        /// The hours the drawing spans: the whole hours around the earliest and latest stretch.
        public var windowStart: Double
        public var windowEnd: Double
    }

    /// The miniature, the same every time. Grouped into half hours by `WeekCalendar.blocks` and
    /// coloured by `AppPalette.hex` over the taxonomy's names, exactly as the Weeks page groups
    /// and colours the sample and your own weeks (#357): drawn run by run, the ten minutes of
    /// Slack inside a Claude half hour showed as a grey stripe the page itself never draws.
    public static let miniature: Miniature = {
        // Monday first, the Weeks page's order; `shape(weekday:)` counts Sunday as 1.
        let week = [2, 3, 4, 5, 6, 7, 1].map(shape(weekday:))
        func minute(_ clock: String) -> Double? {
            let parts = clock.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        // Grouped by the taxonomy's name for each key and coloured by it, as `WeekCalendar.build`
        // does. The seed's names, which are the ones a fresh install shows on the sample's pages.
        let labels = TimelineLabels.from(Taxonomy.seed)
        var keyOf: [String: String] = [:]
        let days = week.map { shape -> (spans: [WeekCalendar.Span], meetings: [WeekCalendar.Meeting]) in
            var spans: [WeekCalendar.Span] = []
            var meetings: [WeekCalendar.Meeting] = []
            for run in shape.runs {
                guard let start = minute(run.clock) else { continue }
                let end = start + Double(run.minutes)
                let name = labels.app(run.app.key)
                if keyOf[name] == nil { keyOf[name] = run.app.key }
                spans.append(WeekCalendar.Span(app: name, start: start, end: end))
                if let meeting = run.meeting {
                    meetings.append(WeekCalendar.Meeting(title: meeting.title, start: start, end: end))
                }
            }
            return (spans, meetings)
        }
        // The week's top apps by their minutes outside meetings, never the unfiled ones, as on the grid.
        var minutesByApp: [String: Double] = [:]
        for day in days {
            for span in day.spans {
                minutesByApp[span.app, default: 0] += span.end - span.start
                    - WeekCalendar.meetingCover(span.start, span.end, day.meetings)
            }
        }
        let top = WeekCalendar.topApps(minutesByApp.filter { keyOf[$0.key] != StatsAggregator.otherKey })
        let colourOf = Dictionary(uniqueKeysWithValues: top.map {
            ($0, AppPalette.hex(forApp: $0, key: keyOf[$0]))
        })
        let columns = days.map { day -> [Miniature.Block] in
            let blocks = WeekCalendar.blocks(spans: day.spans, meetings: day.meetings, top: top)
                .map { block -> Miniature.Block in
                    var colour: UInt32?
                    if case let .app(name) = block.category { colour = colourOf[name] }
                    return Miniature.Block(start: block.start, end: block.end, colorHex: colour, isMeeting: false)
                }
            let meetings = day.meetings.map {
                Miniature.Block(start: $0.start, end: $0.end, colorHex: nil, isMeeting: true)
            }
            return (blocks + meetings).sorted { $0.start < $1.start }
        }
        let blocks = columns.flatMap { $0 }
        let first = blocks.map(\.start).min() ?? WeekCalendar.windowStart
        let last = blocks.map(\.end).max() ?? WeekCalendar.windowEnd
        return Miniature(
            days: columns,
            windowStart: (first / 60).rounded(.down) * 60,
            windowEnd: (last / 60).rounded(.up) * 60
        )
    }()
}
