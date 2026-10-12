import Foundation

/// The six pages of the welcome window, in order (#131, #232, #352, #357).
///
/// It lives in `WorklensCore` for the same reason `SettingsPane` does: the order, the titles and
/// the "4 of 6" counter are one list, and this is the only target with tests. The `Worklens`
/// target draws a view per case and nothing else decides what comes next.
///
/// #232 cut five pages to four. The optional grants — Notifications, Accessibility, browser tab
/// URLs — are no longer asked for before the user has seen a single day: the last page says in
/// one line that they live in Settings → Permissions, which is where they were always changed.
///
/// #352 put a fifth page back, before the first grant: a sample week and the tour over it, so
/// what Worklens gives you is on screen before macOS is asked for anything. It is not a
/// `SetupStep`: the page has one button, **Take the tour** (#357), until a tour has ended once
/// and Continue joins it, so there is nothing on it to leave unfinished and "Finish setting up" still counts the same three steps.
///
/// #357's second pass put a sixth page first: light, dark or the system's, as three cards with
/// light already ringed. Like the tour it is not a `SetupStep` — light is already applied, so it
/// is never unanswered. A stored page name from before it still resumes on the page it names.
public enum SetupPage: String, Sendable, CaseIterable, Equatable, Hashable, Identifiable {
    /// Light, dark or following the Mac, before anything else is said (#357 second pass).
    case appearance
    /// What Worklens does to this Mac, in three lines — and what it never does, in full, for
    /// whoever wants it before anything is captured.
    case privacy
    /// See a sample week: the tour over made-up days (#352), which every first run takes (#357).
    case tour
    /// Screen Recording: the one grant without which there is nothing to describe.
    case screenRecording
    /// The Gemini key, which Worklens needs.
    case keys
    /// Where your days show up: Claude Desktop, or the window this one hands over to.
    case ready

    public var id: String { rawValue }

    /// The heading of the page.
    public var title: String {
        switch self {
        case .appearance: return "Light or dark"
        case .privacy: return "What Worklens does"
        case .tour: return "See a sample week"
        case .screenRecording: return "Screen Recording"
        case .keys: return "Your keys"
        case .ready: return "Ready"
        }
    }

    /// One line saying what this page is for, under the heading.
    public var summary: String {
        switch self {
        case .appearance:
            return "Pick how Worklens looks. You can change it any time in Settings → General."
        case .privacy:
            return "Read this before anything is captured. Nothing has been recorded yet."
        case .tour:
            return "See what you get before Worklens asks macOS for anything."
        case .screenRecording:
            return "macOS has to grant this before Worklens can see a single pixel."
        case .keys:
            return "One key Worklens needs, and one you can leave for later or never."
        case .ready:
            return "Everything above is set. Here is where your days show up."
        }
    }

    /// 1-based position, for "Step 4 of 6".
    public var index: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public static var count: Int { allCases.count }

    /// The page after this one, or nil on the last.
    public var next: SetupPage? {
        let all = Self.allCases
        guard let here = all.firstIndex(of: self), here + 1 < all.count else { return nil }
        return all[here + 1]
    }

    /// The page before this one, or nil on the first.
    public var previous: SetupPage? {
        let all = Self.allCases
        guard let here = all.firstIndex(of: self), here > 0 else { return nil }
        return all[here - 1]
    }

    /// `Step 4 of 6: Screen Recording`. The step dots are drawn, so this is what
    /// VoiceOver reads in their place.
    public var stepLine: String { "Step \(index) of \(Self.count): \(title)" }

    /// The page behind `app_state.setup_page`, or nil when there is nothing to come back to
    /// (#246).
    ///
    /// A page *name* is stored rather than a number, so a page added or removed later degrades
    /// to the first page instead of resuming on the wrong one: #131's five pages include
    /// `optionalPermissions`, which #232 deleted, and a stored `2` would now point at the keys.
    /// An unreadable value, a blank one and a name this build does not have all answer nil.
    public static func stored(_ raw: String?) -> SetupPage? {
        guard let raw, !raw.isEmpty else { return nil }
        return SetupPage(rawValue: raw)
    }
}

/// One thing that has to be true before Worklens is doing the job it was installed for (#131).
///
/// Three, and no more: everything else the welcome window offers is optional by construction and
/// says so on its own page. The order is the order the window asks for them in, which is also
/// the order they become true in on a Mac where nothing is set up yet.
///
/// The Anthropic key was the fourth until #232, and went with the reports on 2026-10-05.
public enum SetupStep: String, Sendable, CaseIterable, Equatable {
    /// macOS has granted Screen Recording to this build.
    case screenRecording
    /// `GEMINI_API_KEY` resolves, so a frame can be described.
    case geminiKey
    /// The welcome window was finished — `onboarded_at` is in `app_state`.
    case welcome

    /// What the step is called where the three are listed one per row.
    public var label: String {
        switch self {
        case .screenRecording: return L10n.string("Screen Recording")
        case .geminiKey: return L10n.string("Gemini key")
        case .welcome: return L10n.string("Finish this window")
        }
    }
}

/// Where the first five minutes have got to (#131).
///
/// A value, not a service: `AppModel` fills it in from the permission state, the resolved config
/// and the `onboarded_at` key, and `MenuModel` reads it. That is what makes the menu line and
/// both launch gates testable without a menu bar or a database.
public struct SetupProgress: Equatable, Sendable {
    public var screenRecording: Bool
    public var geminiKey: Bool
    /// `onboarded_at`: when the welcome was finished — or written silently for an install
    /// that predates this window. Nil means the sequence has not been completed on this Mac.
    public var onboardedAt: Date?

    public init(
        screenRecording: Bool = false,
        geminiKey: Bool = false,
        onboardedAt: Date? = nil
    ) {
        self.screenRecording = screenRecording
        self.geminiKey = geminiKey
        self.onboardedAt = onboardedAt
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .screenRecording: return screenRecording
        case .geminiKey: return geminiKey
        case .welcome: return onboardedAt != nil
        }
    }

    public var done: [SetupStep] { SetupStep.allCases.filter(isDone) }
    public var remaining: [SetupStep] { SetupStep.allCases.filter { !isDone($0) } }
    public var isComplete: Bool { remaining.isEmpty }

    /// Whether the welcome has been finished at all. The menu line is about *this*, not about
    /// the three steps: an install that went through the window and decided against a key has
    /// already been asked once, and a permanent counter would be a nag for a decision made.
    public var onboarded: Bool { onboardedAt != nil }

    /// `Finish setting up Worklens (2 of 3)`, or nil once the window has been finished.
    ///
    /// Stands without its glyph and carries no emoji, like every other menu row (#132).
    public var menuLine: String? {
        guard !onboarded else { return nil }
        return "Finish setting up Worklens (\(done.count) of \(SetupStep.allCases.count))"
    }
}

/// What to do about the welcome window at launch (#131).
///
/// The whole of the decision, as a pure function, because both of its awkward cases cost
/// somebody their running install if they are wrong: an existing install must never be shown a
/// welcome window and must never have its capture deferred, and a launch with no database must
/// still be able to explain itself.
public enum SetupGate {
    public enum Decision: Sendable, Equatable {
        /// Show the window again on the page it was left on, with one line at the top of that
        /// page saying what is now on (#246). The relaunch macOS forces for Screen Recording is
        /// on the happy path, and before this it cost the user every page they had done.
        case resume(page: SetupPage)
        /// Show the window from page one, and hold capture until it is finished.
        case show
        /// This install predates the window: write `onboarded_at` and say nothing.
        case recordSilently
        /// Already onboarded. Nothing to do.
        case nothing

        /// Whether the welcome window opens on this launch: show and resume do.
        public var showsWelcome: Bool {
            switch self {
            case .show, .resume: true
            case .recordSilently, .nothing: false
            }
        }
    }

    /// - Parameters:
    ///   - savedPage: `app_state.setup_page` through `SetupPage.stored(_:)` — the page the
    ///     window was last on, or nil when it has never been left, was a page this build no
    ///     longer has, or could not be read. Only ever consulted where the window is shown at
    ///     all, so it can never re-onboard an install or resume one that is finished.
    ///   - onboardedAt: `app_state.onboarded_at`, or nil when it is absent *or* unreadable.
    ///   - hasCaptures: whether the `captures` table holds a single row.
    ///   - hasStartOnLaunchRow: whether `start_capturing_on_launch` has ever been written, which
    ///     is true exactly when somebody has used Settings → General on this install.
    ///   - databaseOpen: false when a configuration or storage fault left `db` nil, in which
    ///     case nothing above could be read and nothing can be written yet.
    public static func decide(
        savedPage: SetupPage? = nil,
        onboardedAt: Date?,
        hasCaptures: Bool,
        hasStartOnLaunchRow: Bool,
        databaseOpen: Bool
    ) -> Decision {
        // First, and before the database question: a date that is already known — read from
        // `app_state`, or held in memory because the welcome was finished during a launch that
        // had no database to write to — settles it. Without this the no-database case below
        // would show the window again on every reload, which is the loop this must not become.
        guard onboardedAt == nil else { return .nothing }
        // No database: `onboarded_at` can be neither read nor written, so the two signals below
        // are unknowable too. Explaining the app to somebody whose configuration is broken is
        // still better than starting nothing behind a menu that only says "Configuration error",
        // and `AppModel` persists the key once the database opens.
        guard databaseOpen else { return show(savedPage) }
        // An install that has captured anything, or that has ever been told whether to start
        // capturing on launch, has been running since before this window existed. It gets the
        // key written under it and is never interrupted.
        if hasCaptures || hasStartOnLaunchRow { return .recordSilently }
        return show(savedPage)
    }

    /// The `.show` branches, with the stored page folded back in: the two `guard`s above stay
    /// the whole rule, and a page is only ever come back to on a launch that was going to show
    /// the window anyway.
    private static func show(_ savedPage: SetupPage?) -> Decision {
        guard let savedPage else { return .show }
        return .resume(page: savedPage)
    }

    /// The one sentence above a resumed page's heading: the fact first, in the second person,
    /// and nothing about the person in it.
    ///
    /// Said on the way back from the relaunch macOS forces, which is the only way this window
    /// ever reopens mid-sequence — so the thing the user was waiting to hear is whether the
    /// grant arrived.
    public static func resumeLine(screenRecording: Bool) -> String {
        screenRecording
            ? L10n.string("Screen Recording is on. Carry on.")
            : L10n.string("Screen Recording is still off.")
    }
}
