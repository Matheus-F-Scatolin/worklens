import Foundation

/// Turns synced meetings into `activity_blocks`, so a day's timeline says "you were in the
/// portfolio review" even for the stretch where the screen showed nothing but a grid of faces.
///
/// Screen blocks are *not* removed when a meeting covers them: what you had open during a call
/// is exactly the interesting part. The renderer nests them under the meeting instead.
public enum ContextBlocks {
    /// App key every meeting block carries. The app you were in is on the nested screen blocks.
    public static let appKey = "meeting"
    public static let taskKey = "video_call"
    /// A meeting shorter than this is a calendar artefact (a hold, a reminder), not time spent.
    public static let minimumDuration: TimeInterval = 60

    /// Meeting blocks for one local day, clamped to the day's bounds.
    ///
    /// - Parameter events: any context events; non-meetings and events outside the day are
    ///   dropped, and overlapping duplicates (the same call known to both Granola and the
    ///   calendar) are collapsed so the day cannot report more meeting time than it had.
    public static func meetingBlocks(
        day: String,
        events: [ContextEvent],
        timeZone: TimeZone = .current
    ) -> [ActivityBlock] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }

        let inDay = events
            .filter { $0.isMeeting && $0.startAt < range.end && $0.effectiveEndAt > range.start }
            .sorted { $0.startAt < $1.startAt }

        return deduplicate(inDay).compactMap { event in
            let start = max(event.startAt, range.start)
            let end = min(event.effectiveEndAt, range.end)
            guard end.timeIntervalSince(start) >= minimumDuration else { return nil }
            // Redacted before the cut and before it is stored as the block's heading.
            let shown = event.redacted()

            return ActivityBlock(
                id: blockId(for: event),
                day: day,
                startAt: start,
                endAt: end,
                appKey: appKey,
                taskKey: taskKey,
                title: shown.title?.nonEmpty,
                summaryMd: ContextBody.oneLine(shown.bodyMd, limit: 400),
                captureCount: 0,
                source: event.source == .granola ? .granola : .calendar
            )
        }
    }

    // MARK: - Away from the machine (#94)

    /// App key every away block carries. One of `StatsAggregator.inactiveKeys`, so away time is
    /// tracked and never counted as active.
    public static let awayAppKey = StatsAggregator.awayAppKey
    /// Task key: the calendar is the only thing that can tell Worklens you were away.
    public static let awayTaskKey = "calendar"
    /// An event whose span is covered by screen frames for at least this much of it was worked
    /// through, not spent away.
    public static let awayFrameCoverage = 0.2

    /// Blocks for the stretches a calendar event says you were away from the machine.
    ///
    /// Lunch with two colleagues is not a meeting — `CalendarSource` only flags conferences —
    /// so before #94 an hour of it was an unexplained hole the report had to ask about. An event
    /// qualifies when it is timed (an all-day entry is a label on the day), not declined, has
    /// somebody else on it, is not already a meeting block, and the screen was quiet through it.
    ///
    /// - Parameter frames: the day's frames. Coverage is counted in distinct minutes touched by
    ///   a non-idle frame, which is capture-interval-agnostic for any interval up to a minute.
    public static func awayBlocks(
        day: String,
        events: [ContextEvent],
        frames: [TimelineFrame],
        timeZone: TimeZone = .current
    ) -> [ActivityBlock] {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return [] }

        let candidates = events
            .filter { $0.source == .calendar && !$0.isMeeting && $0.endAt != nil }
            .filter { $0.startAt < range.end && $0.effectiveEndAt > range.start }
            .filter { isAway($0, frames: frames) }
            .sorted { $0.startAt < $1.startAt }

        return candidates.compactMap { event in
            let start = max(event.startAt, range.start)
            let end = min(event.effectiveEndAt, range.end)
            guard end.timeIntervalSince(start) >= minimumDuration else { return nil }
            // Redacted before the cut and before it is stored as the block's heading.
            let shown = event.redacted()

            return ActivityBlock(
                id: awayBlockId(for: event),
                day: day,
                startAt: start,
                endAt: end,
                appKey: awayAppKey,
                taskKey: awayTaskKey,
                title: shown.title?.nonEmpty,
                summaryMd: ContextBody.oneLine(shown.bodyMd, limit: 400),
                captureCount: 0,
                source: .calendar
            )
        }
    }

    /// The `awayBlocks` test on one event, without the day's clamping.
    static func isAway(_ event: ContextEvent, frames: [TimelineFrame]) -> Bool {
        let flags = calendarFlags(event)
        guard !flags.allDay, !flags.declined, flags.otherAttendees > 0 else { return false }
        let span = event.effectiveEndAt.timeIntervalSince(event.startAt)
        guard span >= minimumDuration else { return false }
        return frameCoverage(of: event, frames: frames) < awayFrameCoverage
    }

    /// The share of an event's minutes that a non-idle frame landed in. An idle frame is the
    /// machine sitting there without you, which is exactly what being away looks like.
    static func frameCoverage(of event: ContextEvent, frames: [TimelineFrame]) -> Double {
        let start = event.startAt
        let end = event.effectiveEndAt
        let spanMinutes = (end.timeIntervalSince(start) / 60).rounded(.up)
        guard spanMinutes > 0 else { return 1 }
        let touched = Set(
            frames
                .filter { !$0.isIdle && $0.at >= start && $0.at < end }
                .map { Int($0.at.timeIntervalSince(start) / 60) }
        )
        return Double(touched.count) / spanMinutes
    }

    /// What the away test needs from the Google event `CalendarSource` stored in `raw_json`:
    /// whether it is all-day, whether you declined it, and how many other people are on it.
    /// None of it is on `ContextEvent` itself, and none of it is worth a column.
    struct CalendarFlags: Equatable {
        var allDay: Bool
        var declined: Bool
        var otherAttendees: Int
    }

    static func calendarFlags(_ event: ContextEvent) -> CalendarFlags {
        guard let raw = event.rawJson, let data = raw.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            // A calendar event synced before #94 kept no attendee list; `participants_json` is
            // all there is, and it holds you as well as everybody else.
            return CalendarFlags(
                allDay: false, declined: false, otherAttendees: max(event.participants.count - 1, 0)
            )
        }
        let attendees = json["attendees"]?.arrayValue ?? []
        let isSelf = { (attendee: JSONValue) in attendee["self"]?.boolValue == true }
        return CalendarFlags(
            allDay: json["start"]?["dateTime"]?.stringValue == nil
                && json["start"]?["date"]?.stringValue != nil,
            declined: attendees.contains {
                isSelf($0) && $0["responseStatus"]?.stringValue == "declined"
            },
            otherAttendees: attendees.filter { !isSelf($0) }.count
        )
    }

    /// Distinct from `blockId`, so an event can never be a meeting and an away block at once.
    static func awayBlockId(for event: ContextEvent) -> String {
        "away-\(blockId(for: event))"
    }

    /// A block id derived from the event, so a rebuild of the same day produces the same rows and
    /// nothing downstream sees a meeting "move".
    static func blockId(for event: ContextEvent) -> String {
        "ctx-\(event.source.rawValue)-\(event.id)"
    }

    /// The same meeting often arrives twice: Granola took notes on a call that is also in the
    /// calendar. A note and the calendar event it names (`linkedCalendarEventId`, #318) are one
    /// meeting when their times overlap. A note that names no event is one meeting with each
    /// calendar event it overlaps for more than half of the shorter one (#340), so a double
    /// booking it covers loses both invites, unless some note names that event: a link always
    /// wins over a guess. When the note that names the event also overlaps it, that note is the
    /// call and the unlinked note is its second copy, so the unlinked note goes. Granola wins over
    /// the calendar, because it is the copy that carries a summary. Everything else stays separate
    /// — a calendar double booking is two meetings, two unlinked notes are two meetings, and the
    /// totals that read this take the union of their time, never the sum.
    static func deduplicate(_ events: [ContextEvent]) -> [ContextEvent] {
        var calendar: [String: [ContextEvent]] = [:]
        for event in events where event.source == .calendar {
            calendar[event.externalId, default: []].append(event)
        }
        let notes = events.filter { $0.source == .granola }.map { ($0, $0.linkedCalendarEventId) }
        let named = Set(notes.compactMap(\.1))
        var dropped: Set<String> = []
        for (note, linkedId) in notes {
            guard let linkedId else { continue }
            for event in calendar[linkedId] ?? [] where overlaps(note, event) {
                dropped.insert(event.id)
            }
        }
        // Events a linked note named and overlapped: the call itself, already in its note.
        let claimed = dropped
        for (note, linkedId) in notes where linkedId == nil {
            for event in events where event.source == .calendar && overlapsSubstantially(note, event) {
                if !named.contains(event.externalId) {
                    dropped.insert(event.id)
                } else if claimed.contains(event.id) {
                    dropped.insert(note.id)
                }
            }
        }
        return events.filter { !dropped.contains($0.id) }.sorted { $0.startAt < $1.startAt }
    }

    static func overlaps(_ a: ContextEvent, _ b: ContextEvent) -> Bool {
        min(a.effectiveEndAt, b.effectiveEndAt) > max(a.startAt, b.startAt)
    }

    /// The overlap is more than half of the shorter event: the threshold `main` used for every
    /// pair before #318, kept for a note that names no event (#340).
    static func overlapsSubstantially(_ a: ContextEvent, _ b: ContextEvent) -> Bool {
        let overlap = min(a.effectiveEndAt, b.effectiveEndAt).timeIntervalSince(max(a.startAt, b.startAt))
        guard overlap > 0 else { return false }
        let shorter = min(
            a.effectiveEndAt.timeIntervalSince(a.startAt),
            b.effectiveEndAt.timeIntervalSince(b.startAt)
        )
        return shorter > 0 && overlap / shorter > 0.5
    }
}
