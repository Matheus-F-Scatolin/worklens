import Foundation
import Testing

@testable import WorklensCore

private let now = Date(timeIntervalSince1970: 1_757_000_000)  // 2025-09-04T15:33:20Z

// MARK: - The launch gate (#131)

/// The two cases that cost somebody their running install if they are wrong. Everything the
/// welcome window does hangs off this decision, and the decision is made before any of it.
@Suite("Setup launch gate (#131)")
struct SetupGateTests {
    @Test("a Mac with nothing on it is shown the window")
    func freshInstall() {
        #expect(
            SetupGate.decide(
                onboardedAt: nil, hasCaptures: false, hasStartOnLaunchRow: false,
                databaseOpen: true
            ) == .show
        )
    }

    /// The whole point of the rule: the owner's own install, updating to the build that adds
    /// this window, must not be interrupted and must not stop capturing.
    @Test("an install that has captured anything is recorded as onboarded, silently")
    func existingInstallWithCaptures() {
        #expect(
            SetupGate.decide(
                onboardedAt: nil, hasCaptures: true, hasStartOnLaunchRow: false,
                databaseOpen: true
            ) == .recordSilently
        )
    }

    /// The second half of "existing install": somebody who turned capture off in Settings →
    /// General has no captures at all, and is just as clearly not a first run.
    @Test("an install that has a start_capturing_on_launch row is onboarded too")
    func existingInstallWithSettingsRow() {
        #expect(
            SetupGate.decide(
                onboardedAt: nil, hasCaptures: false, hasStartOnLaunchRow: true,
                databaseOpen: true
            ) == .recordSilently
        )
    }

    @Test("once onboarded_at is there, nothing happens again")
    func onboarded() {
        for captures in [false, true] {
            #expect(
                SetupGate.decide(
                    onboardedAt: now, hasCaptures: captures, hasStartOnLaunchRow: captures,
                    databaseOpen: true
                ) == .nothing
            )
        }
    }

    /// `state.configError != nil` leaves `db` nil: `onboarded_at` can be neither read nor
    /// written, and the two signals above are unknowable. The window is still shown.
    @Test("a launch with no database shows the window anyway")
    func noDatabase() {
        #expect(
            SetupGate.decide(
                onboardedAt: nil, hasCaptures: false, hasStartOnLaunchRow: false,
                databaseOpen: false
            ) == .show
        )
    }

    /// …and does not loop. A configuration reload runs the gate again; by then the date is in
    /// memory even though no database has accepted it yet, and that has to be enough.
    @Test("a welcome finished while the database was shut is not shown again")
    func noDatabaseButFinished() {
        #expect(
            SetupGate.decide(
                onboardedAt: now, hasCaptures: false, hasStartOnLaunchRow: false,
                databaseOpen: false
            ) == .nothing
        )
    }
}

// MARK: - Surviving the relaunch (#246)

/// The relaunch macOS forces for Screen Recording is on the happy path, and it used to cost the
/// user every page they had done. The whole of the new rule is `savedPage` reaching the two
/// branches that were already showing the window — so the thing worth nailing down is that it
/// reaches *only* those, for every combination of stored page, onboarded and grant.
@Suite("Setup resume (#246)")
struct SetupResumeTests {
    /// Every saved page × onboarded × screen recording. Onboarded wins over a stored page every
    /// time: an install that has finished the window is never shown it again, grant or no grant.
    @Test("a stored page is come back to on a launch that was going to show the window")
    func everyCombination() {
        for page in SetupPage.allCases {
            for onboarded in [false, true] {
                for screenRecording in [false, true] {
                    let decision = SetupGate.decide(
                        savedPage: page,
                        onboardedAt: onboarded ? now : nil,
                        hasCaptures: false,
                        hasStartOnLaunchRow: false,
                        databaseOpen: true
                    )
                    #expect(decision == (onboarded ? .nothing : .resume(page: page)))
                    // The line is a pure function of the grant and says the fact first.
                    let line = SetupGate.resumeLine(screenRecording: screenRecording)
                    #expect(line.hasPrefix("Screen Recording is"))
                    #expect(line.contains("Carry on") == screenRecording)
                }
            }
        }
    }

    /// No stored page is the sequence that has not been left yet: page one, as before.
    @Test("no stored page is still page one")
    func noStoredPage() {
        #expect(
            SetupGate.decide(
                savedPage: nil, onboardedAt: nil, hasCaptures: false,
                hasStartOnLaunchRow: false, databaseOpen: true
            ) == .show
        )
    }

    /// The two rules a resume must not be able to break: an existing install is never
    /// re-onboarded, and a launch with no database still explains itself.
    @Test("a stored page cannot re-onboard an existing install")
    func existingInstallIsUntouched() {
        for page in SetupPage.allCases {
            #expect(
                SetupGate.decide(
                    savedPage: page, onboardedAt: nil, hasCaptures: true,
                    hasStartOnLaunchRow: false, databaseOpen: true
                ) == .recordSilently
            )
            #expect(
                SetupGate.decide(
                    savedPage: page, onboardedAt: nil, hasCaptures: false,
                    hasStartOnLaunchRow: true, databaseOpen: true
                ) == .recordSilently
            )
            #expect(
                SetupGate.decide(
                    savedPage: page, onboardedAt: nil, hasCaptures: false,
                    hasStartOnLaunchRow: false, databaseOpen: false
                ) == .resume(page: page)
            )
        }
    }

    /// A page name, never a number: #131's five pages included `optionalPermissions`, which #232
    /// deleted. A stored `2` would now point at the keys; a stored name this build does not have
    /// starts the sequence again, which is the safe way to be wrong.
    @Test("a page name this build does not have falls back to page one")
    func unknownPageName() {
        #expect(SetupPage.stored("optionalPermissions") == nil)
        #expect(SetupPage.stored("2") == nil)
        #expect(SetupPage.stored("") == nil)
        #expect(SetupPage.stored(nil) == nil)
        for page in SetupPage.allCases {
            #expect(SetupPage.stored(page.rawValue) == page)
        }
        // #352 added a page; every name stored before it still comes back to the same page.
        #expect(SetupPage.stored("privacy") == .privacy)
        #expect(SetupPage.stored("screenRecording") == .screenRecording)
        #expect(SetupPage.stored("keys") == .keys)
        #expect(SetupPage.stored("ready") == .ready)
        #expect(SetupPage.stored("tour") == .tour)
        #expect(
            SetupGate.decide(
                savedPage: SetupPage.stored("optionalPermissions"),
                onboardedAt: nil, hasCaptures: false, hasStartOnLaunchRow: false,
                databaseOpen: true
            ) == .show
        )
    }

    /// The stored value is a page name and nothing about the person.
    @Test("nothing in a stored page is about what was on screen")
    func storedPageSaysNothingAboutTheUser() {
        for page in SetupPage.allCases {
            #expect(page.rawValue.range(of: "^[a-zA-Z]+$", options: .regularExpression) != nil)
        }
    }
}

/// The half of the gate that has to touch the database: "has this install ever captured
/// anything?" is an existence check and nothing more.
@Suite("Captures exist (#131)")
struct CaptureStoreHasAnyTests {
    @Test("hasAny is false on an empty database and true after one frame")
    func hasAny() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        #expect(try store.hasAny() == false)
        try store.insert(Capture(capturedAt: now, appName: "Slack", createdAt: now))
        #expect(try store.hasAny())
    }

    /// A row the scheduler wrote to say it captured *nothing* — paused, idle, blocked — is
    /// still a row, and still says this install was running before the welcome window existed.
    @Test("a skipped frame counts as much as a captured one")
    func skippedFrameCounts() throws {
        let db = try Database.inMemory()
        let store = CaptureStore(db)
        try store.insert(
            Capture(capturedAt: now, isIdle: true, skipReason: .idle, createdAt: now)
        )
        #expect(try store.hasAny())
    }
}

// MARK: - The four steps

@Suite("Setup progress (#131)")
struct SetupProgressTests {
    private func progress(
        screenRecording: Bool = false,
        gemini: Bool = false,
        onboardedAt: Date? = nil
    ) -> SetupProgress {
        SetupProgress(
            screenRecording: screenRecording, geminiKey: gemini, onboardedAt: onboardedAt
        )
    }

    @Test("the menu line counts the steps that are green")
    func menuLine() {
        #expect(progress().menuLine == "Finish setting up Worklens (0 of 3)")
        #expect(progress(screenRecording: true).menuLine == "Finish setting up Worklens (1 of 3)")
        #expect(
            progress(screenRecording: true, gemini: true).menuLine
                == "Finish setting up Worklens (2 of 3)"
        )
    }

    @Test("finishing the window is itself the third step, and ends the line")
    func onboardedIsTheLastStep() {
        let all = progress(screenRecording: true, gemini: true, onboardedAt: now)
        #expect(all.isDone(.welcome))
        #expect(all.isComplete)
        #expect(all.menuLine == nil)
        // An install that finished the window with a key still missing is not nagged with a
        // counter: it has been asked once, and the key's own problem row says the rest.
        let partial = progress(onboardedAt: now)
        #expect(partial.menuLine == nil)
        #expect(partial.remaining == [.screenRecording, .geminiKey])
    }
}

// MARK: - The pages

@Suite("Setup pages (#131)")
struct SetupPageTests {
    @Test("six pages, in the order the first five minutes happen in")
    func order() {
        #expect(SetupPage.allCases == [.appearance, .privacy, .tour, .screenRecording, .keys, .ready])
        #expect(SetupPage.count == 6)
        #expect(SetupPage.appearance.index == 1)
        #expect(SetupPage.privacy.index == 2)
        #expect(SetupPage.tour.index == 3)
        #expect(SetupPage.ready.index == 6)
    }

    @Test("stepping stops at both ends")
    func stepping() {
        #expect(SetupPage.appearance.previous == nil)
        #expect(SetupPage.appearance.next == .privacy)
        #expect(SetupPage.privacy.previous == .appearance)
        #expect(SetupPage.privacy.next == .tour)
        #expect(SetupPage.tour.next == .screenRecording)
        #expect(SetupPage.ready.next == nil)
        #expect(SetupPage.ready.previous == .keys)
    }

    @Test("every page says where it is and what it is for")
    func lines() {
        #expect(SetupPage.screenRecording.stepLine == "Step 4 of 6: Screen Recording")
        for page in SetupPage.allCases {
            #expect(!page.title.isEmpty)
            #expect(!page.summary.isEmpty)
        }
    }
}

// MARK: - Page 1 and PRIVACY.md

/// Page 1 is the promise the rest of the app keeps, so its words are `PRIVACY.md`'s words.
///
/// They cannot be *read* from `PRIVACY.md`: there are no SPM resources in this package and the
/// document is not inside the `.app`. So they are duplicated as Swift constants, and this is the
/// check that the duplicate has not drifted — the same source-scanning idiom as
/// `NetworkDestinationsDocTests` and `UserDocsTests`, and it stays offline.
@Suite("Setup copy against PRIVACY.md (#131)")
struct SetupCopyTests {
    /// `Tests/WorklensCoreTests/<this file>` → the checkout.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Markdown emphasis, code ticks and where the line happened to wrap are formatting, not
    /// wording: a sentence split across two lines of the document is the same sentence.
    static func normalized(_ text: String) -> String {
        let bare = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        return bare.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    @Test("every sentence page 1 shows still appears in PRIVACY.md")
    func constantsStillAppearInPrivacyMd() throws {
        let url = SetupCopyTests.repoRoot.appendingPathComponent("PRIVACY.md")
        let document = SetupCopyTests.normalized(try String(contentsOf: url, encoding: .utf8))
        #expect(!SetupCopy.Privacy.all.isEmpty)
        for sentence in SetupCopy.Privacy.all {
            #expect(
                document.contains(SetupCopyTests.normalized(sentence)),
                "PRIVACY.md no longer says \"\(sentence)\": change both, or change neither"
            )
        }
    }

    /// The cross-reference the correction asks for, in both directions: this file names
    /// `PRIVACY.md`, and `PRIVACY.md` names this file.
    @Test("both files name the other")
    func crossReferences() throws {
        let privacy = try String(
            contentsOf: SetupCopyTests.repoRoot.appendingPathComponent("PRIVACY.md"),
            encoding: .utf8
        )
        #expect(privacy.contains("SetupCopy.swift"))
        let copy = try String(
            contentsOf: SetupCopyTests.repoRoot
                .appendingPathComponent("Sources/WorklensCore/UI/SetupCopy.swift"),
            encoding: .utf8
        )
        #expect(copy.contains("PRIVACY.md"))
    }

    @Test("nothing the window says carries an emoji")
    func noEmoji() {
        var sentences = SetupCopy.Privacy.all
        sentences.append(contentsOf: [
            SetupCopy.windowTitle, SetupCopy.menuItem, SetupCopy.settingsButton,
            SetupCopy.startLabel, SetupCopy.doneLabel, SetupCopy.nothingCapturedYet,
            SetupCopy.screenRecordingWhy, SetupCopy.screenRecordingRelaunch,
            SetupCopy.screenRecordingGranted, SetupCopy.screenRecordingSkip,
            SetupCopy.keysWhy, SetupCopy.keysLater,
            SetupCopy.geminiHeading, SetupCopy.geminiRequired, SetupCopy.geminiWhy,
            SetupCopy.geminiCost, SetupCopy.geminiLinkLabel,
            SetupCopy.readyCapturing, SetupCopy.readyStartsOnClose,
            SetupCopy.readyClaudeHeading, SetupCopy.readyClaudeBody,
            SetupCopy.readyReaderHeading, SetupCopy.readyReaderBody, SetupCopy.readyReaderButton,
            SetupCopy.readyPermissionsFooter,
            SetupCopy.startWithoutScreenRecording,
            SetupCopy.Privacy.footer,
            SetupCopy.tourWhy, SetupCopy.tourComesBack, SetupCopy.tourTake,
        ])
        sentences.append(contentsOf: SetupCopy.Welcome.lines)
        sentences.append(
            contentsOf: [SetupCopy.Welcome.privacyLink, SetupCopy.Welcome.fullDetail]
        )
        sentences.append(contentsOf: SetupPage.allCases.flatMap { [$0.title, $0.summary] })
        sentences.append(contentsOf: SetupStep.allCases.map(\.label))
        for sentence in sentences {
            // `⌥⇧P` and the arrows are typography, not pictographs: `properties.isEmoji` is
            // false for them, which is exactly the line #132's menu assertion draws.
            let offenders = sentence.unicodeScalars.filter {
                !$0.isASCII && $0.properties.isEmoji
            }
            #expect(offenders.isEmpty, "\"\(sentence)\" carries \(Array(offenders))")
        }
    }

    /// Page 1 has four bulleted lists and no table. The wording it shares with `PRIVACY.md`
    /// must therefore stand on its own: "this table is the whole list" introduces the
    /// destinations table *there*, and points at nothing here.
    @Test("nothing page 1 says points at a table the window does not show")
    func privacyCopyHasNoDanglingTable() {
        for sentence in SetupCopy.Privacy.all {
            #expect(
                !sentence.lowercased().contains("this table"),
                "\"\(sentence)\" refers to a table, and the welcome window has none"
            )
        }
    }

    /// The menu keeps its own "Start capturing" while this window is open, so the standing
    /// promise in the footer has to stay true after somebody presses it.
    @Test("the standing promise is about what Worklens does on its own")
    func nothingCapturedYetSurvivesAStartFromTheMenu() {
        let lowered = SetupCopy.nothingCapturedYet.lowercased()
        #expect(SetupCopy.nothingCapturedYet.contains(SetupCopy.startLabel))
        #expect(lowered.contains("on its own"))
        #expect(!lowered.contains("nothing is captured"))
    }

    /// #246: the launch gate resumes on the stored page, so page 2's note now promises the
    /// page — and must not still promise page one, which is what it said while it could not.
    @Test("the relaunch note promises the page back")
    func relaunchCopyMatchesWhatTheGateDoes() {
        let lowered = SetupCopy.screenRecordingRelaunch.lowercased()
        #expect(lowered.contains("comes back to this page"))
        #expect(!lowered.contains("first page"))
    }
}

// MARK: - What the menu does with it

@Suite("Setup in the menu (#131)")
struct SetupMenuTests {
    private func state(_ setup: SetupProgress?, firstRun: Bool = false) -> MenuState {
        MenuState(
            scheduler: .running,
            accessibilityMissing: true,
            browsersMissingURLs: ["Safari"],
            browsersNotAsked: ["Google Chrome"],
            firstRun: firstRun,
            setup: setup
        )
    }

    @Test("the unfinished welcome is one row, and it replaces the first-run line")
    func setupRow() {
        let setup = SetupProgress(screenRecording: true)
        let menu = MenuModel(state: state(setup, firstRun: true), now: now)
        #expect(menu.setupLine == "Finish setting up Worklens (1 of 3)")
        #expect(menu.setupRow?.kind == .advisory)
        #expect(menu.setupRow?.glyph == .info)
        #expect(menu.firstRunLine == nil)
    }

    @Test("once the welcome is finished the menu says nothing about setup")
    func onboardedIsQuiet() {
        let menu = MenuModel(
            state: state(SetupProgress(onboardedAt: now), firstRun: true), now: now
        )
        #expect(menu.setupLine == nil)
        #expect(menu.setupRow == nil)
        // And the line it stood in for comes back.
        #expect(menu.firstRunLine == MenuModel.firstRunText)
    }

    /// Nothing about setup reaches a menu that is already a remedy for a broken `.env`.
    @Test("a degraded menu says nothing about setup")
    func degraded() {
        var broken = state(SetupProgress())
        broken.configError = "bad .env"
        #expect(MenuModel(state: broken, now: now).setupLine == nil)
    }
}
