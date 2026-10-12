import Foundation
import Testing
@testable import WorklensCore

private let main = "aaaaaaaabbbbbbbbccccccccdddddddd11111111"
private let older = "9999999988888888777777776666666655555555"

@Suite("Auto-update policy")
struct AutoUpdatePolicyTests {
    private func facts(
        remote: String? = main,
        running: String? = older,
        branch: String? = "main",
        dirty: Bool = false,
        upstream: Bool = true,
        adHoc: Bool = false,
        report: Bool = false,
        paused: Bool = false,
        attempted: String? = nil,
        inFlight: Bool = false
    ) -> AutoUpdateFacts {
        AutoUpdateFacts(
            remoteCommit: remote,
            runningCommit: running,
            branch: branch,
            isDirty: dirty,
            hasUpstream: upstream,
            signsAdHoc: adHoc,
            activityRunning: report,
            capturePaused: paused,
            lastAttempted: attempted,
            updateInFlight: inFlight
        )
    }

    @Test("main moved and the checkout can follow it")
    func updates() {
        #expect(AutoUpdatePolicy.decide(facts()) == .update(commit: main))
    }

    @Test("running what main points at is the quiet case")
    func upToDate() {
        #expect(AutoUpdatePolicy.decide(facts(running: main)) == .upToDate)
        // Up to date wins over every reason an update could not have happened: a dirty checkout
        // that is already on the right commit has nothing to say.
        #expect(AutoUpdatePolicy.decide(facts(running: main, dirty: true, adHoc: true)) == .upToDate)
    }

    @Test("offline says nothing")
    func offline() {
        #expect(AutoUpdatePolicy.decide(facts(remote: nil)) == .wait("origin is unreachable"))
    }

    @Test("a commit is attempted once per launch, however it went")
    func attemptedOnce() {
        // The loop this prevents: update.sh skips the pull on a dirty tree but rebuilds anyway,
        // so HEAD never reaches the remote and every poll would restart the app again.
        guard case .wait = AutoUpdatePolicy.decide(facts(attempted: main)) else {
            return #expect(Bool(false), "an attempted commit must not be attempted again")
        }
    }

    @Test("main moving again mid-build does not start a second update")
    func updateInFlight() {
        // A newer commit than the one being built is exactly the case lastAttempted misses.
        let newer = "1111111122222222333333334444444455555555"
        guard case let .wait(reason) = AutoUpdatePolicy.decide(
            facts(remote: newer, attempted: main, inFlight: true)
        ) else {
            return #expect(Bool(false), "a second update.sh must not be started")
        }
        #expect(reason.contains("already running"))
    }

    @Test("a paused kill switch defers the update, however new the commit (#113)")
    func capturePausedWaits() {
        guard case let .wait(reason) = AutoUpdatePolicy.decide(facts(paused: true)) else {
            return #expect(Bool(false), "a paused capture should defer, not update")
        }
        #expect(reason.contains("paused"))
    }

    @Test("pausing does not invent work: the quiet answers still come first (#113)")
    func capturePausedYieldsToQuieterAnswers() {
        #expect(AutoUpdatePolicy.decide(facts(running: main, paused: true)) == .upToDate)
        #expect(
            AutoUpdatePolicy.decide(facts(paused: true, attempted: main))
                == .wait("already attempted \(main.prefix(7))")
        )
    }

    @Test("work in flight is worth waiting for, not blocking on")
    func reportRunning() {
        guard case let .wait(reason) = AutoUpdatePolicy.decide(facts(report: true)) else {
            return #expect(Bool(false), "a running report should defer, not block")
        }
        #expect(reason.contains("in the middle of"))
    }

    @Test("a checkout a person is using is left alone, and says why once")
    func blocked() {
        func reason(_ facts: AutoUpdateFacts) -> String? {
            guard case let .blocked(reason) = AutoUpdatePolicy.decide(facts) else { return nil }
            return reason
        }
        #expect(reason(facts(branch: "claude/issue-106"))?.contains("not main") == true)
        #expect(reason(facts(branch: nil))?.contains("no branch") == true)
        #expect(reason(facts(dirty: true))?.contains("uncommitted") == true)
        #expect(reason(facts(upstream: false))?.contains("upstream") == true)
        // The one with teeth: an ad-hoc signature reads to macOS as a different app, and the
        // Screen Recording grant goes with it — silently, which is the whole problem.
        #expect(reason(facts(adHoc: true))?.contains("Screen Recording") == true)
        // #115: and it names the one command that fixes it, rather than describing a certificate.
        #expect(reason(facts(adHoc: true))?.contains("make dev-cert") == true)
    }

    @Test("polling faster than the minimum is not a thing the app can be asked to do")
    func pollFloor() {
        #expect(AutoUpdatePolicy.minimumPollMinutes >= 5)
    }

    /// #153: **Check now** renders the same decision as a sentence and acts on none of it. The
    /// thing each case has to say is which of the two it is — "you are current" or "main moved,
    /// and here is why this Mac has not followed it".
    @Test("a manual check says what it found and starts nothing")
    func manualCheckLines() {
        #expect(
            AutoUpdatePolicy.manualCheckLine(facts(running: main)).contains("newest commit")
        )
        let moved = AutoUpdatePolicy.manualCheckLine(facts())
        #expect(moved.contains("main has moved"))
        #expect(moved.contains(String(main.prefix(7))))
        #expect(moved.contains("Update and restart"))
        // Offline is an answer here, where the poller stays silent about it: somebody asked.
        #expect(AutoUpdatePolicy.manualCheckLine(facts(remote: nil)).contains("Could not reach"))
        // A reason the update could not be taken is the reason, not an offer to take it.
        let blocked = AutoUpdatePolicy.manualCheckLine(facts(dirty: true))
        #expect(blocked.contains("uncommitted"))
        #expect(!blocked.contains("Update and restart"))
        // Work in flight is the poller's "wait", and it reads as a reason too rather than as
        // silence. #150 widened that reason past reports, so the sentence is the general one.
        #expect(
            AutoUpdatePolicy.manualCheckLine(facts(report: true)).contains("in the middle of")
        )
    }
}
