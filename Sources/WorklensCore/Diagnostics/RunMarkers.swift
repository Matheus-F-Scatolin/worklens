import Foundation

/// How the previous run of the menu-bar app ended (#156).
///
/// Before this there was no answer at all: a crash, a `kill -9`, a machine that lost power and a
/// clean Quit all left exactly the same trace, which is none.
public enum RunOutcome: Sendable, Equatable {
    /// Nothing has ever written a marker — a fresh install, or the first launch after this
    /// landed. Silence is right here: there is no previous run to report on.
    case firstRun
    /// `AppDelegate.applicationShouldTerminate` ran `shutdown()` to the end.
    case clean
    /// Something stopped the app on purpose without going through AppKit: `scripts/update.sh`
    /// quits with `pkill`, and since #106 that runs unattended. A planned restart is not a crash
    /// and must never be reported as one.
    case expectedRestart
    /// The marker still said "running" and nobody had claimed the restart.
    case unexpected(startedAt: Date?)

    public var isUnexpected: Bool {
        if case .unexpected = self { return true }
        return false
    }
}

/// The three `app_state` rows that make an unclean exit visible, and the rules around them.
///
/// **Only the menu-bar app writes `beginRun`/`endRunCleanly`.** The same binary is every
/// `worklens <subcommand>`, and they all open the same `app_state`: a `worklens search` that
/// cleared the marker and exited without setting it again would manufacture a crash out of a
/// working CLI. `AppModel` is the one caller, and it only exists inside the app.
///
/// `expectRestart` is the exception, and the one row a CLI run may write: `worklens
/// expect-restart` is what `scripts/update.sh` calls just before it SIGTERMs the app, so the
/// app's own update path — the most frequent restart on this machine — does not look like a
/// crash. The claim expires: a marker left behind by an update that failed half-way through must
/// not excuse a real crash three days later.
public struct RunMarkers: Sendable {
    /// `running` while the app is up, `clean` once `shutdown()` has finished.
    public static let stateKey = "run_state"
    /// When the run that wrote `stateKey` started, so the notice can say which one it means.
    public static let startedAtKey = "run_started_at"
    /// Written by whoever is about to stop the app on purpose.
    public static let expectedRestartKey = "expected_restart_at"

    public static let runningValue = "running"
    public static let cleanValue = "clean"

    /// How long a claimed restart stays believable. An update takes a minute; half an hour is
    /// generous and still short enough that a stale marker cannot hide tomorrow's crash.
    public static let expectedRestartWindow: TimeInterval = 30 * 60

    private let store: AppStateStore

    public init(_ store: AppStateStore) {
        self.store = store
    }

    /// Reads how the previous run ended, then marks this one as running. Both halves in one call
    /// because the read is only meaningful before the write.
    public func beginRun(now: Date = Date()) throws -> RunOutcome {
        let state = try store.get(RunMarkers.stateKey)
        let startedAt = try store.getDate(RunMarkers.startedAtKey)
        let claimed = try store.getDate(RunMarkers.expectedRestartKey)

        let outcome = RunMarkers.outcome(
            state: state, startedAt: startedAt, expectedRestartAt: claimed, now: now
        )

        try store.set(RunMarkers.stateKey, RunMarkers.runningValue)
        try store.setDate(RunMarkers.startedAtKey, now)
        // Honoured or expired, the restart marker has done its work; leaving it would excuse the
        // next crash too.
        if claimed != nil { try store.delete(RunMarkers.expectedRestartKey) }
        return outcome
    }

    /// Called at the end of `AppModel.shutdown()`, after the WAL checkpoint.
    public func endRunCleanly() throws {
        try store.set(RunMarkers.stateKey, RunMarkers.cleanValue)
    }

    /// "I am about to stop the app on purpose." Written by `worklens expect-restart`.
    public func expectRestart(now: Date = Date()) throws {
        try store.setDate(RunMarkers.expectedRestartKey, now)
    }

    /// The last outcome as it stands right now, without touching anything — what the diagnostics
    /// bundle reports.
    public func currentState() throws -> (state: String?, startedAt: Date?) {
        (try store.get(RunMarkers.stateKey), try store.getDate(RunMarkers.startedAtKey))
    }

    /// The decision itself, pure so all four branches are testable without a launch.
    public static func outcome(
        state: String?,
        startedAt: Date?,
        expectedRestartAt: Date?,
        now: Date
    ) -> RunOutcome {
        guard let state else { return .firstRun }
        if state == cleanValue { return .clean }
        if let expectedRestartAt,
           abs(now.timeIntervalSince(expectedRestartAt)) <= expectedRestartWindow {
            return .expectedRestart
        }
        return .unexpected(startedAt: startedAt)
    }
}

/// What the user reads when a run ended badly. One sentence, second person, no alarm, and
/// specific about what was actually lost rather than "an error occurred" (#156).
public enum RunOutcomeCopy {
    public static func unexpectedExitNotice(startedAt: Date?, now: Date = Date()) -> String {
        let when = startedAt.map { " that started \(BuildStamp.relative($0, now: now))" } ?? ""
        return "Worklens stopped without shutting down last time, so the run\(when) left the "
            + "frames it had not described yet still pending and its last writes to be recovered "
            + "from the write-ahead log: nothing was deleted, and the log says what it was doing."
    }
}
