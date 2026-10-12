import Foundation

/// Drains the describe queue: every `pending` capture becomes a `descriptions` row via one vision
/// call, every `inherited` capture gets a free copy of the frame before it, and both outcomes —
/// plus every failure — land in `llm_calls`.
///
/// Serial by construction (an actor, batches of five): at one frame a minute there is nothing to
/// parallelize, and a serial worker means the "recent context" in each prompt is genuinely the
/// frames that came before.
public actor DescribeWorker {
    /// What happened to one capture. Returned by `processOne` so the CLI and the tests can assert
    /// on it without reading the database back.
    public enum Outcome: Sendable, Equatable {
        case described(descriptionId: String, costUSD: Double)
        case inherited(descriptionId: String)
        /// Left `pending`; the next cycle tries again.
        case retryLater(String)
        /// `describe_status = 'failed'`; no further attempts.
        case failed(String)
        case overBudget
    }

    public enum State: Sendable, Equatable {
        case idle, running, budgetExceeded
    }

    /// Everything needed to describe one frame, without having called anything yet.
    public struct Prepared: Sendable {
        public let capture: Capture
        public let resolved: ResolvedApp?
        public let request: DescribeRequest
        /// What `TextRedactor` took out of the title and the URL on the way into the prompt (#49);
        /// stored under `redactions` in `descriptions.details_json`.
        public let redactions: [TextRedactor.Kind: Int]
        /// The prompt input this request was built from, kept so the one repair attempt can
        /// rebuild the *same* prompt with a note appended instead of re-deriving it.
        public let input: DescribePrompt.Input

        /// Which of d2's three renderings this frame got — what `describe-pending` prints.
        public var mode: DescribePrompt.Mode { input.mode }

        public init(
            capture: Capture,
            resolved: ResolvedApp?,
            request: DescribeRequest,
            redactions: [TextRedactor.Kind: Int] = [:],
            input: DescribePrompt.Input
        ) {
            self.capture = capture
            self.resolved = resolved
            self.request = request
            self.redactions = redactions
            self.input = input
        }
    }

    /// What one `probe` learned (#315): the catalog key the d5 prompt picked, nil for none.
    public enum ProbeOutcome: Sendable, Equatable {
        case answered(projectKey: String?, costUSD: Double)
        case overBudget
        /// `costUSD` is what the call cost when it was paid for but its answer did not decode.
        case failed(String, costUSD: Double)
    }

    public enum WorkerError: Error, CustomStringConvertible {
        case unknownCapture(String)
        case notPending(String, DescribeStatus)
        /// No image *and* no stored window text — nothing to describe the frame from (#54). A
        /// frame with either one is describable, so this is now only the empty case.
        case imageMissing(String)

        public var description: String {
            switch self {
            case let .unknownCapture(id): return "no capture with id \(id)"
            case let .notPending(id, status): return "capture \(id) is \(status.rawValue), not pending"
            case let .imageMissing(path): return "no window text, and the image file is missing: \(path)"
            }
        }
    }

    // MARK: Dependencies

    private let config: Config
    private let taxonomy: TaxonomyStore
    /// Credentials and payment instruments never reach the prompt (#49). Compiled once, here,
    /// because this runs on every frame.
    private let redactor: TextRedactor
    private let describer: any VisionDescriber
    private let cost: any CostGate
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    private let captures: CaptureStore
    private let descriptions: DescriptionStore
    private let ledger: LLMCallStore
    private let appState: AppStateStore
    private let queries: DescribeQueries
    /// #53: the stored window outline, which retention drops alongside the JPEG.
    private let axSnapshots: AXSnapshotStore
    /// #19: lets the prompt name the meeting a frame fell inside.
    private let contextEvents: ContextEventStore

    /// Called with the local day after each successful description, so #10 can redraw it.
    private let onDescribed: (@Sendable (String) async -> Void)?

    /// #125: called when the queue stops moving, and again when it starts again. The only way a
    /// describe failure reaches the menu — before this, every one of them ended in `llm_calls`
    /// and the log, where nobody was looking.
    private let healthHandler: (@Sendable (DescribeHealth) async -> Void)?

    // MARK: Tuning

    /// Fallback poll interval; `nudge()` runs a cycle sooner.
    public static let pollInterval: TimeInterval = 15
    public static let batchSize = 5
    public static let maxAttempts = 3
    /// Ceiling on the queue-wide hold while the provider is unreachable. Long enough that a day
    /// offline is a few dozen probes, short enough that reconnecting is noticed within minutes.
    public static let maxOutageHold: TimeInterval = 300
    /// `app_state` key holding the instant before which no describe attempt should be made.
    public static let backoffKey = "describe_backoff_until"
    /// Consecutive cycles that got nowhere before the menu is told. Three rather than one: a
    /// single failed cycle is a hiccup, and the hold between them means three is still under two
    /// minutes.
    public static let stallCycles = 3

    public private(set) var state: State = .idle

    /// Consecutive cycles that ended in an unreachable provider; paces `holdForOutage` and is
    /// reset by the first call that gets through. In memory on purpose: a relaunch is a good
    /// enough reason to try the network again immediately.
    private var networkOutages = 0

    /// Consecutive cycles that the provider refused outright; paces the queue-wide hold the same
    /// way `networkOutages` does, and is reset by the first call that gets through.
    private var providerRefusals = 0
    /// Cycles in a row that moved no frame forward. Cycles that did nothing at all — an empty
    /// queue, a backoff, a spent budget — count for neither side.
    private var failedCycles = 0
    /// The last failure, by class. Never a response body.
    private var lastFailure: DescribeHealth.Failure?
    /// When the current queue-wide hold ends, so `.holding` can name the time.
    private var holdUntil: Date?

    /// What the menu says about the describe queue (#125). Starts optimistic: nothing has failed.
    public private(set) var health: DescribeHealth = .ok

    private var loopTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var ticks: AsyncStream<Void>.Continuation?

    /// The live power facts, pushed in by whoever owns the OS observers (#145) — the app, from
    /// `CaptureScheduler.power`. Mains until told otherwise, which is what every headless run and
    /// every desktop is.
    private var power: PowerState = .mains

    /// Frames per catalog key over `DescribePrompt.projectCountDays`, and when they were counted
    /// (#315). Only read once the catalog is past `projectKeyLimit`, and recounted hourly.
    private var projectCounts: (at: Date, counts: [String: Int])?
    public static let projectCountsTTL: TimeInterval = 60 * 60

    public init(
        config: Config,
        db: Database,
        taxonomy: TaxonomyStore,
        describer: any VisionDescriber,
        cost: any CostGate = AlwaysAllowCostGate(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        onDescribed: (@Sendable (String) async -> Void)? = nil,
        healthHandler: (@Sendable (DescribeHealth) async -> Void)? = nil
    ) {
        self.config = config
        self.taxonomy = taxonomy
        self.redactor = TextRedactor(config: config)
        self.describer = describer
        self.cost = cost
        self.timeZone = timeZone
        self.now = now
        self.onDescribed = onDescribed
        self.healthHandler = healthHandler
        captures = CaptureStore(db)
        descriptions = DescriptionStore(db)
        ledger = LLMCallStore(db)
        appState = AppStateStore(db)
        queries = DescribeQueries(db)
        axSnapshots = AXSnapshotStore(db)
        contextEvents = ContextEventStore(db)

        if !redactor.invalidPatterns.isEmpty {
            // Key names only: one of these is a regex the user wrote, and the count is the useful
            // half. Same treatment as BLOCKED_TITLE_PATTERNS in `CaptureScheduler`.
            Log.describe.warn(
                "ignoring \(redactor.invalidPatterns.count) unparseable REDACT_EXTRA_PATTERNS"
            )
        }
    }

    // MARK: - Loop

    /// Starts the 15 s fallback loop. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ticks = continuation

        let interval = DescribeWorker.pollInterval
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                continuation.yield(())
            }
        }
        loopTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.runCycleIgnoringErrors()
            }
        }
        continuation.yield(())
    }

    public func stop() {
        timerTask?.cancel()
        ticks?.finish()
        loopTask?.cancel()
        timerTask = nil
        loopTask = nil
        ticks = nil
        state = .idle
    }

    /// Runs a cycle now instead of waiting out the poll interval.
    public func nudge() {
        ticks?.yield(())
    }

    /// #145: the charger went in or out. Pushed rather than polled, because the OS observers live
    /// on the main actor and this is an actor of its own; a nudge on the way back to mains means
    /// the queue does not wait out the poll interval.
    public func setPower(_ fresh: PowerState) {
        let wasAllowed = describeAllowedNow
        power = fresh
        if !wasAllowed, describeAllowedNow { nudge() }
    }

    /// Whether `PowerPolicy` lets the queue make calls at this instant.
    private var describeAllowedNow: Bool {
        PowerPolicy.decide(
            power: power,
            mode: config.captureOnBattery,
            baseIntervalSeconds: config.captureIntervalSeconds
        ).describeAllowed
    }

    private func runCycleIgnoringErrors() async {
        do {
            _ = try await runCycle()
        } catch {
            Log.describe.error("describe cycle failed: \(error)")
        }
    }

    /// One pass: up to `batchSize` real calls, then the free inherited copies.
    ///
    /// Real calls go first on purpose. An unchanged frame copies the frame right before it, so
    /// that frame has to be described before the copy is taken — the other way round, the copy
    /// would come from whatever older frame already had a description, which may have shown a
    /// different app entirely.
    @discardableResult
    public func runCycle(limit: Int = DescribeWorker.batchSize) async throws -> [Outcome] {
        if let until = try appState.getDate(DescribeWorker.backoffKey), now() < until {
            Log.describe.debug("describe backoff until \(until)")
            return []
        }
        // #145: `CAPTURE_ON_BATTERY=describe-later`. A precondition, deliberately not the outage
        // backoff above — that one is a 300 s-capped doubling hold for a provider that is down,
        // and "until the charger is back" has no deadline to count. Frames are simply left
        // `pending`, the same end state the outage path leaves them in, so `setPower` coming back
        // to mains is all it takes to resume.
        guard describeAllowedNow else {
            Log.describe.debug("on battery; leaving frames pending until mains")
            return []
        }
        if !(await cost.allows(.describe)) {
            state = .budgetExceeded
            Log.describe.warn("daily budget reached; leaving frames pending")
            return [.overBudget]
        }

        state = .running
        defer { state = .idle }

        var outcomes: [Outcome] = []
        for capture in try captures.fetchPendingDescribe(limit: limit) {
            outcomes.append(try await process(capture))
        }
        outcomes += try fillInherited(limit: limit)
        await noteCycle(outcomes)
        return outcomes
    }

    // MARK: - Health

    /// Turns a cycle's outcomes into `health`, and tells whoever asked when it changes.
    ///
    /// A cycle that described or inherited anything is proof the provider is answering, whatever
    /// else happened in it; a cycle that only failed is evidence the other way. A cycle that did
    /// neither — an empty queue, the backoff, the budget — says nothing about either, so it moves
    /// no counter: three quiet minutes must not read as three failures.
    private func noteCycle(_ outcomes: [Outcome]) async {
        var progressed = false
        var failed = false
        for outcome in outcomes {
            switch outcome {
            case .described, .inherited: progressed = true
            case .retryLater, .failed: failed = true
            case .overBudget: break
            }
        }
        if progressed {
            failedCycles = 0
            lastFailure = nil
            await setHealth(.ok)
            return
        }
        guard failed else { return }
        failedCycles += 1
        guard failedCycles >= DescribeWorker.stallCycles, let failure = lastFailure else { return }
        if failure.isUnreachable, let until = holdUntil, until > now() {
            await setHealth(.holding(until: until, reason: failure.reason))
        } else {
            await setHealth(.failing(message: failure.reason, httpStatus: failure.httpStatus))
        }
    }

    private func setHealth(_ new: DescribeHealth) async {
        guard new != health else { return }
        health = new
        await healthHandler?(new)
    }

    // MARK: - Inheritance

    /// Gives every `inherited` capture a zero-cost copy of its predecessor's description.
    ///
    /// The predecessor is the frame the scheduler compared against — the row right before this
    /// one that was not idle, locked or blocked — and only that frame: copying an *older*
    /// description past a predecessor that is still `pending` would label the frame with whatever
    /// was on screen before the last change. Such a frame is left alone and picked up on a later
    /// cycle, once the predecessor has been described.
    ///
    /// An inherited row never has an image (the scheduler only saves a JPEG for frames it means
    /// to describe), so a frame with nothing usable to copy cannot be described either: it is
    /// marked `failed` rather than `pending`, which is what an image-less pending row would
    /// become on its next turn anyway.
    @discardableResult
    public func fillInherited(limit: Int = DescribeWorker.batchSize) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for capture in try queries.inheritedWithoutDescription(limit: limit) {
            guard let predecessor = try queries.predecessor(of: capture) else {
                try captures.markDescribed(id: capture.id, status: .failed)
                Log.describe.info("an unchanged frame has no frame before it; nothing to inherit")
                outcomes.append(.failed("nothing to inherit: no earlier frame"))
                continue
            }
            guard let source = try descriptions.fetch(captureId: predecessor.id) else {
                switch predecessor.describeStatus {
                case .pending, .inherited:
                    // Its description is still on the way; this frame's turn comes after it.
                    continue
                case .described, .skipped, .failed:
                    // The screen was unchanged since a frame that never got a description (over
                    // budget, or the model gave up on it), so there is nothing truthful to copy.
                    try captures.markDescribed(id: capture.id, status: .failed)
                    Log.describe.info("an unchanged frame follows a \(predecessor.describeStatus.rawValue) frame; nothing to inherit")
                    outcomes.append(.failed("nothing to inherit: predecessor is \(predecessor.describeStatus.rawValue)"))
                    continue
                }
            }

            let copy = Description(
                captureId: capture.id,
                provider: source.provider,
                model: source.model,
                appKey: source.appKey,
                taskKey: source.taskKey,
                summaryMd: source.summaryMd,
                detailsJson: source.detailsJson,
                isMeeting: source.isMeeting,
                isSensitive: source.isSensitive,
                confidence: source.confidence,
                isInherited: true,
                promptTokens: 0,
                outputTokens: 0,
                thoughtTokens: 0,
                costUsd: 0,
                latencyMs: 0,
                rawJson: source.rawJson,
                createdAt: now()
            )
            try descriptions.insert(copy)
            outcomes.append(.inherited(descriptionId: copy.id))
        }
        return outcomes
    }

    // MARK: - One frame

    /// Describes one capture by id. Used by `describe-one` and by the tests.
    @discardableResult
    public func processOne(captureId: String) async throws -> Outcome {
        guard let capture = try captures.fetch(id: captureId) else {
            throw WorkerError.unknownCapture(captureId)
        }
        if !(await cost.allows(.describe)) {
            state = .budgetExceeded
            return .overBudget
        }
        return try await process(capture)
    }

    private func process(_ capture: Capture) async throws -> Outcome {
        let prepared: Prepared
        do {
            prepared = try prepare(capture)
        } catch let error as WorkerError {
            // A frame with neither an outline nor a file can never be described; do not burn
            // retries on it.
            try captures.markDescribed(id: capture.id, status: .failed)
            Log.describe.warn("capture \(capture.id) has no window text and no image on disk")
            return .failed(error.description)
        }

        var response: DescribeResponse
        var frame: FrameDescription
        do {
            response = try await callDescriber(prepared.request)
            frame = try decode(response.json)
        } catch let decodeError as DecodingError {
            // One repair attempt: the same prompt in the same mode, plus a line saying the last
            // answer did not parse. Rebuilt from the input this frame was prepared with, so a
            // text-only frame does not silently become an image one on its second try. Anything
            // past that is a failure worth recording.
            Log.describe.warn("model output did not match the schema; retrying once")
            let repaired = DescribePrompt.request(
                imageJPEG: prepared.request.imageJPEG,
                resolved: prepared.resolved,
                taxonomy: taxonomy,
                input: prepared.input.withRepairNote(DescribePrompt.repairNote),
                timeZone: timeZone,
                language: config.reportLanguage,
                projects: listedProjects()
            )
            do {
                response = try await callDescriber(repaired)
                frame = try decode(response.json)
            } catch is CancellationError {
                return .retryLater("cancelled")
            } catch {
                return try await recordFailure(capture, error: error, describeError: "\(decodeError)")
            }
        } catch is CancellationError {
            // Quitting mid-call is not the frame's fault: no attempt counted, no backoff, no ledger
            // row. The frame stays pending and the next launch describes it.
            return .retryLater("cancelled")
        } catch {
            return try await recordFailure(capture, error: error, describeError: nil)
        }

        return try await store(
            frame,
            response: response,
            for: capture,
            resolved: prepared.resolved,
            redactions: prepared.redactions
        )
    }

    /// One vision call. A call that gets through is the proof that the network is back and that
    /// the key is accepted, so both counters start over here rather than anywhere further down
    /// the success path.
    private func callDescriber(_ request: DescribeRequest) async throws -> DescribeResponse {
        let response = try await describer.describe(request)
        networkOutages = 0
        providerRefusals = 0
        holdUntil = nil
        return response
    }

    /// Builds the request for a capture without sending it — also what `--dry-run` prints.
    public func prepare(captureId: String) throws -> Prepared {
        guard let capture = try captures.fetch(id: captureId) else {
            throw WorkerError.unknownCapture(captureId)
        }
        return try prepare(capture)
    }

    /// The oldest pending frame, prepared but not sent.
    public func prepareFirstPending() throws -> Prepared? {
        guard let capture = try captures.fetchPendingDescribe(limit: 1).first else { return nil }
        return try prepare(capture)
    }

    /// Since #54 a frame is describable from either artifact: the stored outline, the JPEG, or
    /// both. Only a frame with neither is refused, and it is refused with the same message a
    /// missing file used to get, because that is still the usual cause.
    private func prepare(_ capture: Capture) throws -> Prepared {
        let jpeg = capture.imagePath.flatMap { relative in
            try? Data(contentsOf: config.dataDir.appendingPathComponent(relative))
        }
        // Already redacted: #53 put the outline through `TextRedactor` before it was written and
        // the raw string never survived that tick, so what is stored is what may be sent.
        let snapshot = try? axSnapshots.fetch(captureId: capture.id)
        let windowText = snapshot?.text?.nonEmpty
        guard jpeg != nil || windowText != nil else {
            throw WorkerError.imageMissing(capture.imagePath ?? "(none)")
        }

        let resolved = taxonomy.resolve(bundleID: capture.appBundleId, url: capture.browserUrl)
        let prompt = input(
            for: capture,
            windowText: windowText,
            coverage: snapshot?.coverage,
            hasImage: jpeg != nil,
            repairNote: nil
        )
        let request = DescribePrompt.request(
            imageJPEG: jpeg,
            resolved: resolved,
            taxonomy: taxonomy,
            input: prompt.input,
            timeZone: timeZone,
            language: config.reportLanguage,
            projects: listedProjects()
        )
        return Prepared(
            capture: capture, resolved: resolved, request: request,
            redactions: prompt.redactions, input: prompt.input
        )
    }

    /// The catalog as the d5 prompt lists it (#315): the whole list under the cap, else the house
    /// entry and the most used entries by an hourly count of the last `projectCountDays`.
    private func listedProjects() -> [ProjectEntry] {
        let projects = taxonomy.projects
        guard projects.count > DescribePrompt.projectKeyLimit else { return projects }
        let instant = now()
        if let cached = projectCounts, instant.timeIntervalSince(cached.at) < Self.projectCountsTTL {
            return DescribePrompt.promptProjects(projects, frameCounts: cached.counts)
        }
        var counts: [String: Int] = [:]
        let today = DayBoundaries.dayString(instant, timeZone: timeZone)
        let days = ProjectCatalog.window(
            endingAt: today, days: DescribePrompt.projectCountDays, timeZone: timeZone
        )
        for day in days {
            let observations = (try? descriptions.projectObservations(day: day, timeZone: timeZone)) ?? [:]
            for project in ProjectNames.resolve(observations, projects: projects).values {
                counts[project.key, default: 0] += 1
            }
        }
        projectCounts = (instant, counts)
        return DescribePrompt.promptProjects(projects, frameCounts: counts)
    }

    // MARK: - Probe (#315)

    /// Asks the d5 prompt which catalog key one already-described frame is about, text only, and
    /// stores nothing but the `llm_calls` row: no description, no status change, no retention.
    /// What `worklens projects check` runs. A frame with no stored window text is refused before
    /// any call, since the check is meant to cost a text request and never an image one.
    public func probe(captureId: String) async throws -> ProbeOutcome {
        guard let capture = try captures.fetch(id: captureId) else {
            throw WorkerError.unknownCapture(captureId)
        }
        let snapshot = try? axSnapshots.fetch(captureId: capture.id)
        guard let windowText = snapshot?.text?.nonEmpty else { return .failed("no window text", costUSD: 0) }
        guard await cost.allows(.describe) else { return .overBudget }

        let resolved = taxonomy.resolve(bundleID: capture.appBundleId, url: capture.browserUrl)
        let prompt = input(
            for: capture, windowText: windowText, coverage: snapshot?.coverage, hasImage: false,
            repairNote: nil
        )
        let request = DescribePrompt.request(
            imageJPEG: nil,
            resolved: resolved,
            taxonomy: taxonomy,
            input: prompt.input,
            timeZone: timeZone,
            language: config.reportLanguage,
            projects: listedProjects()
        )
        let response: DescribeResponse
        do {
            response = try await callDescriber(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let llmError = error as? LLMError
            try await recordLedgerFailure(
                message: llmError?.description ?? "\(error)", httpStatus: llmError?.httpStatus
            )
            return .failed("the describe call failed", costUSD: 0)
        }
        try ledger.insert(LLMCall(
            provider: describer.provider,
            model: response.model,
            purpose: .describe,
            promptTokens: response.usage.promptTokens,
            outputTokens: response.usage.outputTokens,
            thoughtTokens: response.usage.thoughtTokens,
            cachedTokens: response.usage.cachedTokens,
            costUsd: response.costUSD,
            latencyMs: response.latencyMs,
            httpStatus: 200,
            createdAt: now()
        ))
        await cost.ledgerChanged()
        guard let frame = try? decode(response.json) else {
            return .failed("the answer did not match the schema", costUSD: response.costUSD)
        }
        let key = frame.projectKey.flatMap { taxonomy.current.project(forKey: $0)?.key }
        return .answered(projectKey: key, costUSD: response.costUSD)
    }

    /// The prompt fields for one capture, with the window title and the URL taken through
    /// `TextRedactor` first (#49) — this is the last point before the text leaves the machine.
    /// The counts ride along so `store` can put them in `details_json`.
    private func input(
        for capture: Capture,
        windowText: String?,
        coverage: AXSnapshot.Coverage?,
        hasImage: Bool,
        repairNote: String?
    ) -> (input: DescribePrompt.Input, redactions: [TextRedactor.Kind: Int]) {
        let context = (try? queries.runContext(for: capture)) ?? .empty
        let title = redactor.redactIfPresent(capture.windowTitle)
        let url = redactor.redactIfPresent(capture.browserUrl)
        let input = DescribePrompt.Input(
            at: capture.capturedAt,
            appName: capture.appName,
            bundleID: capture.appBundleId,
            windowTitle: title.text,
            url: url.text,
            isMeeting: capture.isMeeting,
            meetingTitle: meetingTitle(at: capture.capturedAt, isMeeting: capture.isMeeting),
            context: context,
            repairNote: repairNote,
            windowText: windowText,
            coverage: coverage,
            mode: DescribePrompt.Mode.forFrame(
                hasText: windowText != nil, coverage: coverage, hasImage: hasImage
            )
        )
        return (input, TextRedactor.merge(title.counts, url.counts))
    }

    /// The synced meeting covering this frame, if any (#19). Only looked up for frames the
    /// detector already flagged, so an ordinary frame costs no query.
    private func meetingTitle(at instant: Date, isMeeting: Bool) -> String? {
        guard isMeeting else { return nil }
        return contextEvents.meetingTitle(covering: instant)
    }

    private func decode(_ json: String) throws -> FrameDescription {
        do {
            return try FrameDescription.decoder().decode(FrameDescription.self, from: Data(json.utf8))
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "not JSON: \(error)")
            )
        }
    }

    // MARK: - Persisting

    private func store(
        _ raw: FrameDescription,
        response: DescribeResponse,
        for capture: Capture,
        resolved: ResolvedApp?,
        redactions: [TextRedactor.Kind: Int] = [:]
    ) async throws -> Outcome {
        var frame = raw

        // The schema constrains the enums, but a model can still answer with a key that does not
        // belong to this app — and older fixtures predate the enum entirely. Clamp rather than
        // fail: a frame labeled `other` beats no label at all.
        if frame.appKey != "other", taxonomy.current.tasks(forAppKey: frame.appKey) == nil {
            frame.appKey = resolved?.appKey ?? "other"
        }
        if !taxonomy.isKnownTask(appKey: frame.appKey, taskKey: frame.taskKey) {
            frame.taskKey = "other"
        }
        // #315: a key the catalog no longer has (edited between prompt and answer) is dropped,
        // and one it knows by an alias is stored under the entry's own key.
        frame.projectKey = frame.projectKey.flatMap { taxonomy.current.project(forKey: $0)?.key }

        let description = Description(
            captureId: capture.id,
            provider: describer.provider,
            model: response.model,
            appKey: frame.appKey,
            taskKey: frame.taskKey,
            summaryMd: frame.summary,
            detailsJson: frame.detailsJSON(redactions: TextRedactor.countsJSON(redactions)),
            isMeeting: frame.isMeeting || capture.isMeeting,
            isSensitive: frame.isSensitive,
            // d5 (#315) no longer asks for it; the column stays for older rows.
            confidence: nil,
            isInherited: false,
            promptTokens: response.usage.promptTokens,
            outputTokens: response.usage.outputTokens,
            thoughtTokens: response.usage.thoughtTokens,
            costUsd: response.costUSD,
            latencyMs: response.latencyMs,
            rawJson: DescribePrompt.rawJSON(modelOutput: response.json),
            createdAt: now()
        )
        try descriptions.insert(description)
        try captures.markDescribed(id: capture.id, status: .described)

        try ledger.insert(LLMCall(
            provider: describer.provider,
            model: response.model,
            purpose: .describe,
            promptTokens: response.usage.promptTokens,
            outputTokens: response.usage.outputTokens,
            thoughtTokens: response.usage.thoughtTokens,
            cachedTokens: response.usage.cachedTokens,
            costUsd: response.costUSD,
            latencyMs: response.latencyMs,
            httpStatus: 200,
            createdAt: now()
        ))
        await cost.ledgerChanged()

        try applyRetention(to: capture, isSensitive: frame.isSensitive)
        try appState.delete(DescribeWorker.backoffKey)

        if let onDescribed {
            let day = DayBoundaries.dayString(capture.capturedAt, timeZone: timeZone)
            Task { await onDescribed(day) }
        }
        return .described(descriptionId: description.id, costUSD: response.costUSD)
    }

    /// Sensitive frames lose their image when `DELETE_SENSITIVE_SCREENSHOTS` is on; every frame
    /// loses it when `DELETE_SCREENSHOTS_AFTER_DESCRIBE` is on. The *description* stays either
    /// way — it is written to say what you were doing without quoting the screen.
    ///
    /// Since #53 the same two flags govern `ax_snapshots.text`, because a stored window outline
    /// is the same kind of evidence as the pixels and often a more literal one. Only the text
    /// goes: `text_hash`, `redactions_json` and `coverage` stay, so the next tick's describe
    /// decision and the day's coverage numbers are unaffected.
    private func applyRetention(to capture: Capture, isSensitive: Bool) throws {
        let sensitiveDrop = isSensitive && config.deleteSensitiveScreenshots
        guard sensitiveDrop || config.deleteScreenshotsAfterDescribe else { return }

        try axSnapshots.clearText(captureId: capture.id)

        guard let relative = capture.imagePath else { return }
        try? FileManager.default.removeItem(at: config.dataDir.appendingPathComponent(relative))
        try queries.clearImagePath(captureId: capture.id)
        Log.describe.info(sensitiveDrop ? "deleted a frame flagged sensitive" : "deleted a described frame")
    }

    /// Whether an error means "the provider was never reached", as opposed to "the provider
    /// looked at this frame and would not describe it". `GeminiClient` funnels every `URLError`
    /// into `LLMError.network`; a describer that throws `URLError` itself is matched too.
    ///
    /// A 429 or a 5xx is deliberately *not* here: the provider answered, and the client has
    /// already spent its own five retries on it.
    static func isUnreachable(_ error: Error) -> Bool {
        if let llmError = error as? LLMError, case .network = llmError { return true }
        return error is URLError
    }

    private func recordFailure(_ capture: Capture, error: Error, describeError: String?) async throws -> Outcome {
        let llmError = error as? LLMError
        let message = describeError ?? llmError?.description ?? "\(error)"
        // The class of the failure, for the log and the menu. `message` keeps the provider's own
        // words for `llm_calls`, which is local; neither the log nor the menu ever sees them.
        let failure = describeError == nil
            ? DescribeHealth.classify(error, provider: describer.provider)
            : DescribeHealth.schemaFailure(provider: describer.provider)
        lastFailure = failure

        // The provider answered and said no to the *caller*, not to this frame: a key it will not
        // accept, a quota that is spent. Nothing about the frame caused it and nothing about the
        // frame can fix it, so — exactly like an unreachable provider — the frame keeps its three
        // attempts and stays `pending`. Before #125 a mistyped key burned three attempts per
        // frame and marked every one of them `failed`, which no code path ever undid: the day's
        // frames were gone even after the key was corrected.
        if describeError == nil, failure.isRefusal {
            return try await holdForRefusal(failure, message: message)
        }

        // An unreachable provider says nothing about this frame, so it must not spend one of the
        // frame's three attempts — an hour offline would otherwise mark the head of the queue
        // permanently failed while the rest of the backlog waited happily behind it. Treated like
        // a cancelled call: the frame stays pending, and only the queue-wide hold grows.
        //
        // `describeError` non-nil means the *first* answer arrived and did not fit the schema,
        // which is real evidence about the frame; that still counts, even if the repair call was
        // the thing that could not reach the provider.
        if describeError == nil, DescribeWorker.isUnreachable(error) {
            return try await holdForOutage(
                failure, message: message, httpStatus: llmError?.httpStatus
            )
        }

        try await recordLedgerFailure(message: message, httpStatus: llmError?.httpStatus)

        let attempts = try queries.bumpAttempts(captureId: capture.id)
        if attempts >= DescribeWorker.maxAttempts {
            try captures.markDescribed(id: capture.id, status: .failed)
            Log.describe.error("giving up on a frame after \(attempts) attempts: \(failure.reason)")
            return .failed(message)
        }

        // Exponential hold on the whole queue, not just this frame: the usual cause is the
        // provider being unhappy, and hammering it with the next four frames will not help.
        let delay = pow(2.0, Double(attempts)) * DescribeWorker.pollInterval
        holdUntil = now().addingTimeInterval(delay)
        try appState.setDate(DescribeWorker.backoffKey, now().addingTimeInterval(delay))
        Log.describe.warn(
            "describe attempt \(attempts) failed (\(failure.reason)); holding \(Int(delay))s"
        )
        return .retryLater(message)
    }

    /// Holds the whole queue while the provider is out of reach, leaving every frame `pending`.
    ///
    /// The hold doubles per consecutive outage — 15 s, 30 s, 60 s … up to `maxOutageHold` — so a
    /// long stretch offline costs a handful of probes instead of one every fifteen seconds, and
    /// one row in `llm_calls` instead of hundreds.
    private func holdForOutage(
        _ failure: DescribeHealth.Failure, message: String, httpStatus: Int?
    ) async throws -> Outcome {
        if networkOutages == 0 {
            try await recordLedgerFailure(message: message, httpStatus: httpStatus)
        }
        let delay = min(
            pow(2.0, Double(networkOutages)) * DescribeWorker.pollInterval,
            DescribeWorker.maxOutageHold
        )
        networkOutages += 1
        try applyHold(delay)
        Log.describe.warn(
            "provider unreachable (\(failure.reason)); frames stay pending, holding \(Int(delay))s"
        )
        return .retryLater(message)
    }

    /// Holds the whole queue while the provider refuses to work for this key at all, leaving
    /// every frame `pending`.
    ///
    /// The same shape as `holdForOutage` and for the same reason: the refusal is about the
    /// account, not about the frame at the head of the queue, so the queue waits rather than
    /// feeding itself into it five frames at a time. One ledger row per stretch, not one per
    /// probe. The frames recover on their own once the key is fixed and the app reloads.
    private func holdForRefusal(
        _ failure: DescribeHealth.Failure, message: String
    ) async throws -> Outcome {
        if providerRefusals == 0 {
            try await recordLedgerFailure(message: message, httpStatus: failure.httpStatus)
        }
        let delay = min(
            pow(2.0, Double(providerRefusals)) * DescribeWorker.pollInterval,
            DescribeWorker.maxOutageHold
        )
        providerRefusals += 1
        try applyHold(delay)
        Log.describe.warn(
            "\(failure.reason); frames stay pending, holding \(Int(delay))s"
        )
        return .retryLater(message)
    }

    /// Writes the queue-wide hold and remembers when it ends, so `.holding` can name the time.
    private func applyHold(_ delay: TimeInterval) throws {
        let until = now().addingTimeInterval(delay)
        holdUntil = until
        try appState.setDate(DescribeWorker.backoffKey, until)
    }

    private func recordLedgerFailure(message: String, httpStatus: Int?) async throws {
        try ledger.insert(LLMCall(
            provider: describer.provider,
            model: config.describeModel,
            purpose: .describe,
            costUsd: 0,
            httpStatus: httpStatus,
            error: String(message.prefix(500)),
            createdAt: now()
        ))
        await cost.ledgerChanged()
    }
}
