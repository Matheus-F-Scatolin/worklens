import Foundation

/// Every sentence the welcome window says (#131), in the target that has tests.
///
/// `SetupCopy.Privacy` is the part that matters most: page 1 tells the user what Worklens
/// records **before** a single frame is captured, and those sentences are the ones in
/// `PRIVACY.md` rather than a second set that can drift away from it. There is no SPM resource
/// bundle in this package (`Bundle.module` is unreliable in a hand-built `.app`, see
/// `CONTRIBUTING.md`) and `PRIVACY.md` is not shipped inside the bundle, so the document cannot
/// be read at runtime — the wording is duplicated here deliberately, and
/// `SetupCopyTests.constantsStillAppearInPrivacyMd` fails the build if a sentence here stops
/// appearing in `PRIVACY.md`.
///
/// **If you change a string under `Privacy`, change `PRIVACY.md` with it** — sections
/// "What leaves your machine", "What it records" and "What it never records", which carry a
/// comment pointing back at this file.
public enum SetupCopy {
    /// The window's title, and the id of its scene. The title doubles as the Settings button's
    /// subject ("Show welcome again") and as what the System Events check reads back.
    public static let windowTitle = L10n.string("Welcome to Worklens")

    /// The menu item that re-opens the window, and the Settings → General button.
    public static let menuItem = L10n.string("Set up Worklens\u{2026}")
    public static let settingsButton = L10n.string("Show welcome again")

    public static let backLabel = L10n.string("Back")
    public static let continueLabel = L10n.string("Continue")
    public static let skipLabel = L10n.string("Skip")
    /// The last button of the last page: the only thing in the whole sequence that starts
    /// capture, and the thing that writes `onboarded_at`.
    public static let startLabel = L10n.string("Start capturing")
    /// The last page's primary button. Finishing the window is what starts capture now (#232),
    /// so the word is about this window rather than about the capture loop.
    public static let doneLabel = L10n.string("Done")
    /// What the window says about itself while it is open, on every page.
    ///
    /// Deliberately a statement about what Worklens does *on its own*, not "nothing is being
    /// captured right now": the menu keeps its own "Start capturing" while this window is open,
    /// so a sentence claiming nothing is captured goes stale the moment somebody presses it.
    /// This one stays true in every state, including that one — the label it names is the label
    /// on both buttons.
    public static var nothingCapturedYet: String {
        L10n.format(
            "Worklens does not start capturing on its own. Capture starts when you finish this window, or when you press \u{201C}%@\u{201D} in the menu.",
            startLabel)
    }

    // MARK: - Page 1: what Worklens does

    /// The three lines page 1 now opens with (#232): what it records, where it stays, what you
    /// get. A condensation, not a replacement — the four lists under `Privacy` are still the
    /// page's, one disclosure away, and they are still `PRIVACY.md`'s own words.
    public enum Welcome {
        public static let records = L10n.string(
            "It takes a screenshot of the window you are in, about once a minute.")
        public static let stays = L10n.string(
            "Everything stays in one folder on this Mac. A screenshot goes to the service you connect (Claude, ChatGPT or Gemini) for a one-line summary, and is deleted afterwards.")
        public static let get = L10n.string(
            "You get your day, searchable, here and in Claude Desktop.")

        /// In the order the page reads them.
        public static var lines: [String] { [records, stays, get] }

        /// Opens `PRIVACY.md` the way the Help menu does. The whole document, for somebody who
        /// wants more than the four lists under it.
        public static let privacyLink = L10n.string("Privacy\u{2026}")
        /// The disclosure the four lists sit behind, collapsed.
        public static let fullDetail = L10n.string("What Worklens records, in full")
    }

    // MARK: - Page 1: what this app does to your Mac

    public enum Privacy {
        public static let recordsHeading = L10n.string("What it records")
        public static let neverRecordsHeading = L10n.string("What it never records")
        public static let leavesHeading = L10n.string("What leaves your Mac")
        public static let controlsHeading = L10n.string("What stops it")

        /// `PRIVACY.md` \u{00A7} "What it records".
        public static let records = [
            L10n.string("A screenshot, only when the focused window's own text did not already cover it"),
            L10n.string("Metadata about the moment: the timestamp, which display, the frontmost app's bundle id and name, the window title"),
            L10n.string("The focused window's text, but only if you grant Accessibility"),
            L10n.string("A short text description of each frame: one or two sentences, an app label and a task label from your own taxonomy."),
            L10n.string("A timeline and a spend ledger built from those descriptions."),
        ]

        /// `PRIVACY.md` \u{00A7} "What it never records".
        public static let neverRecords = [
            L10n.string("Audio. Nothing in Worklens opens a microphone."),
            L10n.string("Keystrokes. The only thing it asks the input system is how long ago you last touched the keyboard or mouse, so it can tell whether you are there. Not what you pressed."),
            L10n.string("Other people's screens or accounts. Only the frontmost window of your own session."),
            L10n.string("Anything at all while paused, locked, asleep, idle, or in front of a blocked app."),
            L10n.string("The value of a password field."),
        ]

        /// `PRIVACY.md` \u{00A7} "What leaves your machine".
        public static let leaves = [
            L10n.string("The service you connect summarizes each screenshot: Claude through your Claude plan, ChatGPT through your ChatGPT plan, or Google's Gemini API with your key."),
            // PRIVACY.md's own version of this line opens "This table is the whole list", which
            // is a pointer to the destinations table there. This page has no table, so the
            // sentence it borrows is the one from § "Privacy in 30 seconds" that stands alone.
            L10n.string("Everything else that leaves is optional: GitHub, asked once every 15 minutes what main points at and nothing else, and the context sources you connect yourself."),
            L10n.string("Nothing goes to the author of this software. No analytics, no crash reporting, no identifier."),
        ]

        /// The pause hotkey and the blocklists, from `PRIVACY.md` \u{00A7} "Privacy in 30 seconds"
        /// and \u{00A7} "What it never records".
        public static let controls = [
            L10n.string("\u{2325}\u{21E7}P pauses everything instantly"),
            L10n.string("three blocklists keep an app or a site out entirely, editable in Settings \u{2192} Privacy"),
            L10n.string("1Password and Password are blocked by default"),
            L10n.string("the menu deletes the last 10 minutes or the last hour."),
        ]

        /// Used on the Gemini card as well, and only there: it is the one thing about a Gemini key
        /// that costs privacy rather than money. `PRIVACY.md` \u{00A7} "What leaves your machine".
        public static let billingCaveat = L10n.string(
            "Use a billing-enabled Gemini project. On Google's free tier your prompts and images may be used to improve their models. On a paid project they are not.")

        /// What a subscription changes about who may keep a screenshot. `PRIVACY.md` \u{00A7} "What
        /// leaves your machine". The page links each company's own setting under it.
        public static let subscriptionTerms = L10n.string(
            "With a Claude or ChatGPT plan, that company's own terms for your plan apply, and whether it may train on your screenshots depends on your own setting with it. Google's paid Gemini API does not train on them.")
        /// The two links under `subscriptionTerms`.
        public static let claudeTrainingLink = L10n.string("Your Claude privacy settings")
        public static let chatGPTTrainingLink = L10n.string("Your ChatGPT data controls")

        /// Everything the test checks against `PRIVACY.md`.
        public static var all: [String] {
            records + neverRecords + leaves + controls + [billingCaveat, subscriptionTerms]
        }

        /// The sentence under the four lists, which is the promise the rest of the app keeps.
        public static let footer = L10n.string(
            "PRIVACY.md in the repository says all of this again, naming the file that implements each line. Settings \u{2192} Privacy is where you change it.")
    }

    // MARK: - Page 2: a sample week (#352)

    /// The one sentence on what the tour shows, before anything is asked of macOS.
    public static let tourWhy = L10n.string(
        "The tour opens Worklens over a week of made-up days and points at each part of it, one card at a time.")
    /// Where the tour hands back to, said before it starts, so leaving this window is not a
    /// leap in the dark. The tour has no Skip here (#357), so the sentence offers none.
    public static let tourComesBack = L10n.string(
        "It takes about a minute. When it ends, this window comes back on the Screen Recording page.")
    /// What VoiceOver reads for the drawing of the sample week on the tour page.
    public static let tourPreviewLabel = L10n.string(
        "A drawing of the sample week: made-up days of real tools, a few meetings and a light weekend.")
    /// The page's primary button. The same words as Settings → Advanced's, which runs the
    /// same tour.
    public static let tourTake = L10n.string("Take the tour")

    // MARK: - Page 3: Screen Recording

    public static let screenRecordingWhy = L10n.string(
        "Worklens captures the frontmost window of your own screen and describes it. Without this grant it records which app you were in and nothing of what was on screen.")
    /// The catch that costs people their first ten minutes: the answer reaches the *next*
    /// process, not this one. `ScreenRecordingCopy` owns every other sentence about the grant.
    /// Since #246 the launch gate brings the window back to the page it was left on, with one
    /// line saying whether the grant arrived — so this promises the page, which is what somebody
    /// about to lose their place needs to hear.
    public static let screenRecordingRelaunch = L10n.string(
        "macOS hands a new answer only to a copy of Worklens that starts afterwards, so allow it and then relaunch. This window comes back to this page when Worklens returns.")
    public static let screenRecordingGranted = L10n.string(
        "Granted. Worklens can capture your screen.")
    /// The plain button beside Continue: the grant can be given later, from the menu or from
    /// Settings → Permissions, and a page nobody can leave is a page people force-quit.
    public static let screenRecordingSkip = L10n.string("Skip for now")

    // MARK: - Page 4: how Worklens summarizes

    public static let keysWhy = L10n.string(
        "Each screenshot gets a one-line summary, which is what makes your day searchable. Worklens has no server and no account: it summarizes through a plan or a key you already have. Connect one; you can add the others later in Settings \u{2192} Connections.")
    /// Under the three cards: Worklens never signs anything in for you.
    public static let signInIsYours = L10n.string(
        "You sign in yourself, in Terminal. Worklens never runs the sign-in or reads it, and Disconnect never signs you out.")

    /// The Gemini card's lines.
    public static let geminiWhy = L10n.string(
        "A key from Google AI Studio, billed to you per screenshot. Without any way to summarize, Worklens still captures, and summarizes what it kept once you connect one.")
    /// From `docs/user/cost.md`. A figure, not a promise: the ledger under Settings →
    /// Usage is what says what you actually spent.
    public static let geminiCost = L10n.string(
        "About $0.10 a day at the defaults. Settings \u{2192} Usage shows what you have spent and stops at a daily budget you set.")
    public static let geminiLinkLabel = L10n.string("Get a Gemini key")

    /// The subscription cards' lines.
    public static let subscriptionCost = L10n.string(
        "No bill from Worklens: summaries count against your plan's usage limits, like your own use does.")
    public static let installClaudeLabel = L10n.string("Install Claude Code")
    public static let installCodexLabel = L10n.string("Install Codex")
    public static let copyLabel = L10n.string("Copy")
    public static let copiedLabel = L10n.string("Copied")
    public static let openTerminalLabel = L10n.string("Open Terminal")
    public static let checkAgainLabel = L10n.string("Check again")
    public static let connectLabel = L10n.string("Connect")
    public static let disconnectLabel = L10n.string("Disconnect")

    /// The plain button beside Continue. A way to summarize can be connected later in Settings
    /// → Connections, and the menu says so until one is.
    public static let keysLater = L10n.string("I\u{2019}ll pick one later")

    // MARK: - Page 5: ready

    /// What the last page opens with, in the two states it can be in.
    public static let readyCapturing = L10n.string("Worklens is capturing.")
    public static let readyStartsOnClose = L10n.string(
        "Worklens starts capturing when you close this window.")
    public static let startWithoutScreenRecording = L10n.string(
        "Screen Recording is not granted, so nothing will be captured until it is. You can start anyway: the menu keeps offering the grant, and Settings \u{2192} Capture has it too.")

    /// The first card: the way a Gemini-only install reads its days.
    public static let readyClaudeHeading = L10n.string("Read your days in Claude Desktop")
    public static let readyClaudeBody = L10n.string(
        "Worklens can add itself to Claude Desktop in one click, and then you ask Claude what you worked on yesterday. It reads your days; it cannot capture, pause or delete anything.")

    /// The second card: this app's own window.
    public static let readyReaderHeading = L10n.string("Open Worklens")
    public static let readyReaderBody = L10n.string(
        "Your day and your week, drawn from what Worklens recorded, live in one window. The menu-bar icon opens it whenever you like.")
    public static let readyReaderButton = L10n.string("Open Worklens")

    /// What replaced the old page 4: the optional grants, named once, where they live.
    public static let readyPermissionsFooter = L10n.string(
        "Accessibility and browser access are optional and live in Settings \u{2192} Capture.")
}
