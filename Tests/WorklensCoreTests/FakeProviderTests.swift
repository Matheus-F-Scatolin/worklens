import Foundation
import GRDB
import Testing

@testable import WorklensCore

// MARK: - Harness

/// A throwaway data directory with the seeded taxonomy in it.
private struct Scratch {
    let dataDir: URL
    let config: Config
    let db: WorklensCore.Database
    let taxonomy: TaxonomyStore

    init(day: String) throws {
        dataDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-fake-\(UUID().uuidString)")
        var config = Config.defaults()
        config.dataDir = dataDir
        config.captureIntervalSeconds = SampleData.embeddedIntervalSeconds
        self.config = config
        db = try Database.inMemory()
        taxonomy = try TaxonomyStore(dataDir: dataDir)
        try SampleData.seed(try SampleData.embedded(day: day), into: db)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }

    var timelineWriter: TimelineWriter {
        TimelineWriter(config: config, db: db, taxonomy: taxonomy)
    }

    func worker(onDescribed: (@Sendable (String) async -> Void)? = nil) -> DescribeWorker {
        DescribeWorker(
            config: config, db: db, taxonomy: taxonomy,
            describer: FakeDescriber(), onDescribed: onDescribed
        )
    }
}

private let sampleDay = "2026-09-10"

// MARK: - The describer

@Suite("FakeDescriber")
struct FakeDescriberTests {
    /// The prompt a real frame would produce, so the fake is exercised on the real shape.
    private func request(
        title: String = "Northwind launch plan — Google Docs",
        url: String? = "https://docs.google.com/document/d/sample/edit",
        at: Date = Date(timeIntervalSince1970: 1_757_260_800)
    ) throws -> DescribeRequest {
        let taxonomy = try TaxonomyStore(
            dataDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("worklens-fake-prompt-\(UUID().uuidString)"))
        let resolved = taxonomy.resolve(bundleID: "com.google.Chrome", url: url)
        return DescribePrompt.request(
            imageJPEG: nil,
            resolved: resolved,
            taxonomy: taxonomy,
            input: DescribePrompt.Input(
                at: at, appName: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: title, url: url, windowText: "Northwind launch plan", mode: .text
            )
        )
    }

    @Test("the same frame always produces the same answer")
    func deterministic() async throws {
        let describer = FakeDescriber()
        let first = try await describer.describe(try request())
        let second = try await describer.describe(try request())
        #expect(first.json == second.json)
    }

    /// Not every pair of frames has to differ — the wording is picked from a short list — but a
    /// run of them must not be one sentence repeated, or the timeline collapses to a single bullet.
    @Test("a run of frames does not come back as one repeated sentence")
    func varies() async throws {
        let describer = FakeDescriber()
        var answers: Set<String> = []
        for minute in 0..<8 {
            let at = Date(timeIntervalSince1970: 1_757_260_800 + Double(minute) * 300)
            answers.insert(try await describer.describe(try request(at: at)).json)
        }
        #expect(answers.count > 1)
    }

    @Test("it costs nothing and says which provider it is")
    func free() async throws {
        let response = try await FakeDescriber().describe(try request())
        #expect(FakeDescriber().provider == "fake")
        #expect(response.costUSD == 0)
        #expect(response.usage == .zero)
        #expect(response.model == FakeProvider.model)
    }

    @Test("the labels come out of the request's own schema, so they are always legal")
    func labelsFromSchema() async throws {
        let request = try request()
        let response = try await FakeDescriber().describe(request)
        let frame = try FrameDescription.decoder()
            .decode(FrameDescription.self, from: Data(response.json.utf8))
        #expect(FakeProvider.enumValues(request.schema, property: "app_key").contains(frame.appKey))
        #expect(
            FakeProvider.enumValues(request.schema, property: "task_key").contains(frame.taskKey))
        #expect(frame.appKey == "gdocs")
    }

    @Test("every summary carries the marker and invents no project")
    func marked() async throws {
        let response = try await FakeDescriber().describe(try request())
        let frame = try FrameDescription.decoder()
            .decode(FrameDescription.self, from: Data(response.json.utf8))
        #expect(frame.summary.hasPrefix(FakeProvider.markerSentence))
        #expect(frame.projectHint == nil)
        #expect(frame.projectKey == nil)
        #expect(frame.isSensitive == false)
    }
}

// MARK: - Nothing selects the fake by accident

@Suite("The fake provider is never selected unless it is asked for")
struct FakeSelectionTests {
    /// #87 deleted `DESCRIBE_PROVIDER` and `REPORT_PROVIDER` for labelling rather than selecting.
    /// #121 did not bring them back under another name: the fake is chosen at the call site or
    /// not at all, which is what makes an accidental fake run structurally impossible.
    @Test("no configuration key selects a provider")
    func noProviderKey() {
        let selecting = Config.keys.filter { !$0.retired && $0.name.contains("PROVIDER") }
        #expect(selecting.isEmpty)
        let retired = Config.keys.filter { $0.retired }.map(\.name)
        #expect(retired.contains("DESCRIBE_PROVIDER"))
        #expect(retired.contains("REPORT_PROVIDER"))
    }

    @Test("an env layer asking for the fake changes nothing")
    func envCannotAskForIt() throws {
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
        let asked = try Config.load(
            layers: [
                [
                    "LLM_PROVIDER": "fake",
                    "DESCRIBE_PROVIDER": "fake",
                    "REPORT_PROVIDER": "fake",
                ]
            ],
            cwd: cwd
        )
        #expect(asked == Config.defaults(cwd: cwd))
    }
}

// MARK: - The embedded day

@Suite("SampleData.embedded")
struct EmbeddedSampleDayTests {
    @Test("it is a working day of undescribed frames, each with an outline")
    func shape() throws {
        let bundle = try SampleData.embedded(day: sampleDay)
        #expect(bundle.captures.count >= 20)
        #expect(bundle.snapshots.count == bundle.captures.count)
        #expect(bundle.captures.allSatisfy { $0.describeStatus == .pending })
        #expect(bundle.captures.allSatisfy { $0.imagePath == nil })
        #expect(bundle.days == [sampleDay])
    }

    @Test("seeding it twice seeds the same frames once")
    func idempotent() throws {
        let scratch = try Scratch(day: sampleDay)
        defer { scratch.cleanUp() }
        try SampleData.seed(try SampleData.embedded(day: sampleDay), into: scratch.db)
        let stored = try CaptureStore(scratch.db).fetchPendingDescribe(limit: 500)
        #expect(stored.count == SampleData.embeddedDay.reduce(0) { $0 + $1.frames })
    }

    @Test("a day that is not a day is refused")
    func badDay() {
        #expect(throws: (any Error).self) { try SampleData.embedded(day: "yesterday") }
    }
}

// MARK: - The whole chain, describe → timeline with no keys

@Suite("The fake pipeline end to end")
struct FakePipelineTests {
    @Test("describe → timeline, no keys, nothing but the marker in it")
    func endToEnd() async throws {
        let scratch = try Scratch(day: sampleDay)
        defer { scratch.cleanUp() }

        let timeline = scratch.timelineWriter
        let outcomes = try await scratch.worker().runCycle(limit: 500)
        let described = outcomes.filter { if case .described = $0 { true } else { false } }
        #expect(described.count >= 20)

        let markdown = try await timeline.rebuild(day: sampleDay)
        #expect(markdown.contains(FakeProvider.markerSentence))

        // The ledger is the honest record: every call it made, all of them free.
        let providers: [String] = try await scratch.db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT provider FROM llm_calls")
        }
        #expect(providers == ["fake"])
        let spend = try LLMCallStore(scratch.db)
            .spend(from: .distantPast, to: .distantFuture)
        #expect(spend == 0)
    }
}
