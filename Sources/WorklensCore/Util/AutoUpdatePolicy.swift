import Foundation

/// The facts one auto-update poll gathers about the checkout, the remote and the running app.
/// Everything here is read-only and cheap; deciding what to do with it is `AutoUpdatePolicy`.
public struct AutoUpdateFacts: Equatable, Sendable {
    /// What `origin/main` points at, from `git ls-remote`. Nil when the remote could not be
    /// reached — offline, which is a normal state and not a problem to report.
    public var remoteCommit: String?
    /// The commit the *running* app was built from (`BuildStamp.commit`), falling back to the
    /// checkout's HEAD when the bundle carries no stamp.
    public var runningCommit: String?
    public var branch: String?
    /// The checkout has uncommitted changes, in which case `update.sh` would skip the pull and
    /// rebuild the working tree instead — see the loop `lastAttempted` also guards against.
    public var isDirty: Bool
    public var hasUpstream: Bool
    /// `sign.sh` would fall back to an ad-hoc signature, which macOS reads as a different app
    /// and answers with a revoked Screen Recording grant.
    public var signsAdHoc: Bool
    /// Worklens is in the middle of something the user started — a report, a sync, a
    /// configuration reload, an erase (#150). Restarting through any of them throws the work
    /// away, and through an erase it would leave the deletion half done.
    public var activityRunning: Bool
    /// The user paused capture. Quitting and relaunching would end the pause on the far side of
    /// the restart, which is the one thing the kill switch promises never happens (#113), so an
    /// unattended update waits — indefinitely, if the pause is indefinite.
    public var capturePaused: Bool
    /// The remote commit this process already handed to `update.sh`.
    public var lastAttempted: String?
    /// `update.sh` is still running: it builds for a minute or two before it quits the app, and
    /// main can move again inside that window. Two of them against one `.build` directory would
    /// be a mess neither could finish.
    public var updateInFlight: Bool

    public init(
        remoteCommit: String? = nil,
        runningCommit: String? = nil,
        branch: String? = nil,
        isDirty: Bool = false,
        hasUpstream: Bool = true,
        signsAdHoc: Bool = false,
        activityRunning: Bool = false,
        capturePaused: Bool = false,
        lastAttempted: String? = nil,
        updateInFlight: Bool = false
    ) {
        self.remoteCommit = remoteCommit
        self.runningCommit = runningCommit
        self.branch = branch
        self.isDirty = isDirty
        self.hasUpstream = hasUpstream
        self.signsAdHoc = signsAdHoc
        self.activityRunning = activityRunning
        self.capturePaused = capturePaused
        self.lastAttempted = lastAttempted
        self.updateInFlight = updateInFlight
    }
}

public enum AutoUpdateDecision: Equatable, Sendable {
    /// Run the update. The commit is remembered so the same one is never attempted twice.
    case update(commit: String)
    case upToDate
    /// Nothing to do right now and nothing to say: offline, mid-report, or already tried.
    case wait(String)
    /// Main has moved but this checkout cannot follow it without a person. Worth saying once.
    case blocked(String)
}

/// Whether an unattended pull-build-sign-relaunch is the right thing to do this minute.
///
/// Pure, and separated from the process-running in `AutoUpdater`, because every interesting case
/// here is a case you do not want to discover by having the app restart itself at the wrong
/// moment. The order matters: the cheap "nothing has changed" answers come before the reasons a
/// change could not be followed, so a checkout parked on a feature branch stays silent until
/// main actually moves.
public enum AutoUpdatePolicy {
    /// Below this the poll costs more than the answer is worth: `main` moves a few times a day.
    public static let minimumPollMinutes = 5

    public static func decide(_ facts: AutoUpdateFacts, mainBranch: String = "main") -> AutoUpdateDecision {
        guard let remote = facts.remoteCommit else { return .wait("origin is unreachable") }
        if let running = facts.runningCommit, running == remote { return .upToDate }
        if facts.lastAttempted == remote { return .wait("already attempted \(remote.prefix(7))") }
        if facts.updateInFlight { return .wait("an update is already running") }
        if facts.activityRunning { return .wait("Worklens is in the middle of something") }
        if facts.capturePaused { return .wait("capture is paused") }

        // Everything from here is a reason main moved and this Mac cannot follow it on its own.
        if let branch = facts.branch, branch != mainBranch {
            return .blocked("the checkout is on \(branch), not \(mainBranch)")
        }
        if facts.branch == nil { return .blocked("the checkout has no branch checked out") }
        if facts.isDirty { return .blocked("the checkout has uncommitted changes") }
        if !facts.hasUpstream { return .blocked("the checkout's branch has no upstream") }
        // Auto-updating into an ad-hoc signature would silently stop capture: the grant is tied
        // to the signature, and nothing would say so until a day came back empty.
        if facts.signsAdHoc {
            return .blocked("no \"Worklens Dev\" certificate: run `make dev-cert` once; "
                + "an update would reset Screen Recording")
        }
        return .update(commit: remote)
    }
}

/// What a *manual* check says (#153).
///
/// Settings → General → Updates' **Check now** asks the same question the poller asks and acts on
/// none of the answers: it is a question, and "Update and restart…" beside it is the answer. So
/// the decision is rendered as a sentence instead of being executed, and "offline" is a sentence
/// too — the poller stays silent about it because nobody asked, and here somebody did.
extension AutoUpdatePolicy {
    public static func manualCheckLine(
        _ facts: AutoUpdateFacts, mainBranch: String = "main"
    ) -> String {
        guard let remote = facts.remoteCommit else {
            return "Could not reach GitHub just now, so there is nothing to compare this build "
                + "against. Nothing was sent."
        }
        let short = String(remote.prefix(7))
        switch decide(facts, mainBranch: mainBranch) {
        case .upToDate:
            return "You are running the newest commit on \(mainBranch) (\(short))."
        case .update:
            return "\(mainBranch) has moved (\(short)). \"Update and restart…\" rebuilds this "
                + "checkout and relaunches Worklens."
        case let .blocked(reason), let .wait(reason):
            return "\(mainBranch) has moved (\(short)): \(reason)."
        }
    }
}
