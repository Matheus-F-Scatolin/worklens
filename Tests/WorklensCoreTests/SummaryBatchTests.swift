import Foundation
import GRDB
import Testing
@testable import WorklensCore

// MARK: - Fixtures

private let batchNoon = Date(timeIntervalSince1970: 1_757_260_800)   // 2025-09-07T16:00:00Z
private let utc = TimeZone(identifier: "UTC")!

/// Answers from a queue filled after the captures exist, since a batch answer names their ids.
private final class QueueDescriber: VisionDescriber, @unchecked Sendable {
    let provider = GeminiClient.provider
    private let lock = NSLock()
    private var replies: [Result<DescribeResponse, Error>] = []
    private var seen: [DescribeRequest] = []

    func enqueue(_ json: String, usage: LLMUsage = LLMUsage(promptTokens: 900, outputTokens: 100), cost: Double = 0.0005) {
        lock.withLock {
            replies.append(.success(DescribeResponse(
                json: json, usage: usage, costUSD: cost, latencyMs: 1200, model: "gemini-3.5-flash-lite"
            )))
        }
    }

    var requests: [DescribeRequest] { lock.withLock { seen } }

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

private func fields(id: String? = nil, summary: String = "Editing the describe worker in a terminal.") -> String {
    let idField = id.map { #""id":"\#($0)","# } ?? ""
    return """
        {\(idField)"app_key":"terminal","task_key":"coding_with_agent","summary":"\(summary)",\
        "document":"DescribeWorker.swift","people":[],"project_hint":null,"is_meeting":false,\
        "is_sensitive":false,"confidence":0.9}
        """
}

private func batchAnswer(_ ids: [String]) -> String {
    #"{"screenshots":["# + ids.enumerated().map { fields(id: $1, summary: "Screen \($0 + 1).") }.joined(separator: ",") + "]}"
}

private struct BatchHarness {
    let dataDir: URL
    let db: WorklensCore.Database
    let taxonomy: TaxonomyStore
    let describer: QueueDescriber
    let worker: DescribeWorker
    let captures: CaptureStore
    let descriptions: DescriptionStore

    init(mode: SummaryBatchMode?, minutes: Int = 5, maxSize: Int = 10, now: Date = batchNoon) throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir
        config.summaryBatch = mode
        config.summaryBatchMinutes = minutes
        config.summaryBatchMax = maxSize
        db = try Database.inMemory()
        taxonomy = try TaxonomyStore(dataDir: dataDir)
        describer = QueueDescriber()
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        worker = DescribeWorker(
            config: config, db: db, taxonomy: taxonomy, describer: describer,
            timeZone: utc, now: { now }
        )
    }

    @discardableResult
    func addCapture(at: Date, bundleID: String = "com.mitchellh.ghostty", title: String = "worklens") throws -> Capture {
        let id = Identifiers.new()
        let path = ScreenshotPaths.relativePath(for: at, id: id, timeZone: utc)
        let url = dataDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)
        let capture = Capture(
            id: id, capturedAt: at, imagePath: path, appBundleId: bundleID, appName: "Ghostty",
            windowTitle: title, describeStatus: .pending
        )
        try captures.insert(capture)
        return capture
    }

    /// Three frames a minute apart, well past their window, so the batch is due.
    func addRun(_ count: Int = 3) throws -> [Capture] {
        try (0..<count).map { try addCapture(at: batchNoon.addingTimeInterval(Double(-600 + $0 * 60))) }
    }

    func ledger() throws -> [(frames: Int, cost: Double, status: Int?)] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT frames, cost_usd, http_status FROM llm_calls ORDER BY created_at")
                .map { ($0["frames"], $0["cost_usd"], $0["http_status"]) }
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }
}

private func frame(_ id: String, _ minute: Double, app: String = "a", breakBefore: Bool = false, retryAlone: Bool = false) -> BatchPlanner.Frame {
    BatchPlanner.Frame(
        id: id, capturedAt: batchNoon.addingTimeInterval(minute * 60), app: app,
        breakBefore: breakBefore, retryAlone: retryAlone
    )
}

// MARK: - Settings

@Suite("SUMMARY_BATCH settings")
struct SummaryBatchSettingsTests {
    @Test("unset follows the first summarizer: Gemini alone keeps one screenshot per call")
    func defaultMode() {
        var config = Config.defaults()
        config.geminiAPIKey = "test-key"
        config.summaryProviders = [.gemini]
        #expect(SummaryBatching.mode(config) == .each)
        config.summaryProviders = [.claude, .gemini]
        #expect(SummaryBatching.mode(config) == .appSwitch)
        config.summaryProviders = [.codex]
        #expect(SummaryBatching.mode(config) == .appSwitch)
        config.summaryBatch = .every
        #expect(SummaryBatching.mode(config) == .every)
        config.summaryBatch = .each
        #expect(SummaryBatching.mode(config) == .each)
    }

    @Test("the keys read, validate and clamp")
    func keys() throws {
        let config = try Config.load(layers: [[
            "SUMMARY_BATCH": "every", "SUMMARY_BATCH_MINUTES": "15", "SUMMARY_BATCH_MAX": "4",
        ]], cwd: FileManager.default.temporaryDirectory)
        #expect(config.summaryBatch == .every)
        #expect(config.summaryBatchMinutes == 15)
        #expect(config.summaryBatchMax == 4)
        #expect(throws: ConfigError.self) { try Config.load(layers: [["SUMMARY_BATCH_MINUTES": "7"]], cwd: FileManager.default.temporaryDirectory) }
        #expect(throws: ConfigError.self) { try Config.load(layers: [["SUMMARY_BATCH": "hourly"]], cwd: FileManager.default.temporaryDirectory) }
        var wide = Config.defaults()
        wide.summaryBatchMax = 99
        #expect(SummaryBatching.maxSize(wide) == 20)
        #expect(Config.defaults().summaryBatch == nil)
    }

    @Test("usage shares add up to the call, the remainder going to the first screenshots")
    func shares() {
        let usage = LLMUsage(promptTokens: 1000, outputTokens: 101, thoughtTokens: 2, cachedTokens: 0, imageTokens: 30)
        let shares = SummaryBatching.shares(of: usage, costUSD: 0.003, count: 3)
        #expect(shares.map(\.usage.promptTokens) == [334, 333, 333])
        #expect(shares.map(\.usage.outputTokens) == [34, 34, 33])
        #expect(shares.map(\.usage.thoughtTokens) == [1, 1, 0])
        #expect(shares.map(\.usage.imageTokens) == [10, 10, 10])
        #expect(abs(shares.map(\.costUSD).reduce(0, +) - 0.003) < 1e-12)
        #expect(SummaryBatching.shares(of: usage, costUSD: 1, count: 0).isEmpty)
    }
}

// MARK: - Planner

@Suite("BatchPlanner")
struct BatchPlannerTests {
    private let late = batchNoon.addingTimeInterval(3600)

    @Test("each: one frame per call, always due")
    func each() {
        let plan = BatchPlanner.plan([frame("1", 0), frame("2", 1)], mode: .each, minutes: 5, maxSize: 10, now: batchNoon)
        #expect(plan.due == [["1"], ["2"]])
        #expect(plan.nextDue == nil)
    }

    @Test("every: the window from the first frame closes a batch, apps do not")
    func every() {
        let frames = [frame("1", 0), frame("2", 1, app: "b"), frame("3", 4), frame("4", 5), frame("5", 6)]
        let plan = BatchPlanner.plan(frames, mode: .every, minutes: 5, maxSize: 10, now: late)
        #expect(plan.due == [["1", "2", "3"], ["4", "5"]])
    }

    @Test("a batch still inside its window waits, and says when it is due")
    func waits() {
        let plan = BatchPlanner.plan([frame("1", 0), frame("2", 1)], mode: .every, minutes: 5, maxSize: 10, now: batchNoon.addingTimeInterval(120))
        #expect(plan.due.isEmpty)
        #expect(plan.nextDue == batchNoon.addingTimeInterval(300))
        let flushed = BatchPlanner.plan([frame("1", 0), frame("2", 1)], mode: .every, minutes: 5, maxSize: 10, now: batchNoon, flush: true)
        #expect(flushed.due == [["1", "2"]])
    }

    @Test("a full batch is due at once")
    func full() {
        let frames = (0..<5).map { frame("\($0)", Double($0) * 0.1) }
        let plan = BatchPlanner.plan(frames, mode: .every, minutes: 30, maxSize: 2, now: batchNoon)
        #expect(plan.due == [["0", "1"], ["2", "3"]])
        #expect(plan.nextDue == batchNoon.addingTimeInterval(0.4 * 60 + 1800))
    }

    @Test("app_switch: an app change or a break closes the batch before it")
    func appSwitch() {
        let frames = [frame("1", 0), frame("2", 1), frame("3", 2, app: "b"), frame("4", 3, app: "b", breakBefore: true), frame("5", 4, app: "b")]
        let plan = BatchPlanner.plan(frames, mode: .appSwitch, minutes: 30, maxSize: 10, now: batchNoon.addingTimeInterval(300))
        #expect(plan.due == [["1", "2"], ["3"]])
        #expect(plan.nextDue == batchNoon.addingTimeInterval(3 * 60 + 1800))
        let closed = BatchPlanner.plan(frames, mode: .appSwitch, minutes: 30, maxSize: 10, now: batchNoon.addingTimeInterval(300), closedAfter: true)
        #expect(closed.due == [["1", "2"], ["3"], ["4", "5"]])
        #expect(closed.nextDue == nil)
    }

    @Test("a frame sent before goes alone, and splits the batch around it")
    func retryAlone() {
        let frames = [frame("1", 0), frame("2", 1, retryAlone: true), frame("3", 2)]
        let plan = BatchPlanner.plan(frames, mode: .every, minutes: 5, maxSize: 10, now: late)
        #expect(plan.due == [["1"], ["2"], ["3"]])
    }
}

// MARK: - Prompt and schema

@Suite("DescribePrompt batch (d6)")
struct DescribePromptBatchTests {
    private func items(_ taxonomy: TaxonomyStore) -> [DescribePrompt.BatchItem] {
        let terminal = taxonomy.resolve(bundleID: "com.mitchellh.ghostty", url: nil)
        return [
            DescribePrompt.BatchItem(
                id: "cap-1", resolved: terminal,
                input: DescribePrompt.Input(at: batchNoon, appName: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: "worklens"),
                imageJPEG: Data([1, 2, 3])
            ),
            DescribePrompt.BatchItem(
                id: "cap-2", resolved: nil,
                input: DescribePrompt.Input(
                    at: batchNoon.addingTimeInterval(65), appName: "Mystery", bundleID: "com.example.mystery",
                    windowText: "[AXStaticText] hello", mode: .text
                ),
                imageJPEG: Data([4, 5, 6])
            ),
            DescribePrompt.BatchItem(
                id: "cap-3", resolved: terminal,
                input: DescribePrompt.Input(at: batchNoon.addingTimeInterval(130), appName: "Ghostty", bundleID: "com.mitchellh.ghostty"),
                imageJPEG: Data([7, 8, 9])
            ),
        ]
    }

    private func taxonomy() throws -> (TaxonomyStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("worklens-batch-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try TaxonomyStore(dataDir: dir), dir)
    }

    @Test("every screenshot is labelled with its id, time and whether its picture came")
    func prompt() throws {
        let (store, dir) = try taxonomy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = DescribePrompt.batchRequest(items: items(store), taxonomy: store, timeZone: utc)
        #expect(request.isBatch)
        #expect(request.images.map(\.frameId) == ["cap-1", "cap-3"])
        #expect(request.images.map(\.label) == ["Screenshot 1 of 3, 16:00:00", "Screenshot 3 of 3, 16:02:10"])
        #expect(request.maxOutputTokens == DescribePrompt.maxOutputTokens * 3)
        #expect(request.systemInstruction.contains(DescribePrompt.batchInstruction))
        let prompt = request.userPrompt
        for line in ["Screenshot 2 of 3, 16:01:05", "id: cap-1", "id: cap-2", "id: cap-3", "App key: not recognized",
                     "Image: attached, image 1 of 2.", "Image: none; describe it from the window text.",
                     "Image: attached, image 2 of 2.", "[AXStaticText] hello"] {
            #expect(prompt.contains(line), "\(line)")
        }
        #expect(prompt.components(separatedBy: "Task keys for this app:").count == 2, "the terminal's tasks are listed once")
    }

    @Test("the schema is an array of entries whose id must be one of the batch's")
    func schema() throws {
        let (store, dir) = try taxonomy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = DescribePrompt.batchSchema(items: items(store), taxonomy: store.current)
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["screenshots"])
        let entry = try #require(schema["properties"]?["screenshots"]?["items"])
        #expect(entry["properties"]?["id"]?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["cap-1", "cap-2", "cap-3"])
        let required = entry["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.first == "id")
        let single = DescribePrompt.schema(resolved: store.resolve(bundleID: "com.mitchellh.ghostty", url: nil), taxonomy: store.current)
        #expect(Array(required.dropFirst()) == single["required"]?.arrayValue?.compactMap(\.stringValue))
        // An unrecognized app opens every app key, as a single screenshot's schema does.
        let appKeys = Set(entry["properties"]?["app_key"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(appKeys.isSuperset(of: store.current.allAppKeys))
    }

    @Test("decodeBatch keeps the entries it can place and drops the rest")
    func decode() throws {
        let json = #"{"screenshots":["# + [
            fields(id: "a"), fields(id: "b"), fields(id: "b"), fields(id: "zzz"), #"{"id":"c","summary":3}"#,
        ].joined(separator: ",") + "]}"
        let decoded = try DescribePrompt.decodeBatch(json, ids: ["a", "b", "c"])
        #expect(Set(decoded.keys) == ["a"])
        #expect(decoded["a"]?.frame.appKey == "terminal")
        #expect(throws: DecodingError.self) { try DescribePrompt.decodeBatch(fields(), ids: ["a"]) }
        #expect(throws: DecodingError.self) { try DescribePrompt.decodeBatch(#"{"screenshots":[]}"#, ids: ["a"]) }
        #expect(throws: DecodingError.self) { try DescribePrompt.decodeBatch("nope", ids: ["a"]) }
    }

    @Test("FakeDescriber answers a batch with one legal entry per screenshot")
    func fake() async throws {
        let (store, dir) = try taxonomy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = DescribePrompt.batchRequest(items: items(store), taxonomy: store, timeZone: utc)
        let response = try await FakeDescriber().describe(request)
        let decoded = try DescribePrompt.decodeBatch(response.json, ids: ["cap-1", "cap-2", "cap-3"])
        #expect(decoded.count == 3)
        #expect(decoded["cap-1"]?.frame.appKey == "terminal")
    }
}

// MARK: - Describers

@Suite("Describers carry a batch")
struct BatchDescriberTests {
    private func request() -> DescribeRequest {
        DescribeRequest(
            images: [
                DescribeImage(frameId: "a", label: "Screenshot 1 of 2, 10:00:00", jpeg: Data([1])),
                DescribeImage(frameId: "b", label: "Screenshot 2 of 2, 10:01:00", jpeg: Data([2])),
            ],
            systemInstruction: "sys",
            userPrompt: "prompt",
            schema: [
                "type": "object",
                "properties": ["screenshots": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["project_key": ["type": "string", "enum": ["acme-private"]]],
                ]]],
            ]
        )
    }

    @Test("argvSafe strips the project names nested under the batch's items")
    func argvSafe() {
        let safe = ClaudeDescriber.compactJSON(ClaudeDescriber.argvSafe(request().schema))
        #expect(!safe.contains("acme-private"))
        #expect(safe.contains("project_key"))
    }

    @Test("Claude stdin: the prompt, then each label before its picture")
    func claude() throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: ClaudeDescriber.stdin(for: request()))
        let content = message["message"]?["content"]?.arrayValue ?? []
        #expect(content.map { $0["type"]?.stringValue } == ["text", "text", "image", "text", "image"])
        #expect(content[1]["text"]?.stringValue == "Screenshot 1 of 2, 10:00:00")
        #expect(content[4]["source"]?["data"]?.stringValue == Data([2]).base64EncodedString())
    }

    @Test("Gemini parts: the prompt, then each label before its picture")
    func gemini() {
        let client = GeminiClient(apiKey: "", model: "gemini-3.5-flash-lite")
        let body = client.requestBody(for: request(), imagesBase64: ["AA", "BB"])
        let parts = body["contents"]?.arrayValue?.first?["parts"]?.arrayValue ?? []
        #expect(parts.count == 5)
        #expect(parts[0]["text"]?.stringValue == "prompt")
        #expect(parts[3]["text"]?.stringValue == "Screenshot 2 of 2, 10:01:00")
        #expect(parts[4]["inline_data"]?["data"]?.stringValue == "BB")
    }

    @Test("Gemini keeps one screenshot's body exactly as before")
    func geminiSingle() {
        let client = GeminiClient(apiKey: "", model: "gemini-3.5-flash-lite")
        let single = DescribeRequest(imageJPEG: Data([1]), systemInstruction: "s", userPrompt: "p", schema: ["type": "object"])
        #expect(client.requestBody(for: single, imagesBase64: ["AA"]) == client.requestBody(for: single, imageBase64: "AA"))
    }

    @Test("Codex attaches every picture with its own --image, in order")
    func codex() {
        let arguments = CodexDescriber.arguments(
            model: nil, systemInstruction: "x",
            imageFiles: [URL(fileURLWithPath: "/d/a.jpg"), URL(fileURLWithPath: "/d/b.jpg")],
            schemaFile: URL(fileURLWithPath: "/s.json"), workingDirectory: URL(fileURLWithPath: "/e")
        )
        #expect(arguments.filter { $0.hasPrefix("--image=") } == ["--image=/d/a.jpg", "--image=/d/b.jpg"])
    }
}

// MARK: - Worker

@Suite("DescribeWorker batches")
struct DescribeWorkerBatchTests {
    @Test("each mode is today's behaviour: one single-screenshot call per frame")
    func eachUnchanged() async throws {
        let harness = try BatchHarness(mode: .each)
        defer { harness.cleanUp() }
        _ = try harness.addRun(3)
        for _ in 0..<3 { harness.describer.enqueue(fields()) }

        let outcomes = try await harness.worker.runCycle(limit: 10)
        #expect(outcomes.count == 3)
        let requests = harness.describer.requests
        #expect(requests.count == 3)
        for request in requests {
            #expect(!request.isBatch)
            #expect(request.images.count == 1)
            #expect(request.schema["properties"]?["screenshots"] == nil)
            #expect(request.schema["properties"]?["app_key"] != nil)
            #expect(!request.userPrompt.contains("Screenshot 1 of"))
        }
        #expect(try harness.ledger().map(\.frames) == [1, 1, 1])
    }

    @Test("an unset mode with no subscription summarizer is each")
    func defaultIsEach() async throws {
        let harness = try BatchHarness(mode: nil)
        defer { harness.cleanUp() }
        _ = try harness.addRun(2)
        for _ in 0..<2 { harness.describer.enqueue(fields()) }
        _ = try await harness.worker.runCycle(limit: 10)
        #expect(harness.describer.requests.count == 2)
        #expect(harness.describer.requests.allSatisfy { !$0.isBatch })
    }

    @Test("a due batch is one call, one summary per screenshot, one ledger row")
    func batch() async throws {
        let harness = try BatchHarness(mode: .every)
        defer { harness.cleanUp() }
        let run = try harness.addRun(3)
        harness.describer.enqueue(batchAnswer(run.map(\.id)), usage: LLMUsage(promptTokens: 3001, outputTokens: 300), cost: 0.003)

        let outcomes = try await harness.worker.runCycle(limit: 10)
        #expect(outcomes.count == 3)
        #expect(harness.describer.requests.count == 1)
        let request = try #require(harness.describer.requests.first)
        #expect(request.isBatch)
        #expect(request.images.map(\.frameId) == run.map(\.id))

        var promptTokens = 0
        var summaries: [String] = []
        for (index, capture) in run.enumerated() {
            let stored = try #require(try harness.descriptions.fetch(captureId: capture.id))
            #expect(stored.summaryMd == "Screen \(index + 1).")
            promptTokens += stored.promptTokens ?? 0
            summaries.append(stored.summaryMd)
            #expect(try harness.captures.fetch(id: capture.id)?.describeStatus == .described)
        }
        #expect(Set(summaries).count == 3)
        #expect(promptTokens == 3001)
        let ledger = try harness.ledger()
        #expect(ledger.count == 1)
        #expect(ledger.first?.frames == 3)
        #expect(ledger.first?.cost == 0.003)
    }

    @Test("a batch inside its window waits, unless flushed")
    func waitsThenFlushes() async throws {
        let harness = try BatchHarness(mode: .every)
        defer { harness.cleanUp() }
        let a = try harness.addCapture(at: batchNoon.addingTimeInterval(-60))
        let b = try harness.addCapture(at: batchNoon.addingTimeInterval(-30))
        harness.describer.enqueue(batchAnswer([a.id, b.id]))

        #expect(try await harness.worker.runCycle(limit: 10).isEmpty)
        #expect(harness.describer.requests.isEmpty)
        let flushed = try await harness.worker.runCycle(limit: 10, flush: true)
        #expect(flushed.count == 2)
        #expect(harness.describer.requests.count == 1)
    }

    @Test("app_switch sends each app's stretch as its own call")
    func appSwitch() async throws {
        let harness = try BatchHarness(mode: .appSwitch)
        defer { harness.cleanUp() }
        let a = try harness.addCapture(at: batchNoon.addingTimeInterval(-600))
        let b = try harness.addCapture(at: batchNoon.addingTimeInterval(-540))
        let c = try harness.addCapture(at: batchNoon.addingTimeInterval(-480), bundleID: "com.apple.Safari", title: "docs")
        harness.describer.enqueue(batchAnswer([a.id, b.id]))
        harness.describer.enqueue(fields())

        _ = try await harness.worker.runCycle(limit: 10)
        let requests = harness.describer.requests
        #expect(requests.count == 2)
        #expect(requests.first?.images.map(\.frameId) == [a.id, b.id])
        #expect(requests.last?.isBatch == false)
        #expect(try harness.captures.fetch(id: c.id)?.describeStatus == .described)
    }

    @Test("a screenshot the answer left out goes again, alone")
    func missingRetriedAlone() async throws {
        let harness = try BatchHarness(mode: .every)
        defer { harness.cleanUp() }
        let run = try harness.addRun(3)
        harness.describer.enqueue(batchAnswer([run[0].id, run[2].id]))
        harness.describer.enqueue(fields())

        let first = try await harness.worker.runCycle(limit: 10)
        #expect(first.filter { if case .retryLater = $0 { true } else { false } }.count == 1)
        let missed = try #require(try harness.captures.fetch(id: run[1].id))
        #expect(missed.describeStatus == .pending)
        #expect(missed.describeAttempts == 1)

        _ = try await harness.worker.runCycle(limit: 10)
        let retry = try #require(harness.describer.requests.last)
        #expect(harness.describer.requests.count == 2)
        #expect(!retry.isBatch)
        #expect(try harness.captures.fetch(id: run[1].id)?.describeStatus == .described)
        #expect(try harness.ledger().map(\.frames) == [3, 1])
    }

    @Test("an answer that never fits spends one attempt on every screenshot and writes one failed row")
    func wholeBatchFails() async throws {
        let harness = try BatchHarness(mode: .every)
        defer { harness.cleanUp() }
        let run = try harness.addRun(3)
        harness.describer.enqueue("not json")
        harness.describer.enqueue(#"{"screenshots":[]}"#)

        _ = try await harness.worker.runCycle(limit: 10)
        #expect(harness.describer.requests.count == 2, "one call and one repair")
        #expect(harness.describer.requests.last?.userPrompt.contains(DescribePrompt.repairNote) == true)
        for capture in run {
            let stored = try #require(try harness.captures.fetch(id: capture.id))
            #expect(stored.describeAttempts == 1)
            #expect(stored.describeStatus == .pending)
        }
        let ledger = try harness.ledger()
        #expect(ledger.count == 1)
        #expect(ledger.first?.frames == 3)
    }

    @Test("dry run prepares the next batch without sending it")
    func prepareNextCall() async throws {
        let harness = try BatchHarness(mode: .every)
        defer { harness.cleanUp() }
        let run = try harness.addRun(2)
        let next = try #require(try await harness.worker.prepareNextCall())
        #expect(next.captures.map(\.id) == run.map(\.id))
        #expect(next.request.isBatch)
        #expect(harness.describer.requests.isEmpty)
    }
}

// MARK: - Storage

@Suite("llm_calls.frames")
struct LLMCallFramesTests {
    @Test("old rows read as one screenshot, new rows keep their count")
    func column() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(LLMCall(
            provider: "gemini", model: "m", purpose: .describe, promptTokens: 1, outputTokens: 1,
            costUsd: 0, latencyMs: 1, httpStatus: 200, frames: 4, createdAt: batchNoon
        ))
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO llm_calls (id, provider, model, purpose, prompt_tokens, output_tokens, cost_usd, latency_ms, created_at)
                SELECT 'legacy', provider, model, purpose, prompt_tokens, output_tokens, cost_usd, latency_ms, created_at FROM llm_calls
                """)
        }
        let frames = try db.writer.read { try Int.fetchAll($0, sql: "SELECT frames FROM llm_calls ORDER BY id = 'legacy'") }
        #expect(frames == [4, 1])
    }
}
