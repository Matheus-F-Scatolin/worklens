import Foundation

/// Granola meeting notes: title, time, attendees, the AI summary and the full transcript.
///
/// Shapes below are from `https://docs.granola.ai/api-reference/{list-notes,get-note,get-transcript}.md`,
/// read on 2026-09-07 — do not re-derive them from memory. The API only returns notes that already
/// have a summary and a transcript, i.e. finished meetings, so "you are in a meeting right now"
/// comes from the calendar source (#22), never from here.
///
/// Privacy: these are meetings the user attended and whose notes are already on their machine.
/// The transcript goes to a file under `DATA_DIR/context/granola/` and only the summary is stored
/// inline, so a transcript can never leak into a report prompt.
public struct GranolaSource: ContextSyncSource {
    public let id: ContextSource = .granola
    public let displayName = "Granola"

    public static let base = URL(string: "https://public-api.granola.ai/v1")!
    /// `page_size` maxima the API documents.
    public static let notesPageSize = 30
    public static let transcriptPageSize = 100
    /// Stop after this many pages, whatever the cursor says — a pagination bug upstream must not
    /// turn a background sync into an endless loop.
    public static let maxPages = 25
    /// A note is created when its meeting starts, but not always to the second; look back a
    /// little further than the window so a meeting on its edge is not missed.
    public static let listGrace: TimeInterval = 12 * 3600

    private let http: ContextHTTP
    private let timeZone: TimeZone

    public init(http: ContextHTTP = ContextHTTP(minimumSpacing: 0.2), timeZone: TimeZone = .current) {
        self.http = http
        self.timeZone = timeZone
    }

    public func isConfigured(_ config: Config) -> Bool {
        !(config.granolaAPIKey ?? "").isEmpty
    }

    // MARK: Sync

    public func sync(window: DateInterval, into store: ContextEventStore, config: Config) async throws -> SyncResult {
        guard let key = config.granolaAPIKey, !key.isEmpty else {
            throw ContextSyncError.notConfigured("GRANOLA_API_KEY")
        }
        var result = SyncResult()

        // Meetings stored before #316, or by an older parser, get their next steps from the note
        // JSON already on disk: the loop below skips every note whose `updated_at` has not moved.
        try store.refreshMeetingOutcomes()
        // "Names you" means the account's name, the same for every note (see `granolaYouName`).
        let you = try store.granolaYouName()

        let earliest = window.start.addingTimeInterval(-GranolaSource.listGrace)
        for summary in try await listNotes(since: window.start, key: key) {
            try Task.checkCancellation()

            // `created_after` is the server's filter and this is the same bound applied locally:
            // a note created long before the window cannot be a meeting inside it, and skipping
            // it here saves a detail *and* a transcript call.
            if let created = summary.createdAt, created < earliest {
                result.skipped += 1
                continue
            }

            // The cheap half of "second sync inserts 0 and updates only changed notes": the list
            // response carries `updated_at`, so an unchanged note costs no detail or transcript
            // call at all.
            if let stored = try store.find(source: .granola, externalId: summary.id),
               let seen = storedUpdatedAt(stored), let current = summary.updatedAt,
               seen == current {
                result.skipped += 1
                continue
            }

            let note: Note
            do {
                note = try await fetchNote(summary.id, key: key)
            } catch let error as ContextSyncError {
                if case .unauthorized = error { throw error }
                result.warnings.append("could not read note \(summary.id): \(error.description)")
                continue
            }

            guard window.contains(note.startAt) || window.contains(note.endAt) else {
                result.skipped += 1
                continue
            }

            let transcript = try await fetchTranscript(note.id, key: key, warnings: &result.warnings)
            let event = try makeEvent(note, transcript: transcript, config: config, youName: you)
            switch try store.save(event) {
            case .inserted: result.inserted += 1
            case .updated: result.updated += 1
            case .unchanged: result.skipped += 1
            }
        }
        // The first sync, or one that tipped the majority, settles whose name "names you" means.
        if try store.granolaYouName() != you {
            try store.refreshMeetingOutcomes(all: true)
        }
        return result
    }

    // MARK: Listing

    /// One entry of `GET /notes`.
    struct NoteSummary: Sendable, Equatable {
        var id: String
        var createdAt: Date?
        var updatedAt: Date?
    }

    /// The Settings Test button (#135): one page of one note, stored nowhere.
    ///
    /// The cheapest question the API answers, and the only one that can tell a working key from
    /// one Granola will not honour. A 401 means either the key is wrong or the plan does not
    /// include API access — the API does not distinguish them, so neither does the sentence, and
    /// the setup sheet states the Business-plan requirement before the field rather than after a
    /// refusal.
    public func check(key: String) async throws -> String {
        let page = try await http.get(
            url("notes", [URLQueryItem(name: "page_size", value: "1")]),
            headers: headers(key),
            unauthorizedHint: Self.authHint
        )
        let notes = page["notes"]?.arrayValue ?? []
        guard !notes.isEmpty else {
            return "Granola answered, and has no finished meeting notes yet."
        }
        return "Granola answered, and your notes are reachable."
    }

    func listNotes(since: Date, key: String) async throws -> [NoteSummary] {
        var cursor: String?
        var notes: [NoteSummary] = []

        for _ in 0..<GranolaSource.maxPages {
            var items = [
                URLQueryItem(name: "created_after",
                             value: ContextDates.iso8601(since.addingTimeInterval(-GranolaSource.listGrace))),
                URLQueryItem(name: "page_size", value: String(GranolaSource.notesPageSize)),
            ]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }

            let page = try await http.get(url("notes", items), headers: headers(key), unauthorizedHint: Self.authHint)
            for note in page["notes"]?.arrayValue ?? [] {
                guard let id = note["id"]?.stringValue else { continue }
                notes.append(NoteSummary(
                    id: id,
                    createdAt: ContextDates.parseISO8601(note["created_at"]?.stringValue),
                    updatedAt: ContextDates.parseISO8601(note["updated_at"]?.stringValue)
                ))
            }
            guard page["hasMore"]?.boolValue == true, let next = page["cursor"]?.stringValue, !next.isEmpty else {
                break
            }
            cursor = next
        }
        return notes
    }

    // MARK: One note

    /// `GET /notes/{id}`, mapped to the fields Worklens keeps.
    struct Note: Sendable {
        var id: String
        var title: String?
        var startAt: Date
        var endAt: Date
        var attendees: [String]
        var summaryMarkdown: String?
        /// The note JSON with `transcript` removed — that half belongs in a file, not in a column.
        var raw: JSONValue
    }

    func fetchNote(_ id: String, key: String) async throws -> Note {
        try parseNote(try await http.get(url("notes/\(id)"), headers: headers(key), unauthorizedHint: Self.authHint))
    }

    func parseNote(_ json: JSONValue) throws -> Note {
        guard let id = json["id"]?.stringValue else {
            throw ContextSyncError.decode("a note came back with no id")
        }
        let event = json["calendar_event"]
        let created = ContextDates.parseISO8601(json["created_at"]?.stringValue) ?? Date()
        let start = ContextDates.parseISO8601(event?["scheduled_start_time"]?.stringValue) ?? created
        let end = ContextDates.parseISO8601(event?["scheduled_end_time"]?.stringValue)
            ?? start.addingTimeInterval(ContextEvent.assumedMeetingDuration)

        var raw = json.objectValue ?? [:]
        raw.removeValue(forKey: "transcript")

        return Note(
            id: id,
            title: (json["title"]?.stringValue ?? event?["event_title"]?.stringValue)?.nonEmpty,
            startAt: start,
            endAt: max(end, start),
            attendees: Self.attendees(json),
            summaryMarkdown: Self.summaryMarkdown(json),
            raw: .object(raw)
        )
    }

    /// The full AI summary, before any cut. The transcript and the private notes are never read.
    static func summaryMarkdown(_ json: JSONValue) -> String? {
        (json["summary_markdown"]?.stringValue ?? json["summary_text"]?.stringValue)?.nonEmpty
    }

    /// `attendees[]` first — it is the list of people who actually joined — falling back to the
    /// calendar invitees when Granola has not filled it in.
    static func attendees(_ json: JSONValue) -> [String] {
        let people = json["attendees"]?.arrayValue ?? []
        let named = people.compactMap { person -> String? in
            let email = person["email"]?.stringValue?.nonEmpty
            guard let name = person["name"]?.stringValue?.nonEmpty else { return email }
            return email.map { "\(name) <\($0)>" } ?? name
        }
        if !named.isEmpty { return named }
        return (json["calendar_event"]?["invitees"]?.arrayValue ?? [])
            .compactMap { $0["email"]?.stringValue?.nonEmpty }
    }

    // MARK: Transcript

    struct Segment: Sendable, Equatable {
        var speaker: String
        /// `microphone` (you) or `speaker` (everyone else, as your Mac heard them).
        var source: String
        var text: String
        var startAt: Date?
    }

    func fetchTranscript(_ id: String, key: String, warnings: inout [String]) async throws -> [Segment] {
        var cursor: String?
        var segments: [Segment] = []

        for _ in 0..<GranolaSource.maxPages {
            var items = [URLQueryItem(name: "page_size", value: String(GranolaSource.transcriptPageSize))]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }

            let page: JSONValue
            do {
                page = try await http.get(
                    url("notes/\(id)/transcript", items), headers: headers(key), unauthorizedHint: Self.authHint
                )
            } catch let error as ContextSyncError {
                if case .unauthorized = error { throw error }
                warnings.append("transcript for \(id) is incomplete: \(error.description)")
                break
            }

            segments += Self.parseSegments(page["transcript"])
            guard page["hasMore"]?.boolValue == true, let next = page["cursor"]?.stringValue, !next.isEmpty else {
                break
            }
            cursor = next
        }
        return segments
    }

    static func parseSegments(_ json: JSONValue?) -> [Segment] {
        (json?.arrayValue ?? []).compactMap { item in
            guard let text = item["text"]?.stringValue?.nonEmpty else { return nil }
            let speaker = item["speaker"]
            let source = speaker?["source"]?.stringValue ?? "unknown"
            let name = speaker?["name"]?.stringValue?.nonEmpty
                ?? speaker?["diarization_label"]?.stringValue?.nonEmpty
                ?? (speaker?["attribution"]?.stringValue == "me" ? "You" : "Speaker")
            return Segment(
                speaker: name, source: source, text: text,
                startAt: ContextDates.parseISO8601(item["start_time"]?.stringValue)
            )
        }
    }

    // MARK: Mapping

    /// `youName` is the account's name (`ContextEventStore.granolaYouName`), never the note's
    /// own owner, which on a shared note is a colleague.
    func makeEvent(_ note: Note, transcript: [Segment], config: Config, youName: String?) throws -> ContextEvent {
        let bodyPath = transcript.isEmpty && note.summaryMarkdown == nil
            ? nil
            : try ContextBody.write(
                bodyFile(note, transcript: transcript),
                source: .granola, externalId: note.id, config: config
            )

        return ContextEvent(
            source: .granola,
            externalId: note.id,
            startAt: note.startAt,
            endAt: note.endAt,
            title: note.title,
            participantsJson: ContextEvent.encodeParticipants(note.attendees),
            bodyMd: ContextBody.inline(note.summaryMarkdown),
            bodyPath: bodyPath,
            isMeeting: true,
            rawJson: Self.encode(note.raw),
            // From the full summary: the next steps usually sit past `body_md`'s cut.
            outcomesJson: MeetingOutcomes.parse(
                summaryMarkdown: note.summaryMarkdown, youName: youName
            ).encoded
        )
    }

    /// Front matter, the AI summary, then the transcript. Written so the file reads on its own in
    /// any editor — it is the copy the user keeps.
    func bodyFile(_ note: Note, transcript: [Segment]) -> String {
        var parts = [
            ContextBody.frontMatter(
                source: .granola, externalId: note.id, title: note.title,
                startAt: note.startAt, endAt: note.endAt, participants: note.attendees
            ),
            "",
            "# \(note.title ?? "Untitled meeting")",
        ]
        if let summary = note.summaryMarkdown {
            parts += ["", "## Summary", "", summary]
        }
        if !transcript.isEmpty {
            parts += ["", "## Transcript", ""]
            parts += transcript.map { line(for: $0) }
        }
        return parts.joined(separator: "\n") + "\n"
    }

    /// `[14:03:22] Ana (source=speaker): …`
    func line(for segment: Segment) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm:ss"
        let stamp = segment.startAt.map { "[\(clock.string(from: $0))] " } ?? ""
        return "\(stamp)\(segment.speaker) (source=\(segment.source)): \(segment.text)"
    }

    // MARK: Plumbing

    static let authHint =
        "Granola key invalid or plan does not allow API access (personal API keys need a Business plan)"

    /// `updated_at` as the last sync saw it, straight out of the stored note JSON.
    private func storedUpdatedAt(_ event: ContextEvent) -> Date? {
        guard let raw = event.rawJson, let data = raw.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return ContextDates.parseISO8601(json["updated_at"]?.stringValue)
    }

    private func headers(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    }

    private func url(_ path: String, _ items: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: GranolaSource.base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    static func encode(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
