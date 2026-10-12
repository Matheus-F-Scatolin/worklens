import Foundation

/// Pulls every configured context source on a timer so reports, the timeline and the chat can
/// read meetings, messages and mail out of SQLite instead of making live API calls.
///
/// Sources are synced one after another rather than concurrently: they are all rate-limited,
/// none of them is slow enough for the parallelism to matter, and a serial round makes the
/// per-source backoff bookkeeping obvious.
public actor ContextSyncScheduler {
    /// How far back a routine sync looks. Long enough that a laptop closed over a long weekend
    /// still catches up, short enough that a round stays cheap.
    public static let lookback: TimeInterval = 48 * 3600
    /// …and forward, so tomorrow's calendar is already known when the day starts.
    public static let lookahead: TimeInterval = 24 * 3600
    /// Minutes to wait after the 1st, 2nd, 3rd and 4th-or-later consecutive failure.
    public static let backoffMinutes: [Double] = [1, 5, 15, 60]
    /// The slice of the day handed to `MeetingDetector` after each round.
    static let meetingFeedBefore: TimeInterval = 2 * 3600
    static let meetingFeedAfter: TimeInterval = 12 * 3600

    private let sources: [any ContextSyncSource]
    private let config: Config
    private let store: ContextEventStore
    /// Where a round's outcome survives a relaunch (#141).
    private let appState: AppStateStore
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let onMeetings: (@Sendable ([ContextEvent]) async -> Void)?
    /// #314: the GitHub shipped ledger, awaited once per round. Nil when `GITHUB_SHIPPED` is off.
    private let outputs: OutputSync?
    /// #321: the Claude Code and Codex session logs, read once per round after the meetings are
    /// published. Nil when `AGENT_SESSIONS` is off.
    private let agents: AgentSessionSync?

    private var statuses: [ContextSource: SourceStatus] = [:]
    private var loopTask: Task<Void, Never>?

    /// - Parameter onMeetings: receives the meetings around now after every round. The app
    ///   hands this to `MeetingDetector`, which is why the scheduler itself has no
    ///   opinion about capture cadence.
    public init(
        sources: [any ContextSyncSource],
        db: Database,
        config: Config,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        onMeetings: (@Sendable ([ContextEvent]) async -> Void)? = nil,
        outputs: OutputSync? = nil,
        agents: AgentSessionSync? = nil
    ) {
        self.sources = sources
        self.outputs = outputs
        self.agents = agents
        self.config = config
        self.store = ContextEventStore(db)
        self.appState = AppStateStore(db)
        self.clock = clock
        self.now = now
        self.onMeetings = onMeetings
        for source in sources {
            // #141: the last round, out of `app_state`. Without it every relaunch showed
            // "Connected · never synced" for a source holding thousands of events, and a
            // credential that had been refused all week looked healthy again until the next
            // round failed.
            statuses[source.id] = SourceStatus.load(source: source, config: config, db: db)
        }
    }

    // MARK: Status

    public var status: [ContextSource: SourceStatus] { statuses }

    /// Every source in declaration order — what Settings → Integrations lists.
    public var statusList: [SourceStatus] {
        sources.compactMap { statuses[$0.id] }
    }

    public var isRunning: Bool { loopTask != nil }

    // MARK: Lifecycle

    /// Syncs once now, then every `CONTEXT_SYNC_MINUTES`.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            // Publish what is already in the database before the first round runs. A round takes
            // tens of seconds (every source is rate-limited), and until it finished the capture
            // scheduler had no idea a meeting synced before the last restart was in progress.
            await self.publishMeetings()
            await self.loop()
        }
        Log.net.info("context sync scheduler started, every \(config.contextSyncMinutes) min")
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        Log.net.info("context sync scheduler stopped")
    }

    private func loop() async {
        let interval = Double(max(1, config.contextSyncMinutes)) * 60
        while !Task.isCancelled {
            _ = await syncDue()
            do {
                try await clock.sleep(for: .seconds(interval))
            } catch {
                return  // cancelled
            }
        }
    }

    // MARK: Syncing

    /// The routine round: every configured source that is not in backoff.
    @discardableResult
    public func syncDue() async -> [ContextSource: Result<SyncResult, any Error>] {
        await run(sources.filter { shouldSyncNow($0) }, respectingBackoff: true, includeOutputs: true)
    }

    /// What "Sync now" calls. Ignores backoff — the user asking is a
    /// better signal than the timer's caution.
    ///
    /// - Parameter lookbackDays: overrides the 48-hour window, for a first backfill. Sources are
    ///   rate-limited per day of window, so a long backfill is slow by design rather than broken.
    @discardableResult
    public func syncNow(
        source: ContextSource? = nil, lookbackDays: Int? = nil
    ) async -> [ContextSource: Result<SyncResult, any Error>] {
        let selected = source.map { id in sources.filter { $0.id == id } } ?? sources
        return await run(
            selected,
            respectingBackoff: false,
            includeOutputs: source == nil,
            lookback: lookbackDays.map { Double($0) * 24 * 3600 }
        )
    }

    private func shouldSyncNow(_ source: any ContextSyncSource) -> Bool {
        guard source.isConfigured(config) else { return false }
        guard let retryAfter = statuses[source.id]?.retryAfter else { return true }
        return now() >= retryAfter
    }

    private func run(
        _ selected: [any ContextSyncSource], respectingBackoff: Bool, includeOutputs: Bool,
        lookback: TimeInterval? = nil
    ) async -> [ContextSource: Result<SyncResult, any Error>] {
        var results: [ContextSource: Result<SyncResult, any Error>] = [:]
        let at = now()
        let window = DateInterval(
            start: at.addingTimeInterval(-(lookback ?? ContextSyncScheduler.lookback)),
            end: at.addingTimeInterval(ContextSyncScheduler.lookahead)
        )

        for source in selected {
            refreshConfigured(source)
            guard source.isConfigured(config) else {
                let error = ContextSyncError.notConfigured(source.displayName)
                results[source.id] = .failure(error)
                // #141: a source that was set up and is not any more is exactly the actionable
                // case — record it so it earns a menu line and a notification. A source that was
                // never set up is at rest, and records nothing.
                if statuses[source.id]?.lastSyncAt != nil { record(failure: error, for: source) }
                continue
            }
            do {
                let result = try await source.sync(window: window, into: store, config: config)
                record(success: result, for: source)
                results[source.id] = .success(result)
                Log.net.info("\(source.id.rawValue) sync: \(result.summary)")
            } catch is CancellationError {
                return results
            } catch {
                record(failure: error, for: source)
                results[source.id] = .failure(error)
                Log.net.warn("\(source.id.rawValue) sync failed: \(Self.describe(error))")
            }
        }

        // #314: after the sources, before the meetings are published. It keeps its own status and
        // backoff, so a missing `gh` costs this round nothing. "Sync now" for every source skips
        // that backoff, like the sources'; "Sync now" for one source leaves GitHub alone.
        if includeOutputs, let outputs {
            if respectingBackoff { await outputs.syncIfDue() } else { await outputs.sync() }
        }

        await publishMeetings()
        // #321: local files only, so no backoff; last, because a first round reads a lot.
        if includeOutputs, let agents { await agents.sync() }
        return results
    }

    private func refreshConfigured(_ source: any ContextSyncSource) {
        statuses[source.id]?.isConfigured = source.isConfigured(config)
    }

    private func record(success: SyncResult, for source: any ContextSyncSource) {
        var status = statuses[source.id] ?? SourceStatus(id: source.id, displayName: source.displayName)
        status.isConfigured = true
        status.lastSyncAt = now()
        status.lastError = nil
        status.lastErrorWasCredential = false
        status.lastErrorIsActionable = false
        status.needsReconnect = false
        status.lastWarnings = success.warnings
        status.lastInserted = success.inserted
        status.consecutiveFailures = 0
        status.lastFailureAt = nil
        // The incident is over: the next actionable failure gets its own notification.
        status.notifiedFailureAt = nil
        status.retryAfter = nil
        status.eventCount = (try? store.count(source: source.id)) ?? status.eventCount
        statuses[source.id] = status
        persist(source.id)
    }

    private func record(failure: any Error, for source: any ContextSyncSource) {
        var status = statuses[source.id] ?? SourceStatus(id: source.id, displayName: source.displayName)
        status.lastError = Self.describe(failure)
        // #135: kept as a fact rather than re-derived from the sentence later, so the Integrations
        // card can tell "paste a new token" from "the network was down".
        status.lastErrorWasCredential = ContextSyncError.isCredential(failure)
        // #141: whether waiting will fix it. An actionable failure earns a menu line and one
        // notification; a rate limit or a 5xx stays on the Integrations tab, where it belongs.
        status.lastErrorIsActionable = ContextSyncError.isActionable(
            failure, hadSynced: status.lastSyncAt != nil
        )
        // #139: the Google grant died. Asked of the error's own type, so the flag survives every
        // rewording of the sentence beside it. This is the narrow case of the actionable flag
        // above — an expired grant is always both — and it is narrow on purpose: it is the only
        // failure a new consent fixes, so it is the only one that may offer a Reconnect button.
        // `AppModel` therefore shows these under the reconnect banner and leaves them out of the
        // generic "needs attention" line, so one incident still speaks once.
        status.needsReconnect = GoogleAuth.needsReconnect(failure)
        status.consecutiveFailures += 1
        status.lastFailureAt = now()
        status.retryAfter = now().addingTimeInterval(Self.backoff(after: status.consecutiveFailures))
        statuses[source.id] = status
        persist(source.id)
    }

    /// Writes one source's status to `app_state`. Best-effort: a status that cannot be stored is
    /// not worth failing a sync over, and the in-memory copy is still right for this launch.
    private func persist(_ source: ContextSource) {
        guard let status = statuses[source] else { return }
        try? appState.setCodable(SourceStatus.statusKey(source), status.persisted)
    }

    /// Records that this source's actionable failure has been announced, so one incident
    /// produces one notification however many rounds it survives (#141).
    public func markAttentionNotified(_ source: ContextSource, at: Date? = nil) {
        guard statuses[source]?.lastErrorIsActionable == true else { return }
        statuses[source]?.notifiedFailureAt = at ?? now()
        persist(source)
    }

    /// Forgets everything stored about one source's syncing — what Disconnect leaves
    /// behind (#141).
    public func forget(_ source: ContextSource) {
        try? appState.delete(SourceStatus.statusKey(source))
        guard let existing = statuses[source] else { return }
        statuses[source] = SourceStatus(
            id: existing.id,
            displayName: existing.displayName,
            isConfigured: sources.first { $0.id == source }?.isConfigured(config) ?? false,
            eventCount: (try? store.count(source: source)) ?? 0
        )
    }

    /// The sources whose Google grant has expired, if any (#139). The menu raises one line for
    /// them all rather than one per source: it is one sign-in, not two.
    /// Asked of the configuration as it is now, not of the flag alone: a Disconnect takes the
    /// "Paused until you reconnect" line with it, without waiting for a round that will not run
    /// for a source that is no longer set up.
    public var sourcesNeedingReconnect: [ContextSource] {
        sources
            .filter { statuses[$0.id]?.needsReconnect == true && $0.isConfigured(config) }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// 1, 5, 15 then 60 minutes. A source that has been failing all morning is asked once an
    /// hour, not once a minute.
    public static func backoff(after failures: Int) -> TimeInterval {
        let index = min(max(failures, 1), backoffMinutes.count) - 1
        return backoffMinutes[index] * 60
    }

    /// Our own error types already read as sentences, so any of them that says how it should be
    /// phrased gets to. Only a Foundation or URLSession error falls through to
    /// `localizedDescription` — for a plain Swift `Error` that is
    /// "The operation couldn't be completed. (Module.Type error 2.)", which is exactly what
    /// `GoogleAuth.Failure.notConnected` must never show up as in Settings → Integrations.
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ContextSyncError: return error.description
        case let error as LLMError: return error.description
        case let error as any CustomStringConvertible & Error: return error.description
        default: return error.localizedDescription
        }
    }

    private func publishMeetings() async {
        guard let onMeetings else { return }
        let at = now()
        let meetings = (try? store.meetings(
            overlapping: at.addingTimeInterval(-ContextSyncScheduler.meetingFeedBefore),
            to: at.addingTimeInterval(ContextSyncScheduler.meetingFeedAfter)
        )) ?? []
        await onMeetings(meetings)
    }
}
