import Foundation
import WorklensCore

/// Watches `origin/main` and, when it moves, runs exactly what the menu's "Update and restart…"
/// item runs — pull, build, sign, relaunch.
///
/// This is not CI: a GitHub runner cannot reach this Mac, and the interesting half of the round
/// trip (the release build, the `Worklens Dev` signature, the relaunch) only means anything here.
/// So the app that is already running does the polling, and `scripts/update.sh` does the work it
/// has always done.
///
/// Three things keep an unattended update from being worse than no update:
///
/// * `AutoUpdatePolicy` refuses to touch a checkout that is dirty, on another branch, or without
///   the signing certificate — the last one because an ad-hoc signature reads to macOS as a new
///   app and silently loses Screen Recording.
/// * Every remote commit is attempted at most once per launch. `update.sh` skips the pull on a
///   dirty tree and rebuilds anyway, so a poller that only compared SHAs would restart the app
///   every interval forever; and a commit that fails to build should not be retried on a loop.
/// * `update.sh` builds before it quits the app, so a broken `main` costs nothing: the old build
///   keeps running and the log says why.
@MainActor
final class AutoUpdater {
    private let repo: URL
    private let interval: TimeInterval
    private weak var model: AppModel?
    private var task: Task<Void, Never>?

    /// The remote commit this process already handed to `update.sh`, successful or not.
    private var lastAttempted: String?
    /// The last reason reported, so a checkout that stays blocked says so once and then hushes.
    private var lastBlocked: String?
    /// When `update.sh` was last handed the job. It quits this app as soon as the build succeeds,
    /// so this only matters for the minutes before that — and for a build that failed, after
    /// which the grace expires and a *newer* commit gets its turn.
    private var updateStartedAt: Date?

    /// Waited out before the first poll: launch is busy enough, and a Mac that just woke may not
    /// have the network yet.
    nonisolated static let settleDelay: TimeInterval = 60
    /// How long a single git command gets before it is killed. Generous for `ls-remote`, short
    /// enough that a hung network cannot leave a child process around until the app quits.
    nonisolated static let gitTimeout: TimeInterval = 20
    /// How long after handing off to `update.sh` this counts as an update in flight. Longer than
    /// a release build, short enough that a failed one does not wedge the poller for the day.
    nonisolated static let updateGrace: TimeInterval = 15 * 60

    init(repo: URL, pollMinutes: Int, model: AppModel) {
        self.repo = repo
        self.interval = TimeInterval(max(pollMinutes, AutoUpdatePolicy.minimumPollMinutes) * 60)
        self.model = model
    }

    func start() {
        guard task == nil else { return }
        Log.ui.info("auto-update: watching origin/main every \(Int(interval / 60)) min")
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AutoUpdater.settleDelay))
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkNow()
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One poll: gather the facts off the main actor, then act on the decision.
    func checkNow() async {
        let repo = self.repo
        let running = BuildStamp.current.commit
        let attempted = lastAttempted
        let activityRunning = model?.state.isBusy == true
        // A paused kill switch outranks a new commit: the restart would come back capturing.
        var capturePaused = false
        if case .paused? = model?.state.scheduler { capturePaused = true }
        let inFlight = updateStartedAt.map {
            Date().timeIntervalSince($0) < AutoUpdater.updateGrace
        } ?? false

        let facts = await Task.detached(priority: .utility) {
            AutoUpdater.gatherFacts(
                repo: repo,
                runningCommit: running,
                activityRunning: activityRunning,
                capturePaused: capturePaused,
                lastAttempted: attempted,
                updateInFlight: inFlight
            )
        }.value

        switch AutoUpdatePolicy.decide(facts) {
        case .upToDate:
            lastBlocked = nil
            model?.updateAvailableLine = nil
        case let .wait(reason):
            Log.ui.debug("auto-update: waiting, \(reason)")
        case let .blocked(reason):
            let short = String(facts.remoteCommit?.prefix(7) ?? "main")
            model?.updateAvailableLine = AutoUpdatePolicy.blockedLine
            if lastBlocked != reason {
                lastBlocked = reason
                Log.ui.info("auto-update: not updating to \(short), \(reason)")
            }
        case let .update(commit):
            lastAttempted = commit
            lastBlocked = nil
            update(to: commit)
        }
    }

    private func update(to commit: String) {
        let short = String(commit.prefix(7))
        updateStartedAt = Date()
        Log.ui.info("auto-update: main moved to \(short), updating and restarting")
        model?.updateAvailableLine = "Updating…"
        // The app is about to quit and come back; a notification is the only part of this that
        // outlives the process and explains why the menu bar blinked.
        // #149: no branch name and no commit SHA in a banner — the SHA stays in the log line
        // above and in `updateAvailableLine`, where somebody who wants it is already looking.
        model?.postBanner(
            title: NotificationCopy.updatingTitle,
            body: NotificationCopy.updatingBody,
            identifier: "auto-update-\(short)"
        )
        model?.runUpdateScript(arguments: ["--log"], announce: false)
    }

    /// The read-only half, for Settings → General → Updates' **Check now** (#153): the same
    /// facts, gathered off the main actor, with nothing started on the strength of them.
    /// `AutoUpdatePolicy.manualCheckLine` turns them into the sentence the pane shows.
    ///
    /// The poller's own bookkeeping — what it last attempted, whether an update is in flight — is
    /// deliberately left out. Somebody clicking a button is asking what `main` points at now, not
    /// what this process has already tried; and there is no instance to ask when
    /// `AUTO_UPDATE_ENABLED` is false, which is exactly when the button matters most.
    nonisolated static func check(repo: URL, runningCommit: String?) async -> AutoUpdateFacts {
        await Task.detached(priority: .utility) {
            AutoUpdater.gatherFacts(
                repo: repo,
                runningCommit: runningCommit,
                activityRunning: false,
                capturePaused: false,
                lastAttempted: nil,
                updateInFlight: false
            )
        }.value
    }

    // MARK: - Reading the world

    /// Six short commands, once per interval. Runs off the main actor: `Process` blocks.
    private nonisolated static func gatherFacts(
        repo: URL,
        runningCommit: String?,
        activityRunning: Bool,
        capturePaused: Bool,
        lastAttempted: String?,
        updateInFlight: Bool
    ) -> AutoUpdateFacts {
        let head = git(["rev-parse", "HEAD"], in: repo)?.output
        let branch = git(["branch", "--show-current"], in: repo)?.output
        return AutoUpdateFacts(
            // `ls-remote` asks the remote without touching the checkout: no fetch, no index lock,
            // nothing to undo if the answer is "you are already there".
            remoteCommit: git(["ls-remote", "origin", "refs/heads/main"], in: repo)?
                .output.split(separator: "\t").first.map(String.init),
            // An unstamped bundle (`swift run`, or one built before stamping existed) has no
            // commit of its own; HEAD is the closest honest answer.
            runningCommit: runningCommit ?? head,
            // Empty means a detached HEAD, which `update.sh` could not pull onto anyway.
            branch: (branch?.isEmpty == false) ? branch : nil,
            isDirty: git(["status", "--porcelain"], in: repo)?.output.isEmpty == false,
            hasUpstream: git(["rev-parse", "--abbrev-ref", "@{u}"], in: repo) != nil,
            signsAdHoc: !SigningIdentity.hasIdentity(),
            activityRunning: activityRunning,
            capturePaused: capturePaused,
            lastAttempted: lastAttempted,
            updateInFlight: updateInFlight
        )
    }

    /// Runs one git command in `repo` and returns its trimmed stdout, or nil when it failed —
    /// which for `rev-parse @{u}` is itself the answer.
    private nonisolated static func git(
        _ arguments: [String], in repo: URL
    ) -> (output: String, status: Int32)? {
        run("/usr/bin/git", arguments, in: repo).flatMap { $0.status == 0 ? $0 : nil }
    }

    private nonisolated static func run(
        _ executable: String, _ arguments: [String], in directory: URL?
    ) -> (output: String, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }

        // LaunchServices hands a GUI app a minimal environment, so PATH is spelled out the way
        // update.sh spells it out. GIT_TERMINAL_PROMPT is the load-bearing one: without it a
        // credential prompt would leave git waiting for a terminal that does not exist until the
        // watchdog below kills it. GIT_OPTIONAL_LOCKS keeps `status` from fighting a build for
        // the index lock.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { "\($0):" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.ui.debug("auto-update: could not run \(executable): \(error.localizedDescription)")
            return nil
        }

        // Kill rather than wait forever. Terminating closes the pipe, so the read below returns.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + gitTimeout, execute: watchdog)
        // Safe to read to EOF before waiting: every command here prints one short line, far
        // inside the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, process.terminationStatus)
    }
}
