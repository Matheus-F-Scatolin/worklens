import Foundation

/// The user's primary Google Calendar, read-only.
///
/// Two jobs. It names meetings, so the timeline can say "Portfolio review" instead of "a video
/// call". And it is the only source that knows about a meeting *before* it happens, which is what
/// lets `MeetingDetector` drop the capture cadence the moment a call with a Meet link starts —
/// Granola only publishes a note once the meeting is over.
public struct CalendarSource: ContextSyncSource {
    public let id: ContextSource = .calendar
    public let displayName = "Google Calendar"

    public static let endpoint =
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
    public static let pageSize = 250
    public static let maxPages = 10

    /// Locations that mean "this is a video call" when there is no `conferenceData`.
    public static let conferenceHints = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com"]

    private let auth: GoogleAuth
    private let http: ContextHTTP

    public init(auth: GoogleAuth, http: ContextHTTP = ContextHTTP(minimumSpacing: 0.2)) {
        self.auth = auth
        self.http = http
    }

    public func isConfigured(_ config: Config) -> Bool {
        auth.isConfigured && auth.hasStoredGrant
    }

    // MARK: Sync

    public func sync(window: DateInterval, into store: ContextEventStore, config: Config) async throws -> SyncResult {
        let token = try await auth.token()
        var result = SyncResult()
        var pageToken: String?

        for _ in 0..<CalendarSource.maxPages {
            try Task.checkCancellation()
            var items = [
                URLQueryItem(name: "timeMin", value: ContextDates.iso8601(window.start)),
                URLQueryItem(name: "timeMax", value: ContextDates.iso8601(window.end)),
                // Recurring events expanded into their instances, which is what a day actually had.
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: String(CalendarSource.pageSize)),
                // Ask for cancellations too, so a meeting removed from the calendar can be removed
                // from the timeline instead of lingering.
                URLQueryItem(name: "showDeleted", value: "true"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }

            var components = URLComponents(url: CalendarSource.endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = items
            let page = try await http.get(
                components.url!,
                headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
                unauthorizedHint: IntegrationSetup.googleUnauthorizedHint("Calendar")
            )

            for item in page["items"]?.arrayValue ?? [] {
                guard let id = item["id"]?.stringValue?.nonEmpty else { continue }
                if item["status"]?.stringValue == "cancelled" {
                    // Not an error: an event you declined out of existence should leave no trace.
                    if try store.delete(source: .calendar, externalId: id, config: config) {
                        result.updated += 1
                    } else {
                        result.skipped += 1
                    }
                    continue
                }
                guard let event = Self.map(item) else {
                    result.skipped += 1
                    continue
                }
                switch try store.save(event) {
                case .inserted: result.inserted += 1
                case .updated: result.updated += 1
                case .unchanged: result.skipped += 1
                }
            }

            guard let next = page["nextPageToken"]?.stringValue?.nonEmpty else { break }
            pageToken = next
        }
        return result
    }

    // MARK: Mapping (pure)

    static func map(_ item: JSONValue) -> ContextEvent? {
        guard let id = item["id"]?.stringValue?.nonEmpty else { return nil }
        guard let (start, end, allDay) = times(item) else { return nil }

        let attendees = item["attendees"]?.arrayValue ?? []
        let declined = attendees.contains { $0["self"]?.boolValue == true && $0["responseStatus"]?.stringValue == "declined" }

        return ContextEvent(
            source: .calendar,
            externalId: id,
            startAt: start,
            endAt: end,
            title: item["summary"]?.stringValue?.nonEmpty,
            participantsJson: ContextEvent.encodeParticipants(participants(attendees)),
            bodyMd: ContextBody.inline(item["description"]?.stringValue),
            bodyPath: nil,
            // An all-day entry is a label on the day, not an hour you sat in a call; a meeting you
            // declined is one you did not attend.
            isMeeting: !allDay && !declined && isConference(item),
            rawJson: GranolaSource.encode(trimmed(item))
        )
    }

    /// `dateTime` for a timed event, `date` for an all-day one. The flag matters: an all-day
    /// entry must never look like an eight-hour meeting.
    static func times(_ item: JSONValue) -> (start: Date, end: Date, allDay: Bool)? {
        if let start = ContextDates.parseISO8601(item["start"]?["dateTime"]?.stringValue) {
            let end = ContextDates.parseISO8601(item["end"]?["dateTime"]?.stringValue)
                ?? start.addingTimeInterval(ContextEvent.assumedMeetingDuration)
            return (start, max(end, start), false)
        }
        guard let startDay = item["start"]?["date"]?.stringValue,
              let start = DayBoundaries.range(day: startDay)?.start else { return nil }
        // Google's all-day `end.date` is exclusive.
        let endDay = item["end"]?["date"]?.stringValue
        let end = endDay.flatMap { DayBoundaries.range(day: $0)?.start } ?? start.addingTimeInterval(86400)
        return (start, max(end, start), true)
    }

    /// A conferencing link, or a location that clearly is one.
    static func isConference(_ item: JSONValue) -> Bool {
        if item["hangoutLink"]?.stringValue?.nonEmpty != nil { return true }
        if item["conferenceData"]?.objectValue?.isEmpty == false { return true }
        let haystack = [
            item["location"]?.stringValue,
            item["description"]?.stringValue,
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        return conferenceHints.contains { haystack.contains($0) }
    }

    static func participants(_ attendees: [JSONValue]) -> [String] {
        attendees.compactMap { attendee in
            guard let email = attendee["email"]?.stringValue?.nonEmpty else { return nil }
            guard let status = attendee["responseStatus"]?.stringValue?.nonEmpty else { return email }
            return "\(email) (\(status))"
        }
    }

    /// Keeps the fields worth having in `raw_json` and drops the rest: Google's event objects
    /// carry a lot of scheduling machinery nothing downstream reads.
    static func trimmed(_ item: JSONValue) -> JSONValue {
        let keep = [
            "id", "status", "summary", "start", "end", "location", "hangoutLink",
            "htmlLink", "organizer", "attendees", "eventType", "recurringEventId",
        ]
        return .object((item.objectValue ?? [:]).filter { keep.contains($0.key) })
    }
}
