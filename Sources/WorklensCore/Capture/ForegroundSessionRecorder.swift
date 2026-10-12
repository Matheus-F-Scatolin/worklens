import AppKit
import Foundation

// MARK: - The activation source

/// The app the OS says is in front. An activation event carries a process, nothing more — no
/// window title, no URL — which is exactly why a session row can hold neither.
public struct ActivatedApp: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String? = nil, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Where foreground switches come from. A protocol so the recorder's tests can switch apps
/// without a desktop.
@MainActor
public protocol AppActivationObserving: AnyObject {
    /// Whatever is in front right now, or nil at the login window and during fast user switching.
    func frontmostApp() -> ActivatedApp?
    func start(onActivate: @escaping (ActivatedApp) -> Void)
    func stop()
}

/// The live source: `NSWorkspace.didActivateApplicationNotification`, which fires on every
/// foreground switch and needs no permission at all.
@MainActor
public final class WorkspaceActivationObserver: AppActivationObserving {
    private var token: NSObjectProtocol?

    public init() {}

    public func frontmostApp() -> ActivatedApp? {
        NSWorkspace.shared.frontmostApplication.map {
            ActivatedApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
    }

    public func start(onActivate: @escaping (ActivatedApp) -> Void) {
        guard token == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                onActivate(ActivatedApp(bundleID: app?.bundleIdentifier, name: app?.localizedName))
            }
        }
    }

    public func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}

// MARK: - The recorder

/// Exact foreground intervals, from the same OS signal Screen Time uses (#46).
///
/// Screenshots sample: a 40-second Slack check between two ticks simply does not exist, and a
/// two-minute switch counts as one minute or three depending on tick phase. An activation event
/// is not a sample, so `foreground_sessions` gets the switch instant to the second and the frames
/// are left doing the only thing they are good for — saying *what* the time was spent on.
///
/// One interval is open at a time. It closes on the next activation, on lock, on sleep, on pause,
/// on stop, and on idle; wake and unlock reopen it for whatever is in front, without waiting for
/// a capture tick.
///
/// Nothing here is logged above debug: a stream of "you switched to X at 14:03" at info level
/// would be a keystroke-grade record in a plaintext log file.
@MainActor
public final class ForegroundSessionRecorder {
    /// Idle is a poll, not a notification — there is no "the user stopped typing" event. Thirty
    /// seconds bounds how late an idle stretch is noticed; the interval is still closed at the
    /// *last input*, so the lag costs nothing in the numbers.
    public static let idlePollInterval: TimeInterval = 30

    private let store: ForegroundSessionStore
    private let database: Database
    private let activation: any AppActivationObserving
    private let system: any SystemStateProviding
    private let privacy: PrivacyPolicy
    private let idleThreshold: TimeInterval
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    /// The row currently open, mirrored in memory so an event does not have to read it back.
    private var open: ForegroundSession?
    private var pollTask: Task<Void, Never>?
    /// A reopen may never precede the close it follows, whatever the idle arithmetic says.
    private var lastCloseAt: Date?

    public private(set) var isRunning = false
    public private(set) var isPaused = false

    public init(
        config: Config,
        db: Database,
        activation: (any AppActivationObserving)? = nil,
        // Defaulted to nil rather than to a live monitor for the same reason the scheduler does
        // it: a default argument is evaluated at the call site, which is not the main actor.
        system: (any SystemStateProviding)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = db
        self.store = ForegroundSessionStore(db)
        self.activation = activation ?? WorkspaceActivationObserver()
        self.system = system ?? SystemStateMonitor()
        self.privacy = PrivacyPolicy(config: config)
        self.idleThreshold = Double(config.captureIdleSeconds)
        self.clock = clock
        self.now = now
    }

    // MARK: Lifecycle

    /// Closes whatever the last run left open, then starts recording from the app in front.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        closeStaleSession()

        activation.start { [weak self] app in self?.activated(app) }
        system.start(owner: self, handlers: SystemStateHandlers(
            onWake: { [weak self] in self?.woke() },
            onLock: { [weak self] in self?.closeOpen(at: self?.now() ?? Date()) },
            onSleep: { [weak self] in self?.closeOpen(at: self?.now() ?? Date()) }
        ))

        openFrontmost(at: now())
        startIdlePoll()
        Log.capture.debug("foreground session recorder started")
    }

    public func stop() {
        guard isRunning else { return }
        closeOpen(at: now())
        pollTask?.cancel()
        pollTask = nil
        activation.stop()
        system.stop(owner: self)
        isRunning = false
        isPaused = false
        Log.capture.debug("foreground session recorder stopped")
    }

    /// Paused records nothing at all — the promise `PRIVACY.md` makes. The open interval is
    /// closed at the moment of the pause rather than left hanging.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        closeOpen(at: now())
        Log.capture.debug("foreground session recorder paused")
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        guard isRunning else { return }
        openFrontmost(at: now())
        Log.capture.debug("foreground session recorder resumed")
    }

    // MARK: Events

    /// A foreground switch: the old interval ends and the new one begins at the same instant, so
    /// the day has neither a gap nor an overlap at the switch.
    func activated(_ app: ActivatedApp) {
        guard isRunning, !isPaused else { return }
        let at = now()
        guard !identity(of: app).matches(open) else { return }
        closeOpen(at: at)
        openInterval(app, at: at)
    }

    /// Wake or unlock. The frame after a wake arrives `CaptureScheduler.wakeTickDelay` late; the
    /// interval does not have to.
    func woke() {
        guard isRunning, !isPaused else { return }
        openFrontmost(at: now())
    }

    /// One idle check. Called by the poll loop; exposed for the tests, which have no wall clock.
    func pollIdle() {
        guard isRunning, !isPaused else { return }
        let idle = system.idleSeconds()
        if idle >= idleThreshold {
            // Close at the last input, not at the moment the poll noticed: the user stopped
            // working `idle` seconds ago, and up to `idlePollInterval` of that is poll lag.
            if open != nil { closeOpen(at: now().addingTimeInterval(-idle)) }
        } else if open == nil {
            // First input after an idle stretch. The last-input time is the best evidence there
            // is; the floor keeps a reopen from reaching back before the close.
            let at = max(lastCloseAt ?? .distantPast, now().addingTimeInterval(-idle))
            openFrontmost(at: at)
        }
    }

    private func startIdlePoll() {
        let clock = self.clock
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(ForegroundSessionRecorder.idlePollInterval))
                } catch {
                    return  // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                self.pollIdle()
            }
        }
    }

    // MARK: Intervals

    /// Every reason not to have an interval open, in one place.
    private var canRecord: Bool {
        isRunning && !isPaused && !system.isLocked && !system.isAsleep
            && system.idleSeconds() < idleThreshold
    }

    private func openFrontmost(at: Date) {
        guard let app = activation.frontmostApp() else { return }
        guard !identity(of: app).matches(open) else { return }
        closeOpen(at: at)
        openInterval(app, at: at)
    }

    private func openInterval(_ app: ActivatedApp, at: Date) {
        guard canRecord else { return }
        let identity = identity(of: app)
        // The bundle blocklist is the only one of the three that can apply: an activation event
        // carries no window title and no URL, and the row stores neither.
        let session = ForegroundSession(
            startAt: max(at, lastCloseAt ?? at),
            appBundleId: identity.bundleID,
            appName: identity.name,
            isBlocked: identity.isBlocked
        )
        do {
            try store.openInterval(session)
            open = session
        } catch {
            Log.capture.debug("could not open a foreground session: \(error)")
        }
    }

    private func closeOpen(at: Date) {
        guard let session = open else { return }
        let closedAt = max(session.startAt, min(at, now()))
        open = nil
        lastCloseAt = closedAt
        do {
            try store.close(id: session.id, at: closedAt)
        } catch {
            Log.capture.debug("could not close a foreground session: \(error)")
        }
    }

    /// A row left open by a crash or a kill is closed at the last thing that proves the machine
    /// was in use — the newest `captures.captured_at` — or at launch if that is earlier. Never at
    /// launch when there is older evidence: the hours the app was not running are not yours.
    private func closeStaleSession() {
        do {
            guard try store.openSession() != nil else { return }
            let launch = now()
            let evidence = (try? database.latestCapture())?.capturedAt
            let closedAt = min(evidence ?? launch, launch)
            let closed = try store.closeOpen(at: closedAt)
            lastCloseAt = closedAt
            Log.capture.debug("closed \(closed) stale foreground session(s)")
        } catch {
            Log.capture.debug("could not close stale foreground sessions: \(error)")
        }
    }

    // MARK: Identity

    /// What a row would record for this app, after the blocklist has had its say.
    private struct Identity {
        var bundleID: String?
        var name: String?
        var isBlocked: Bool

        /// True when `session` is already this app, so an activation for what is already in
        /// front does not split one interval into two.
        func matches(_ session: ForegroundSession?) -> Bool {
            guard let session else { return false }
            return session.appBundleId == bundleID && session.isBlocked == isBlocked
        }
    }

    private func identity(of app: ActivatedApp) -> Identity {
        let blocked = privacy
            .decision(bundleID: app.bundleID, windowTitle: nil, browserURL: nil)
            .isRedacted
        return Identity(
            bundleID: blocked ? nil : app.bundleID,
            name: blocked ? nil : app.name,
            isBlocked: blocked
        )
    }
}
