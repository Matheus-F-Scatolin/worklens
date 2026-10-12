import Foundation
import Testing
@testable import WorklensCore

/// #156 — the clean-exit marker, and the one restart that must never look like a crash.
@Suite("Run markers")
struct RunMarkersTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("nothing recorded yet is a first run, not a crash")
    func firstRun() {
        #expect(RunMarkers.outcome(
            state: nil, startedAt: nil, expectedRestartAt: nil, now: now
        ) == .firstRun)
    }

    @Test("a marker left at clean is a clean quit")
    func clean() {
        #expect(RunMarkers.outcome(
            state: RunMarkers.cleanValue, startedAt: now, expectedRestartAt: nil, now: now
        ) == .clean)
    }

    @Test("a marker left at running with nobody claiming the restart is a crash")
    func unexpected() {
        let started = now.addingTimeInterval(-3600)
        #expect(RunMarkers.outcome(
            state: RunMarkers.runningValue, startedAt: started, expectedRestartAt: nil, now: now
        ) == .unexpected(startedAt: started))
    }

    /// The update path SIGTERMs the app, so the marker is still `running` — the difference is the
    /// claim `scripts/update.sh` records first. Without this the app's own unattended update
    /// would post a crash notice on a schedule.
    @Test("an update that claimed the restart is not a crash")
    func expectedRestart() {
        #expect(RunMarkers.outcome(
            state: RunMarkers.runningValue,
            startedAt: now.addingTimeInterval(-3600),
            expectedRestartAt: now.addingTimeInterval(-30),
            now: now
        ) == .expectedRestart)
    }

    @Test("a claim older than the window cannot excuse a later crash")
    func expiredClaim() {
        let started = now.addingTimeInterval(-7200)
        let stale = now.addingTimeInterval(-RunMarkers.expectedRestartWindow - 60)
        #expect(RunMarkers.outcome(
            state: RunMarkers.runningValue,
            startedAt: started,
            expectedRestartAt: stale,
            now: now
        ) == .unexpected(startedAt: started))
    }

    @Test("a launch reports the previous run, then claims this one")
    func roundTrip() throws {
        let db = try Database.inMemory()
        let markers = RunMarkers(AppStateStore(db))

        #expect(try markers.beginRun(now: now) == .firstRun)
        try markers.endRunCleanly()
        #expect(try markers.beginRun(now: now.addingTimeInterval(60)) == .clean)

        // No clean exit this time: the process was killed.
        #expect(try markers.beginRun(now: now.addingTimeInterval(120)).isUnexpected)
        // …and the second launch after that says nothing, because the first one already did.
        #expect(try markers.beginRun(now: now.addingTimeInterval(180)).isUnexpected == true)
    }

    @Test("a claimed restart is consumed by the launch that honours it")
    func claimIsConsumed() throws {
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        let markers = RunMarkers(store)

        _ = try markers.beginRun(now: now)
        try markers.expectRestart(now: now.addingTimeInterval(10))
        #expect(try markers.beginRun(now: now.addingTimeInterval(20)) == .expectedRestart)
        #expect(try store.get(RunMarkers.expectedRestartKey) == nil)

        // The next kill has no claim left to hide behind.
        #expect(try markers.beginRun(now: now.addingTimeInterval(30)).isUnexpected)
    }

    /// `worklens expect-restart` is the only thing a CLI run may write here: it must not touch
    /// the state marker, or a CLI subcommand would manufacture a crash out of a running app.
    @Test("claiming a restart leaves the run state alone")
    func claimDoesNotTouchState() throws {
        let db = try Database.inMemory()
        let store = AppStateStore(db)
        _ = try RunMarkers(store).beginRun(now: now)
        try RunMarkers(store).expectRestart(now: now)
        #expect(try store.get(RunMarkers.stateKey) == RunMarkers.runningValue)
    }

    @Test("the notice is one sentence, in the second person, and says what was left behind")
    func noticeCopy() {
        let message = RunOutcomeCopy.unexpectedExitNotice(
            startedAt: now.addingTimeInterval(-3600), now: now
        )
        #expect(message.hasPrefix("Worklens stopped without shutting down"))
        #expect(message.contains("pending"))
        #expect(message.contains("write-ahead log"))
        #expect(message.contains("1 hour ago"))
        // One sentence: no full stop before the end.
        #expect(message.filter { $0 == "." }.count == 1)
        #expect(!message.lowercased().contains("error occurred"))
    }

    @Test("the notice still reads when no start time was recorded")
    func noticeWithoutStart() {
        let message = RunOutcomeCopy.unexpectedExitNotice(startedAt: nil, now: now)
        #expect(!message.contains("that started"))
    }

    @Test("its button opens the log")
    func noticeButton() {
        #expect(NoticeAction.openLogFile.label.hasPrefix("Open the log"))
    }
}
