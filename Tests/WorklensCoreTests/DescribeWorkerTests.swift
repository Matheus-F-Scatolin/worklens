import Foundation
import GRDB
import Testing
@testable import WorklensCore

// MARK: - Doubles

/// Answers from a canned list and remembers what it was asked. `Stub…` rather than
/// `Fake…` since #121: `WorklensCore.FakeDescriber` is a real describer that ships. Named `Stub…` because
/// `WorklensCore.StubDescriber` (#121) is a real, shipped describer and this is not.
final class StubDescriber: VisionDescriber, @unchecked Sendable {
    /// The same name the real client writes, so ledger rows read as production's do.
    let provider = GeminiClient.provider
    private let lock = NSLock()
    private var replies: [Result<DescribeResponse, Error>]
    private var seen: [DescribeRequest] = []

    init(replies: [Result<DescribeResponse, Error>]) {
        self.replies = replies
    }

    convenience init(json: String..., usage: LLMUsage = LLMUsage(promptTokens: 900, outputTokens: 100)) {
        self.init(replies: json.map { text in
            .success(DescribeResponse(
                json: text, usage: usage, costUSD: 0.0005, latencyMs: 1200,
                model: "gemini-3.5-flash-lite"
            ))
        })
    }

    /// One canned success, for a list that mixes successes and failures.
    static func ok(_ json: String) -> Result<DescribeResponse, Error> {
        .success(DescribeResponse(
            json: json, usage: LLMUsage(promptTokens: 900, outputTokens: 100),
            costUSD: 0.0005, latencyMs: 1200, model: "gemini-3.5-flash-lite"
        ))
    }

    var requests: [DescribeRequest] { lock.withLock { seen } }
    var callCount: Int { lock.withLock { seen.count } }

    func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        let reply: Result<DescribeResponse, Error>? = lock.withLock {
            seen.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        switch reply {
        case let .success(response): return response
        case let .failure(error): throw error
        case .none: throw LLMError.network("the fake ran out of replies")
        }
    }
}

struct OverBudgetGate: CostGate {
    var isOverBudget: Bool { get async { true } }
}

// MARK: - Fixtures

private let noon = Date(timeIntervalSince1970: 1_757_260_800)   // 2025-09-07T16:00:00Z

private func goodJSON(
    app: String = "terminal",
    task: String = "coding_with_agent",
    sensitive: Bool = false
) -> String {
    """
    {"app_key":"\(app)","task_key":"\(task)",
     "summary":"Editing the describe worker in a terminal.","document":"DescribeWorker.swift",
     "people":[],"project_hint":"worklens","is_meeting":false,
     "is_sensitive":\(sensitive),"confidence":0.9}
    """
}

/// A worker over an in-memory database, a temp DATA_DIR and a fake describer.
private struct Harness {
    let dataDir: URL
    let config: Config
    let db: WorklensCore.Database
    let taxonomy: TaxonomyStore
    let describer: StubDescriber
    let worker: DescribeWorker
    let captures: CaptureStore
    let descriptions: DescriptionStore
    let axSnapshots: AXSnapshotStore
    let nudgedDays: LockedBox<[String]>
    /// #125: every health change the worker announced, in order.
    let healths: LockedBox<[DescribeHealth]>

    init(
        describer: StubDescriber,
        cost: any CostGate = AlwaysAllowCostGate(),
        deleteSensitive: Bool = true,
        deleteAfterDescribe: Bool = false,
        batteryMode: BatteryCaptureMode = .slow
    ) throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-describe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        var config = Config.defaults()
        config.dataDir = dataDir
        config.deleteSensitiveScreenshots = deleteSensitive
        config.deleteScreenshotsAfterDescribe = deleteAfterDescribe
        config.captureOnBattery = batteryMode
        self.config = config

        db = try Database.inMemory()
        taxonomy = try TaxonomyStore(dataDir: dataDir)
        self.describer = describer
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        axSnapshots = AXSnapshotStore(db)

        let nudged = LockedBox<[String]>([])
        nudgedDays = nudged
        let health = LockedBox<[DescribeHealth]>([])
        healths = health
        worker = DescribeWorker(
            config: config, db: db, taxonomy: taxonomy, describer: describer, cost: cost,
            timeZone: TimeZone(identifier: "UTC")!,
            now: { noon },
            onDescribed: { day in nudged.withLock { $0.append(day) } },
            healthHandler: { state in health.withLock { $0.append(state) } }
        )
    }

    /// Inserts a capture and writes a placeholder JPEG for it.
    @discardableResult
    func addCapture(
        at: Date = noon,
        status: DescribeStatus = .pending,
        bundleID: String? = "com.mitchellh.ghostty",
        windowTitle: String? = "worklens",
        browserURL: String? = nil,
        withImage: Bool = true
    ) throws -> Capture {
        let id = Identifiers.new()
        var relative: String?
        if withImage {
            let path = ScreenshotPaths.relativePath(for: at, id: id, timeZone: TimeZone(identifier: "UTC")!)
            let url = dataDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)
            relative = path
        }
        let capture = Capture(
            id: id, capturedAt: at, imagePath: relative,
            appBundleId: bundleID, appName: "Ghostty", windowTitle: windowTitle,
            browserUrl: browserURL,
            describeStatus: status
        )
        try captures.insert(capture)
        return capture
    }

    /// A stored window outline for one frame — what #53's retention rules act on.
    @discardableResult
    func addAXSnapshot(
        _ capture: Capture,
        text: String = "[AXStaticText] worklens — README.md",
        coverage: AXSnapshot.Coverage = .full
    ) throws -> AXSnapshotRecord {
        let record = AXSnapshotRecord(
            captureId: capture.id, coverage: coverage, nodeCount: 40, textChars: text.count,
            elapsedMs: 51, textHash: AXOutline.hash(text), text: text,
            redactionsJson: nil, createdAt: capture.capturedAt
        )
        try axSnapshots.insert(record)
        return record
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dataDir)
    }
}

// MARK: - Tests

@Suite("DescribeWorker happy path")
struct DescribeWorkerHappyPathTests {
    @Test("a pending frame becomes a described row, a ledger row and a timeline nudge")
    func describesPendingFrame() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        guard case let .described(_, cost) = outcome else {
            Issue.record("expected .described, got \(outcome)")
            return
        }
        #expect(cost == 0.0005)

        let stored = try #require(try harness.descriptions.fetch(captureId: capture.id))
        #expect(stored.appKey == "terminal")
        #expect(stored.taskKey == "coding_with_agent")
        #expect(stored.isInherited == false)
        #expect(stored.promptTokens == 900)
        #expect(stored.costUsd == 0.0005)
        #expect(stored.provider == "gemini")
        #expect(stored.detailsJson?.contains("DescribeWorker.swift") == true)
        #expect(stored.rawJson?.contains(#""prompt_version":"\#(DescribePrompt.version)""#) == true)

        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .described)
        #expect(try LLMCallStore(harness.db).spend(from: noon.addingTimeInterval(-60), to: noon.addingTimeInterval(60)) == 0.0005)

        // The image survives by default, as evidence.
        #expect(FileManager.default.fileExists(
            atPath: harness.dataDir.appendingPathComponent(capture.imagePath!).path
        ))
    }

    @Test("the prompt carries the run this frame is in, with repeated summaries collapsed (#65)")
    func prompCarriesRecentContext() async throws {
        let harness = try Harness(describer: StubDescriber(
            json: goodJSON(), goodJSON(), goodJSON(), goodJSON(), goodJSON()
        ))
        defer { harness.cleanUp() }

        for minute in 0..<5 {
            let capture = try harness.addCapture(at: noon.addingTimeInterval(Double(minute) * 60))
            _ = try await harness.worker.processOne(captureId: capture.id)
        }

        let last = try #require(harness.describer.requests.last)
        let contextLines = last.userPrompt
            .split(separator: "\n")
            .filter { $0.hasPrefix("- 16:") }
        // Four earlier frames, all in the same app and all saying the same thing: the header
        // counts them, one line quotes the summary, and "… 3 more frames" accounts for the rest.
        #expect(last.userPrompt.contains("In this app since 16:00 (4 frames):"))
        #expect(contextLines.count == 1)
        #expect(last.userPrompt.contains("… 3 more frames"))
        // Nothing came before this app, so there is no switch line to draw.
        #expect(!last.userPrompt.contains("Before this app:"))
    }

    @Test("the schema enumerates only the resolved app's tasks plus the universal ones")
    func schemaIsScopedToTheApp() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        _ = try await harness.worker.processOne(captureId: capture.id)

        let schema = try #require(harness.describer.requests.first?.schema)
        let taskEnum = try #require(schema["properties"]?["task_key"]?["enum"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(taskEnum == ["running_commands", "coding_with_agent", "other", "switching"])

        let appEnum = try #require(schema["properties"]?["app_key"]?["enum"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(appEnum == ["terminal", "other"])
    }
}

/// #49: the last point before a title or a URL leaves the machine.
@Suite("DescribeWorker redaction")
struct DescribeWorkerRedactionTests {
    @Test("the prompt gets placeholders and details_json gets the counts")
    func redactsTitleAndURL() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture(
            windowTitle: "Checkout — 4111 1111 1111 1111 — senha=hunter2 — api_key=sk-live-9f8a7b6c5d4e3f2a1b",
            browserURL: "https://alice:hunter2@pay.example.com/orders?api_key=sk-live-9f8a7b6c5d4e3f2a1b"
        )

        _ = try await harness.worker.processOne(captureId: capture.id)

        let prompt = try #require(harness.describer.requests.first?.userPrompt)
        #expect(prompt.contains("[CARD_1]"))
        #expect(prompt.contains("senha=[PASSWORD]"))
        #expect(prompt.contains("api_key=[SECRET_1]"))
        // The userinfo and the query go whole.
        #expect(prompt.contains("https://pay.example.com/orders"))
        #expect(!prompt.contains("alice"))
        #expect(!prompt.contains("4111"))
        #expect(!prompt.contains("hunter2"))
        #expect(!prompt.contains("sk-live"))

        // The title was redacted when it was stored, and the placeholders it holds still count.
        let stored = try #require(try harness.descriptions.fetch(captureId: capture.id))
        let details = try #require(stored.detailsJson)
        #expect(details.contains(#""redactions""#))
        #expect(details.contains(#""card":1"#))
        #expect(details.contains(#""password":1"#))
        #expect(details.contains(#""secret":1"#))

        // The row itself never held the card or the password (#2): a title is stored, indexed
        // and handed to MCP clients, so it is redacted on the way in.
        let row = try #require(try harness.captures.fetch(id: capture.id))
        #expect(row.windowTitle == "Checkout — [CARD_1] — senha=[PASSWORD] — api_key=[SECRET_1]")
        #expect(row.browserUrl == "https://pay.example.com/orders")
    }

    @Test("a synced meeting's title is redacted before it enters the prompt")
    func redactsMeetingTitle() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        try ContextEventStore(harness.db).upsert(ContextEvent(
            source: .calendar, externalId: "evt-1",
            startAt: noon.addingTimeInterval(-600), endAt: noon.addingTimeInterval(600),
            title: "Rotate keys — password=hunter2 AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY",
            isMeeting: true, syncedAt: noon
        ))
        let capture = Capture(
            capturedAt: noon, appBundleId: "us.zoom.xos", appName: "zoom.us",
            windowTitle: "Zoom Meeting", isMeeting: true, describeStatus: .pending
        )
        try harness.captures.insert(capture)
        try harness.addAXSnapshot(capture, text: "[AXStaticText] Rotate keys")

        _ = try await harness.worker.processOne(captureId: capture.id)

        let prompt = try #require(harness.describer.requests.first?.userPrompt)
        #expect(prompt.contains("Rotate keys — password=[PASSWORD] [SECRET_1]"))
        #expect(!prompt.contains("hunter2"))
        #expect(!prompt.contains("AIza"))
        let details = try #require(try harness.descriptions.fetch(captureId: capture.id)?.detailsJson)
        #expect(details.contains(#""password":1"#))
        #expect(details.contains(#""secret":1"#))
    }

    @Test("a clean frame's details_json gains no redactions key")
    func cleanFrame() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        _ = try await harness.worker.processOne(captureId: capture.id)

        let stored = try #require(try harness.descriptions.fetch(captureId: capture.id))
        #expect(stored.detailsJson?.contains("redactions") == false)
    }
}

@Suite("DescribeWorker validation")
struct DescribeWorkerValidationTests {
    @Test("a task key outside the enum entirely is stored as other")
    func unknownTaskBecomesOther() async throws {
        let harness = try Harness(describer: StubDescriber(
            json: goodJSON(task: "reviewing_pull_request")
        ))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        _ = try await harness.worker.processOne(captureId: capture.id)

        #expect(try harness.descriptions.fetch(captureId: capture.id)?.taskKey == "other")
    }

    @Test("a task key from another app is clamped to other")
    func foreignTaskIsClamped() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON(task: "huddle")))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        _ = try await harness.worker.processOne(captureId: capture.id)

        #expect(try harness.descriptions.fetch(captureId: capture.id)?.taskKey == "other")
    }

    @Test("an app key outside the taxonomy falls back to the resolved app")
    func foreignAppIsClamped() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON(app: "spreadsheet_thing")))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        _ = try await harness.worker.processOne(captureId: capture.id)
        #expect(try harness.descriptions.fetch(captureId: capture.id)?.appKey == "terminal")
    }
}

@Suite("DescribeWorker failure handling")
struct DescribeWorkerFailureTests {
    @Test("invalid JSON is retried once with a repair note, then fails the frame")
    func invalidJSONRetriesOnce() async throws {
        let harness = try Harness(describer: StubDescriber(json: "not json", "still not json"))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        guard case .retryLater = outcome else {
            Issue.record("expected .retryLater, got \(outcome)")
            return
        }
        #expect(harness.describer.callCount == 2)
        #expect(harness.describer.requests[1].userPrompt.contains(DescribePrompt.repairNote))
        #expect(harness.describer.requests[0].userPrompt.contains(DescribePrompt.repairNote) == false)

        let reloaded = try #require(try harness.captures.fetch(id: capture.id))
        #expect(reloaded.describeAttempts == 1)
        #expect(reloaded.describeStatus == .pending)
        #expect(try harness.descriptions.fetch(captureId: capture.id) == nil)
    }

    @Test("the repair attempt is kept when it parses")
    func repairSucceeds() async throws {
        let harness = try Harness(describer: StubDescriber(json: "{oops", goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        guard case .described = outcome else {
            Issue.record("expected .described, got \(outcome)")
            return
        }
        #expect(harness.describer.callCount == 2)
    }

    @Test("three failures mark the frame failed, and every attempt is in the ledger")
    func givesUpAfterThreeAttempts() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.serverError(503)), count: 6)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        for _ in 0..<3 { _ = try await harness.worker.processOne(captureId: capture.id) }

        let reloaded = try #require(try harness.captures.fetch(id: capture.id))
        #expect(reloaded.describeStatus == .failed)
        #expect(reloaded.describeAttempts == 3)

        let calls = try await harness.db.writer.read { db in
            try LLMCall.fetchAll(db)
        }
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.httpStatus == 503 && $0.costUsd == 0 })
        #expect(calls.allSatisfy { ($0.error ?? "").contains("503") })
    }

    @Test("a failure holds the whole queue with an exponential backoff")
    func failureSetsBackoff() async throws {
        let harness = try Harness(describer: StubDescriber(replies: [.failure(LLMError.rateLimited)]))
        defer { harness.cleanUp() }
        try harness.addCapture()

        _ = try await harness.worker.runCycle()
        let until = try #require(try AppStateStore(harness.db).getDate(DescribeWorker.backoffKey))
        #expect(until > noon)

        // The next cycle is a no-op until the hold expires.
        let outcomes = try await harness.worker.runCycle()
        #expect(outcomes.isEmpty)
        #expect(harness.describer.callCount == 1)
    }

    @Test("a call cancelled by shutdown leaves the frame pending with no attempt, backoff or ledger row")
    func cancellationLeavesFrameUntouched() async throws {
        let harness = try Harness(describer: StubDescriber(replies: [.failure(CancellationError())]))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        if case .retryLater = outcome {} else { Issue.record("expected .retryLater, got \(outcome)") }

        let reloaded = try #require(try harness.captures.fetch(id: capture.id))
        #expect(reloaded.describeStatus == .pending)
        #expect(reloaded.describeAttempts == 0)
        #expect(try AppStateStore(harness.db).getDate(DescribeWorker.backoffKey) == nil)
        #expect(try LLMCallStore(harness.db).summary(days: 1).isEmpty)
    }

    @Test("an unreachable provider never fails a frame, however long the outage lasts")
    func offlineNeverGivesUpOnAFrame() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.network("offline")), count: 6)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        for _ in 0..<6 {
            let outcome = try await harness.worker.processOne(captureId: capture.id)
            if case .retryLater = outcome {} else { Issue.record("expected .retryLater, got \(outcome)") }
        }

        // Past `maxAttempts` twice over, and still describable once the network is back.
        let reloaded = try #require(try harness.captures.fetch(id: capture.id))
        #expect(reloaded.describeStatus == .pending)
        #expect(reloaded.describeAttempts == 0)
    }

    @Test("an outage holds the queue, doubling to the cap, and writes one ledger row")
    func offlineHoldsTheQueueAndLogsOnce() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.network("offline")), count: 8)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        let appState = AppStateStore(harness.db)

        var holds: [TimeInterval] = []
        for _ in 0..<8 {
            _ = try await harness.worker.processOne(captureId: capture.id)
            let until = try #require(try appState.getDate(DescribeWorker.backoffKey))
            holds.append(until.timeIntervalSince(noon))
        }
        #expect(Array(holds.prefix(3)) == [15, 30, 60])
        #expect(holds.last == DescribeWorker.maxOutageHold)

        // One diagnostic row for the whole outage, not one per probe.
        let calls = try await harness.db.writer.read { db in try LLMCall.fetchAll(db) }
        #expect(calls.count == 1)
        #expect(calls.first?.costUsd == 0)
        #expect((calls.first?.error ?? "").contains("network"))
    }

    @Test("a call that gets through resets the outage hold")
    func reconnectingResetsTheHold() async throws {
        let harness = try Harness(describer: StubDescriber(replies: [
            .failure(LLMError.network("offline")),
            StubDescriber.ok(goodJSON()),
            .failure(LLMError.network("offline")),
        ]))
        defer { harness.cleanUp() }
        let first = try harness.addCapture()
        let second = try harness.addCapture(at: noon.addingTimeInterval(60))
        let appState = AppStateStore(harness.db)

        _ = try await harness.worker.processOne(captureId: first.id)
        #expect(try appState.getDate(DescribeWorker.backoffKey)?.timeIntervalSince(noon) == 15)

        _ = try await harness.worker.processOne(captureId: first.id)
        _ = try await harness.worker.processOne(captureId: second.id)
        // 15 s again, not 30: the successful call in between ended the outage.
        #expect(try appState.getDate(DescribeWorker.backoffKey)?.timeIntervalSince(noon) == 15)
    }

    @Test("a provider that answers with a 5xx still spends the frame's attempts")
    func serverErrorsStillCount() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.serverError(503)), count: 3)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        for _ in 0..<3 { _ = try await harness.worker.processOne(captureId: capture.id) }
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .failed)
    }

    @Test("a frame whose image is gone fails immediately without a call")
    func missingImageFails() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture(withImage: false)

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        guard case let .failed(message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("image"))
        #expect(harness.describer.callCount == 0)
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .failed)
    }
}

// MARK: - Describing from the window text (#54)

@Suite("DescribeWorker describes from text")
struct DescribeWorkerTextTests {
    @Test("a fully covered frame with no JPEG is described from its outline alone")
    func fullFrameWithoutAnImage() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture(withImage: false)
        let outline = "[AXWindow] worklens\n  [AXStaticText] DescribeWorker.swift"
        try harness.addAXSnapshot(capture, text: outline, coverage: .full)

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        guard case .described = outcome else {
            Issue.record("expected .described, got \(outcome)")
            return
        }
        let request = try #require(harness.describer.requests.first)
        // The whole point: no pixels went out, and the outline did.
        #expect(request.imageJPEG == nil)
        #expect(request.userPrompt.contains(outline))
        #expect(request.userPrompt.contains("full coverage"))
        #expect(request.userPrompt.contains("from the window text above"))
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .described)
    }

    @Test("a partly covered frame sends the outline and the picture")
    func partialFrameSendsBoth() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        try harness.addAXSnapshot(capture, text: "[AXStaticText] a fragment", coverage: .partial)

        _ = try await harness.worker.processOne(captureId: capture.id)
        let request = try #require(harness.describer.requests.first)
        #expect(request.imageJPEG != nil)
        #expect(request.userPrompt.contains("partial coverage"))
        #expect(request.userPrompt.contains("from the window text and the screenshot"))
    }

    @Test("a frame with a picture and no outline is d1's image-only call")
    func noOutlineIsImageOnly() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        _ = try await harness.worker.processOne(captureId: capture.id)
        let request = try #require(harness.describer.requests.first)
        #expect(request.imageJPEG != nil)
        #expect(!request.userPrompt.contains("Focused window text"))
        #expect(request.userPrompt.contains("Describe the screenshot."))
    }

    @Test("a full frame whose outline retention already dropped falls back to the picture")
    func droppedTextFallsBackToTheImage() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        // `.full`, but the text is gone (DELETE_SCREENSHOTS_AFTER_DESCRIBE on an earlier pass).
        try harness.addAXSnapshot(capture, text: "[AXStaticText] gone", coverage: .full)
        try harness.axSnapshots.clearText(captureId: capture.id)

        _ = try await harness.worker.processOne(captureId: capture.id)
        let request = try #require(harness.describer.requests.first)
        #expect(request.imageJPEG != nil)
        #expect(!request.userPrompt.contains("Focused window text"))
    }

    @Test("neither an outline nor a file is the only unfixable frame")
    func nothingAtAllFails() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture(withImage: false)

        let outcome = try await harness.worker.processOne(captureId: capture.id)
        guard case let .failed(message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("no window text"))
        #expect(harness.describer.callCount == 0)
    }

    @Test("the one repair keeps the text-only mode instead of quietly finding the picture")
    func repairKeepsTextOnly() async throws {
        let harness = try Harness(describer: StubDescriber(replies: [
            StubDescriber.ok("not json at all"),
            StubDescriber.ok(goodJSON()),
        ]))
        defer { harness.cleanUp() }
        // A frame that has both artifacts but is fully covered: the repair must not reach for
        // the JPEG just because one exists.
        let capture = try harness.addCapture()
        try harness.addAXSnapshot(capture, text: "[AXStaticText] worklens", coverage: .full)

        _ = try await harness.worker.processOne(captureId: capture.id)
        #expect(harness.describer.requests.count == 2)
        #expect(harness.describer.requests.allSatisfy { $0.imageJPEG == nil })
        #expect(harness.describer.requests[1].userPrompt.contains(DescribePrompt.repairNote))
        #expect(harness.describer.requests[1].userPrompt.contains("full coverage"))
    }
}

@Suite("DescribeWorker privacy and budget")
struct DescribeWorkerPrivacyTests {
    @Test("a sensitive frame loses its image but keeps its text")
    func sensitiveImageDeleted() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON(sensitive: true)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        let path = harness.dataDir.appendingPathComponent(capture.imagePath!).path

        _ = try await harness.worker.processOne(captureId: capture.id)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try harness.captures.fetch(id: capture.id)?.imagePath == nil)
        #expect(try harness.descriptions.fetch(captureId: capture.id)?.isSensitive == true)
        #expect(try harness.descriptions.fetch(captureId: capture.id)?.summaryMd.isEmpty == false)
    }

    @Test("DELETE_SCREENSHOTS_AFTER_DESCRIBE drops every image")
    func deleteAfterDescribe() async throws {
        let harness = try Harness(
            describer: StubDescriber(json: goodJSON()), deleteAfterDescribe: true
        )
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        let path = harness.dataDir.appendingPathComponent(capture.imagePath!).path

        _ = try await harness.worker.processOne(captureId: capture.id)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("DELETE_SCREENSHOTS_AFTER_DESCRIBE drops the window text too, keeping its hash")
    func deleteAfterDescribeDropsWindowText() async throws {
        let harness = try Harness(
            describer: StubDescriber(json: goodJSON()), deleteAfterDescribe: true
        )
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        let stored = try harness.addAXSnapshot(capture)

        _ = try await harness.worker.processOne(captureId: capture.id)

        let after = try #require(try harness.axSnapshots.fetch(captureId: capture.id))
        #expect(after.text == nil)
        // The hash, the counts and the coverage are what the next tick's decision and the day's
        // coverage line are made of; only the text is evidence.
        #expect(after.textHash == stored.textHash)
        #expect(after.textChars == stored.textChars)
        #expect(after.coverage == .full)
    }

    @Test("a sensitive frame loses its window text as well as its image")
    func sensitiveDropsWindowText() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON(sensitive: true)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        try harness.addAXSnapshot(capture, text: "[AXTextField] account 12345 — balance")

        _ = try await harness.worker.processOne(captureId: capture.id)

        #expect(try harness.axSnapshots.fetch(captureId: capture.id)?.text == nil)
        #expect(try harness.captures.fetch(id: capture.id)?.imagePath == nil)
    }

    @Test("with both flags off, a described frame keeps its window text")
    func windowTextKeptByDefault() async throws {
        let harness = try Harness(
            describer: StubDescriber(json: goodJSON()), deleteSensitive: false
        )
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        try harness.addAXSnapshot(capture)

        _ = try await harness.worker.processOne(captureId: capture.id)
        #expect(try harness.axSnapshots.fetch(captureId: capture.id)?.text != nil)
    }

    @Test("DELETE_SENSITIVE_SCREENSHOTS=false keeps a sensitive frame's image")
    func sensitiveKeptWhenConfigured() async throws {
        let harness = try Harness(
            describer: StubDescriber(json: goodJSON(sensitive: true)), deleteSensitive: false
        )
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()
        let path = harness.dataDir.appendingPathComponent(capture.imagePath!).path

        _ = try await harness.worker.processOne(captureId: capture.id)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("over budget, nothing is sent and the frames stay pending")
    func overBudgetSendsNothing() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()), cost: OverBudgetGate())
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        let outcomes = try await harness.worker.runCycle()
        #expect(outcomes == [.overBudget])
        #expect(harness.describer.callCount == 0)
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .pending)
        let state = await harness.worker.state
        #expect(state == .budgetExceeded)
    }
}

@Suite("DescribeWorker inheritance")
struct DescribeWorkerInheritanceTests {
    @Test("an inherited frame copies the previous description for free")
    func inheritsPreviousDescription() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }

        let first = try harness.addCapture(at: noon)
        _ = try await harness.worker.processOne(captureId: first.id)
        let second = try harness.addCapture(at: noon.addingTimeInterval(60), status: .inherited)

        let outcomes = try await harness.worker.fillInherited()
        #expect(outcomes.count == 1)

        let copied = try #require(try harness.descriptions.fetch(captureId: second.id))
        let original = try #require(try harness.descriptions.fetch(captureId: first.id))
        #expect(copied.isInherited)
        #expect(copied.summaryMd == original.summaryMd)
        #expect(copied.appKey == original.appKey)
        #expect(copied.costUsd == 0)
        #expect(copied.promptTokens == 0)
        #expect(harness.describer.callCount == 1)
    }

    @Test("a frame with nothing before it is marked failed: an unchanged row has no image to describe")
    func orphanWithNothingBeforeItFails() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }
        let orphan = try harness.addCapture(at: noon, status: .inherited, withImage: false)

        let outcomes = try await harness.worker.fillInherited()
        #expect(outcomes.count == 1)
        if case .failed = outcomes[0] {} else { Issue.record("expected .failed, got \(outcomes[0])") }
        #expect(try harness.captures.fetch(id: orphan.id)?.describeStatus == .failed)
        #expect(try harness.descriptions.fetch(captureId: orphan.id) == nil)

        // …and a later cycle does not spend a call on it.
        _ = try await harness.worker.runCycle()
        #expect(harness.describer.callCount == 0)
    }

    @Test("a frame inherits across midnight from the frame right before it")
    func inheritsAcrossMidnight() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }

        // 23:59 the previous local day (the harness runs in UTC), then 00:00.
        let dayStart = DayBoundaries.range(day: "2025-09-07", timeZone: TimeZone(identifier: "UTC")!)!.start
        let lateLastNight = try harness.addCapture(at: dayStart.addingTimeInterval(-60))
        _ = try await harness.worker.processOne(captureId: lateLastNight.id)
        let firstToday = try harness.addCapture(at: dayStart, status: .inherited, withImage: false)

        _ = try await harness.worker.fillInherited()
        let copied = try #require(try harness.descriptions.fetch(captureId: firstToday.id))
        #expect(copied.isInherited)
        #expect(copied.summaryMd == (try harness.descriptions.fetch(captureId: lateLastNight.id))?.summaryMd)
        #expect(try harness.captures.fetch(id: firstToday.id)?.describeStatus == .inherited)
    }

    @Test("an inherited frame whose predecessor is still pending waits instead of copying an older frame")
    func waitsForPendingPredecessor() async throws {
        // The frame before the pending one showed a different app; copying it would mislabel.
        let harness = try Harness(describer: StubDescriber(
            json: goodJSON(app: "terminal", task: "running_commands"), goodJSON(app: "terminal", task: "coding_with_agent")
        ))
        defer { harness.cleanUp() }

        let older = try harness.addCapture(at: noon.addingTimeInterval(-120))
        _ = try await harness.worker.processOne(captureId: older.id)
        let pending = try harness.addCapture(at: noon.addingTimeInterval(-60))
        let follower = try harness.addCapture(at: noon, status: .inherited, withImage: false)

        // Filling alone must not touch the follower: its predecessor has no description yet.
        let outcomes = try await harness.worker.fillInherited()
        #expect(outcomes.isEmpty)
        #expect(try harness.captures.fetch(id: follower.id)?.describeStatus == .inherited)
        #expect(try harness.descriptions.fetch(captureId: follower.id) == nil)

        // A full cycle describes the predecessor first, then the follower copies *it*.
        _ = try await harness.worker.runCycle()
        let copied = try #require(try harness.descriptions.fetch(captureId: follower.id))
        let source = try #require(try harness.descriptions.fetch(captureId: pending.id))
        #expect(copied.isInherited)
        #expect(copied.taskKey == source.taskKey)
        #expect(copied.taskKey == "coding_with_agent")
        #expect(harness.describer.callCount == 2)
    }

    @Test("a cycle describes pending frames before filling, so a follower copies its real predecessor")
    func cycleDescribesPendingFirst() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON(), goodJSON()))
        defer { harness.cleanUp() }

        let first = try harness.addCapture(at: noon)
        let follower = try harness.addCapture(at: noon.addingTimeInterval(60), status: .inherited, withImage: false)
        try harness.addCapture(at: noon.addingTimeInterval(120))

        let outcomes = try await harness.worker.runCycle()
        #expect(outcomes.count == 3)
        if case .described = outcomes[0] {} else { Issue.record("pending frames come first") }
        if case .described = outcomes[1] {} else { Issue.record("both pending frames are described") }
        if case .inherited = outcomes[2] {} else { Issue.record("then the inherited copy") }
        #expect(harness.describer.callCount == 2)
        let copied = try #require(try harness.descriptions.fetch(captureId: follower.id))
        #expect(copied.summaryMd == (try harness.descriptions.fetch(captureId: first.id))?.summaryMd)
    }

    @Test("an unchanged frame after a failed frame fails too: there is nothing truthful to copy")
    func followerOfFailedFrameFails() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }

        let failed = try harness.addCapture(at: noon, status: .failed)
        let follower = try harness.addCapture(at: noon.addingTimeInterval(60), status: .inherited, withImage: false)

        _ = try await harness.worker.fillInherited()
        #expect(try harness.captures.fetch(id: follower.id)?.describeStatus == .failed)
        #expect(try harness.descriptions.fetch(captureId: follower.id) == nil)
        #expect(try harness.descriptions.fetch(captureId: failed.id) == nil)
        #expect(harness.describer.callCount == 0)
    }

    @Test("idle and blocked rows are skipped over when looking for the predecessor")
    func skipRowsAreNotPredecessors() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()))
        defer { harness.cleanUp() }

        let real = try harness.addCapture(at: noon)
        _ = try await harness.worker.processOne(captureId: real.id)
        // A budget row would count; an idle row and a redacted row must not.
        try harness.captures.insert(Capture(
            capturedAt: noon.addingTimeInterval(30), isIdle: true, skipReason: .idle, describeStatus: .skipped
        ))
        try harness.captures.insert(Capture(
            capturedAt: noon.addingTimeInterval(45), appBundleId: "com.1password.1password",
            isRedacted: true, skipReason: .blocked, describeStatus: .skipped
        ))
        let follower = try harness.addCapture(at: noon.addingTimeInterval(60), status: .inherited, withImage: false)

        _ = try await harness.worker.fillInherited()
        let copied = try #require(try harness.descriptions.fetch(captureId: follower.id))
        #expect(copied.summaryMd == (try harness.descriptions.fetch(captureId: real.id))?.summaryMd)
    }
}

// MARK: - Health (#125)

@Suite("DescribeWorker health")
struct DescribeWorkerHealthTests {
    /// The worker holds the queue after a refusal, and the hold is read from `app_state` on the
    /// next cycle. Tests that want several cycles at one fixed clock move it back out of the way.
    private func clearHold(_ harness: Harness) throws {
        try AppStateStore(harness.db).setDate(
            DescribeWorker.backoffKey, noon.addingTimeInterval(-1)
        )
    }

    @Test("a rejected key never spends a frame's attempts: the frames survive the key being fixed")
    func rejectedKeyLeavesFramesPending() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.badRequest(403, "forbidden")), count: 6)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        for _ in 0..<6 {
            let outcome = try await harness.worker.processOne(captureId: capture.id)
            if case .retryLater = outcome {} else { Issue.record("expected .retryLater, got \(outcome)") }
        }

        // Twice past `maxAttempts`, and the frame is still describable once the key is corrected.
        let reloaded = try #require(try harness.captures.fetch(id: capture.id))
        #expect(reloaded.describeStatus == .pending)
        #expect(reloaded.describeAttempts == 0)
    }

    @Test("Gemini's 400 for a mistyped key is a refusal, not a bad frame")
    func invalidKey400() async throws {
        let body = #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"API key not valid"}}"#
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.badRequest(400, body)), count: 4)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        for _ in 0..<4 { _ = try await harness.worker.processOne(captureId: capture.id) }

        let reloaded = try #require(try harness.captures.fetch(id: capture.id))
        #expect(reloaded.describeStatus == .pending)
        #expect(reloaded.describeAttempts == 0)
    }

    @Test("a refusal writes one ledger row per stretch, not one per probe")
    func oneLedgerRowPerRefusalStretch() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.badRequest(401, "unauthorized")), count: 5)))
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        for _ in 0..<5 { _ = try await harness.worker.processOne(captureId: capture.id) }

        let calls = try await harness.db.writer.read { db in try LLMCall.fetchAll(db) }
        #expect(calls.count == 1)
        #expect(calls.first?.httpStatus == 401)
    }

    @Test("three failed cycles tell the menu what is wrong, and a described frame takes it back")
    func stallAfterThreeCycles() async throws {
        let harness = try Harness(describer: StubDescriber(replies: [
            .failure(LLMError.badRequest(403, "forbidden")),
            .failure(LLMError.badRequest(403, "forbidden")),
            .failure(LLMError.badRequest(403, "forbidden")),
            StubDescriber.ok(goodJSON()),
        ]))
        defer { harness.cleanUp() }
        try harness.addCapture()

        // Two failed cycles are a hiccup and say nothing.
        for _ in 0..<2 {
            try clearHold(harness)
            _ = try await harness.worker.runCycle()
        }
        #expect(harness.healths.withLock { $0 }.isEmpty)

        try clearHold(harness)
        _ = try await harness.worker.runCycle()
        #expect(harness.healths.withLock { $0 } == [
            .failing(message: "Gemini rejected the key", httpStatus: 403),
        ])

        // The key was fixed: one frame through is all the proof needed.
        try clearHold(harness)
        _ = try await harness.worker.runCycle()
        #expect(harness.healths.withLock { $0.last } == .ok)
        #expect(await harness.worker.health == .ok)
    }

    @Test("a stall is announced once, however long it lasts")
    func stallAnnouncedOnce() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.badRequest(403, "forbidden")), count: 8)))
        defer { harness.cleanUp() }
        try harness.addCapture()

        for _ in 0..<8 {
            try clearHold(harness)
            _ = try await harness.worker.runCycle()
        }
        #expect(harness.healths.withLock { $0.count } == 1)
    }

    @Test("an outage is a hold, not a failure: it clears itself and never earns the icon")
    func outageHolds() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.network("offline")), count: 4)))
        defer { harness.cleanUp() }
        try harness.addCapture()

        for _ in 0..<3 {
            try clearHold(harness)
            _ = try await harness.worker.runCycle()
        }
        let health = try #require(harness.healths.withLock { $0.first })
        guard case let .holding(until, reason) = health else {
            Issue.record("expected .holding, got \(health)")
            return
        }
        #expect(reason == "Gemini is unreachable")
        #expect(until > noon)
        #expect(!health.isFailing)
    }

    @Test("a hold that turns into a refusal is a stall, and says so")
    func holdBecomesFailure() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.network("offline")), count: 3)
                + [.failure(LLMError.badRequest(403, "forbidden"))]))
        defer { harness.cleanUp() }
        try harness.addCapture()

        // Offline long enough to be noticed: a hold, which clears itself and says nothing loud.
        for _ in 0..<3 {
            try clearHold(harness)
            _ = try await harness.worker.runCycle()
        }
        #expect(harness.healths.withLock { $0.count } == 1)
        #expect(harness.healths.withLock { $0.first }?.isFailing == false)

        // The network came back and the key turned out to be the real problem. This is the first
        // moment the queue is genuinely stuck, so it has to be announced even though the state it
        // came from was not `.ok`.
        try clearHold(harness)
        _ = try await harness.worker.runCycle()
        let health = try #require(harness.healths.withLock { $0.last })
        #expect(health == .failing(message: "Gemini rejected the key", httpStatus: 403))
        #expect(health.startsStall(after: try #require(harness.healths.withLock { $0.first })))
    }

    @Test("a cycle with nothing to do is neither a success nor a failure")
    func quietCyclesSayNothing() async throws {
        let harness = try Harness(describer: StubDescriber(replies: []))
        defer { harness.cleanUp() }

        for _ in 0..<5 { _ = try await harness.worker.runCycle() }
        #expect(harness.healths.withLock { $0 }.isEmpty)
        #expect(await harness.worker.health == .ok)
        #expect(harness.describer.callCount == 0)
    }

    @Test("three frames given up on are a stall too, not just a refusal")
    func repeatedHardFailuresStall() async throws {
        let harness = try Harness(describer: StubDescriber(replies:
            Array(repeating: .failure(LLMError.serverError(503)), count: 6)))
        defer { harness.cleanUp() }
        try harness.addCapture()

        for _ in 0..<3 {
            try clearHold(harness)
            _ = try await harness.worker.runCycle()
        }
        #expect(harness.healths.withLock { $0 } == [
            .failing(message: "Gemini is having trouble", httpStatus: 503),
        ])
    }

}

/// #145: the battery precondition, which is deliberately not the outage backoff.
@Suite("DescribeWorker on battery")
struct DescribeWorkerBatteryTests {
    @Test("`describe-later` leaves frames pending until the charger is back")
    func batteryHoldsTheQueue() async throws {
        let harness = try Harness(
            describer: StubDescriber(json: goodJSON()), batteryMode: .describeLater
        )
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        await harness.worker.setPower(PowerState(onBattery: true))
        #expect(try await harness.worker.runCycle().isEmpty)
        #expect(harness.describer.callCount == 0)
        // Pending, not failed and not skipped: the same end state the outage hold leaves, so
        // nothing downstream has to know a battery was involved.
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .pending)

        await harness.worker.setPower(.mains)
        let outcomes = try await harness.worker.runCycle()
        #expect(outcomes.count == 1)
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .described)
    }

    @Test("`slow` keeps describing on battery — only the cadence changes")
    func slowKeepsDescribing() async throws {
        let harness = try Harness(describer: StubDescriber(json: goodJSON()), batteryMode: .slow)
        defer { harness.cleanUp() }
        let capture = try harness.addCapture()

        await harness.worker.setPower(PowerState(onBattery: true))
        #expect(try await harness.worker.runCycle().count == 1)
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .described)
    }
}

// MARK: - d5 project keys (#315)

private func d5JSON(key: String?) -> String {
    let value = key.map { "\"\($0)\"" } ?? "null"
    return """
        {"app_key":"terminal","task_key":"coding_with_agent",
         "summary":"Edits the board deck.","project_hint":"Acme Corp","project_key":\(value),
         "is_meeting":false,"is_sensitive":false}
        """
}

private func rowCount(_ db: WorklensCore.Database, _ table: String) throws -> Int {
    try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
}

@Suite("DescribeWorker d5 project keys")
struct DescribeWorkerProjectKeyTests {
    private func catalog(_ harness: Harness) throws {
        var taxonomy = harness.taxonomy.current
        taxonomy.projects = [
            ProjectEntry(key: "firm", name: "Firm", kind: .house),
            ProjectEntry(key: "acme", name: "Acme Corp", aliases: ["acme labs"], kind: .company),
        ]
        try harness.taxonomy.save(taxonomy)
    }

    @Test("a known key is stored, confidence is NULL, and the schema names the catalog")
    func storesKnownKey() async throws {
        let harness = try Harness(describer: StubDescriber(json: d5JSON(key: "acme")))
        defer { harness.cleanUp() }
        try catalog(harness)
        let capture = try harness.addCapture()

        _ = try await harness.worker.processOne(captureId: capture.id)
        let stored = try #require(try harness.descriptions.fetch(captureId: capture.id))
        #expect(TimelineFrame.details(json: stored.detailsJson).projectKey == "acme")
        #expect(stored.confidence == nil)
        let schema = try #require(harness.describer.requests.first?.schema)
        #expect(schema["properties"]?["project_key"]?["enum"]
            == .array([.string("firm"), .string("acme"), .null]))
    }

    @Test("an unknown key is dropped before it is stored, an alias is stored as its entry's key")
    func dropsUnknownKey() async throws {
        let harness = try Harness(describer: StubDescriber(json: d5JSON(key: "gone"), d5JSON(key: "acme labs")))
        defer { harness.cleanUp() }
        try catalog(harness)
        let first = try harness.addCapture()
        let second = try harness.addCapture(at: noon.addingTimeInterval(60))

        _ = try await harness.worker.processOne(captureId: first.id)
        _ = try await harness.worker.processOne(captureId: second.id)
        let dropped = try #require(try harness.descriptions.fetch(captureId: first.id))
        #expect(TimelineFrame.details(json: dropped.detailsJson).projectKey == nil)
        #expect(TimelineFrame.details(json: dropped.detailsJson).projectHint == "Acme Corp")
        let aliased = try #require(try harness.descriptions.fetch(captureId: second.id))
        #expect(TimelineFrame.details(json: aliased.detailsJson).projectKey == "acme")
    }

    @Test("a probe asks text only, writes one llm_calls row and no description")
    func probeWritesOnlyTheLedger() async throws {
        let harness = try Harness(describer: StubDescriber(
            json: d5JSON(key: "acme"), d5JSON(key: nil), "not json"
        ))
        defer { harness.cleanUp() }
        try catalog(harness)
        let capture = try harness.addCapture(status: .described)
        try harness.addAXSnapshot(capture, coverage: .partial)
        let noText = try harness.addCapture(at: noon.addingTimeInterval(60), status: .described)

        #expect(try await harness.worker.probe(captureId: capture.id) == .answered(projectKey: "acme", costUSD: 0.0005))
        #expect(try await harness.worker.probe(captureId: capture.id) == .answered(projectKey: nil, costUSD: 0.0005))
        // A paid answer that does not decode still carries its cost.
        #expect(try await harness.worker.probe(captureId: capture.id)
            == .failed("the answer did not match the schema", costUSD: 0.0005))
        // No outline, no call: the check never pays for an image.
        #expect(try await harness.worker.probe(captureId: noText.id) == .failed("no window text", costUSD: 0))

        #expect(harness.describer.callCount == 3)
        #expect(harness.describer.requests.allSatisfy { $0.imageJPEG == nil })
        // The outline is labelled with the coverage it was stored with, never promoted to full.
        #expect(harness.describer.requests.allSatisfy { $0.userPrompt.contains("partial coverage") })
        #expect(try rowCount(harness.db, "llm_calls") == 3)
        #expect(try rowCount(harness.db, "descriptions") == 0)
        #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .described)
    }

    @Test("a probe over budget calls nothing and writes nothing")
    func probeOverBudget() async throws {
        let harness = try Harness(describer: StubDescriber(json: d5JSON(key: "acme")), cost: OverBudgetGate())
        defer { harness.cleanUp() }
        try catalog(harness)
        let capture = try harness.addCapture(status: .described)
        try harness.addAXSnapshot(capture)

        #expect(try await harness.worker.probe(captureId: capture.id) == .overBudget)
        #expect(harness.describer.callCount == 0)
        #expect(try rowCount(harness.db, "llm_calls") == 0)
    }
}
