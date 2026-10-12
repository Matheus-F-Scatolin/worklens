import Foundation

/// The handful of things everything downstream of a sync asks a `ContextEvent`.
///
/// Kept next to the sync framework rather than on the record itself: the record is the table,
/// these are #19's conventions about how to read it.
public extension ContextEvent {
    /// How long a meeting with no end time is assumed to last. Granola notes carry a calendar
    /// window most of the time; when they do not, 45 minutes is the honest guess.
    static let assumedMeetingDuration: TimeInterval = 45 * 60

    /// A meeting always occupies a stretch of the day, even when the source only gave a start.
    var effectiveEndAt: Date {
        endAt ?? startAt.addingTimeInterval(ContextEvent.assumedMeetingDuration)
    }

    /// An instant event — a start with no end, and not a meeting — rather than a stretch of time.
    var isInstant: Bool { endAt == nil && !isMeeting }

    var participants: [String] {
        guard let json = participantsJson, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// The attendees' addresses, lowercased, in the order the source listed them (#318). Reads
    /// both shapes `participants_json` holds: the calendar's `email (status)` and Granola's
    /// `Name <email>`, plus a bare address. An entry with no address in it is skipped.
    var participantEmails: [String] {
        participants.compactMap(ContextEvent.email(in:))
    }

    /// The calendar event a Granola note was taken on (#318): `calendar_event.calendar_event_id`
    /// in the stored note, the same id the calendar row keeps as `external_id`. Nil on every
    /// calendar row and on a note Granola did not tie to an event.
    var linkedCalendarEventId: String? {
        guard source == .granola else { return nil }
        return rawJSON?["calendar_event"]?["calendar_event_id"]?.stringValue?.nonEmpty
    }

    /// `raw_json` parsed, or nil when there is none or it does not parse.
    internal var rawJSON: JSONValue? {
        guard let raw = rawJson, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The address inside one `participants_json` entry, lowercased.
    internal static func email(in entry: String) -> String? {
        var candidate = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = candidate.lastIndex(of: "<"),
           let close = candidate[open...].firstIndex(of: ">") {
            candidate = String(candidate[candidate.index(after: open)..<close])
        } else if let first = candidate.split(whereSeparator: \.isWhitespace).first {
            candidate = String(first)
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = candidate.lastIndex(of: "@"), at != candidate.startIndex,
              candidate.index(after: at) != candidate.endIndex
        else { return nil }
        return candidate
    }

    /// `["a@b.com", "c@d.com"]` — the encoding `participants_json` holds.
    static func encodeParticipants(_ values: [String]) -> String? {
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty, let data = try? JSONEncoder().encode(cleaned) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// True while `instant` falls inside the meeting, with `tolerance` of slack on both ends —
    /// people join a minute early and the call runs a minute over.
    func covers(_ instant: Date, tolerance: TimeInterval = 0) -> Bool {
        instant >= startAt.addingTimeInterval(-tolerance)
            && instant <= effectiveEndAt.addingTimeInterval(tolerance)
    }
}
