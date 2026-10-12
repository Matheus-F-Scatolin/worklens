import Combine
import CoreGraphics
import Foundation

// MARK: - Public vocabulary

public enum SchedulerState: Equatable, Sendable {
    case stopped
    case running
    /// `nil` means paused until the user resumes, not until a deadline.
    case paused(until: Date?)
    case idle
    case locked
    case asleep
    case permissionMissing
    case budgetExceeded
}

/// What one tick did. The raw values are what the menu bar (#15) shows through `lastTick`, so
/// they are stable strings.
public enum TickDecision: String, Sendable, CaseIterable {
    /// A frame was saved and queued for the vision model.
    case describedPending = "described_pending"
    /// A frame worth describing was saved but not queued: today's spend is over
    /// `DAILY_BUDGET_USD`. Distinct from `describedPending` because nothing downstream should
    /// act as though there were new work — and because `--verbose` saying "queued" about a
    /// frame that was held is a lie.
    case budgetSkipped = "budget_skipped"
    /// A row was written with no image: the screen and the context both looked the same.
    case unchanged
    case idle
    case locked
    case blocked
    case paused
    /// The tick came less than half an interval after the last one, so it collected nothing
    /// (#63). In practice that is a wake tick landing on top of a normal one; inside a meeting
    /// it is also #19's throttle, which was where this guard started.
    case tooSoon = "too_soon"
    /// `CAPTURE_SOURCE=accessibility` and the window exposed no text (#54): nothing was
    /// collected, because in that mode there is no picture to fall back to.
    case noText = "no_text"
    case error
}

public struct TickResult: Sendable, Equatable {
    /// Nil when the tick deliberately wrote nothing (paused, or a repeat of an idle/lock period).
    public let captureId: String?
    public let decision: TickDecision
    public let elapsedMs: Int
    /// Change against the previous frame, when one was measured. Printed by `--verbose`.
    public let changeScore: Double?
    /// Whether a JPEG hit the disk, so the CLI can say `saved=yes|no` without a second lookup.
    public let savedImage: Bool
    /// App name for the verbose CLI line.
    public let appName: String?
    /// Window title for the verbose CLI line only — nil on redacted and skipped ticks, and never
    /// written to a log above `.debug`.
    public let windowTitle: String?

    public init(
        captureId: String?,
        decision: TickDecision,
        elapsedMs: Int,
        changeScore: Double? = nil,
        savedImage: Bool = false,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.captureId = captureId
        self.decision = decision
        self.elapsedMs = elapsedMs
        self.changeScore = changeScore
        self.savedImage = savedImage
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

// MARK: - The describe decision (pure)

/// Whether a frame is worth a vision call. Split out because it is the single most cost-relevant
/// rule in the app and deserves to be tested as arithmetic, not as a scheduler side effect.
public enum DescribeDecision {
    /// - Parameters:
    ///   - changeScore: pixel change against the previous frame; nil for the very first frame.
    ///   - signatureChanged: whether app / window title / page changed.
    ///   - secondsSinceLastDescribed: nil when nothing has been described yet.
    ///   - threshold: `CHANGE_THRESHOLD`.
    ///   - heartbeat: `CAPTURE_HEARTBEAT_SECONDS`.
    ///   - textChanged: whether the focused window's redacted accessibility text hash moved since
    ///     the previous frame. Nil when there is no snapshot, or when its coverage is `.none` —
    ///     both mean "no opinion", and today's pixel rule decides alone.
    ///   - coverage: the snapshot's grade, which is what says how much the text hash is worth.
    public static func needsDescribe(
        changeScore: Double?,
        signatureChanged: Bool,
        secondsSinceLastDescribed: TimeInterval?,
        threshold: Double,
        heartbeat: TimeInterval,
        textChanged: Bool? = nil,
        coverage: AXSnapshot.Coverage? = nil
    ) -> Bool {
        // No previous frame to compare against: describe, or the timeline starts blind. Ahead of
        // the text rules on purpose — "nothing to compare" is not a statement about the text.
        guard let changeScore else { return true }

        let heartbeatDue = secondsSinceLastDescribed.map { $0 >= heartbeat } ?? true
        // Today's rule, unchanged, and still the whole rule for a frame with no usable text.
        let pixelRule = signatureChanged || changeScore >= threshold || heartbeatDue

        guard let textChanged, let coverage, coverage != .none else { return pixelRule }

        switch coverage {
        case .full:
            // The tree covered the window, so its hash is the better signal *and* the pixel term
            // is what wastes money: a playing video, a blinking cursor and a sliding notification
            // all cross CHANGE_THRESHOLD without changing what the user is doing.
            return textChanged || signatureChanged || heartbeatDue
        case .partial:
            // Some text, but not enough to drop the pixels: the text hash can only add describes
            // here, never remove one.
            return textChanged || pixelRule
        case .none:
            return pixelRule
        }
    }

    /// The rule for a frame with no pixels at all (#54): under `CAPTURE_SOURCE=auto` a fully
    /// covered window is never photographed, so there is no change score to consult and the text
    /// hash, the window signature and the heartbeat are the whole rule. Deliberately the same
    /// three terms as the `.full` branch above — dropping the pixels does not change *what* makes
    /// a frame worth describing, only what is left to ask.
    public static func needsDescribeFromText(
        textChanged: Bool,
        signatureChanged: Bool,
        secondsSinceLastDescribed: TimeInterval?,
        heartbeat: TimeInterval
    ) -> Bool {
        let heartbeatDue = secondsSinceLastDescribed.map { $0 >= heartbeat } ?? true
        return textChanged || signatureChanged || heartbeatDue
    }

    /// #52 measured Slack grading `.full` off **two** nodes — a window title and one untitled
    /// group — because `Coverage.classify`'s node floor is "more than one". An outline like that
    /// holds no message text, so its hash does not move when a message arrives, and trusting it
    /// as `.full` would drop the pixel term that is currently the only thing noticing. So the
    /// grade is re-checked here, where it is consumed, against a node floor: a thin tree is
    /// treated as `.partial` and keeps the pixel rule underneath it.
    ///
    /// Deliberately *not* in `classify`: that grade is what `ax_snapshots.coverage` stores and
    /// what #54's measurements bucket frames by, and re-defining it would silently move the
    /// numbers in `docs/decisions.md`.
    public static let trustedFullMinNodes = 5

    public static func trustedCoverage(
        _ coverage: AXSnapshot.Coverage, nodeCount: Int
    ) -> AXSnapshot.Coverage {
        coverage == .full && nodeCount < trustedFullMinNodes ? .partial : coverage
    }
}

// MARK: - Scheduler

/// The heartbeat of Worklens: one tick per interval, each writing at most one `captures` row.
///
/// Every reason not to capture — paused, locked, idle, blocked — still produces a row (once per
/// period) rather than a silent gap, because a timeline with unexplained holes is worse than one
/// that says "you were away".
@MainActor
public final class CaptureScheduler: ObservableObject {
    @Published public private(set) var state: SchedulerState = .stopped
    @Published public private(set) var lastTick: TickResult?
    /// The live power facts (#145), republished so the menu can explain a slower cadence. Set
    /// from `system` at construction and whenever the charger or Low Power Mode changes.
    @Published public private(set) var power: PowerState = .mains

    /// Called once per tick, after `lastTick` is set. The menu bar (#15) can observe `lastTick`
    /// instead.
    public var onTick: (@MainActor (TickResult) -> Void)?

    private let config: Config
    private let store: CaptureStore
    /// #146: where "was Worklens watching at 14:30?" is written down.
    private let coverageEvents: CoverageEventStore
    private let axSnapshots: AXSnapshotStore
    private let database: Database
    private let capture: any ScreenCapturing
    private let context: any ForegroundContextProviding
    private let meeting: MeetingDetector
    private let system: any SystemStateProviding
    private let costGate: any CostGate
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let privacy: PrivacyPolicy
    /// The accessibility read (#53). Nil disables it entirely — what `capture-once` and the tests
    /// that predate this issue use. The live snapshotter is also the one place the Accessibility
    /// grant is checked: it answers nil when the process is not trusted, so a missing grant costs
    /// one `AXIsProcessTrusted()` per tick and changes nothing else.
    private let snapshotter: (any AccessibilitySnapshotting)?
    /// Credentials and payment instruments never reach a row (#49). Compiled once, here, because
    /// this runs on every frame.
    private let redactor: TextRedactor

    private var loopTask: Task<Void, Never>?
    private var lastFingerprint: FrameFingerprint?
    private var lastContextSignature: String?
    private var lastDescribedAt: Date?
    /// The skip reason on the row we wrote last, or nil if that row was a real capture. This is
    /// the whole "one row per idle/lock period" rule.
    private var lastWrittenSkipReason: SkipReason?
    /// Set when permission is missing; ticks short-circuit until it passes, so a denied TCC
    /// prompt costs one check every five minutes rather than one per interval.
    private var permissionRetryAfter: Date?
    /// Guards against a wake-triggered tick landing right after a normal one during a meeting.
    private var lastCaptureAt: Date?
    /// The previous frame's redacted accessibility text hash — the whole describe-from-text rule.
    /// Persisted in `app_state.last_ax_text_hash` so a restart does not pay for a describe.
    private var lastAXTextHash: String?
    /// Which app the hash above belongs to. A hash means nothing across a switch, and this is
    /// also when `AXEnhancedUserInterface` is turned back off.
    private var lastAXBundleID: String?
    /// The pid the snapshotter reported setting `AXEnhancedUserInterface` on, so it can be reset
    /// when that app stops being frontmost.
    private var axEnhancedPid: pid_t?

    public static let permissionRetryInterval: TimeInterval = 300
    /// After a wake or unlock, take a frame this soon rather than waiting out the interval.
    public static let wakeTickDelay: TimeInterval = 10

    public init(
        config: Config,
        db: Database,
        capture: any ScreenCapturing,
        context: any ForegroundContextProviding,
        meeting: MeetingDetector,
        // Defaulted to nil rather than to a SystemStateMonitor: default arguments are
        // evaluated at the call site, which is not the main actor.
        system: (any SystemStateProviding)? = nil,
        costGate: any CostGate = AlwaysAllowCostGate(),
        snapshotter: (any AccessibilitySnapshotting)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.database = db
        self.store = CaptureStore(db)
        self.coverageEvents = CoverageEventStore(db)
        self.axSnapshots = AXSnapshotStore(db)
        self.capture = capture
        self.context = context
        self.meeting = meeting
        self.system = system ?? SystemStateMonitor()
        self.costGate = costGate
        self.clock = clock
        self.now = now
        self.privacy = PrivacyPolicy(config: config)
        self.snapshotter = snapshotter
        self.redactor = TextRedactor(config: config)
        power = self.system.power

        // Restored here rather than in start(), so `run --once` also compares against the last
        // run's frame instead of paying for a describe every single time.
        restoreState()

        if !privacy.invalidPatterns.isEmpty {
            Log.capture.warn("ignoring \(privacy.invalidPatterns.count) unparseable BLOCKED_TITLE_PATTERNS")
        }
    }

    // MARK: Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        system.start(
            owner: self,
            handlers: SystemStateHandlers(
                onWake: { [weak self] in self?.scheduleWakeTick() },
                // #145: nothing to do but republish it — the next sleep already reads
                // `baseInterval` afresh, and the menu needs to say why it got longer.
                onPowerChange: { [weak self] in
                    guard let self else { return }
                    self.power = self.system.power
                }
            )
        )
        // #145: the observers were torn down by `stop()`, so a charger change while stopped fires
        // nothing. Re-read it here or a Mac unplugged before Start keeps the mains cadence until
        // the next charger event.
        power = system.power
        state = .running
        // #146: before saying "watching from here", close whatever the last run left open. A run
        // that ended in a crash, a force-quit or an update wrote no `stopped`, and the honest end
        // of it is the last frame it managed to record.
        closeUnfinishedRun()
        recordCoverage(.started)
        // Running is running: a pause record left by an earlier run must not outlive it, or the
        // updater would wait for a pause nobody is in (#113). `startRestoringPause()` writes it
        // back immediately when there is one to restore.
        forgetPauseRecord()
        loopTask = Task { [weak self] in await self?.loop() }
        Log.capture.info("capture scheduler started, interval \(config.captureIntervalSeconds)s")
    }

    /// Note what this does *not* do: it leaves the pause record alone. `AppModel.shutdown()`
    /// stops the scheduler on the way out, so clearing it here would erase the pause every time
    /// you quit — which is the whole thing #113 fixes.
    ///
    /// A scheduler that never started writes no `stopped` (#313): a second copy that quits at
    /// launch stops one, and its row would end the running copy's coverage. The loop runs while
    /// paused, so `loopTask` is the one fact that says this one ever watched.
    public func stop() {
        let ran = loopTask != nil
        loopTask?.cancel()
        loopTask = nil
        system.stop(owner: self)
        state = .stopped
        if ran { recordCoverage(.stopped) }
        Log.capture.info("capture scheduler stopped")
    }

    public func pause(for duration: TimeInterval?) {
        pause(until: duration.map { now().addingTimeInterval($0) })
    }

    /// The deadline form, so a pause restored from disk comes back with the *same* deadline
    /// rather than one recomputed from a launch that happened minutes later.
    public func pause(until deadline: Date?) {
        state = .paused(until: deadline)
        recordPause(until: deadline)
        recordCoverage(.paused, reason: .user)
        let seconds = deadline.map { Int($0.timeIntervalSince(now())) }
        Log.capture.info("capture paused\(seconds.map { " for \($0)s" } ?? " until resumed")")
    }

    public func resume() {
        guard case .paused = state else { return }
        state = .running
        forgetPauseRecord()
        recordCoverage(.resumed)
        Log.capture.info("capture resumed")
    }

    // MARK: A pause that outlives the process (#113)

    /// What the last run was paused until, in `app_state`. An empty value is "until you resume".
    /// Written by `pause(until:)`, removed by `resume()`, by `start()` and by the expiry inside
    /// `performTick` — the three ways a pause can end.
    public static let pausedUntilKey = "capture_paused_until"

    /// A pause found on disk at launch.
    public enum StoredPause: Equatable, Sendable {
        case untilResumed
        case until(Date)

        public var deadline: Date? {
            if case let .until(date) = self { return date }
            return nil
        }
    }

    /// The pause the last run left behind, or nil when there is none. A deadline that has already
    /// passed — or a value nothing can parse — is deleted here and answers nil, so the next launch
    /// simply captures.
    public static func storedPause(_ database: Database, now: Date = Date()) -> StoredPause? {
        let appState = AppStateStore(database)
        guard let raw = (try? appState.get(pausedUntilKey)) ?? nil else { return nil }
        if raw.isEmpty { return .untilResumed }
        guard let deadline = ISO8601DateFormatter().date(from: raw), deadline > now else {
            try? appState.delete(pausedUntilKey)
            return nil
        }
        return .until(deadline)
    }

    /// Starts the loop, then puts it straight back into whatever pause the last run left behind.
    /// The loop has to run for a *timed* pause to expire on its own, which is why this is not
    /// "set `.paused` and stay stopped".
    @discardableResult
    public func startRestoringPause() -> SchedulerState {
        // Read first: `start()` clears the record, so the order here is the whole trick.
        let stored = CaptureScheduler.storedPause(database, now: now())
        start()
        if let stored { pause(until: stored.deadline) }
        return state
    }

    private func recordPause(until deadline: Date?) {
        let value = deadline.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        try? AppStateStore(database).set(CaptureScheduler.pausedUntilKey, value)
    }

    private func forgetPauseRecord() {
        try? AppStateStore(database).delete(CaptureScheduler.pausedUntilKey)
    }

    // MARK: Coverage (#146)

    /// The last transition written, so a tick that keeps saying the same thing writes nothing.
    /// Read from the database once, in `restoreState()`, and kept in step from there.
    private var lastCoverage: CoverageEvent?

    /// Writes one transition, unless it says exactly what the previous one already said. The
    /// dedupe is what lets the permission path — which runs every five minutes for as long as the
    /// grant is missing — be recorded from the one place that notices it.
    private func recordCoverage(_ kind: CoverageKind, reason: CoverageReason? = nil, at: Date? = nil) {
        guard lastCoverage?.coverageKind != kind || lastCoverage?.coverageReason != reason else { return }
        let event = CoverageEvent(at: at ?? now(), kind: kind, reason: reason)
        do {
            try coverageEvents.insert(event)
            lastCoverage = event
        } catch {
            // A missed transition costs one footnote, never a frame: the loop goes on.
            Log.capture.warn("could not record a coverage transition: \(error)")
        }
    }

    /// A run that never wrote `stopped` — a crash, a force-quit, an update — ended somewhere, and
    /// the last frame it recorded is the only honest guess at where. Nothing is written when the
    /// last transition is already a `stopped`, or when there has never been one.
    private func closeUnfinishedRun() {
        guard let last = lastCoverage, last.opensGap != .notRunning else { return }
        let lastFrame = (try? database.latestCapture())?.capturedAt
        let ended = min(max(lastFrame ?? last.at, last.at), now())
        let event = CoverageEvent(at: ended, kind: .stopped)
        do {
            try coverageEvents.insert(event)
            lastCoverage = event
        } catch {
            Log.capture.warn("could not close the previous run's coverage: \(error)")
        }
    }

    /// Reads back what the last run left behind, so a restart does not duplicate an idle/lock row
    /// or reset the describe heartbeat.
    private func restoreState() {
        lastCoverage = (try? coverageEvents.latest()) ?? nil
        lastFingerprint = try? store.fetchLastFingerprint()
        lastAXTextHash = try? store.fetchLastAXTextHash()
        if let latest = try? database.latestCapture() {
            lastWrittenSkipReason = latest.skipReason
            lastContextSignature = latest.contextSignature
            // Which app was blocked matters as much as the fact that one was, or a restart
            // inside the same blocked stretch would write a second row for it.
            if latest.skipReason?.isBlocked == true { lastBlockedBundleID = latest.appBundleId }
            // Which app the restored text hash belongs to, or the first tick would read it as a
            // switch and throw it away — which is the one thing persisting it was meant to avoid.
            lastAXBundleID = latest.appBundleId
        }
        if let imaged = try? database.latestImagedCapture() {
            lastDescribedAt = imaged.capturedAt
            lastCaptureAt = imaged.capturedAt
        }
    }

    // MARK: Loop

    /// Interval jitter, so Worklens does not line up with every other periodic thing on the Mac.
    static let jitterFraction = 0.05

    /// The configured interval for right now, before `currentInterval`'s jitter — and after
    /// `PowerPolicy`, which stretches it while the Mac is on battery (#145).
    var baseInterval: TimeInterval {
        let configured = meeting.isInMeeting
            ? config.meetingCaptureIntervalSeconds
            : config.captureIntervalSeconds
        return Double(
            PowerPolicy.decide(
                power: power, mode: config.captureOnBattery, baseIntervalSeconds: configured
            ).captureIntervalSeconds
        )
    }

    func currentInterval() -> TimeInterval {
        let base = baseInterval
        let jitter = base * CaptureScheduler.jitterFraction
        return max(1, base + Double.random(in: -jitter...jitter))
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: .seconds(currentInterval()))
            } catch {
                return  // cancelled
            }
            guard !Task.isCancelled else { return }
            _ = await tick()
        }
    }

    private func scheduleWakeTick() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: .seconds(CaptureScheduler.wakeTickDelay))
            guard self.loopTask != nil else { return }
            _ = await self.tick()
        }
    }

    // MARK: Tick

    /// A tick that ignores pause and idle — what the menu's "capture now" does.
    @discardableResult
    public func captureNow() async -> TickResult {
        await tick(forced: true)
    }

    @discardableResult
    public func tick(forced: Bool = false) async -> TickResult {
        let started = now()
        do {
            let result = try await performTick(forced: forced, startedAt: started)
            lastTick = result
            onTick?(result)
            return result
        } catch {
            // One bad tick must never kill the loop; the next interval tries again.
            Log.capture.error("tick failed: \(error.localizedDescription)")
            let result = TickResult(
                captureId: nil, decision: .error, elapsedMs: elapsedMs(since: started)
            )
            lastTick = result
            onTick?(result)
            return result
        }
    }

    private func performTick(forced: Bool, startedAt: Date) async throws -> TickResult {
        // 1. Paused.
        if !forced, case let .paused(until) = state {
            if let until, until <= startedAt {
                state = .running
                forgetPauseRecord()
                recordCoverage(.resumed, at: until)
            } else {
                return TickResult(captureId: nil, decision: .paused, elapsedMs: elapsedMs(since: startedAt))
            }
        }

        // 2. Locked or asleep. Nothing on screen worth looking at, and the display may be off.
        if system.isLocked || system.isAsleep {
            state = system.isAsleep ? .asleep : .locked
            return try skipTick(
                reason: system.isAsleep ? .asleep : .locked, decision: .locked, isIdle: true,
                startedAt: startedAt
            )
        }

        // 3. Idle. `forced` skips this: an explicit "capture now" means the user is right here.
        if !forced, system.idleSeconds() >= Double(config.captureIdleSeconds) {
            state = .idle
            return try skipTick(reason: .idle, decision: .idle, isIdle: true, startedAt: startedAt)
        }

        // 4. Context — cheap, and needed even by the paths that never take a picture. #55: the
        // collector resolves the focused window on the way, and the walk below reuses it, so the
        // whole tick creates one application element and looks the focused window up once.
        let reading = context.collectWithHeader()
        let ctx = reading.context
        meeting.update(context: ctx)
        // Which reader answered, never what it said: a title or a URL is `.debug` at most, and
        // there is nothing about them worth saying even then.
        Log.capture.debug(
            "context sources: title=\(ctx.titleSource.rawValue) url=\(ctx.urlSource.rawValue)"
        )

        // The accessibility text hash is per-app: across a switch there is nothing to compare
        // against. Ahead of the blocklist on purpose, so switching *into* a blocked app still
        // turns the previous app's `AXEnhancedUserInterface` back off.
        if ctx.bundleID != lastAXBundleID {
            await forgetAXText(previousPid: axEnhancedPid)
            lastAXBundleID = ctx.bundleID
        }

        // 5. The privacy policy. The row keeps which app it was, and nothing else. It runs before
        // any accessibility walk, as #50 requires: a blocked app's tree is never read.
        if let reason = privacy.decision(for: ctx).skipReason {
            return try blockedTick(ctx, reason: reason, startedAt: startedAt)
        }

        // Two ticks inside half an interval are one tick: `SystemStateMonitor.onWake` schedules
        // one 10 s after wake while the loop's own sleep fires the moment the machine is back,
        // and outside a meeting nothing used to stop the pair (#63). `lastCaptureAt` moves on
        // every persisted row, text-only ones included, so this holds for every `CAPTURE_SOURCE`
        // mode. A forced tick — `captureNow` — is the user asking, and is never throttled.
        if !forced, let last = lastCaptureAt,
           startedAt.timeIntervalSince(last) < baseInterval * 0.5 {
            return TickResult(
                captureId: nil, decision: .tooSoon,
                elapsedMs: elapsedMs(since: startedAt), appName: ctx.appName
            )
        }

        // 6. The accessibility snapshot. `CAPTURE_SOURCE` (#54) decides what a tick collects:
        // `screenshot` never walks, `both` does both every tick, `accessibility` never
        // photographs, and `auto` — the interesting one — photographs only what the outline did
        // not cover.
        let source = config.captureSource
        // Started here rather than awaited here. For `screenshot`/`both` the walk's deadline
        // (`AX_WALK_TIMEOUT_MS`) and the capture's latency overlap instead of adding up, and the
        // snapshotter hops off the main actor itself, so the overlap is real. `auto` and
        // `accessibility` decide *from* the coverage, so they pay for the walk up front. The
        // header travels with it (#55): the walk reuses the window the collector already found.
        let axTask: Task<RedactedSnapshot?, Never>? = source == .screenshot
            ? nil
            : Task { [snapshotter, redactor, header = reading.header] in
                await CaptureScheduler.read(
                    snapshotter: snapshotter, redactor: redactor, pid: ctx.pid, header: header
                )
            }

        // The paths that bail before consuming the walk — a missing Screen Recording grant, a
        // capture that threw — should not leave one running for a frame nobody will write.
        // Cancelling one that has already been awaited is a no-op.
        defer { axTask?.cancel() }

        var ax: RedactedSnapshot?
        var axAwaited = false
        if source == .auto || source == .accessibility {
            ax = await axTask?.value
            axAwaited = true
            if let ax, ax.didSetEnhancedUserInterface { axEnhancedPid = ctx.pid }
        }
        // A thin tree that graded `.full` is demoted here, not in `Coverage.classify` — see
        // `DescribeDecision.trustedCoverage`.
        var axCoverage = ax.map { DescribeDecision.trustedCoverage($0.coverage, nodeCount: $0.nodeCount) }

        let takesScreenshot: Bool
        switch source {
        case .screenshot, .both: takesScreenshot = true
        case .accessibility: takesScreenshot = false
        // No grant, no snapshotter, a frozen app or a canvas all land here as "not `.full`", so
        // `auto` degrades into today's pipeline rather than into a blind one.
        case .auto: takesScreenshot = axCoverage != AXSnapshot.Coverage.full
        }

        let signatureChanged = ctx.signature != lastContextSignature
        let sinceDescribed = lastDescribedAt.map { startedAt.timeIntervalSince($0) }
        let heartbeat = Double(config.captureHeartbeatSeconds)
        // Nil is "no opinion": no snapshot at all, or a walk that found nothing to hash. A first
        // hash with nothing to compare against counts as changed — the frame is new to us.
        let previousHash = lastAXTextHash
        func textMoved(_ read: RedactedSnapshot?, _ grade: AXSnapshot.Coverage?) -> Bool? {
            read.flatMap { grade == AXSnapshot.Coverage.none ? nil : $0.textHash != previousHash }
        }

        // 7. The text-only path: no permission check, no picture, no fingerprint. Either `auto`
        // found the window fully covered, or `accessibility` was asked for and there is nothing
        // else to collect.
        if !takesScreenshot {
            guard let ax, let textChanged = textMoved(ax, axCoverage) else {
                // Only reachable under `accessibility`: `auto` would have taken a picture.
                return try noTextTick(ctx, startedAt: startedAt)
            }
            if state != .running {
                state = .running
                // #146: a no-op unless the last transition was a gap — which is how a restored
                // Screen Recording grant closes the span it opened.
                recordCoverage(.resumed, at: startedAt)
            }
            let needsDescribe = DescribeDecision.needsDescribeFromText(
                textChanged: textChanged,
                signatureChanged: signatureChanged,
                secondsSinceLastDescribed: sinceDescribed,
                heartbeat: heartbeat
            )
            return try await writeCapture(
                frame: nil, processed: nil, needsDescribe: needsDescribe, source: .accessibility,
                context: ctx, ax: ax, startedAt: startedAt
            )
        }

        // 8/9. Permission, then the screenshot itself.
        if let retryAfter = permissionRetryAfter, startedAt < retryAfter {
            return TickResult(captureId: nil, decision: .error, elapsedMs: elapsedMs(since: startedAt))
        }
        if await capture.permissionState() == .denied {
            return permissionMissingTick(startedAt: startedAt)
        }
        let frame: CapturedFrame
        do {
            frame = try await capture.capture()
        } catch CaptureError.permissionDenied {
            return permissionMissingTick(startedAt: startedAt)
        }
        permissionRetryAfter = nil
        if state != .running {
            state = .running
            recordCoverage(.resumed, at: startedAt)
        }

        // `both` and `screenshot` let the walk run alongside the capture, so its answer is
        // collected here; `auto` already has it and must not await the task twice.
        if !axAwaited {
            ax = await axTask?.value
            if let ax, ax.didSetEnhancedUserInterface { axEnhancedPid = ctx.pid }
            axCoverage = ax.map { DescribeDecision.trustedCoverage($0.coverage, nodeCount: $0.nodeCount) }
        }
        let coverage = axCoverage
        let textChanged = textMoved(ax, coverage)

        // 10. Downscale, fingerprint and (maybe) encode, off the main actor — this is the only
        // part of a tick heavy enough to be worth the hop.
        let maxEdge = config.captureMaxEdgePx
        let previous = lastFingerprint
        let threshold = config.changeThreshold

        let processed = await Task.detached(priority: .utility) { () -> ProcessedFrame in
            let small = ImagePipeline.downscale(frame.image, maxEdge: maxEdge)
            let fingerprint = ImagePipeline.fingerprint(small)
            let score = previous.map { ImagePipeline.changeScore($0, fingerprint) }

            // 11. The one decision that costs money.
            let needsDescribe = DescribeDecision.needsDescribe(
                changeScore: score,
                signatureChanged: signatureChanged,
                secondsSinceLastDescribed: sinceDescribed,
                threshold: threshold,
                heartbeat: heartbeat,
                textChanged: textChanged,
                coverage: coverage
            )
            return ProcessedFrame(
                fingerprint: fingerprint,
                changeScore: score,
                needsDescribe: needsDescribe,
                width: small.width,
                height: small.height,
                jpeg: needsDescribe ? ImagePipeline.jpegData(small) : nil
            )
        }.value

        return try await writeCapture(
            frame: frame, processed: processed, needsDescribe: processed.needsDescribe,
            // `both` whenever the window was walked as well; `screenshot` means the mode said so,
            // or there was no grant and no snapshotter to answer. A `.none` grade still counts as
            // a walk: it happened, the row records what it found, and that is what the coverage
            // numbers are made of.
            source: ax == nil ? .screenshot : .both,
            context: ctx, ax: ax, startedAt: startedAt
        )
    }

    // MARK: The accessibility read

    /// One tick's accessibility read, already redacted. The raw outline never leaves this type:
    /// `TextRedactor` runs on the same task that produced it, and `textHash` is the hash of the
    /// **redacted** text, so a stored outline and the hash beside it can never disagree.
    struct RedactedSnapshot: Sendable {
        let coverage: AXSnapshot.Coverage
        let nodeCount: Int
        let elapsedMs: Int
        let documentURL: String?
        /// The redacted outline; empty when the walk found nothing.
        let text: String
        let textHash: String
        let redactions: [TextRedactor.Kind: Int]
        let didSetEnhancedUserInterface: Bool
    }

    /// `nonisolated` and static so it carries nothing off the main actor but Sendable values.
    /// Nothing here is logged: window text is `.debug` at most, and there is nothing about it
    /// worth saying even then.
    private nonisolated static func read(
        snapshotter: (any AccessibilitySnapshotting)?,
        redactor: TextRedactor,
        pid: pid_t,
        header: AXHeader?
    ) async -> RedactedSnapshot? {
        guard let snapshotter,
              let snapshot = await snapshotter.snapshot(pid: pid, header: header)
        else { return nil }
        let redacted = redactor.redact(snapshot.text)
        return RedactedSnapshot(
            coverage: snapshot.coverage,
            nodeCount: snapshot.nodeCount,
            elapsedMs: snapshot.elapsedMs,
            documentURL: snapshot.documentURL,
            text: redacted.text,
            textHash: AXOutline.hash(redacted.text),
            redactions: redacted.counts,
            didSetEnhancedUserInterface: snapshot.didSetEnhancedUserInterface
        )
    }

    /// Forgets the text hash, and turns `AXEnhancedUserInterface` back off on the app it belonged
    /// to. Called when the frontmost bundle changes and on every continuity break.
    private func forgetAXText(previousPid: pid_t?) async {
        lastAXTextHash = nil
        try? store.deleteLastAXTextHash()
        if let previousPid, let snapshotter {
            await snapshotter.resetEnhancedUserInterface(pid: previousPid)
        }
        axEnhancedPid = nil
    }

    // MARK: Row writers

    private struct ProcessedFrame: Sendable {
        let fingerprint: FrameFingerprint
        let changeScore: Double?
        let needsDescribe: Bool
        let width: Int
        let height: Int
        let jpeg: Data?
    }

    /// Writes one frame's row, its outline and whatever the next tick compares against.
    ///
    /// `frame` and `processed` are nil for a text-only frame (#54): there are no pixels, so no
    /// display id, no dhash, no change score and no JPEG, and `image_path` stays NULL — which is
    /// all `DiskBudget` needs to see fewer files.
    private func writeCapture(
        frame: CapturedFrame?,
        processed: ProcessedFrame?,
        needsDescribe: Bool,
        source: CaptureSource,
        context ctx: ForegroundContext,
        ax: RedactedSnapshot?,
        startedAt: Date
    ) async throws -> TickResult {
        // The tick's own clock timestamps the row, not `frame.capturedAt`: skip rows and capture
        // rows then share one time source, so a day's rows are always ordered consistently. The
        // two differ by the capture latency, a couple of hundred milliseconds at most.
        var row = Capture(
            capturedAt: startedAt,
            displayId: frame.map { Int($0.displayID) },
            dhash: processed?.fingerprint.dhashHex,
            changeScore: processed?.changeScore,
            appBundleId: ctx.bundleID,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            browserUrl: ctx.browserURL,
            urlHost: ctx.urlHost,
            contextSignature: ctx.signature,
            captureSource: source,
            // #55: which reader answered, so the stored rows can say whether the AppleScript
            // probe and Screen Recording are still carrying any frames.
            titleSource: ctx.titleSource,
            urlSource: ctx.urlSource,
            isMeeting: meeting.isInMeeting,
            intervalSeconds: Int(baseInterval.rounded())
        )

        var savedImage = false
        if needsDescribe {
            // 12. The budget gate. Collecting is free; only the vision call is not, so an
            // over-budget frame is still stored — it just never gets sent.
            let overBudget = !(await costGate.allows(.describe))
            if let processed, let jpeg = processed.jpeg {
                let url = try ScreenshotPaths.url(for: row.capturedAt, id: row.id, dataDir: config.dataDir)
                try FilePermissions.writePrivate(jpeg, to: url)
                row.imagePath = ScreenshotPaths.relativePath(for: row.capturedAt, id: row.id)
                row.width = processed.width
                row.height = processed.height
                savedImage = true
            }

            if overBudget {
                row.describeStatus = .skipped
                row.skipReason = .budget
                state = .budgetExceeded
            } else {
                row.describeStatus = .pending
                lastDescribedAt = row.capturedAt
                if state == .budgetExceeded { state = .running }
            }
        } else {
            // The describe worker (#9) copies the previous description onto an inherited row, so
            // time accounting stays continuous without paying for a second look at the same screen.
            row.describeStatus = .inherited
            row.skipReason = .unchanged
        }

        try store.insert(row)

        // The outline is stored redacted, and only redacted: `ax.text` was put through
        // `TextRedactor` on the way out of the walk and the raw string is already gone.
        if let ax {
            try axSnapshots.insert(AXSnapshotRecord(
                captureId: row.id,
                coverage: ax.coverage,
                nodeCount: ax.nodeCount,
                textChars: ax.text.count,
                elapsedMs: ax.elapsedMs,
                textHash: ax.textHash,
                documentUrl: BrowserRegistry.storableDocumentURL(
                    ax.documentURL, bundleID: ctx.bundleID, collectBrowserURL: config.collectBrowserURL
                ),
                text: ax.text.isEmpty ? nil : ax.text,
                redactionsJson: AXSnapshotRecord.encodeRedactions(ax.redactions),
                createdAt: row.capturedAt
            ))
        }

        // 13. Persist what the next tick compares against. A text-only frame took no picture, so
        // the last fingerprint stays the last one that *was* taken: the pixel rule then means
        // "changed since the last photograph", which is the only thing it can honestly mean.
        if let processed {
            lastFingerprint = processed.fingerprint
            try? store.setLastFingerprint(processed.fingerprint)
        }
        lastContextSignature = ctx.signature
        // Only a walk that found something is worth remembering: the hash of an empty outline
        // would make the next empty tick look unchanged, and `.none` never consults it anyway.
        if let ax, ax.coverage != .none {
            lastAXTextHash = ax.textHash
            try? store.setLastAXTextHash(ax.textHash)
        }
        lastWrittenSkipReason = row.skipReason
        lastCaptureAt = row.capturedAt

        return TickResult(
            captureId: row.id,
            decision: decision(for: row, needsDescribe: needsDescribe),
            elapsedMs: elapsedMs(since: startedAt),
            changeScore: processed?.changeScore,
            savedImage: savedImage,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle
        )
    }

    private func decision(for row: Capture, needsDescribe: Bool) -> TickDecision {
        guard needsDescribe else { return .unchanged }
        return row.skipReason == .budget ? .budgetSkipped : .describedPending
    }

    /// One row per idle/lock period: the first tick of the period writes, the rest write nothing.
    private func skipTick(
        reason: SkipReason, decision: TickDecision, isIdle: Bool, startedAt: Date
    ) throws -> TickResult {
        guard lastWrittenSkipReason != reason else {
            return TickResult(captureId: nil, decision: decision, elapsedMs: elapsedMs(since: startedAt))
        }
        let row = Capture(
            capturedAt: startedAt,
            isIdle: isIdle,
            skipReason: reason,
            describeStatus: .skipped
        )
        try store.insert(row)
        lastWrittenSkipReason = reason
        forgetLastFrame()
        return TickResult(captureId: row.id, decision: decision, elapsedMs: elapsedMs(since: startedAt))
    }

    /// A blocked app is recorded, not hidden: which app keeps the timeline honest, while the
    /// title and URL — the parts that could carry a password or a private page — are dropped.
    private func blockedTick(
        _ ctx: ForegroundContext, reason: SkipReason, startedAt: Date
    ) throws -> TickResult {
        guard lastWrittenSkipReason != reason || ctx.bundleID != lastBlockedBundleID else {
            return TickResult(
                captureId: nil, decision: .blocked,
                elapsedMs: elapsedMs(since: startedAt), appName: ctx.appName
            )
        }
        let row = Capture(
            capturedAt: startedAt,
            appBundleId: ctx.bundleID,
            appName: ctx.appName,
            windowTitle: nil,
            browserUrl: nil,
            urlHost: nil,
            isRedacted: true,
            isMeeting: meeting.isInMeeting,
            intervalSeconds: Int(baseInterval.rounded()),
            skipReason: reason,
            describeStatus: .skipped
        )
        try store.insert(row)
        lastWrittenSkipReason = reason
        lastBlockedBundleID = ctx.bundleID
        forgetLastFrame()
        return TickResult(
            captureId: row.id, decision: .blocked,
            elapsedMs: elapsedMs(since: startedAt), appName: ctx.appName
        )
    }

    private var lastBlockedBundleID: String?

    /// `CAPTURE_SOURCE=accessibility` and this window exposed nothing to walk — a game, a VM, a
    /// canvas app, or no Accessibility grant at all (#54). The mode forbids the screenshot that
    /// would otherwise be the fallback, so the frame is recorded and left undescribed.
    ///
    /// One row per stretch, and a new one when the app changes: the same rule `blockedTick` uses,
    /// for the same reason — a morning in Figma should be one row, not four hundred.
    private func noTextTick(_ ctx: ForegroundContext, startedAt: Date) throws -> TickResult {
        guard lastWrittenSkipReason != .noText || ctx.bundleID != lastNoTextBundleID else {
            return TickResult(
                captureId: nil, decision: .noText,
                elapsedMs: elapsedMs(since: startedAt), appName: ctx.appName
            )
        }
        let row = Capture(
            capturedAt: startedAt,
            appBundleId: ctx.bundleID,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            browserUrl: ctx.browserURL,
            urlHost: ctx.urlHost,
            contextSignature: ctx.signature,
            captureSource: .accessibility,
            isMeeting: meeting.isInMeeting,
            intervalSeconds: Int(baseInterval.rounded()),
            skipReason: .noText,
            describeStatus: .skipped
        )
        try store.insert(row)
        lastWrittenSkipReason = .noText
        lastNoTextBundleID = ctx.bundleID
        // The app name only — never the title, which is `.debug` at most.
        Log.capture.info(
            "\(ctx.appName ?? "an app") exposes no window text and CAPTURE_SOURCE=accessibility; "
                + "the frame was recorded without a description"
        )
        return TickResult(
            captureId: row.id, decision: .noText,
            elapsedMs: elapsedMs(since: startedAt), appName: ctx.appName
        )
    }

    private var lastNoTextBundleID: String?

    /// A lock, an idle stretch or a blocked app breaks visual continuity: the next real frame
    /// should be described, not diffed against whatever was on screen before you left. The
    /// persisted copy goes too, or a restart would resurrect it across the gap.
    private func forgetLastFrame() {
        lastFingerprint = nil
        lastContextSignature = nil
        try? AppStateStore(database).delete(CaptureStore.lastFingerprintKey)
        // The text hash goes with it, for the same reason: after a lock or a blocked stretch the
        // next real frame should be described, not diffed against whatever was on screen before.
        lastAXTextHash = nil
        try? store.deleteLastAXTextHash()
    }

    private func permissionMissingTick(startedAt: Date) -> TickResult {
        state = .permissionMissing
        // #146: worse than a pause — this path writes no `captures` row at all, so without this
        // transition a revoked afternoon is indistinguishable from one spent away from the desk.
        recordCoverage(.paused, reason: .permissionMissing, at: startedAt)
        permissionRetryAfter = startedAt.addingTimeInterval(CaptureScheduler.permissionRetryInterval)
        Log.capture.warn("Screen Recording permission missing; retrying in 5 minutes")
        return TickResult(captureId: nil, decision: .error, elapsedMs: elapsedMs(since: startedAt))
    }

    private func elapsedMs(since start: Date) -> Int {
        Int(now().timeIntervalSince(start) * 1000)
    }
}
