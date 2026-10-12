import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!

private func temporaryConfig(_ configure: (inout Config) -> Void = { _ in }) -> Config {
    var config = Config.defaults()
    config.dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-granola-\(UUID().uuidString)")
    config.granolaAPIKey = "grn_test"
    configure(&config)
    return config
}

private let window = DateInterval(
    start: ContextDates.parseISO8601("2026-09-06T00:00:00Z")!,
    end: ContextDates.parseISO8601("2026-09-08T00:00:00Z")!
)

// MARK: - Recorded fixtures
//
// Shapes copied from docs.granola.ai/api-reference/{list-notes,get-note,get-transcript}.md,
// read 2026-09-07. Do not "tidy" the field names — they are the contract.

private let listPage1 = """
{
  "notes": [
    {"id": "not_1d3tmYTlCICgjy", "object": "note", "title": "Quarterly yoghurt budget review",
     "owner": {"name": "Oat Benson", "email": "oat@granola.ai"},
     "created_at": "2026-09-07T15:30:00Z", "updated_at": "2026-09-07T16:45:00Z"},
    {"id": "not_2aaaaaaaaaaaaa", "object": "note", "title": "Too old to matter",
     "owner": {"name": "Oat Benson", "email": "oat@granola.ai"},
     "created_at": "2026-08-01T09:00:00Z", "updated_at": "2026-08-01T09:30:00Z"}
  ],
  "hasMore": true,
  "cursor": "cursor-page-2"
}
"""

private let listPage2 = """
{"notes": [{"id": "not_3bbbbbbbbbbbbb", "object": "note", "title": "Second page",
            "created_at": "2026-09-07T09:00:00Z", "updated_at": "2026-09-07T09:30:00Z"}],
 "hasMore": false, "cursor": null}
"""

private func noteBody(id: String = "not_1d3tmYTlCICgjy", updated: String = "2026-09-07T16:45:00Z") -> String {
    """
    {
      "id": "\(id)", "object": "note", "title": "Quarterly yoghurt budget review",
      "owner": {"name": "Oat Benson", "email": "oat@granola.ai"},
      "created_at": "2026-09-07T15:30:00Z", "updated_at": "\(updated)",
      "web_url": "https://granola.ai/notes/\(id)",
      "calendar_event": {
        "event_title": "Quarterly yoghurt budget review",
        "invitees": [{"email": "cal@example.com"}],
        "organiser": "oat@granola.ai",
        "calendar_event_id": "evt_1",
        "scheduled_start_time": "2026-09-07T15:30:00Z",
        "scheduled_end_time": "2026-09-07T16:15:00Z"
      },
      "attendees": [{"name": "Oat Benson", "email": "oat@granola.ai"}, {"name": null, "email": "ana@example.com"}],
      "summary_markdown": "## Decisions\\n- Ship the strawberry tier.",
      "summary_text": "Decisions: ship the strawberry tier.",
      "transcript": [{"speaker": {"source": "microphone"}, "text": "inline copy", "start_time": "2026-09-07T15:30:05Z", "end_time": "2026-09-07T15:30:07Z"}]
    }
    """
}

private let transcriptPage1 = """
{
  "transcript": [
    {"speaker": {"source": "microphone", "attribution": "me", "name": "Oat"},
     "text": "Let's start with the budget.",
     "start_time": "2026-09-07T15:30:05Z", "end_time": "2026-09-07T15:30:08Z"},
    {"speaker": {"source": "speaker", "attribution": "them", "diarization_label": "Speaker 2"},
     "text": "Strawberry is over by twelve percent.",
     "start_time": "2026-09-07T15:30:09Z", "end_time": "2026-09-07T15:30:12Z"}
  ],
  "hasMore": true,
  "cursor": "transcript-page-2"
}
"""

private let transcriptPage2 = """
{"transcript": [{"speaker": {"source": "microphone", "attribution": "me", "name": "Oat"},
                 "text": "Then we ship the strawberry tier.",
                 "start_time": "2026-09-07T16:14:00Z", "end_time": "2026-09-07T16:14:03Z"}],
 "hasMore": false, "cursor": null}
"""

private func source(_ stub: Stub) -> GranolaSource {
    GranolaSource(
        http: ContextHTTP(session: stub.session, minimumSpacing: 0, maxRetries: 1, sleeper: { _ in }),
        timeZone: utc
    )
}

// MARK: - Tests

@Suite("GranolaSource")
struct GranolaSourceTests {
    @Test("a note becomes one meeting event with attendees, a summary and a transcript file")
    func mapsANote() async throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let stub = Stub([
            .json(listPage1), .json(listPage2),
            .json(noteBody()), .json(transcriptPage1), .json(transcriptPage2),
            .json(noteBody(id: "not_3bbbbbbbbbbbbb", updated: "2026-09-07T09:30:00Z")), .json("""
            {"transcript": [], "hasMore": false, "cursor": null}
            """),
        ])
        let db = try Database.inMemory()
        let store = ContextEventStore(db)

        let result = try await source(stub).sync(window: window, into: store, config: config)
        // The August note is filtered out by the window; the two September ones land.
        #expect(result.inserted == 2)

        let event = try #require(try store.find(source: .granola, externalId: "not_1d3tmYTlCICgjy"))
        #expect(event.title == "Quarterly yoghurt budget review")
        #expect(event.isMeeting)
        #expect(event.startAt == ContextDates.parseISO8601("2026-09-07T15:30:00Z"))
        #expect(event.endAt == ContextDates.parseISO8601("2026-09-07T16:15:00Z"))
        #expect(event.participants == ["Oat Benson <oat@granola.ai>", "ana@example.com"])
        #expect(event.bodyMd == "## Decisions\n- Ship the strawberry tier.")

        let path = try #require(event.bodyPath)
        let body = try ContextBody.read(path, config: config)
        #expect(body.contains("[15:30:05] Oat (source=microphone): Let's start with the budget."))
        #expect(body.contains("[15:30:09] Speaker 2 (source=speaker): Strawberry is over by twelve percent."))
        #expect(body.contains("[16:14:00] Oat (source=microphone): Then we ship the strawberry tier."),
                "the second transcript page was not fetched")
        #expect(body.contains("external_id: not_1d3tmYTlCICgjy"))
    }

    @Test("the stored note JSON never carries the transcript")
    func rawJsonExcludesTranscript() throws {
        let stub = Stub([])
        let note = try source(stub).parseNote(
            try JSONDecoder().decode(JSONValue.self, from: Data(noteBody().utf8))
        )
        let raw = try #require(GranolaSource.encode(note.raw))
        #expect(!raw.contains("inline copy"))
        #expect(raw.contains("summary_markdown"))
    }

    @Test("listing follows the cursor and asks for created_after")
    func pagination() async throws {
        let stub = Stub([.json(listPage1), .json(listPage2)])
        let notes = try await source(stub).listNotes(
            since: ContextDates.parseISO8601("2026-09-06T00:00:00Z")!, key: "grn_test"
        )
        #expect(notes.map(\.id) == ["not_1d3tmYTlCICgjy", "not_2aaaaaaaaaaaaa", "not_3bbbbbbbbbbbbb"])

        let first = try #require(stub.sent.first?.url?.absoluteString)
        // 12 h of grace before the window, so a meeting on the edge is not missed.
        #expect(first.contains("created_after=2026-09-05T12:00:00Z"))
        #expect(first.contains("page_size=30"))
        #expect(stub.sent[1].url?.absoluteString.contains("cursor=cursor-page-2") == true)
        #expect(stub.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer grn_test")
    }

    @Test("a second sync of an unchanged note costs no detail or transcript call")
    func incrementalSync() async throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let db = try Database.inMemory()
        let store = ContextEventStore(db)

        let firstStub = Stub([
            .json(listPage1), .json(listPage2),
            .json(noteBody()), .json(transcriptPage1), .json(transcriptPage2),
            .json(noteBody(id: "not_3bbbbbbbbbbbbb", updated: "2026-09-07T09:30:00Z")),
            .json("""
            {"transcript": [], "hasMore": false, "cursor": null}
            """),
        ])
        _ = try await source(firstStub).sync(window: window, into: store, config: config)

        // Same list, same updated_at: two list pages and nothing else.
        let secondStub = Stub([.json(listPage1), .json(listPage2)])
        let second = try await source(secondStub).sync(window: window, into: store, config: config)
        #expect(second.inserted == 0)
        #expect(second.updated == 0)
        #expect(second.skipped == 3)
        #expect(secondStub.sent.count == 2, "an unchanged note must not be fetched again")
    }

    @Test("a note whose updated_at moved is refetched and updated")
    func changedNote() async throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let db = try Database.inMemory()
        let store = ContextEventStore(db)

        // Bound to a local: `Stub` clears its registry entry in `deinit`, so a temporary would
        // be gone before the async sync makes its first request.
        let firstStub = Stub([
            .json(listPage1), .json(listPage2),
            .json(noteBody()), .json(transcriptPage1), .json(transcriptPage2),
            .json(noteBody(id: "not_3bbbbbbbbbbbbb", updated: "2026-09-07T09:30:00Z")),
            .json("""
            {"transcript": [], "hasMore": false, "cursor": null}
            """),
        ])
        _ = try await source(firstStub).sync(window: window, into: store, config: config)

        let movedList = listPage1.replacingOccurrences(
            of: "\"updated_at\": \"2026-09-07T16:45:00Z\"", with: "\"updated_at\": \"2026-09-07T18:00:00Z\""
        )
        let rewritten = noteBody(updated: "2026-09-07T18:00:00Z")
            .replacingOccurrences(of: "Ship the strawberry tier.", with: "Ship the vanilla tier.")
        let secondStub = Stub([
            .json(movedList), .json(listPage2),
            .json(rewritten), .json(transcriptPage1), .json(transcriptPage2),
        ])
        let second = try await source(secondStub).sync(window: window, into: store, config: config)

        #expect(second.updated == 1)
        #expect(second.skipped == 2)
        let event = try #require(try store.find(source: .granola, externalId: "not_1d3tmYTlCICgjy"))
        #expect(event.bodyMd?.contains("vanilla") == true)
    }

    @Test("a 401 says what the user has to do about it")
    func unauthorized() async throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let stub = Stub([.json("{\"error\":\"unauthorized\"}", status: 401)])
        let db = try Database.inMemory()

        do {
            _ = try await source(stub).sync(window: window, into: ContextEventStore(db), config: config)
            Issue.record("expected a ContextSyncError")
        } catch let error as ContextSyncError {
            #expect(error.description.contains(GranolaSource.authHint))
            // The provider's own words come through too — "HTTP 401" alone is not a diagnosis.
            #expect(error.description.contains("401"))
        }
    }

    @Test("a 429 is retried after Retry-After and then succeeds")
    func rateLimited() async throws {
        let slept = LockedBox<[TimeInterval]>([])
        let stub = Stub([
            .json("{}", status: 429, headers: ["Retry-After": "3"]),
            .json(listPage2),
        ])
        let source = GranolaSource(
            http: ContextHTTP(
                session: stub.session, minimumSpacing: 0, maxRetries: 2,
                sleeper: { seconds in slept.withLock { $0.append(seconds) } }
            ),
            timeZone: utc
        )
        let notes = try await source.listNotes(since: window.start, key: "grn_test")
        #expect(notes.map(\.id) == ["not_3bbbbbbbbbbbbb"])
        #expect(slept.withLock { $0 } == [3])
    }

    @Test("a transcript that fails leaves the meeting stored, with a warning")
    func transcriptFailureIsAWarning() async throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let stub = Stub([
            .json("""
            {"notes": [{"id": "not_1d3tmYTlCICgjy", "updated_at": "2026-09-07T16:45:00Z"}],
             "hasMore": false, "cursor": null}
            """),
            .json(noteBody()),
            .json("{\"error\":\"boom\"}", status: 500),
            .json("{\"error\":\"boom\"}", status: 500),
        ])
        let db = try Database.inMemory()
        let store = ContextEventStore(db)

        let result = try await source(stub).sync(window: window, into: store, config: config)
        #expect(result.inserted == 1)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("incomplete"))
        #expect(try store.find(source: .granola, externalId: "not_1d3tmYTlCICgjy") != nil)
    }

    @Test("isConfigured needs the key")
    func configuration() {
        let stub = Stub([])
        var config = temporaryConfig()
        #expect(source(stub).isConfigured(config))

        config.granolaAPIKey = nil
        #expect(!source(stub).isConfigured(config))
    }

    @Test("makeEvent keeps the next steps from the full summary while body_md stays cut (#316)")
    func outcomesFromTheFullSummary() throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let filler = (1...40).map { "- Point \($0): the team walked through the numbers once more." }
        let summary = (["# Review"] + filler + ["## Next steps", "- Oat sends the deck", "- Ana books the room"])
            .joined(separator: "\n")
        var json = try JSONDecoder().decode(JSONValue.self, from: Data(noteBody().utf8))
        if case .object(var object) = json {
            object["summary_markdown"] = .string(summary)
            json = .object(object)
        }

        let granola = source(Stub([]))
        let note = try granola.parseNote(json)
        let event = try granola.makeEvent(note, transcript: [], config: config, youName: "Oat Benson")

        #expect((event.bodyMd ?? "").count <= ContextBody.inlineLimit)
        #expect(!(event.bodyMd ?? "").contains("Oat sends the deck"))
        let outcomes = try #require(event.outcomes)
        #expect(outcomes.nextSteps.map(\.text) == ["Oat sends the deck", "Ana books the room"])
        #expect(outcomes.nextSteps.map(\.namesYou) == [true, false])
    }

    @Test("a sync fills the outcomes of a stored meeting the list no longer returns (#316)")
    func syncRefreshesStoredOutcomes() async throws {
        let config = temporaryConfig()
        defer { try? FileManager.default.removeItem(at: config.dataDir) }
        let db = try Database.inMemory()
        let store = ContextEventStore(db)
        let raw = GranolaSource.encode(.object([
            "id": "not_old", "owner": .object(["name": "Oat Benson"]),
            "summary_markdown": "## Next steps\n- Oat sends the deck",
        ]))
        try store.upsert(ContextEvent(
            source: .granola, externalId: "not_old", startAt: window.start, title: "Old review",
            isMeeting: true, rawJson: raw, outcomesJson: nil
        ))

        let stub = Stub([.json(#"{"notes": [], "hasMore": false, "cursor": null}"#)])
        _ = try await source(stub).sync(window: window, into: store, config: config)

        let stored = try #require(try store.find(source: .granola, externalId: "not_old"))
        #expect(stored.outcomes?.nextSteps.map(\.text) == ["Oat sends the deck"])
        #expect(stored.outcomes?.nextSteps.map(\.namesYou) == [true])
    }
}
