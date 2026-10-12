import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
private let day = "2026-09-07"
private let dayStart = DayBoundaries.range(day: day, timeZone: utc)!.start

// MARK: - MenuModel (pure)

@Suite("Menu model")
struct MenuModelTests {
    private func model(
        _ scheduler: SchedulerState,
        counts: MenuCounts = .zero,
        budget: Double = 1.5,
        interval: Int = 60,
        meeting: Bool = false,
        notices: [Notice] = [],
        describeHealth: DescribeHealth = .ok,
        busy: Bool = false,
        configError: String? = nil,
        configErrorDetails: [String] = [],
        storageError: String? = nil,
        configWarnings: [String] = [],
        accessibilityMissing: Bool = false,
        browsersMissingURLs: [String] = [],
        browsersNotAsked: [String] = [],
        screenRecordingEverGranted: Bool = false,
        accessibilityAdvisorySkipped: Bool = false,
        browserAdvisorySkipped: Bool = false,
        firstRun: Bool = false,
        now: Date = dayStart
    ) -> MenuModel {
        MenuModel(
            state: MenuState(
                scheduler: scheduler,
                captureIntervalSeconds: interval,
                meetingIntervalSeconds: 300,
                inMeeting: meeting,
                counts: counts,
                describeHealth: describeHealth,
                budgetUSD: budget,
                notices: notices,
                activities: busy
                    ? [Activity(id: "sync", kind: .sync, label: "Syncing integrations")] : [],
                configError: configError,
                configErrorDetails: configErrorDetails,
                storageError: storageError,
                configWarnings: configWarnings,
                accessibilityMissing: accessibilityMissing,
                browsersMissingURLs: browsersMissingURLs,
                browsersNotAsked: browsersNotAsked,
                screenRecordingEverGranted: screenRecordingEverGranted,
                accessibilityAdvisorySkipped: accessibilityAdvisorySkipped,
                browserAdvisorySkipped: browserAdvisorySkipped,
                firstRun: firstRun
            ),
            now: now,
            timeZone: utc
        )
    }

    @Test("each scheduler state gets its own icon and status line")
    func statesRender() {
        #expect(model(.running).icon == .capturing)
        #expect(model(.running).statusLine == "Capturing · every 60 s")
        #expect(model(.running).statusRow.glyph == .capturing)
        #expect(model(.paused(until: nil)).icon == .paused)
        #expect(model(.paused(until: nil)).statusLine == "Paused until you resume")
        #expect(model(.paused(until: nil)).statusRow.glyph == .paused)
        #expect(model(.idle).icon == .resting)
        #expect(model(.locked).icon == .resting)
        #expect(model(.asleep).icon == .resting)
        #expect(model(.permissionMissing).icon == .attention)
        #expect(model(.permissionMissing).statusLine.contains("Screen Recording"))
        #expect(model(.budgetExceeded).icon == .overBudget)
        #expect(model(.budgetExceeded).statusLine.contains("Budget reached"))
        #expect(model(.stopped).icon == .stopped)
        #expect(model(.stopped).statusLine == "Stopped")
        #expect(model(.stopped).statusRow.glyph == .stopped)
        // #114: the two that used to lie. Over budget is still capturing, so it must not look
        // like a healthy capture; stopped is not something the user chose, so it must not look
        // like a pause.
        #expect(model(.budgetExceeded).icon != model(.running).icon)
        #expect(model(.stopped).icon != model(.paused(until: nil)).icon)
    }

    @Test("#114: every icon draws a different shape, so no two states look alike")
    func iconsAreDistinct() {
        let badges = MenuIcon.allCases.map(\.badge)
        #expect(Set(badges).count == MenuIcon.allCases.count)
    }

    @Test("#114: work in flight is a treatment over the state, not a state of its own (#252)")
    func busyWhileWorking() {
        #expect(model(.running, busy: true).icon == .capturing)
        #expect(model(.running, busy: true).isBusy)
        #expect(model(.idle, busy: true).icon == .resting)
        #expect(model(.idle, busy: true).isBusy)
        // An unmet permission outranks the *state*: a sync must not hide the one thing to
        // act on. Busy is still true beside it.
        #expect(model(.permissionMissing, busy: true).icon == .attention)
        #expect(model(.running, busy: true, configError: "bad .env").icon == .attention)
    }

    @Test("a deadline pause names the local time it ends")
    func pausedUntil() {
        let until = dayStart.addingTimeInterval(15 * 3600 + 30 * 60)
        #expect(model(.paused(until: until)).statusLine == "Paused until 15:30")
    }

    @Test("a meeting shows the meeting cadence")
    func meetingCadence() {
        #expect(model(.running, meeting: true).statusLine == "Capturing · every 5 min (meeting)")
    }

    @Test("the counts line names only the numbers that are non-zero")
    func countsLine() {
        let quiet = MenuCounts(captures: 312, described: 143, spendUSD: 0.19)
        #expect(model(.running, counts: quiet).countsLine
            == "Today: 312 screenshots · 143 summarized · $0.19 of $1.50")

        let busy = MenuCounts(captures: 312, described: 143, pending: 4, skippedForBudget: 7, spendUSD: 0.19)
        #expect(model(.running, counts: busy).countsLine
            == "Today: 312 screenshots · 143 summarized · 4 waiting · 7 on hold · $0.19 of $1.50")

        // #125: failed frames are printed only when there are some. A "0 failed" on every
        // ordinary day teaches the eye to skip the one number that matters.
        let bad = MenuCounts(captures: 312, described: 140, pending: 4, failed: 3, spendUSD: 0.19)
        #expect(model(.running, counts: bad).countsLine
            == "Today: 312 screenshots · 140 summarized · 4 waiting · 3 failed · $0.19 of $1.50")

        let single = MenuCounts(captures: 1, described: 1)
        #expect(model(.running, counts: single).countsLine
            == "Today: 1 screenshot · 1 summarized · $0.00 of $1.50")
    }

    /// A menu item title cannot be coloured, so #17's 80 %/100 % lines say so in the text.
    @Test("the spend line marks the warning and over-budget lines")
    func spendMarkers() {
        let warning = MenuCounts(captures: 10, described: 10, spendUSD: 1.20)
        #expect(model(.running, counts: warning).spendLevel == .warning)
        #expect(model(.running, counts: warning).countsLine
            .contains("$1.20 of $1.50 (80 % of today's budget)"))
        #expect(model(.running, counts: warning).countsRow.glyph == .budget)

        let over = MenuCounts(captures: 10, described: 10, spendUSD: 1.60)
        #expect(model(.running, counts: over).spendLevel == .over)
        #expect(model(.running, counts: over).countsLine.contains("$1.60 of $1.50: over budget"))
        #expect(model(.running, counts: over).countsRow.glyph == .budget)
        #expect(model(.running, counts: over).countsRow.kind == .problem)

        // No budget set means no budget line and no marker.
        let unbudgeted = model(.running, counts: over, budget: 0)
        #expect(unbudgeted.spendLevel == .nominal)
        #expect(unbudgeted.countsLine.hasSuffix("· $1.60"))
    }

    @Test("sub-cent spend keeps four decimals")
    func moneyFormatting() {
        #expect(MenuModel.money(0) == "$0.00")
        #expect(MenuModel.money(0.0042) == "$0.0042")
        #expect(MenuModel.money(0.19) == "$0.19")
        #expect(MenuModel.money(12.5) == "$12.50")
    }

    @Test("cadence reads in seconds below two minutes and in minutes above")
    func cadence() {
        #expect(MenuModel.cadence(60) == "60 s")
        #expect(MenuModel.cadence(119) == "119 s")
        #expect(MenuModel.cadence(300) == "5 min")
        #expect(MenuModel.cadence(150) == "2.5 min")
    }

    /// The whole point of #110: what used to vanish at ten minutes now stays, because the
    /// condition it describes has not changed.
    @Test("a problem outlives the old ten-minute slot and goes when it is dismissed")
    func problemPersists() {
        let problem = Notice(kind: .problem, message: "Capture failed", at: dayStart)
        let eleven = dayStart.addingTimeInterval(11 * 60)
        #expect(model(.running, notices: [problem], now: eleven).problemLine == "Capture failed")
        #expect(model(.running, notices: [problem], now: eleven).problem?.id == problem.id)

        var dismissed = problem
        dismissed.dismissedAt = dayStart.addingTimeInterval(30)
        #expect(model(.running, notices: [dismissed], now: eleven).problemLine == nil)
        // And it stays gone on the next render, rather than reappearing with a new `now`.
        let muchLater = dayStart.addingTimeInterval(86_400)
        #expect(model(.running, notices: [dismissed], now: muchLater).problem == nil)
    }

    /// A bad morning must not push "Pause" off the bottom of the menu.
    @Test("the menu shows one problem, worst first")
    func problemCap() {
        let older = Notice(kind: .problem, message: "Sync failed", at: dayStart)
        let newer = Notice(kind: .problem, message: "Sync failed", at: dayStart.addingTimeInterval(60))
        let issue = Notice(.noGeminiKey, at: dayStart.addingTimeInterval(-3600))

        let ordinary = model(.running, notices: [older, newer], now: dayStart.addingTimeInterval(120))
        #expect(ordinary.problem?.message == "Sync failed")  // newest of equals

        // A condition that is still true outranks a one-off failure, however old it is.
        let withIssue = model(
            .running, notices: [older, newer, issue], now: dayStart.addingTimeInterval(120)
        )
        #expect(withIssue.problem?.issue == .noGeminiKey)
    }

    /// An `NSMenu` is as wide as its widest item, so a row quoting a transport error is a row
    /// that can stretch every other row past the edge of the screen.
    @Test("a row never gets wider than the menu, however long the words handed to it")
    func rowWidthIsBounded() throws {
        let dump = "Granola sync for 2026-09-15 failed: network error: Error "
            + "Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be "
            + "offline.\" UserInfo={_kCFStreamErrorCodeKey=-4, "
            + "NSErrorFailingURLStringKey=https://public-api.granola.ai/v1/notes, "
            + "_kCFStreamErrorDomainKey=1} (retrying at 08:35)"
        let problem = Notice(kind: .problem, message: dump, at: dayStart)
        let menu = model(.running, notices: [problem], now: dayStart)

        let line = try #require(menu.problemLine)
        #expect(line.count <= MenuRow.textLimit)
        #expect(line.count > MenuRow.textLimit - 8, "it trims to the limit, not well under it")
        // Both ends survive: which sync failed, and when it will try again.
        #expect(line.hasPrefix("Granola sync for 2026-09-15 failed: network error:"))
        #expect(line.hasSuffix("… (retrying at 08:35)"))
        // The notice itself is untouched: Settings → Activity has the whole sentence.
        #expect(menu.problem?.message == dump)

        // A line that fits is left exactly as it was written.
        let short = Notice(kind: .problem, message: "Capture failed", at: dayStart)
        #expect(model(.running, notices: [short], now: dayStart).problemLine == "Capture failed")

        // And the whole shape of it, for the sentence a dropped connection actually writes now.
        let offline = "Granola sync for 2026-09-15 failed: network error: "
            + "The Internet connection appears to be offline. (retrying at 08:35)"
        #expect(MenuRow.quoted(offline) == "Granola sync for 2026-09-15 failed: network error: "
            + "The Internet conne… (retrying at 08:35)")
    }

    /// The counts row is the one line that has to carry its own end — the spend — so it is held
    /// to a stop against a bug rather than to the width the prose rows are trimmed to.
    @Test("a tally keeps the spend on the end of it, where a quoted sentence is trimmed")
    func tallyKeepsItsEnd() {
        let counts = MenuCounts(
            captures: 300, described: 280, pending: 4, failed: 2, skippedForBudget: 3,
            blocked: 12, sensitive: 3, redactions: 7, spendUSD: 0.2, uncoveredSeconds: 7_800
        )
        let row = MenuModel.countsRow(counts, budget: 1.5, level: .nominal)
        #expect(row.text.count > MenuRow.textLimit, "a day with every tally on it is long")
        #expect(row.text.hasSuffix("$0.20 of $1.50"))
        #expect(row.text.count <= MenuRow.tallyLimit)
    }

    /// A menu item draws a two-line title as one line with the break swallowed, which runs the
    /// last word of one line into the first of the next.
    @Test("a row flattens newlines rather than running two words together")
    func rowFlattensNewlines() {
        let text = " could not read\nthe data folder "
        let row = MenuRow(kind: .problem, glyph: .warning, text: text)
        #expect(row.text == "could not read the data folder")
    }

    /// A sentence with nothing worth keeping on the end of it — no clause, no word boundary in
    /// reach — is trimmed from the end like any other.
    @Test("a middle trim falls back to the end when there is no last clause to keep")
    func middleTrimNeedsAClause() {
        let unbroken = String(repeating: "x", count: 200)
        let trimmed = MenuRow.quoted(unbroken)
        #expect(trimmed.count == MenuRow.textLimit)
        #expect(trimmed.hasSuffix("…"))
        #expect(!trimmed.contains("… "))
    }

    /// The stance at the top of `MenuModel`: a permission the user may never want to grant is not
    /// worth a permanent badge, but a key that is missing means nothing is being described.
    @Test("a blocking setup issue moves the icon; an advisory one does not")
    func setupIssueIcon() {
        let key = Notice(.noGeminiKey, at: dayStart)
        #expect(model(.running, notices: [key]).icon == .attention)
        #expect(model(.running, accessibilityMissing: true).icon == .capturing)
        #expect(model(.running, browsersMissingURLs: ["Safari"]).icon == .capturing)
        // Pause is the user's own decision and stays visible.
        #expect(model(.paused(until: nil), notices: [key]).icon == .paused)
        // A dismissed one is not open, so it does not hold the icon either.
        var dismissed = key
        dismissed.dismissedAt = dayStart
        #expect(model(.running, notices: [dismissed]).icon == .capturing)
    }

    @Test("the Pause submenu stays open while paused, so a pause can be extended (#136)")
    func pauseResume() {
        let running = model(.running)
        #expect(running.canPause && !running.canResume)

        // Both, deliberately: picking a duration from the submenu while paused replaces the
        // deadline, which is the only way to extend a pause without resuming first.
        let paused = model(.paused(until: nil))
        #expect(paused.canPause && paused.canResume)

        let stopped = model(.stopped)
        #expect(!stopped.canPause && !stopped.canResume)

        // Idle and locked are states the timer entered by itself; pausing out of them is fine.
        #expect(model(.idle).canPause)
    }

    @Test("the four pause choices, and the two that are a fixed length (#136)")
    func pauseChoices() {
        #expect(PauseChoice.allCases.map(\.label) == [
            "15 minutes", "1 hour", "Until tomorrow", "Until I resume",
        ])
        #expect(PauseChoice.fifteenMinutes.seconds == 900)
        #expect(PauseChoice.oneHour.seconds == 3600)
        #expect(PauseChoice.untilTomorrow.seconds == nil)
        #expect(PauseChoice.untilResumed.seconds == nil)
    }

    @Test("a midnight pause says \"until tomorrow\", not \"until 00:00\" (#136)")
    func midnightPauseWording() {
        let midnight = dayStart.addingTimeInterval(24 * 3600)
        #expect(model(.paused(until: midnight)).statusLine == "Paused until tomorrow")
        #expect(
            MenuModel.iconLabel(MenuState(scheduler: .paused(until: midnight)), timeZone: utc)
                == "Worklens, paused until tomorrow"
        )
        // An ordinary deadline still says the time.
        let tenish = dayStart.addingTimeInterval(10 * 3600 + 15 * 60)
        #expect(model(.paused(until: tenish)).statusLine == "Paused until 10:15")
    }

    // MARK: - #252: a menu bar that tells the truth

    @Test("a pause with an end does not draw the pause that has none")
    func timedPauseHasItsOwnIcon() {
        let inTwelve = dayStart.addingTimeInterval(12 * 60)
        #expect(model(.paused(until: nil)).icon == .paused)
        #expect(model(.paused(until: inTwelve)).icon == .pausedTimed)
        #expect(model(.paused(until: dayStart.addingTimeInterval(24 * 3600))).icon == .pausedTimed)
    }

    @Test("a short pause counts down; a long one keeps the clock (#252)")
    func shortPauseSaysWhatIsLeft() {
        #expect(model(.paused(until: dayStart.addingTimeInterval(12 * 60))).statusLine
            == "Paused · 12 minutes left")
        // Rounded up, so the last half-minute is never "0 minutes left".
        let tenAM = dayStart.addingTimeInterval(10 * 3600)
        #expect(model(.paused(until: tenAM.addingTimeInterval(30)), now: tenAM).statusLine
            == "Paused · 1 minute left")
        // An hour out, the time of day is the easier fact to hold.
        #expect(model(.paused(until: dayStart.addingTimeInterval(3 * 3600))).statusLine
            == "Paused until 03:00")
        #expect(model(.paused(until: nil)).statusLine == "Paused until you resume")
        #expect(model(.paused(until: dayStart.addingTimeInterval(24 * 3600))).statusLine
            == "Paused until tomorrow")
        // Spoken the same way.
        #expect(
            MenuModel.iconLabel(
                MenuState(scheduler: .paused(until: dayStart.addingTimeInterval(12 * 60))),
                now: dayStart, timeZone: utc
            ) == "Worklens, paused, 12 minutes left"
        )
    }

    @Test("the status item speaks its tally rather than reading a row of digits (#252)")
    func spokenTally() {
        var counts = MenuCounts.zero
        counts.captures = 212
        counts.described = 143
        counts.spendUSD = 0.19
        let spoken = model(.running, counts: counts).spokenTally
        #expect(spoken == "212 screenshots today, 143 summarized, $0.19 spent")
        // Written for speech: no interpunct, and no number left without the word for what it
        // counts — which is what `countsLine` hands VoiceOver today.
        #expect(!spoken.contains("·"))
        #expect(model(.running, counts: counts).countsLine.contains("·"))
        for (index, character) in spoken.enumerated() where character.isNumber {
            let next = spoken.index(spoken.startIndex, offsetBy: index + 1)
            #expect(next != spoken.endIndex, "the tally ends on a digit: \(spoken)")
            #expect(spoken[next] != ",", "a clause ends on a digit: \(spoken)")
        }
        #expect(model(.running).spokenTally == "Nothing recorded yet today")
    }

    @Test("a config error degrades the menu to the error and nothing else")
    func degraded() {
        let broken = model(.running, configError: "CAPTURE_INTERVAL_SECONDS: expected an integer")
        #expect(broken.isDegraded)
        #expect(broken.degraded == .configuration)
        #expect(broken.icon == .attention)
        #expect(broken.countsLine.contains("expected an integer"))
        #expect(!broken.canPause && !broken.canCaptureNow)
    }

    @Test("#126: a data-folder fault is its own degradation, with its own line")
    func storageDegraded() {
        let broken = model(
            .running,
            storageError: "Worklens could not open its data folder at /Volumes/gone/data"
        )
        #expect(broken.degraded == .storage)
        #expect(broken.statusLine == "Data folder problem")
        #expect(broken.statusRow.glyph == .warning)
        #expect(broken.countsLine.contains("/Volumes/gone/data"))
        #expect(!broken.canPause && !broken.canCaptureNow)
    }

    @Test("#126: storage wins over a config error, the folder is the thing in the way")
    func storageOutranksConfig() {
        let both = model(.running, configError: "LOG_LEVEL: expected one of debug, info", storageError: "no folder")
        #expect(both.degraded == .storage)
        #expect(both.countsLine == "no folder")
    }

    @Test("#126: a warning is advisory, it shows without degrading anything")
    func warningsDoNotDegrade() {
        let warned = model(
            .running,
            configWarnings: ["DESCRIBE_MODEL is set to \"gemini-9-flash\", which is not in the price table"]
        )
        #expect(!warned.isDegraded)
        #expect(warned.canPause && warned.canCaptureNow)
        #expect(warned.statusLine == "Capturing · every 60 s")
    }

    @Test("#116: a first run asks for keys once instead of warning about each of them")
    func firstRun() {
        // #239: the missing Gemini key is the one thing raised at launch.
        let keys = [Notice(.noGeminiKey, at: dayStart)]
        let fresh = model(.running, notices: keys, firstRun: true)
        #expect(fresh.firstRunLine == "Add your Gemini API key to get started")
        // The key warning says the same thing twice to someone who has not started yet.
        #expect(fresh.problemLine == nil)
        // #239: a setup step is not a fault, so the first icon a new install shows is the
        // ordinary capturing glyph, not an exclamation mark.
        #expect(fresh.icon != .attention)
        #expect(!fresh.isDegraded)
        #expect(fresh.canPause && fresh.canCaptureNow)

        // Every other problem is still the user's to see.
        let denied = model(
            .running, notices: keys + [Notice(.screenRecordingDenied, at: dayStart)], firstRun: true
        )
        #expect(denied.problem?.issue == .screenRecordingDenied)

        // Past the first run the key's warning comes back.
        let later = model(.running, notices: keys)
        #expect(later.firstRunLine == nil)
        #expect(later.problem?.issue == .noGeminiKey)

        // A broken .env is a configuration error, not an invitation to set one up.
        let broken = model(.running, configError: "bad .env", firstRun: true)
        #expect(broken.firstRunLine == nil)
    }

    /// The optional grants are offers in Settings → Permissions; capture keeps running on pixels,
    /// so nothing about the menu moves.
    @Test("a missing optional grant moves nothing in the menu")
    func optionalGrantsStayOutOfTheMenu() {
        let granted = model(.running)
        let missing = model(
            .running, accessibilityMissing: true,
            browsersMissingURLs: ["Safari"], browsersNotAsked: ["Google Chrome"]
        )
        #expect(missing.icon == .capturing)
        #expect(missing.statusLine == granted.statusLine)
        #expect(missing.problemLine == nil)
        #expect(missing.canPause && missing.canCaptureNow)
        #expect(!missing.isDegraded)
    }

    // MARK: - #117

    @Test("a missing grant offers one thing and disables the rest")
    func permissionMissingMode() {
        let missing = model(.permissionMissing)
        #expect(missing.permissionFixLine == "Screen Recording is not on yet: Fix…")
        // Nothing is being captured, so there is nothing to pause and nothing to capture now.
        #expect(!missing.canPause)
        #expect(!missing.canResume)
        #expect(!missing.canCaptureNow)
        // It is not a degraded menu: what was already captured is still there to read.
        #expect(!missing.isDegraded)
        #expect(missing.icon == .attention)
    }

    @Test("every other scheduler state offers no Fix line")
    func permissionFixLineOnlyWhenMissing() {
        for state in [SchedulerState.running, .idle, .locked, .asleep, .budgetExceeded, .stopped] {
            #expect(model(state).permissionFixLine == nil)
        }
        #expect(model(.paused(until: nil)).permissionFixLine == nil)
        // A broken .env outranks it, like every other line.
        #expect(model(.permissionMissing, configError: "bad .env").permissionFixLine == nil)
    }

    @Test("a Mac that was never asked is not told it lost anything")
    func twoWordings() {
        let never = model(.permissionMissing, screenRecordingEverGranted: false)
        let lost = model(.permissionMissing, screenRecordingEverGranted: true)
        #expect(never.permissionFixLine == "Screen Recording is not on yet: Fix…")
        #expect(lost.permissionFixLine == "Screen Recording is off: Fix…")
        #expect(never.permissionFixLine?.contains("lost") == false)

        // The same fork, in the sentences the notification and the problem row carry.
        #expect(ScreenRecordingCopy.problemMessage(everGranted: false).contains("not on yet"))
        #expect(ScreenRecordingCopy.problemMessage(everGranted: true).contains("lost"))
        #expect(!ScreenRecordingCopy.problemMessage(everGranted: false).contains("lost"))
        #expect(ScreenRecordingCopy.notificationTitle(everGranted: true).contains("lost"))
        #expect(!ScreenRecordingCopy.notificationTitle(everGranted: false).contains("lost"))
        #expect(ScreenRecordingCopy.notificationBody(everGranted: false).contains("turn it on"))
    }

    @Test("\"Capture now\" only claims a capture the tick actually made")
    func captureNowOnlyClaimsWhatHappened() {
        // The two that collected something: the menu's own "Captured this screen." is true.
        #expect(MenuModel.captureNowSkippedLine(.describedPending) == nil)
        #expect(MenuModel.captureNowSkippedLine(.budgetSkipped) == nil)
        // A forced tick still refuses, and every refusal has to say so rather than over-claim.
        for decision in TickDecision.allCases
        where decision != .describedPending && decision != .budgetSkipped {
            let line = MenuModel.captureNowSkippedLine(decision)
            #expect(line != nil)
            #expect(line?.contains("Captured this screen") == false)
        }
        #expect(MenuModel.captureNowSkippedLine(.blocked)?.contains("never-capture") == true)
    }

    @Test("a relaunch runs open only after this process is gone")
    func relaunchScript() {
        let script = RelaunchPlan.script(processID: 4242, bundlePath: "/Applications/Worklens.app")
        // The wait comes first: a copy launched while this one is alive would activate it and
        // exit again (SingleInstance), which is why NSWorkspace.openApplication is not what this
        // does. `kill -0` asks whether the pid still exists and sends nothing.
        #expect(script.hasPrefix("while kill -0 4242 2>/dev/null; do sleep 0.1; done;"))
        #expect(script.hasSuffix("open '/Applications/Worklens.app'"))
        // A pid, never the binary path: the path would appear in this helper's own command line,
        // and `pgrep -a -f` counts its ancestors, so the loop would match itself forever.
        #expect(!script.contains("pgrep"))
        #expect(!script.contains("Contents/MacOS"))
        // A folder may be called anything at all.
        #expect(RelaunchPlan.quote("/Users/me/Bob's Apps/Worklens.app")
            == "'/Users/me/Bob'\\''s Apps/Worklens.app'")
    }
}

// MARK: - MenuCounts (over a database)

@Suite("Menu counts")
struct MenuCountsTests {
    private func capture(
        minute: Double,
        status: DescribeStatus,
        skip: SkipReason? = nil,
        idle: Bool = false
    ) -> Capture {
        Capture(
            capturedAt: dayStart.addingTimeInterval(minute * 60),
            isIdle: idle,
            skipReason: skip,
            describeStatus: status
        )
    }

    @Test("counts group by describe status, and inherited frames count as described")
    func grouping() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        try store.insert(capture(minute: 1, status: .described))
        try store.insert(capture(minute: 2, status: .described))
        try store.insert(capture(minute: 3, status: .inherited, skip: .unchanged))
        try store.insert(capture(minute: 4, status: .pending))
        try store.insert(capture(minute: 5, status: .skipped, skip: .idle, idle: true))
        try store.insert(capture(minute: 6, status: .skipped, skip: .budget))
        try store.insert(capture(minute: 7, status: .failed))

        let counts = try MenuCounts.load(db: db, day: day, timeZone: utc)
        #expect(counts.captures == 7)
        #expect(counts.described == 3)
        #expect(counts.pending == 1)
        // #125: the count the menu prints only when it is not zero.
        #expect(counts.failed == 1)
        #expect(counts.skippedForBudget == 1)
        #expect(counts.spendUSD == 0)
    }

    @Test("only the asked-for day is counted, and its spend comes from llm_calls")
    func dayScoping() throws {
        let db = try Database.inMemory()
        try CaptureStore(db).insert(capture(minute: 60, status: .described))
        try CaptureStore(db).insert(Capture(
            capturedAt: dayStart.addingTimeInterval(-3600), describeStatus: .described
        ))
        let ledger = LLMCallStore(db)
        try ledger.insert(LLMCall(
            provider: "gemini", model: "m", purpose: .describe, costUsd: 0.02,
            createdAt: dayStart.addingTimeInterval(3600)
        ))
        try ledger.insert(LLMCall(
            provider: "gemini", model: "m", purpose: .describe, costUsd: 5,
            createdAt: dayStart.addingTimeInterval(-7200)
        ))

        let counts = try MenuCounts.load(db: db, day: day, timeZone: utc)
        #expect(counts.captures == 1)
        #expect(counts.described == 1)
        #expect(abs(counts.spendUSD - 0.02) < 1e-9)
    }

    @Test("a day that never happened is all zeroes")
    func emptyDay() throws {
        let db = try Database.inMemory()
        #expect(try MenuCounts.load(db: db, day: day, timeZone: utc) == .zero)
        #expect(try MenuCounts.load(db: db, day: "not-a-day", timeZone: utc) == .zero)
    }
}

// MARK: - Describe health (#125)

@Suite("Menu model: describe health")
struct MenuHealthRenderingTests {
    private func model(
        _ health: DescribeHealth,
        scheduler: SchedulerState = .running,
        notices: [Notice] = [],
        configError: String? = nil,
        busy: Bool = false
    ) -> MenuModel {
        MenuModel(
            state: MenuState(
                scheduler: scheduler,
                counts: MenuCounts(captures: 12, described: 4, pending: 8),
                describeHealth: health,
                budgetUSD: 1.5,
                notices: notices,
                activities: busy
                    ? [Activity(id: "sync", kind: .sync, label: "Syncing integrations")] : [],
                configError: configError
            ),
            now: dayStart,
            timeZone: utc
        )
    }

    @Test("a healthy queue says nothing at all")
    func okIsSilent() {
        let menu = model(.ok)
        #expect(menu.describeHealthLine == nil)
        #expect(menu.describeFixAction == nil)
        #expect(menu.icon == .capturing)
    }

    @Test("a rejected key names the cause, offers a fix and takes the green light away")
    func rejectedKey() {
        let menu = model(.failing(message: "Gemini rejected the key", httpStatus: 403))
        #expect(menu.describeHealthLine == "Not summarizing: Gemini rejected the key (HTTP 403)")
        #expect(menu.describeFixAction == .openAccountSettings)
        // The one thing #125 exists for: a wrong key can never look like a healthy day.
        #expect(menu.icon == .attention)
        #expect(menu.icon != .capturing)
    }

    @Test("a spent quota and a schema failure get their own sentences")
    func otherFailures() {
        #expect(model(.failing(message: "Gemini's quota is spent", httpStatus: 429)).describeHealthLine
            == "Not summarizing: Gemini's quota is spent (HTTP 429)")
        let schema = model(.failing(
            message: "Gemini's answers did not fit the schema", httpStatus: nil
        ))
        #expect(schema.describeHealthLine
            == "Not summarizing: Gemini's answers did not fit the schema")
        #expect(schema.icon == .attention)
    }

    /// #191: the sentence is right for all of these; the button was not. Opening the field where
    /// the API key is typed cannot help a provider that is having trouble or an answer that did
    /// not parse, and a button that cannot help is worse than no button.
    @Test("only a rejected key carries the fix action; every other failure keeps the line alone")
    func fixActionIsForKeyRejectionsOnly() {
        let rejected = model(.failing(message: "Gemini rejected the key", httpStatus: 403))
        #expect(rejected.describeFixAction == .openAccountSettings)
        #expect(rejected.describeHealthLine == "Not summarizing: Gemini rejected the key (HTTP 403)")

        let serverTrouble = model(.failing(message: "Gemini is having trouble", httpStatus: 503))
        #expect(serverTrouble.describeFixAction == nil)
        // Unchanged: what it says is still exactly right.
        #expect(serverTrouble.describeHealthLine
            == "Not summarizing: Gemini is having trouble (HTTP 503)")
        #expect(serverTrouble.icon == .attention)

        let schema = model(.failing(
            message: "Gemini's answers did not fit the schema", httpStatus: nil
        ))
        #expect(schema.describeFixAction == nil)
        #expect(schema.describeHealthLine
            == "Not summarizing: Gemini's answers did not fit the schema")
        #expect(schema.icon == .attention)

        // A spent quota is a refusal, but it is the plan's fault and not the key's.
        let quota = model(.failing(message: "Gemini's quota is spent", httpStatus: 429))
        #expect(quota.describeFixAction == nil)
        #expect(quota.describeHealthLine == "Not summarizing: Gemini's quota is spent (HTTP 429)")
    }

    /// #299: the menu's attention row falls back to this line when nothing else needs saying, so
    /// a stalled queue with no notice behind it still reaches the menu with its reason.
    @Test("a stalled queue with nothing else open still has a reason line")
    func degradedHealthStillHasAReason() {
        let menu = model(.failing(message: "Gemini is having trouble", httpStatus: 503))
        #expect(menu.problemLine == nil)
        #expect(menu.permissionFixLine == nil)
        #expect(menu.firstRunLine == nil)
        #expect(menu.setupLine == nil)
        #expect(menu.integrationAttentionLine == nil)
        #expect(menu.describeHealthLine == "Not summarizing: Gemini is having trouble (HTTP 503)")
        #expect(menu.icon == .attention)
    }

    @Test("a 401 offers the fix action too: it is the key the provider is refusing")
    func unauthorizedAlsoOffersTheFix() {
        let menu = model(.failing(message: "Gemini rejected the key", httpStatus: 401))
        #expect(menu.describeFixAction == .openAccountSettings)
    }

    @Test("a hold names the time it ends, and leaves the icon and the buttons alone")
    func holding() {
        let until = dayStart.addingTimeInterval(9 * 3600 + 5 * 60)
        let menu = model(.holding(until: until, reason: "Gemini is unreachable"))
        #expect(menu.describeHealthLine
            == "Not summarizing: Gemini is unreachable; trying again at 09:05")
        // Nothing to fix: it clears itself.
        #expect(menu.describeFixAction == nil)
        #expect(menu.icon == .capturing)
    }

    @Test("a paused capture keeps its own icon: a stall is not a fault the user caused")
    func pausedKeepsItsIcon() {
        let menu = model(
            .failing(message: "Gemini rejected the key", httpStatus: 403),
            scheduler: .paused(until: nil)
        )
        #expect(menu.icon == .paused)
        #expect(menu.describeHealthLine != nil)
    }

    @Test("work in flight does not hide a stall")
    func busyDoesNotHideIt() {
        let menu = model(
            .failing(message: "Gemini rejected the key", httpStatus: 403), busy: true
        )
        #expect(menu.icon == .attention)
    }

    @Test("the same sentence is one row, not two: a problem already saying it wins")
    func dedupedAgainstTheProblemRow() {
        let line = "Not summarizing: Gemini rejected the key (HTTP 403)"
        let menu = model(
            .failing(message: "Gemini rejected the key", httpStatus: 403),
            notices: [Notice(.keyRejected, message: line, at: dayStart)]
        )
        #expect(menu.problemLine == line)
        #expect(menu.describeHealthLine == nil)
        #expect(menu.describeFixAction == nil)
        // The problem row carries the same button, so nothing is lost with the line.
        #expect(menu.problem?.action == .openAccountSettings)
        #expect(menu.icon == .attention)
    }

    @Test("a different open problem does not swallow the health row")
    func otherProblemsDoNotDedupe() {
        let menu = model(
            .failing(message: "Gemini rejected the key", httpStatus: 403),
            notices: [Notice(.dataDirAnotherMac, at: dayStart)]
        )
        #expect(menu.describeHealthLine != nil)
    }

    @Test("a configuration error still replaces the whole menu")
    func degradedWins() {
        let menu = model(
            .failing(message: "Gemini rejected the key", httpStatus: 403),
            configError: "bad .env"
        )
        #expect(menu.describeHealthLine == nil)
        #expect(menu.describeFixAction == nil)
        #expect(menu.isDegraded)
    }
}

// MARK: - #132: typed symbols instead of emoji, and a name for VoiceOver

/// True for a scalar that a screen reader announces as a picture — "warning sign", "money with
/// wings" — rather than reading as part of a sentence. ASCII is excluded because `Character
/// .isEmoji` is true for digits and `#`, which are not what this is looking for.
private func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.isASCII { return false }
    // The three geometric glyphs the status line used as bullets. Not emoji by Unicode's
    // reckoning, exactly as wrong in a menu that now has a symbol field.
    if ["\u{25CF}", "\u{25CB}", "\u{23F8}"].contains(String(scalar)) { return true }
    return scalar.properties.isEmoji
}

@Suite("Menu symbols and VoiceOver (#132)")
struct MenuSymbolsTests {
    private let until = dayStart.addingTimeInterval(15 * 3600 + 30 * 60)

    private func state(
        _ scheduler: SchedulerState,
        counts: MenuCounts = MenuCounts(captures: 12, described: 10, pending: 1, failed: 1, spendUSD: 1.2),
        meeting: Bool = false,
        notices: [Notice] = [],
        describeHealth: DescribeHealth = .ok,
        configError: String? = nil,
        storageError: String? = nil
    ) -> MenuState {
        MenuState(
            scheduler: scheduler,
            captureIntervalSeconds: 60,
            meetingIntervalSeconds: 300,
            inMeeting: meeting,
            counts: counts,
            describeHealth: describeHealth,
            budgetUSD: 1.5,
            notices: notices,
            configError: configError,
            configErrorDetails: configError.map { [$0] } ?? [],
            storageError: storageError,
            configWarnings: ["DESCRIBE_MODEL is set to \"gemini-9-flash\", which is not in the price table"],
            accessibilityMissing: true,
            browsersMissingURLs: ["Safari"],
            browsersNotAsked: ["Google Chrome"]
        )
    }

    /// Every state the menu can be in, plus the two degraded ones and a stalled describe queue.
    private var everyState: [MenuState] {
        var all: [MenuState] = [
            state(.running),
            state(.running, meeting: true),
            state(.paused(until: nil)),
            state(.paused(until: until)),
            state(.idle),
            state(.locked),
            state(.asleep),
            state(.permissionMissing),
            state(.budgetExceeded),
            state(.stopped),
            state(.running, counts: MenuCounts(captures: 1, described: 1, spendUSD: 1.6)),
            state(.running, counts: .zero),
            state(.running, notices: [Notice(kind: .problem, message: "Capture failed", at: dayStart)]),
            state(.running, notices: [Notice(kind: .done, message: "Deleted 12 screenshots.", at: dayStart)]),
            state(.running, notices: [Notice(kind: .info, message: "Sync skipped", at: dayStart)]),
            state(.running, describeHealth: .failing(message: "Gemini rejected the key", httpStatus: 403)),
            state(.running, configError: "DAILY_BUDGET_USD is not a number"),
            state(.running, storageError: "Worklens could not open its data folder at /Volumes/gone/data"),
        ]
        all.append(contentsOf: [state(.running), state(.stopped)].map {
            var copy = $0
            copy.firstRun = true
            return copy
        })
        // #131: the welcome window's own line, at each count it can show.
        all.append(contentsOf: [0, 1, 3].map { done in
            var copy = state(.stopped)
            copy.setup = SetupProgress(
                screenRecording: done > 0,
                geminiKey: done > 1,
                onboardedAt: done > 2 ? dayStart : nil
            )
            return copy
        })
        return all
    }

    private func everySentence(_ menu: MenuModel) -> [String] {
        var said = [menu.statusLine, menu.countsLine, menu.iconLabel, menu.spokenTally]
        said.append(contentsOf: [
            menu.problemLine, menu.describeHealthLine, menu.permissionFixLine,
            menu.firstRunLine, menu.setupLine, menu.integrationAttentionLine,
        ].compactMap { $0 })
        return said
    }

    @Test("nothing the menu says contains an emoji or a bullet glyph")
    func noEmojiAnywhere() {
        var checked = 0
        for state in everyState {
            let menu = MenuModel(state: state, now: dayStart, timeZone: utc)
            for sentence in everySentence(menu) {
                checked += 1
                let offenders = sentence.unicodeScalars.filter(isPictograph)
                #expect(offenders.isEmpty, "\"\(sentence)\" still carries \(Array(offenders))")
            }
        }
        #expect(checked > everyState.count * 4)
    }

    @Test("each state's status row carries its own symbol, and the words stand without it")
    func statusRowsCarryGlyphs() {
        let rows: [(SchedulerState, StatusGlyph, String)] = [
            (.running, .capturing, "Capturing · every 60 s"),
            (.paused(until: nil), .paused, "Paused until you resume"),
            (.paused(until: until), .paused, "Paused until 15:30"),
            (.idle, .resting, "Idle · nothing to record"),
            (.locked, .locked, "Locked"),
            (.asleep, .resting, "Asleep"),
            (.permissionMissing, .warning, "Screen Recording permission needed"),
            (.budgetExceeded, .budget, "Budget reached: screenshots on hold"),
            (.stopped, .stopped, "Stopped"),
        ]
        for (scheduler, glyph, text) in rows {
            let row = MenuModel(state: state(scheduler), now: dayStart, timeZone: utc).statusRow
            #expect(row.glyph == glyph)
            #expect(row.text == text)
            // The whole point: the sentence says the state on its own, in case the menu draws
            // no image at all.
            #expect(!row.text.isEmpty)
        }
    }

    @Test("a symbol is an SF Symbol name and no two glyphs share one")
    func glyphsAreDistinctSymbols() {
        #expect(Set(StatusGlyph.allCases.map(\.symbol)).count == StatusGlyph.allCases.count)
        for glyph in StatusGlyph.allCases {
            #expect(glyph.symbol == glyph.rawValue)
            #expect(!glyph.symbol.isEmpty)
            #expect(glyph.symbol.unicodeScalars.allSatisfy { $0.isASCII })
            // SF Symbol names are dot-separated lower case; anything else is a typo.
            #expect(glyph.symbol.lowercased() == glyph.symbol)
        }
    }

    @Test("the budget warning says the share in words now that the marker is gone")
    func budgetWordsReplaceTheMarker() {
        let warning = MenuModel(
            state: state(.running, counts: MenuCounts(captures: 10, described: 10, spendUSD: 1.2)),
            now: dayStart, timeZone: utc
        )
        #expect(warning.spendLevel == .warning)
        #expect(warning.countsLine.hasSuffix("$1.20 of $1.50 (80 % of today's budget)"))

        let nearly = MenuModel(
            state: state(.running, counts: MenuCounts(captures: 10, described: 10, spendUSD: 1.49)),
            now: dayStart, timeZone: utc
        )
        // A cent short of the budget must not round up to a 100 % the `.over` wording owns.
        #expect(nearly.countsLine.hasSuffix("(99 % of today's budget)"))

        let over = MenuModel(
            state: state(.running, counts: MenuCounts(captures: 10, described: 10, spendUSD: 1.6)),
            now: dayStart, timeZone: utc
        )
        #expect(over.countsLine.hasSuffix("$1.60 of $1.50: over budget"))
        #expect(MenuModel.budgetPercent(1.2, budget: 1.5) == 80)
        #expect(MenuModel.budgetPercent(1.0, budget: 0) == 0)
    }

    @Test("the menu-bar item names the app and says what it is doing")
    func iconLabelSpeaks() {
        func label(_ scheduler: SchedulerState, meeting: Bool = false) -> String {
            MenuModel(state: state(scheduler, meeting: meeting), now: dayStart, timeZone: utc).iconLabel
        }
        #expect(label(.running) == "Worklens, capturing every 60 seconds")
        #expect(label(.running, meeting: true) == "Worklens, capturing every 5 minutes, meeting cadence")
        #expect(label(.paused(until: until)) == "Worklens, paused until 15:30")
        #expect(label(.paused(until: nil)) == "Worklens, paused until you resume")
        #expect(label(.permissionMissing) == "Worklens, Screen Recording permission needed")
        #expect(label(.budgetExceeded) == "Worklens, daily budget reached, screenshots on hold")
        #expect(label(.idle) == "Worklens, idle, nothing to record")
        #expect(label(.locked) == "Worklens, screen locked")
        #expect(label(.asleep) == "Worklens, asleep")
        #expect(label(.stopped) == "Worklens, stopped")

        let degraded = MenuModel(
            state: state(.running, configError: "DAILY_BUDGET_USD is not a number"),
            now: dayStart, timeZone: utc
        )
        #expect(degraded.iconLabel == "Worklens, configuration error")
        let storage = MenuModel(
            state: state(.running, storageError: "no such folder"), now: dayStart, timeZone: utc
        )
        #expect(storage.iconLabel == "Worklens, data folder problem")

        // Every one of them names the app first: it is the only thing on screen that says which
        // app this is.
        for scheduler in [SchedulerState.running, .idle, .stopped, .permissionMissing] {
            #expect(label(scheduler).hasPrefix("Worklens, "))
        }
    }

    @Test("the spoken cadence is words, not the menu's abbreviation")
    func spokenCadenceReads() {
        #expect(MenuModel.spokenCadence(60) == "every 60 seconds")
        #expect(MenuModel.spokenCadence(1) == "every 1 second")
        #expect(MenuModel.spokenCadence(300) == "every 5 minutes")
        #expect(MenuModel.spokenCadence(60 * 60) == "every 60 minutes")
        #expect(MenuModel.spokenCadence(150) == "every 2.5 minutes")
    }

    @Test("rows carry the kind that says what they are")
    func rowKinds() {
        let menu = MenuModel(state: state(.running), now: dayStart, timeZone: utc)
        #expect(menu.statusRow.kind == .status)

        var fresh = state(.running)
        fresh.firstRun = true
        let first = MenuModel(state: fresh, now: dayStart, timeZone: utc)
        #expect(first.firstRunRow?.kind == .advisory)
        #expect(first.firstRunRow?.glyph == .info)

        let broken = MenuModel(
            state: state(.running, configError: "DAILY_BUDGET_USD is not a number"),
            now: dayStart, timeZone: utc
        )
        #expect(broken.statusRow.kind == .problem)
        #expect(broken.countsRow.kind == .problem)
        #expect(broken.countsRow.glyph == .warning)
    }
}
