import ArgumentParser
import Foundation
import WorklensCore

/// Everything the describe CLI commands need, assembled once.
struct DescribeStack {
    let config: Config
    let db: Database
    let taxonomy: TaxonomyStore
    let timeline: TimelineWriter
    let worker: DescribeWorker

    /// - Parameter fake: #121's offline describer. Only ever true because someone typed
    ///   `--fake`; no configuration key selects it.
    init(requireKey: Bool, fake: Bool = false) throws {
        config = try CLIConfig.load()
        if requireKey, !fake, (config.geminiAPIKey ?? "").isEmpty {
            // Exit 4 and one line, not a usage block: nothing about the command line is wrong.
            throw CLIFailure.config(
                "GEMINI_API_KEY is not set. Put it in .env (a billing-enabled project: on the "
                    + "free tier Google may train on your screenshots). docs/user/setup.md#keys "
                    + "says where to get one."
            )
        }
        db = try Database(dataDir: config.dataDir)
        taxonomy = try TaxonomyStore(dataDir: config.dataDir)
        let timeline = TimelineWriter(config: config, db: db, taxonomy: taxonomy)
        self.timeline = timeline
        let describer: any VisionDescriber = fake
            ? FakeDescriber()
            : GeminiClient(apiKey: config.geminiAPIKey ?? "", model: config.describeModel)
        worker = DescribeWorker(
            config: config,
            db: db,
            taxonomy: taxonomy,
            describer: describer,
            // The real budget gate, exactly as the app wires it: `describe-pending` is the
            // same spend on the same ledger, and a CLI that ignored DAILY_BUDGET_USD would be a
            // way around it rather than a way to run the stage.
            cost: CostTracker(db: db, config: config),
            // Each described frame redraws its day, exactly as the app will.
            onDescribed: { day in await timeline.nudge(day: day) }
        )
    }

    /// Runs the debounced timeline rebuild now, which a short-lived CLI process would
    /// otherwise exit before.
    func flushTimeline() async {
        await timeline.flush()
    }

    /// `41 KB` or `none (described from text)` — the one line that says whether this frame cost
    /// an image at all.
    static func imageSize(_ jpeg: Data?) -> String {
        guard let jpeg else { return "none (described from text)" }
        return "\(jpeg.count / 1024) KB"
    }

    /// `1 842 characters, full coverage` or `none`.
    static func textSize(_ input: DescribePrompt.Input) -> String {
        guard let text = input.windowText, !text.isEmpty else { return "none" }
        let grade = input.coverage?.rawValue ?? "unknown"
        return "\(text.count) characters, \(grade) coverage"
    }

    static func report(_ outcomes: [DescribeWorker.Outcome]) {
        var described = 0
        var inherited = 0
        var cost = 0.0
        for outcome in outcomes {
            switch outcome {
            case let .described(id, usd):
                described += 1
                cost += usd
                print("described   \(id)  $\(String(format: "%.6f", usd))")
            case let .inherited(id):
                inherited += 1
                print("inherited   \(id)  $0")
            case let .retryLater(message):
                print("retry       \(message)")
            case let .failed(message):
                print("failed      \(message)")
            case .overBudget:
                print("over budget: DAILY_BUDGET_USD reached, nothing was sent")
            }
        }
        print("")
        print("\(described) described, \(inherited) inherited, $\(String(format: "%.6f", cost)) this run")
        if described > 0 {
            print("average     $\(String(format: "%.6f", cost / Double(described))) per described frame")
        }
    }
}

struct DescribePendingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe-pending",
        abstract: "Describe queued captures: one vision call each, free copies for unchanged frames."
    )

    @Option(help: "How many pending captures to process.")
    var limit: Int = DescribeWorker.batchSize

    @Flag(help: "Print the prompt and schema for the first pending capture without calling the API.")
    var dryRun = false

    @Flag(help: """
        Describe with the offline fake provider: no key, no network, $0, and summaries that say \
        so.
        """)
    var fake = false

    func run() async throws {
        let stack = try DescribeStack(requireKey: !dryRun, fake: fake)
        if fake { print("--fake: describing with the offline fake provider. \(FakeProvider.marker).\n") }

        if dryRun {
            guard let prepared = try await stack.worker.prepareFirstPending() else {
                print("nothing pending")
                return
            }
            print("capture    \(prepared.capture.id)")
            print("captured   \(prepared.capture.capturedAt)")
            print("app_key    \(prepared.resolved?.appKey ?? "(unresolved)")")
            // Which of the three d2 renderings this frame got, and what each half of it weighs.
            print("mode       \(prepared.mode.rawValue)")
            print("image      \(DescribeStack.imageSize(prepared.request.imageJPEG))")
            print("text       \(DescribeStack.textSize(prepared.input))")
            print("")
            print("--- system instruction ---")
            print(prepared.request.systemInstruction)
            print("")
            print("--- user prompt ---")
            print(prepared.request.userPrompt)
            print("")
            print("--- response schema ---")
            print(DescribePrompt.prettyJSON(prepared.request.schema))
            return
        }

        let outcomes = try await stack.worker.runCycle(limit: limit)
        await stack.flushTimeline()
        DescribeStack.report(outcomes)
    }
}

struct DescribeOneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe-one",
        abstract: "Describe one capture by id, whatever its state."
    )

    @Argument(help: "The captures.id to describe.")
    var captureID: String

    func run() async throws {
        let stack = try DescribeStack(requireKey: true)
        let outcome = try await stack.worker.processOne(captureId: captureID)
        await stack.flushTimeline()
        DescribeStack.report([outcome])
    }
}
