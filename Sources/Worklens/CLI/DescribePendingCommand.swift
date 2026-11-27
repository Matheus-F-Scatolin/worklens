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
    /// - Parameter provider: `--provider`, one summarizer instead of the configured chain.
    init(requireKey: Bool, fake: Bool = false, provider: SummaryProvider? = nil) throws {
        config = try CLIConfig.load()
        let built = fake ? FakeDescriber() : SummaryProviders.describer(config: config, only: provider)
        if requireKey, built == nil {
            // Exit 4 and one line, not a usage block: nothing about the command line is wrong.
            if provider == .gemini || (provider == nil && config.summaryProviders.isEmpty) {
                throw CLIFailure.config(
                    "GEMINI_API_KEY is not set. Put it in .env (a billing-enabled project: on the "
                        + "free tier Google may train on your screenshots). docs/user/setup.md#summaries "
                        + "says where to get one."
                )
            }
            throw CLIFailure.config(
                "Nothing is set up to summarize screenshots. `worklens summaries check` says what "
                    + "Claude Code, Codex and Gemini each need."
            )
        }
        db = try Database(dataDir: config.dataDir)
        // The real budget gate, exactly as the app wires it: `describe-pending` is the same
        // spend on the same ledger, and a CLI that ignored DAILY_BUDGET_USD would be a way around
        // it rather than a way to run the stage.
        let cost = CostTracker(db: db, config: config)
        // Rebuilt with the budget now that the ledger is open: a plan in the order summarizes
        // with the budget spent, Gemini does not (`SummaryBudgetGate`).
        let budgeted = fake ? built : SummaryProviders.describer(config: config, only: provider, budget: cost)
        taxonomy = try TaxonomyStore(dataDir: config.dataDir)
        let timeline = TimelineWriter(config: config, db: db, taxonomy: taxonomy)
        self.timeline = timeline
        let describer: any VisionDescriber = budgeted
            ?? GeminiClient(apiKey: config.geminiAPIKey ?? "", model: config.describeModel)
        worker = DescribeWorker(
            config: config,
            db: db,
            taxonomy: taxonomy,
            describer: describer,
            cost: SummaryBudgetGate(cost, describer: describer),
            // Each described frame redraws its day, exactly as the app will.
            onDescribed: { day in await timeline.nudge(day: day) }
        )
    }

    /// What `--dry-run` prints for a subscription summarizer: the command line and what goes on
    /// stdin, with the screenshot itself shown as its size. Nil for Gemini, whose request is the
    /// prompt and schema printed above it.
    static func commandPreview(
        _ request: DescribeRequest, provider: SummaryProvider, config: Config
    ) -> String? {
        switch provider {
        case .gemini:
            return nil
        case .claude:
            let arguments = ClaudeDescriber.arguments(
                model: config.claudeSummaryModel,
                systemInstruction: request.systemInstruction,
                schema: request.schema
            )
            var stdin = String(decoding: ClaudeDescriber.stdin(for: request), as: UTF8.self)
            for jpeg in request.images.map(\.jpeg) {
                stdin = stdin.replacingOccurrences(
                    of: jpeg.base64EncodedString(), with: "<\(jpeg.count) bytes of JPEG, base64>"
                )
            }
            return "--- command ---\n" + shellLine(["claude"] + arguments)
                + "\n\n--- stdin ---\n" + stdin
        case .codex:
            let workspace = SubscriptionWorkspace(dataDir: config.dataDir)
            let arguments = CodexDescriber.arguments(
                model: "<newest gpt-*-\(config.codexSummaryModel)>",
                systemInstruction: request.systemInstruction,
                imageFiles: request.images.isEmpty
                    ? [workspace.temporaryDirectory.appendingPathComponent("<screenshot>.jpg")]
                    : request.images.map {
                        $0.file ?? workspace.temporaryDirectory.appendingPathComponent("<screenshot>.jpg")
                    },
                schemaFile: workspace.temporaryDirectory.appendingPathComponent("<schema>.json"),
                workingDirectory: workspace.emptyDirectory
            )
            return "--- command ---\n" + shellLine(["codex"] + arguments)
                + "\n\n--- stdin ---\n" + request.userPrompt
                + "\n\n--- <schema>.json ---\n"
                + DescribePrompt.prettyJSON(CodexDescriber.strictSchema(request.schema))
        }
    }

    /// Arguments quoted the way a shell would need them, so the line can be read, not run.
    static func shellLine(_ arguments: [String]) -> String {
        arguments.map { argument in
            guard argument.isEmpty || argument.contains(where: { " \"'$\\\n{}[]*?;&|<>()`".contains($0) }) else {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
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
        abstract: "Describe queued captures: one vision call each, or one per batch, free copies for unchanged frames."
    )

    @Option(help: "How many calls to make: one capture each, or one batch each when SUMMARY_BATCH batches.")
    var limit: Int = DescribeWorker.batchSize

    @Flag(help: "Print the prompt and schema for the next call (one capture, or the next batch) without calling the API.")
    var dryRun = false

    @Flag(help: """
        Describe with the offline fake provider: no key, no network, $0, and summaries that say \
        so.
        """)
    var fake = false

    @Option(help: "Summarize with this one summarizer instead of SUMMARY_PROVIDERS: claude, codex or gemini.")
    var provider: SummaryProvider?

    func run() async throws {
        let stack = try DescribeStack(requireKey: !dryRun, fake: fake, provider: provider)
        if fake { print("--fake: describing with the offline fake provider. \(FakeProvider.marker).\n") }

        if dryRun {
            guard let next = try await stack.worker.prepareNextCall() else {
                print("nothing pending")
                return
            }
            if next.captures.count > 1 {
                printBatch(next.captures, request: next.request, config: stack.config)
                return
            }
            let prepared = try await stack.worker.prepare(captureId: next.captures[0].id)
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
            if let chosen = provider ?? SummaryProviders.effective(stack.config).first,
               let preview = DescribeStack.commandPreview(prepared.request, provider: chosen, config: stack.config) {
                print("")
                print("=== as sent to \(chosen.rawValue) ===")
                print(preview)
            }
            return
        }

        // Run by hand, the queue is summarized now: a batch still waiting on its timer goes too.
        let outcomes = try await stack.worker.runCycle(limit: limit, flush: true)
        await stack.flushTimeline()
        DescribeStack.report(outcomes)
    }

    /// The dry run of a batch (`SUMMARY_BATCH`): which captures, then the one request.
    private func printBatch(_ captures: [Capture], request: DescribeRequest, config: Config) {
        print("batch      \(captures.count) captures, \(request.images.count) with an image (SUMMARY_BATCH=\(SummaryBatching.mode(config).rawValue))")
        for capture in captures {
            print("capture    \(capture.id)  \(capture.capturedAt)")
        }
        let bytes = request.images.map(\.jpeg.count).reduce(0, +)
        print("images     \(request.images.isEmpty ? "none (described from text)" : "\(bytes / 1024) KB in all")")
        print("")
        print("--- system instruction ---")
        print(request.systemInstruction)
        print("")
        print("--- user prompt ---")
        print(request.userPrompt)
        print("")
        print("--- response schema ---")
        print(DescribePrompt.prettyJSON(request.schema))
        if let chosen = provider ?? SummaryProviders.effective(config).first,
           let preview = DescribeStack.commandPreview(request, provider: chosen, config: config) {
            print("")
            print("=== as sent to \(chosen.rawValue) ===")
            print(preview)
        }
    }
}

struct DescribeOneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe-one",
        abstract: "Describe one capture by id, whatever its state."
    )

    @Argument(help: "The captures.id to describe.")
    var captureID: String

    @Option(help: "Summarize with this one summarizer instead of SUMMARY_PROVIDERS: claude, codex or gemini.")
    var provider: SummaryProvider?

    func run() async throws {
        let stack = try DescribeStack(requireKey: true, provider: provider)
        let outcome = try await stack.worker.processOne(captureId: captureID)
        await stack.flushTimeline()
        DescribeStack.report([outcome])
    }
}

extension SummaryProvider: ExpressibleByArgument {}
