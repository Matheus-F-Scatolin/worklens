import Foundation
import GRDB

/// Turning the sample's shapes into rows, and the rows into its own database (#349).
extension SampleWeek {
    /// Everything the sample writes, before it is written. A value, so the tests can compare two
    /// builds without a database.
    public struct Content: Sendable, Equatable {
        /// Every day of last calendar week, then this week up to today, oldest first.
        public var days: [String]
        public var captures: [Capture]
        /// Screen blocks and the meeting blocks the calendar events become.
        public var blocks: [ActivityBlock]
        public var events: [ContextEvent]

        /// Every sentence and title in the content: block titles and summaries, meeting titles
        /// and bodies, screenshot window titles.
        public var lines: [String] {
            blocks.flatMap { [$0.title, $0.summaryMd].compactMap { $0 } }
                + events.flatMap { [$0.title, $0.bodyMd].compactMap { $0 } }
                + captures.compactMap(\.windowTitle)
        }
    }

    /// Last calendar week in full and this week up to `now`'s day, built from the weekday shapes
    /// (#357). A Monday used to open on seven days ending today, which left the Weeks page one
    /// morning and six empty columns; now there is always a whole week behind this one.
    ///
    /// Today is cut at the later of `now` and noon: a sample opened at 08:00 still has a morning
    /// to look at, and one opened at 16:00 does not show the evening yet.
    public static func content(now: Date = Date(), timeZone: TimeZone = .current) -> Content {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        var content = Content(days: [], captures: [], blocks: [], events: [])
        let count = dayCount(now: now, timeZone: timeZone)
        for back in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let day = DayBoundaries.dayString(date, timeZone: timeZone)
            let weekday = calendar.component(.weekday, from: date)
            let cutoff: Date? = back == 0
                ? max(now, calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? now)
                : nil
            append(
                shape(weekday: weekday), day: day, date: date, cutoff: cutoff,
                calendar: calendar, timeZone: timeZone, into: &content
            )
            content.days.append(day)
        }
        return content
    }

    /// How many days the sample holds on `now`'s day: last week's seven, and this week's days up
    /// to and including today. Eight on a Monday, fourteen on a Sunday.
    public static func dayCount(now: Date = Date(), timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // `weekday` counts from Sunday as 1; the ISO week starts on Monday.
        let weekday = calendar.component(.weekday, from: now)
        let intoThisWeek = (weekday + 5) % 7
        return 7 + intoThisWeek + 1
    }

    /// The least number of whole days, before today, that the tour's Week stop shows.
    public static let tourWeekWholeDays = 4

    /// The week the tour's Week stop opens on (#357): this one once it holds
    /// `tourWeekWholeDays` whole days before today (from Friday on), and last week before that,
    /// so the stop always lands on a week with something in most of its columns.
    public static func tourWeek(now: Date = Date(), timeZone: TimeZone = .current) -> ISOWeek? {
        guard let this = ISOWeek.containing(now, timeZone: timeZone) else { return nil }
        let wholeDays = dayCount(now: now, timeZone: timeZone) - 7 - 1
        return wholeDays >= tourWeekWholeDays ? this : this.previous(timeZone: timeZone)
    }

    private static func append(
        _ shape: DayShape, day: String, date: Date, cutoff: Date?,
        calendar: Calendar, timeZone: TimeZone, into content: inout Content
    ) {
        var events: [ContextEvent] = []
        for (index, run) in shape.runs.enumerated() {
            guard let start = moment(run.clock, on: date, calendar: calendar) else { continue }
            var end = start.addingTimeInterval(TimeInterval(run.minutes * 60))
            if let cutoff {
                guard start < cutoff else { continue }
                end = min(end, cutoff)
            }
            let frames = max(1, Int(end.timeIntervalSince(start)) / intervalSeconds)
            let blockID = "\(idPrefix)\(day)-b\(index)"
            for frame in 0..<frames {
                let at = start.addingTimeInterval(TimeInterval(frame * intervalSeconds))
                content.captures.append(Capture(
                    id: "\(idPrefix)\(day)-c\(index)-\(frame)",
                    capturedAt: at,
                    appBundleId: run.app.bundleID,
                    appName: run.app.name,
                    windowTitle: run.title,
                    urlHost: run.app.host,
                    captureSource: .screenshot,
                    intervalSeconds: intervalSeconds,
                    describeStatus: .described,
                    createdAt: at
                ))
            }
            content.blocks.append(ActivityBlock(
                id: blockID, day: day, startAt: start, endAt: end,
                appKey: run.app.key, taskKey: run.task, title: run.title, summaryMd: run.summary,
                captureCount: frames, source: .screen, createdAt: start, updatedAt: start
            ))
            if let meeting = run.meeting {
                // Cut at the same place as the screen block beside it, so a meeting running at
                // `now` does not draw into the rest of today.
                events.append(ContextEvent(
                    id: "\(idPrefix)\(day)-m\(index)",
                    source: .calendar,
                    externalId: "\(idPrefix)\(day)-m\(index)",
                    startAt: start,
                    endAt: end,
                    title: meeting.title,
                    bodyMd: meeting.summary,
                    isMeeting: true,
                    syncedAt: start
                ))
            }
        }
        // The same path a synced calendar takes into the timeline, so the Weeks grid draws the
        // chips and the Today page counts the meetings exactly as it would for a real day.
        let meetingBlocks = ContextBlocks.meetingBlocks(day: day, events: events, timeZone: timeZone)
            .map { block -> ActivityBlock in
                var block = block
                block.createdAt = block.startAt
                block.updatedAt = block.startAt
                return block
            }
        content.events.append(contentsOf: events)
        content.blocks.append(contentsOf: meetingBlocks)
    }

    private static func moment(_ clock: String, on date: Date, calendar: Calendar) -> Date? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)
    }

    // MARK: The database

    /// Writes `content` into `db` in one transaction, with the marker that says it is the sample.
    public static func write(_ content: Content, into db: Database) throws {
        try db.writer.write { db in
            for capture in content.captures { try capture.insert(db) }
            for event in content.events { try event.insert(db) }
            for block in content.blocks { try block.insert(db) }
        }
        try AppStateStore(db).set(markerKey, "true")
    }

    /// Whether `db` is a sample database. The real ledger never carries the marker.
    public static func isSample(_ db: Database) -> Bool {
        ((try? AppStateStore(db).get(markerKey)) ?? nil) == "true"
    }

    /// Throws the sample folder away and builds a fresh one for `now`, returning it open.
    ///
    /// Rebuilt every time rather than kept: the dates have to move with today, and an invented
    /// week is cheaper to write again (a few hundred rows) than to migrate.
    public static func rebuild(
        dataDir: URL, now: Date = Date(), timeZone: TimeZone = .current
    ) throws -> Database {
        let folder = directory(dataDir: dataDir)
        remove(dataDir: dataDir)
        let db = try Database(dataDir: folder)
        try write(content(now: now, timeZone: timeZone), into: db)
        return db
    }

    /// Deletes the sample folder, if there is one. The real ledger beside it is never touched.
    public static func remove(dataDir: URL) {
        let folder = directory(dataDir: dataDir)
        guard folder.standardizedFileURL != dataDir.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
