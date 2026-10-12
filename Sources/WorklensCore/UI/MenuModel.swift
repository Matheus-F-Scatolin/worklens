import Foundation

/// What the menu-bar icon shows. One case per thing the user needs to tell apart at a glance,
/// drawn by `MenuBarGlyph` from `WorklensMark` — the same ring the app icon is cut from.
///
/// The raw value is an SF Symbol that says the same thing, used only if drawing fails. It is
/// not an eye: #15 chose `eye`/`eye.slash` (`docs/issues/15-menu-bar-ui.md:34`) and this
/// deliberately overrides that choice, because an eye is the surveillance metaphor this
/// product rejects — and because four symbols could not tell eight scheduler states apart.
public enum MenuIcon: String, Sendable, Equatable, CaseIterable {
    /// Capturing: the lens is open.
    case capturing = "smallcircle.filled.circle"
    /// Capturing but not describing — today's spend is over `DAILY_BUDGET_USD`. A hollow
    /// centre rather than a money badge: the state is about frames, and the menu's own spend
    /// line already says the number.
    case overBudget = "circle.circle"
    /// Paused by the user with no end: it stays off until they resume.
    case paused = "pause.circle"
    /// Paused with an end — it comes back by itself (#252). A separate case because "this is
    /// off until I say so" and "this is off for twelve more minutes" are different answers to
    /// the only question the menu bar is asked.
    case pausedTimed = "pause.circle.fill"
    /// The scheduler is not running at all.
    case stopped = "circle.slash"
    /// Idle, locked or asleep — nothing to record.
    case resting = "minus.circle"
    /// Something needs the user: a missing permission, a broken `.env`.
    case attention = "exclamationmark.circle"

    /// True for either pause, timed or not — the one thing a blocked pipeline must not
    /// overwrite, because a pause is the user's own decision.
    public var isPaused: Bool { self == .paused || self == .pausedTimed }

    /// The shape `MenuBarGlyph` draws for this state.
    public var badge: WorklensMark.Badge {
        switch self {
        case .capturing: return .dot
        case .overBudget: return .hollow
        case .paused: return .pause
        case .pausedTimed: return .pauseTimed
        case .stopped: return .slash
        case .resting: return .dash
        case .attention: return .alert
        }
    }
}

/// How today's spend compares with `DAILY_BUDGET_USD`. The menu colours the line with it.
public enum SpendLevel: String, Sendable, Equatable {
    case nominal, warning, over

    /// 80 % of the budget is the warning line, as issue #17 specifies.
    public static let warningFraction = 0.8

    public static func of(spend: Double, budget: Double) -> SpendLevel {
        guard budget > 0 else { return .nominal }
        // A hair of tolerance, or `budget * 0.8` lands just above a spend that is exactly 80 %
        // (1.5 × 0.8 is 1.2000000000000002) and the warning never appears on a round budget.
        let epsilon = 1e-9
        if spend >= budget - epsilon { return .over }
        return spend >= budget * warningFraction - epsilon ? .warning : .nominal
    }
}

/// The symbol a menu row draws beside its words (#132).
///
/// The raw value *is* the SF Symbol name, so `WorklensCore` can name a glyph without importing
/// SwiftUI or AppKit and nothing has to keep a second table in sync. These replace the colour
/// emoji the status strings used to start with: emoji are the one thing in the menu macOS will
/// not tint, they sat next to monochrome glyphs everywhere else in the app, and VoiceOver read
/// them out as "warning sign" and "money with wings" before the sentence they prefixed.
///
/// The first seven are states the scheduler can be in; `info`, `done` and `tally` cover the rows
/// that are not a scheduler state — an advisory, a confirmation, and today's counts.
///
/// Nothing here carries colour: an `NSMenuItem` title is drawn in the system colour whatever a
/// SwiftUI `foregroundStyle` says (see `countsLine`), so every row has to mean what it means in
/// words. The glyph is a second channel, never the only one.
public enum StatusGlyph: String, Sendable, Equatable, CaseIterable {
    /// Capturing.
    case capturing = "record.circle"
    /// Paused by the user.
    case paused = "pause.circle"
    /// Idle or asleep — nothing to record.
    case resting = "moon.zzz"
    /// The screen is locked.
    case locked = "lock"
    /// Something needs the user: a missing permission, a broken `.env`, a failure.
    case warning = "exclamationmark.triangle"
    /// About money: today's spend against `DAILY_BUDGET_USD`.
    case budget = "dollarsign.circle"
    /// The scheduler is not running at all.
    case stopped = "stop.circle"
    /// An advisory: true, worth saying, nothing has gone wrong.
    case info = "info.circle"
    /// Today's tally.
    case tally = "list.bullet"

    /// The SF Symbol name the menu renders. Identical to the raw value; named so that call sites
    /// read as what they are.
    public var symbol: String { rawValue }
}

/// One informational row of the menu-bar menu: what kind of thing it is, the symbol beside it,
/// and the words (#132).
///
/// The words stand alone. `MenuBarExtra(.menu)` is an AppKit menu underneath, and whether a
/// non-`Button` `Label` draws its image there is macOS's decision rather than ours — so a row
/// that needed its glyph to be understood would be a row that sometimes says nothing.
public struct MenuRow: Equatable, Sendable {
    /// What the row is for. It groups rows for a reader and for a later layout pass; it is also
    /// why glyph and text are separate fields at all, instead of one string built with a prefix.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// What Worklens is doing right now, and the tally under it.
        case status
        /// Something is wrong and the user has to act.
        case problem
        /// True and worth saying; nothing is broken.
        case advisory
    }

    public let kind: Kind
    public let glyph: StatusGlyph
    /// The words, on one line and no wider than `tallyLimit` — `textLimit` for a quoted one.
    public let text: String

    /// The widest a row that quotes words from outside Worklens gets, in characters.
    ///
    /// An `NSMenuItem` is as wide as its title and an `NSMenu` is as wide as its widest item, so
    /// one long row stretches every other row with it: a failure that quoted a whole
    /// `URLError` — `Error Domain=NSURLErrorDomain Code=-1009 "…" UserInfo={…}` — pulled the
    /// menu out past the width of a window and the key equivalents off its right-hand edge.
    ///
    /// 90 rather than the 102 characters a busy counts row runs to, because the two are not the
    /// same width: a tally is digits, spaces and middots, and an error is dense lowercase, so 90
    /// characters of prose and 102 of tally come out at about the same number of points.
    ///
    /// `quoted(_:)` applies it, at the few places in `MenuModel` where words Worklens did not
    /// write become a row: a notice's message, the describe-health sentence, a configuration
    /// loader's complaint. Every other line here was written for this menu and is left alone —
    /// including the ones that are `.problem` rows, like the two-sentence budget status line, so
    /// the kind of a row is no guide to who wrote it.
    public static let textLimit = 90

    /// The stop every row is held to, whoever wrote its words, applied by `init`.
    ///
    /// Well above anything the menu draws on purpose except one: a day with every privacy tally
    /// and an over-budget spend on it runs to 164 characters, and that row is trimmed here. It
    /// keeps its end, which is the point of trimming from the middle — the spend is the half of
    /// a tally nobody can be asked to open Settings for.
    public static let tallyLimit = 128

    /// How much of the end a middle trim keeps.
    public static let endBudget = 24

    /// `text` flattened to one line and ellipsized past `limit`.
    ///
    /// Newlines go first, because a menu item draws a two-line title as one line with the break
    /// swallowed — which is how the last word of one line and the first of the next become one.
    ///
    /// The trim takes the middle, which is what an `NSMenu` does to an item it cannot
    /// fit and what the last clause of one of these lines deserves: a failure row ends in the
    /// `(retrying at 08:35)` a reader acts on, a tally ends in the spend, and a path ends in the
    /// name that says which file it is. A line with no clause to keep — no word boundary within
    /// `endBudget` of the end — falls back to the end.
    public static func trimmed(_ text: String, to limit: Int = MenuRow.textLimit) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        guard let end = MenuRow.lastClause(of: flat), end.count + 8 < limit else {
            return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let head = String(flat.prefix(limit - end.count - 2))
            .trimmingCharacters(in: .whitespaces)
        return head + "… " + end
    }

    /// One row's worth of a sentence written somewhere else.
    public static func quoted(_ text: String) -> String {
        MenuRow.trimmed(text, to: MenuRow.textLimit)
    }

    /// The last `endBudget` characters of `text`, snapped forward to a word boundary so a middle
    /// trim never resumes halfway through a word. Nil when there is no boundary to snap to.
    static func lastClause(of text: String) -> String? {
        let tail = text.suffix(MenuRow.endBudget)
        guard let space = tail.firstIndex(of: " ") else { return nil }
        let clause = tail[tail.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return clause.isEmpty ? nil : clause
    }

    public init(kind: Kind, glyph: StatusGlyph, text: String) {
        self.kind = kind
        self.glyph = glyph
        self.text = MenuRow.trimmed(text, to: MenuRow.tallyLimit)
    }
}

/// One item of the "Pause" submenu (#136).
///
/// The menu used to offer three sibling "Pause …" buttons that vanished the moment a pause
/// started, so a pause could be ended but never extended. These are the four choices, drawn in
/// one submenu that stays reachable while paused: choosing one while paused replaces the
/// deadline.
public enum PauseChoice: String, Sendable, Equatable, CaseIterable {
    case fifteenMinutes
    case oneHour
    case untilTomorrow
    case untilResumed

    /// What the submenu item says. No "Pause" prefix — the submenu's own title carries it.
    public var label: String {
        switch self {
        case .fifteenMinutes: return L10n.string("15 minutes")
        case .oneHour: return L10n.string("1 hour")
        case .untilTomorrow: return L10n.string("Until tomorrow")
        case .untilResumed: return L10n.string("Until I resume")
        }
    }

    /// How long the pause lasts, for the two choices that are a fixed length. `untilTomorrow`
    /// depends on the clock and `untilResumed` has no deadline at all, so both are nil and the
    /// caller decides — `AppModel.pauseUntilTomorrow()` and `pause(for: nil)` respectively.
    public var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 3600
        case .untilTomorrow, .untilResumed: return nil
        }
    }
}

/// Everything the menu draws from, in one value. `AppModel` keeps one of these up to date and the
/// SwiftUI menu reads `MenuModel(state:now:)` — which is pure, and therefore testable without a
/// menu bar, a database or a screen.
public struct MenuState: Equatable, Sendable {
    public var scheduler: SchedulerState
    public var captureIntervalSeconds: Int
    public var meetingIntervalSeconds: Int
    public var inMeeting: Bool
    public var counts: MenuCounts
    /// #125: whether the describe queue is moving, and why not when it is not. `DescribeWorker`
    /// raises it; a rejected key, a spent quota or a stretch offline all land here rather than
    /// only in `llm_calls`, where nobody was looking.
    public var describeHealth: DescribeHealth
    public var budgetUSD: Double
    /// Everything worth telling the user, newest first (#110). A `.problem` stays until the user
    /// dismisses it or — when a `SetupIssue` raised it — until that condition clears; `.done` and
    /// `.info` fade on their own. The menu shows at most one problem and counts the rest.
    public var notices: [Notice]
    /// Everything Worklens is doing right now that the user set going (#150) — a sync, a
    /// configuration reload, an erase. Keyed per thing. This is the one list.
    public var activities: [Activity]
    /// True while anything at all is running. What defers an auto-update (#150): restarting the
    /// app out from under a half-finished erase is worse than waiting a minute.
    public var isBusy: Bool { !activities.isEmpty }
    /// Set when `.env` could not be parsed: the menu then offers little but the error and a way
    /// to open the file. One line — `configErrorDetails` has the rest.
    public var configError: String?
    /// #126: one sentence per bad setting, each already naming the file it is in. The Settings
    /// banner lists them; the menu shows `configError` alone, because a menu that grows a row
    /// per mistake is a menu you cannot reach "Quit" in.
    public var configErrorDetails: [String]
    /// #126: the file the user has to open to fix the first error. Drives nothing in the menu —
    /// "Open .env…" already opens the file the app read — and is what the banner labels itself
    /// with, so "fix the value" says *where*.
    public var configErrorFile: String?
    /// #126: the data directory could not be opened. A different fault from a bad value, with a
    /// different remedy, so it is a different field: no amount of re-reading `.env` fixes a
    /// folder that is not writable, and offering "Reload configuration" as the answer taught
    /// people to click it twice and give up. Checked before `configError` when both are set.
    public var storageError: String?
    /// #126: advisory sentences from the last load — an unknown key, a model id that is in no
    /// price table, a regex list with the wrong separator. Never degrade the menu.
    public var configWarnings: [String]
    /// #53: Accessibility is not granted, so no window text is being read. Advisory, not an
    /// error — capture keeps running on pixels, which is exactly what it did before #53 — so it
    /// gets a line of its own and leaves the icon and every action alone.
    public var accessibilityMissing: Bool
    /// #64: browsers — by display name — whose frames today carry no URL at all and whose
    /// Automation grant is `denied`. Names rather than bundle ids, because the line names them
    /// and `MenuModel` stays a pure mapping with nothing to look up.
    ///
    /// #117 narrowed this to denials: a browser nobody has been asked about is a different
    /// sentence with a different button, and it is `browsersNotAsked`.
    public var browsersMissingURLs: [String]
    /// #117: browsers, by display name, that produced no URL today and have never been asked.
    /// The one case Worklens can fix from inside its own menu, so it offers to rather than
    /// pointing at a System Settings pane that does not list an app until it has been asked.
    public var browsersNotAsked: [String]
    /// #117: whether Screen Recording has ever been granted to this build — the presence of
    /// `screen_recording_granted_at` in `app_state`. The two states look identical to macOS and
    /// need opposite sentences; see `ScreenRecordingCopy`.
    public var screenRecordingEverGranted: Bool
    /// #117: the user asked not to be reminded about Accessibility again (Settings →
    /// Permissions). The grant is optional, so a line about it that cannot be turned off is a
    /// permanent nag for a decision that has already been made.
    public var accessibilityAdvisorySkipped: Bool
    /// #117: the same, for the browser tab URL lines.
    public var browserAdvisorySkipped: Bool
    /// #116: no API key of either kind is set, so Worklens has never been configured. The menu
    /// answers with one calm line and a way to open the file rather than with the two key
    /// warnings, which say the same thing twice to someone who has not started yet. It is not
    /// "no `.env` exists": the app writes one on first launch, and the user still has to fill
    /// it in afterwards.
    public var firstRun: Bool
    /// #141: the sources whose last sync failed in a way that only you can clear — a refused
    /// token, a revoked grant — by display name. A transient failure is deliberately absent: it
    /// clears itself, and the Integrations tab already shows it. These do not: a revoked token
    /// drains context out of the timeline for weeks without a single line anywhere.
    public var integrationsNeedingAttention: [String]
    /// #131: how far the welcome window has got, or nil when there is nothing to say about
    /// setup — an install that finished it, and every state built before this window existed.
    /// It decides two things and no others: the `Finish setting up Worklens (2 of 4)` row, and
    /// whether the two optional-permission advisories are held back for now.
    public var setup: SetupProgress?
    /// #145: the charger and Low Power Mode, and what `CAPTURE_ON_BATTERY` says to do about them.
    /// Together they decide whether the status row explains a longer cadence.
    public var power: PowerState
    public var batteryMode: BatteryCaptureMode
    /// #157: the locale the menu's numbers, money and clocks are written in.
    ///
    /// It defaults to the fixed locale rather than `.autoupdatingCurrent` on purpose: every test
    /// in `WorklensCoreTests` builds a `MenuState` and asserts the strings that come out of it,
    /// and a default that read System Settings would make those tests pass or fail depending on
    /// the machine they ran on. The app sets it to the user's own locale in `AppModel`, which is
    /// the one place a real person is looking at the result.
    public var locale: Locale = Format.fixed

    public init(
        scheduler: SchedulerState = .stopped,
        captureIntervalSeconds: Int = 60,
        meetingIntervalSeconds: Int = 300,
        inMeeting: Bool = false,
        counts: MenuCounts = .zero,
        describeHealth: DescribeHealth = .ok,
        budgetUSD: Double = 0,
        notices: [Notice] = [],
        activities: [Activity] = [],
        configError: String? = nil,
        configErrorDetails: [String] = [],
        configErrorFile: String? = nil,
        storageError: String? = nil,
        configWarnings: [String] = [],
        accessibilityMissing: Bool = false,
        browsersMissingURLs: [String] = [],
        browsersNotAsked: [String] = [],
        screenRecordingEverGranted: Bool = false,
        accessibilityAdvisorySkipped: Bool = false,
        browserAdvisorySkipped: Bool = false,
        firstRun: Bool = false,
        integrationsNeedingAttention: [String] = [],
        setup: SetupProgress? = nil,
        power: PowerState = .mains,
        batteryMode: BatteryCaptureMode = .slow,
        locale: Locale = Format.fixed
    ) {
        self.scheduler = scheduler
        self.captureIntervalSeconds = captureIntervalSeconds
        self.meetingIntervalSeconds = meetingIntervalSeconds
        self.inMeeting = inMeeting
        self.counts = counts
        self.describeHealth = describeHealth
        self.budgetUSD = budgetUSD
        self.notices = notices
        self.activities = activities
        self.configError = configError
        self.configErrorDetails = configErrorDetails
        self.configErrorFile = configErrorFile
        self.storageError = storageError
        self.configWarnings = configWarnings
        self.accessibilityMissing = accessibilityMissing
        self.browsersMissingURLs = browsersMissingURLs
        self.browsersNotAsked = browsersNotAsked
        self.screenRecordingEverGranted = screenRecordingEverGranted
        self.accessibilityAdvisorySkipped = accessibilityAdvisorySkipped
        self.browserAdvisorySkipped = browserAdvisorySkipped
        self.firstRun = firstRun
        self.integrationsNeedingAttention = integrationsNeedingAttention
        self.setup = setup
        self.power = power
        self.batteryMode = batteryMode
        self.locale = locale
    }
}

/// Why the menu is showing a remedy instead of the app (#126).
///
/// Two cases, not one, because they are fixed in different places. `configuration` is a value in
/// a file; `storage` is a folder. Before #126 both set `configError` and both were offered
/// "Open .env…" and "Reload configuration" — which, for a `DATA_DIR` on a disconnected volume,
/// is two buttons that cannot possibly work.
public enum DegradedReason: String, Sendable, Equatable, CaseIterable {
    case configuration
    case storage
}

/// `MenuState` rendered into the exact strings and enablement flags the menu shows.
///
/// Pure on purpose: the whole menu is one struct away from a unit test, and SwiftUI's menu body
/// (which re-runs on every open) does no work beyond reading these fields.
public struct MenuModel: Equatable, Sendable {
    public let icon: MenuIcon
    /// #252: true while anything the user set going is still running. A treatment over `icon`
    /// rather than a value of it — `MenuBarGlyph` draws the state's badge with a thin arc over
    /// it, so "paused" and "syncing" can both be true and both be legible.
    public let isBusy: Bool
    /// `Capturing · every 60 s`, with the glyph that says the same thing (#132).
    public let statusRow: MenuRow
    /// `Today: 312 frames · 143 described · 4 pending · $0.19 of $1.50`, with its glyph.
    public let countsRow: MenuRow
    /// What `statusRow` says, for the call sites that only want the words — the menu's first
    /// row and the tests.
    public var statusLine: String { statusRow.text }
    /// What `countsRow` says.
    public var countsLine: String { countsRow.text }
    /// The same numbers, written for speech (#252) — what the status item's `accessibilityValue`
    /// says. `countsLine` is an interpunct-separated row written for a glance, and VoiceOver
    /// reads it as a run of digits and punctuation; this is a sentence, the way `iconLabel`
    /// already is beside it.
    public let spokenTally: String
    /// The one open problem the menu shows, or nil. Its `action` is the button next to it; the
    /// rest are listed in Settings → General rather than stacked up, so a bad morning cannot push
    /// the menu itself off the screen.
    public let problem: Notice?
    /// The words of `problem`, or nil.
    public let problemLine: String?
    /// #125: `Not summarizing — Gemini rejected the key (HTTP 403)`, or nil while the queue is
    /// moving. A persistent row, not a ten-minute note: the condition is still true tomorrow
    /// morning, and it is the single most expensive thing that can fail quietly here. Nil when an
    /// open problem already says the same sentence, so a rejected key is one row and not two.
    public let describeHealthLine: String?
    /// The button next to `describeHealthLine`, or nil. Only a failure with something to fix
    /// carries one — a hold clears itself, and a button that cannot help is worse than no button.
    ///
    /// #191: "something to fix" is a rejected key and nothing else. Gemini having trouble (503)
    /// and an answer that did not fit the schema are real stalls and earn the sentence, but
    /// neither is the key's fault and this button opens the field where the key is typed — so
    /// they keep the line and lose the button.
    public let describeFixAction: NoticeAction?
    /// #117: the whole of what the menu offers while Screen Recording is missing —
    /// `Screen Recording is off — Fix…`, or nil when it is not missing. Everything else about
    /// capture is disabled behind it: there is nothing to pause and nothing to capture.
    public let permissionFixLine: String?
    /// #141: `Granola needs attention — reconnect it in Settings`, or nil. A row of its own
    /// rather than a notice: it is derived from the scheduler's live state, it goes the moment a
    /// round succeeds, and it has to survive a relaunch, which a dismissed notice would not.
    public let integrationAttentionLine: String?
    public let spendLevel: SpendLevel
    /// #137: what a one-click raise would set today's budget to, or nil unless today's spend is
    /// over the budget in force: the spend so far rounded up to the dollar, plus fifty cents.
    /// Settings' over-budget banner names this number rather than the difference, because a
    /// ceiling is what a banner about a budget should say.
    public let budgetRaiseTarget: Double?

    /// Whether the "Pause" submenu can be opened. True while paused too (#136): choosing a
    /// duration then replaces the deadline, which is how a pause gets extended.
    public let canPause: Bool
    public let canResume: Bool
    public let canCaptureNow: Bool
    /// True when config failed to load or the data directory could not be opened: the menu
    /// drops to the remedy for whichever it is, and "quit".
    public var isDegraded: Bool { degraded != nil }
    /// #126: *which* fault degraded the menu, because the two have different remedies. A bad
    /// value is fixed in a file; an unwritable `DATA_DIR` is fixed by choosing another folder,
    /// and re-reading `.env` will not help.
    public let degraded: DegradedReason?
    /// `Add your Gemini API key to get started`, or nil once the Gemini key is set (#116). Not a problem
    /// and not degradation — the app runs, it just has nothing to describe frames with yet — so
    /// it is a line of its own, above the "Open .env…" item the menu grows beside it.
    public let firstRunLine: String?
    /// `firstRunLine` as a row.
    public var firstRunRow: MenuRow? {
        firstRunLine.map { MenuRow(kind: .advisory, glyph: .info, text: $0) }
    }
    /// `Finish setting up Worklens (2 of 4)` while the welcome window has not been finished,
    /// nil otherwise (#131). Not a problem and not degradation — it is the offer to carry on
    /// where the window left off, and the menu makes the status line itself the button.
    ///
    /// It replaces `firstRunLine` while it stands: both say "you are not set up yet", and the
    /// window is the better answer of the two because it takes the keys as well.
    public let setupLine: String?
    /// `setupLine` as a row.
    public var setupRow: MenuRow? {
        setupLine.map { MenuRow(kind: .advisory, glyph: .info, text: $0) }
    }

    /// What VoiceOver says when it reaches the menu-bar item (#132).
    ///
    /// The item is the app's always-visible surface. It has been named since #114, but with
    /// `statusLine` — the menu row's own text, written for a 22-point-tall menu bar and prefixed
    /// with an emoji, so VoiceOver announced a picture and an abbreviation: "black circle,
    /// Capturing · every 60 s". This names the app and then says what it is doing, spelled for
    /// speech — "every 60 seconds", not "every 60 s".
    public let iconLabel: String

    public init(state: MenuState, now: Date = Date(), timeZone: TimeZone = .current) {
        // Storage first: when the data directory cannot be opened there is nothing to capture
        // into whatever `.env` says, and "fix the value" would be the wrong thing to tell
        // somebody whose values are all fine (#126).
        let reason: DegradedReason? =
            state.storageError != nil ? .storage : (state.configError != nil ? .configuration : nil)
        degraded = reason
        // #131: while the welcome is unfinished the menu offers to finish it, and says nothing
        // else about setup. A degraded menu is a remedy for one fault and has room for neither.
        setupLine = reason != nil ? nil : state.setup?.menuLine
        firstRunLine = reason != nil || !state.firstRun || setupLine != nil
            ? nil
            : MenuModel.firstRunText

        if let reason, let message = reason == .storage ? state.storageError : state.configError {
            icon = .attention
            isBusy = state.isBusy
            let headline = reason == .storage
                ? L10n.string("Data folder problem")
                : L10n.string("Configuration error")
            statusRow = MenuRow(kind: .problem, glyph: .warning, text: headline)
            // The one row under it is the sentence that says what went wrong, so it takes the
            // counts slot rather than adding a row to a menu that is already a remedy.
            countsRow = MenuRow(kind: .problem, glyph: .warning, text: MenuRow.quoted(message))
            spokenTally = MenuModel.spokenTally(state.counts, locale: state.locale)
            iconLabel = L10n.format("Worklens, %@", headline.lowercased())
            problem = nil
            problemLine = nil
            describeHealthLine = nil
            describeFixAction = nil
            permissionFixLine = nil
            spendLevel = .nominal
            budgetRaiseTarget = nil
            integrationAttentionLine = nil
            canPause = false
            canResume = false
            canCaptureNow = false
            return
        }

        let problems = MenuModel.openProblems(state.notices, now: now, hidingMissingKeys: state.firstRun)
        problem = problems.first
        // Trimmed here, so a provider's error dump cannot stretch the menu to the width of the
        // screen.
        problemLine = problems.first.map { MenuRow.quoted($0.message) }

        // The health sentence, unless a problem row is already saying it: `AppModel` raises a
        // rejected key as a `SetupIssue` so it survives a relaunch and reaches the Activity log,
        // and one condition deserves one line.
        let healthLine = state.describeHealth.line(now: now, timeZone: timeZone)
        describeHealthLine = problems.contains(where: { $0.message == healthLine })
            ? nil
            : healthLine.map { MenuRow.quoted($0) }
        // #124 moved the keys into Settings, so the Fix… button leads to the Accounts section
        // rather than into a text editor — the same place the rejected-key problem row goes.
        // #191: which is why only a key rejection carries it. `isKeyRejection` is the same
        // predicate `AppModel` uses to decide whether a failure is the credential's fault, so
        // the button and the problem row it duplicates can never disagree; a 503 or a schema
        // failure gets the sentence and no button, because this one leads nowhere useful.
        describeFixAction = state.describeHealth.isKeyRejection && describeHealthLine != nil
            ? .openAccountSettings
            : nil

        // A missing or rejected key is the one problem that moves the icon: nothing is being
        // described at all, and the user has no other way to find that out. Pause is
        // left alone — it is the user's own decision, and overwriting it would read as a fault.
        let schedulerIcon = MenuModel.icon(for: state.scheduler)
        // #239: a brand-new install is a setup step, not a fault — the welcome window and
        // `firstRunLine` are already asking for the key, so the first thing a new user sees in
        // the menu bar is not an exclamation mark. The moment describing actually fails, the
        // line below says so.
        // A queue that is failing is exactly the same kind of fact as a missing key — a whole
        // stage of the pipeline is doing nothing — so it moves the icon too, and a healthy
        // "Capturing" can never be the answer while it is true.
        let blocked = state.describeHealth.isFailing
            || problems.contains { $0.issue?.blocksWork == true }
        let resolved: MenuIcon = blocked && !schedulerIcon.isPaused ? .attention : schedulerIcon
        // #252: busy is a treatment, not a state. Until now it *replaced* the capture state —
        // so a paused app running a sync read as neither paused nor capturing for the minute
        // the sync took, which is the one minute the icon's only job went unanswered. It
        // travels beside the state instead, and `.attention` still outranks the state itself.
        icon = resolved
        isBusy = state.isBusy
        statusRow = MenuModel.statusRow(state, now: now, timeZone: timeZone)
        iconLabel = MenuModel.iconLabel(state, now: now, timeZone: timeZone)
        spendLevel = SpendLevel.of(spend: state.counts.spendUSD, budget: state.budgetUSD)
        budgetRaiseTarget = MenuModel.budgetRaise(
            spend: state.counts.spendUSD, budget: state.budgetUSD
        )?.target
        countsRow = MenuModel.countsRow(
            state.counts, budget: state.budgetUSD, level: spendLevel, locale: state.locale
        )
        spokenTally = MenuModel.spokenTally(state.counts, locale: state.locale)

        permissionFixLine = state.scheduler == .permissionMissing
            ? ScreenRecordingCopy.menuFixLine(everGranted: state.screenRecordingEverGranted)
            : nil
        integrationAttentionLine = MenuModel.integrationAttentionLine(
            state.integrationsNeedingAttention
        )

        switch state.scheduler {
        // #136: paused is not "nothing to pause" — picking a duration here sets a new deadline,
        // which is the only way to extend a pause without resuming first.
        case .paused:
            canPause = true
            canResume = true
        // Nothing is being captured, so there is nothing to pause: an enabled "Pause 15 minutes"
        // over a missing grant offers to stop something that already stopped, and reads as if
        // Worklens thinks it is working (#117). `canCaptureNow` is already false below.
        case .stopped, .permissionMissing:
            canPause = false
            canResume = false
        default:
            canPause = true
            canResume = false
        }
        // "Capture now" deliberately ignores pause and idle — it is the user asking, not the timer.
        canCaptureNow = state.scheduler != .permissionMissing
    }

    /// The open problems, worst first: a `SetupIssue` outranks an ad-hoc failure because it is
    /// still true by construction, and among equals the newest wins. Dismissed and faded notices
    /// are already gone.
    public static func openProblems(
        _ notices: [Notice],
        now: Date,
        hidingMissingKeys: Bool = false
    ) -> [Notice] {
        notices
            .filter { $0.kind == .problem && $0.isLive(at: now) }
            // On a first run the missing Gemini key is not news, it is the setup step
            // `firstRunLine` is already asking for (#116). Everything else still shows.
            .filter { !hidingMissingKeys || !MenuModel.isMissingKey($0) }
            .sorted { lhs, rhs in
                let left = MenuModel.rank(lhs.issue)
                let right = MenuModel.rank(rhs.issue)
                return left == right ? lhs.at > rhs.at : left < right
            }
    }

    private static func rank(_ issue: SetupIssue?) -> Int {
        guard let issue else { return SetupIssue.bySeverity.count }
        return SetupIssue.bySeverity.firstIndex(of: issue) ?? SetupIssue.bySeverity.count
    }

    /// The first-run line. Second person, no warning glyph: nothing has gone wrong yet.
    public static var firstRunText: String { L10n.string("Add your Gemini API key to get started") }

    /// The problem `firstRunText` stands in for. #239: only the Gemini key — a missing Claude
    /// key is a choice, not a problem, and is never raised at launch.
    static func isMissingKey(_ notice: Notice) -> Bool {
        notice.issue == .noGeminiKey
    }

    /// `Granola needs attention — reconnect it in Settings`, or with two sources,
    /// `Granola and Google Calendar need attention — reconnect them in Settings`. Nil when nothing does.
    ///
    /// One row however many sources, for the same reason the problems above are capped: a menu
    /// that grows a row per failure is a menu you cannot reach "Pause" in.
    public static func integrationAttentionLine(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        guard names.count > 1 else {
            return L10n.format("%@ needs attention: reconnect it in Settings", names[0])
        }
        let list = L10n.format(
            "%@ and %@",
            names.dropLast().joined(separator: ", "), names[names.count - 1])
        return L10n.format("%@ need attention: reconnect them in Settings", list)
    }

    /// #136: what "Capture now" says when the forced tick deliberately collected nothing, and
    /// nil when it collected something — a saved frame, or the text a `CAPTURE_SOURCE` without
    /// pictures collects instead. A tick that refused must say so: claiming a capture that did
    /// not happen is worse here than in any other menu line.
    public static func captureNowSkippedLine(_ decision: TickDecision) -> String? {
        switch decision {
        case .describedPending, .budgetSkipped:
            return nil
        case .blocked:
            return L10n.string("Not captured: that app is on your never-capture list.")
        case .locked:
            return L10n.string("Not captured: the screen is locked.")
        case .noText:
            return L10n.string("Not captured: this window exposed no text to read.")
        case .hostUnknown:
            return L10n.string("Not captured: Worklens could not read this page's address to check it against your never-capture list.")
        case .noWindow:
            return L10n.string("Not captured: no window was in front to take a screenshot of.")
        case .focusChanged:
            return L10n.string("Not captured: the window in front changed while the screenshot was being taken.")
        case .unchanged:
            return L10n.string("Nothing new: this screen looks the same as the last one.")
        case .idle, .paused, .tooSoon, .error:
            return L10n.string("Not captured this time.")
        }
    }

    // MARK: Pieces

    /// #137: what a one-click raise would set today's budget to, or nil when today is not over
    /// budget. `CostTracker.suggestedRaise` is the one place that arithmetic lives.
    static func budgetRaise(spend: Double, budget: Double) -> (target: Double, more: Double)? {
        guard budget > 0, SpendLevel.of(spend: spend, budget: budget) == .over else { return nil }
        let target = CostTracker.suggestedRaise(spend: spend)
        guard target > budget else { return nil }
        return (target, target - budget)
    }

    /// Six glyphs for eight states. `.idle`, `.locked` and `.asleep` share `.resting` on
    /// purpose — they all mean "nothing to record", and the status line says which. The two
    /// that used to lie no longer do: `.budgetExceeded` looked exactly like healthy capture
    /// and `.stopped` exactly like a user-initiated pause.
    static func icon(for state: SchedulerState) -> MenuIcon {
        switch state {
        case .running: return .capturing
        case let .paused(until): return until == nil ? .paused : .pausedTimed
        case .idle, .locked, .asleep: return .resting
        case .permissionMissing: return .attention
        case .budgetExceeded: return .overBudget
        case .stopped: return .stopped
        }
    }

    /// The status row: the glyph for what the scheduler is doing, and the words that say the same
    /// thing without it (#132).
    ///
    /// Every sentence here used to start with an emoji — a filled circle before `Capturing`,
    /// a sleep glyph before `Idle`, a banknote before `Budget reached`. The glyph is a field now,
    /// so the words carry the meaning on their own and VoiceOver no longer opens with "money with
    /// wings".
    static func statusRow(
        _ state: MenuState, now: Date = Date(), timeZone: TimeZone
    ) -> MenuRow {
        let interval = MenuModel.effectiveInterval(state)
        let every = L10n.format("every %@", MenuModel.cadence(interval, locale: state.locale))
        let cadence = state.inMeeting ? L10n.format("%@ (meeting)", every) : every
        func row(_ kind: MenuRow.Kind, _ glyph: StatusGlyph, _ text: String) -> MenuRow {
            MenuRow(kind: kind, glyph: glyph, text: text)
        }
        switch state.scheduler {
        case .running:
            // #145: the battery line replaces "Capturing" rather than sitting under it. The
            // cadence in it is the same number, and two rows saying "every 5 min" in different
            // words is how a menu stops being read.
            if let battery = MenuModel.batteryLine(state) {
                return row(.status, .capturing, battery)
            }
            return row(.status, .capturing, L10n.format("Capturing · %@", cadence))
        case let .paused(until):
            // Named in full, because a pause now survives a quit: coming back to "Paused"
            // should say, without a click, that nothing resumes until you say so (#113).
            guard let until else {
                return row(.status, .paused, L10n.string("Paused until you resume"))
            }
            // #136: a midnight deadline is the "until tomorrow" pause, and printing it as
            // `Paused until 00:00` was the menu reading its own arithmetic back to the user.
            if MenuModel.isMidnight(until, timeZone: timeZone) {
                return row(.status, .paused, L10n.string("Paused until tomorrow"))
            }
            // #252: a short pause is a countdown, and the clock time was the app reading its own
            // arithmetic back — "Paused until 14:42" makes the reader do the subtraction the app
            // already did. Under an hour it says what is left; a longer one keeps the clock,
            // where the time of day is the easier fact to hold.
            if let left = MenuModel.minutesLeft(until: until, now: now) {
                return row(.status, .paused, L10n.plural(
                    count: left, one: "Paused · %lld minute left",
                    other: "Paused · %lld minutes left"
                ))
            }
            let clock = MenuModel.clock(until, timeZone: timeZone, locale: state.locale)
            return row(.status, .paused, L10n.format("Paused until %@", clock))
        case .idle:
            return row(.status, .resting, L10n.string("Idle · nothing to record"))
        case .locked:
            return row(.status, .locked, L10n.string("Locked"))
        case .asleep:
            return row(.status, .resting, L10n.string("Asleep"))
        case .permissionMissing:
            return row(.problem, .warning, L10n.string("Screen Recording permission needed"))
        case .budgetExceeded:
            // One clause in the swept vocabulary (#157): "on hold" is the same words the counts row
            // right below uses for these screenshots.
            return row(.problem, .budget, L10n.string("Budget reached: screenshots on hold"))
        case .stopped:
            return row(.status, .stopped, L10n.string("Stopped"))
        }
    }

    /// Whole minutes left of a pause that ends inside the hour, or nil when it is further off
    /// than that (or already over). Rounded up, so the last half-minute still reads "1 minute
    /// left" rather than "0".
    static func minutesLeft(until: Date, now: Date) -> Int? {
        let remaining = until.timeIntervalSince(now)
        guard remaining > 0, remaining < 3600 else { return nil }
        return max(1, Int((remaining / 60).rounded(.up)))
    }

    /// What the menu-bar item announces to VoiceOver: the app's name, then what it is doing,
    /// spelled out for speech (#132).
    ///
    /// Separate from `statusRow.text` on purpose. The row is read with the menu open and can lean
    /// on the rows around it; this sentence is all there is, so it says "Worklens" first and
    /// spells the cadence in words a screen reader pronounces correctly.
    public static func iconLabel(
        _ state: MenuState, now: Date = Date(), timeZone: TimeZone = .current
    ) -> String {
        if state.storageError != nil { return L10n.string("Worklens, data folder problem") }
        if state.configError != nil { return L10n.string("Worklens, configuration error") }
        let interval = MenuModel.effectiveInterval(state)
        let cadence = MenuModel.spokenCadence(interval, locale: state.locale)
        switch state.scheduler {
        case .running:
            // #145: same fact as the status row, spelled for speech.
            if PowerPolicy.isEasedOff(power: state.power, mode: state.batteryMode) {
                let reason = state.power.onBattery
                    ? L10n.string("on battery")
                    : L10n.string("in Low Power Mode")
                let spoken = L10n.format("Worklens, %@, capturing %@", reason, cadence)
                guard state.batteryMode == .describeLater else { return spoken }
                return L10n.format("%@, describing when plugged in", spoken)
            }
            guard state.inMeeting else {
                return L10n.format("Worklens, capturing %@", cadence)
            }
            return L10n.format("Worklens, capturing %@, meeting cadence", cadence)
        case let .paused(until):
            guard let until else { return L10n.string("Worklens, paused until you resume") }
            if MenuModel.isMidnight(until, timeZone: timeZone) {
                return L10n.string("Worklens, paused until tomorrow")
            }
            if let left = MenuModel.minutesLeft(until: until, now: now) {
                return L10n.plural(
                    count: left, one: "Worklens, paused, %lld minute left",
                    other: "Worklens, paused, %lld minutes left"
                )
            }
            return L10n.format(
                "Worklens, paused until %@",
                MenuModel.clock(until, timeZone: timeZone, locale: state.locale))
        case .idle:
            return L10n.string("Worklens, idle, nothing to record")
        case .locked:
            return L10n.string("Worklens, screen locked")
        case .asleep:
            return L10n.string("Worklens, asleep")
        case .permissionMissing:
            return L10n.string("Worklens, Screen Recording permission needed")
        case .budgetExceeded:
            return L10n.string("Worklens, daily budget reached, screenshots on hold")
        case .stopped:
            return L10n.string("Worklens, stopped")
        }
    }

    /// `every 60 seconds`, `every 5 minutes`. `cadence` abbreviates for a menu row that has to
    /// fit; a screen reader reads "60 s" as "60 s".
    static func spokenCadence(_ seconds: Int, locale: Locale = Format.fixed) -> String {
        if seconds < 120 {
            return L10n.plural(
                count: seconds, one: "every %lld second", other: "every %lld seconds")
        }
        let minutes = Double(seconds) / 60
        guard minutes == minutes.rounded() else {
            return L10n.format(
                "every %@ minutes", Format.decimal(minutes, places: 1, locale: locale))
        }
        let whole = Int(minutes)
        return L10n.plural(count: whole, one: "every %lld minute", other: "every %lld minutes")
    }

    /// Today's numbers as a spoken sentence (#252).
    ///
    /// Every number carries the word for what it counts, and the clauses are separated by commas
    /// rather than the interpunct `countsRow` uses — VoiceOver pauses on a comma and reads a `·`
    /// aloud. Only the three numbers a hover would act on: what was taken, what was summarized,
    /// and what it cost.
    public static func spokenTally(_ counts: MenuCounts, locale: Locale = Format.fixed) -> String {
        guard counts.captures > 0 else {
            return L10n.string("Nothing recorded yet today")
        }
        let taken = L10n.plural(
            count: counts.captures,
            one: "%lld screenshot today", other: "%lld screenshots today"
        )
        let summarized = L10n.format("%lld summarized", counts.described)
        let spent = L10n.format("%@ spent", MenuModel.money(counts.spendUSD, locale: locale))
        return [taken, summarized, spent].joined(separator: ", ")
    }

    /// #146: below this, a day counts as watched. Fifteen minutes is about the shortest gap a
    /// reader would notice missing from an afternoon.
    public static let materialGap: TimeInterval = 15 * 60

    /// An `NSMenuItem` title cannot be coloured, so the 80 %/100 % lines say so in words — and
    /// since #132 in words alone, with `StatusGlyph.budget` beside them rather than an emoji
    /// prefix. Dropping the marker without replacing it would have deleted the only warning the
    /// menu gives before the budget is spent.
    static func countsRow(
        _ counts: MenuCounts, budget: Double, level: SpendLevel, locale: Locale = Format.fixed
    ) -> MenuRow {
        // docs/copy.md: screenshot, summarized, waiting, on hold. "Frame" is the database's word
        // and the code's word; nobody outside this repository has heard it (#157).
        var parts = [
            L10n.plural(
                count: counts.captures,
                one: "Today: %lld screenshot", other: "Today: %lld screenshots"
            ),
            L10n.format("%lld summarized", counts.described),
        ]
        if counts.pending > 0 { parts.append(L10n.format("%lld waiting", counts.pending)) }
        // Printed only when it is not zero: a "0 failed" on every ordinary day teaches the eye to
        // skip the number, which is the one day it matters (#125).
        if counts.failed > 0 { parts.append(L10n.format("%lld failed", counts.failed)) }
        // "On hold", not "over budget": the screenshot is still there and a raise releases it.
        // Over budget is a fact about the day, and the spend clause below says it.
        if counts.skippedForBudget > 0 {
            parts.append(L10n.format("%lld on hold", counts.skippedForBudget))
        }
        // #151: the three privacy outcomes, each only when it happened — the same rule the
        // numbers above it follow. Before this they existed in a markdown footnote and in a
        // debug log, so a blocklist that stopped matching, or a morning of flagged frames, was
        // something you found out about a day later or not at all.
        if counts.blocked > 0 { parts.append(L10n.format("%lld blocked", counts.blocked)) }
        if counts.sensitive > 0 {
            parts.append(L10n.format("%lld flagged sensitive", counts.sensitive))
        }
        if counts.redactions > 0 {
            parts.append(
                L10n.plural(
                    count: counts.redactions,
                    one: "%lld item redacted", other: "%lld items redacted"
                ))
        }
        // #146: only when it is material. A day Worklens watched end to end gains nothing here,
        // and a minute lost to a restart is not worth a word — but an afternoon you paused has
        // to be visible, or the timeline's quiet afternoon looks like a fact about you.
        if counts.uncoveredSeconds >= MenuModel.materialGap {
            parts.append(
                L10n.format("%@ not watched", TimelineRenderer.duration(counts.uncoveredSeconds)))
        }

        let spend = MenuModel.money(counts.spendUSD, locale: locale)
        if budget > 0 {
            let against = L10n.format(
                "%@ of %@", spend, MenuModel.money(budget, locale: locale))
            switch level {
            case .over:
                parts.append(L10n.format("%@: over budget", against))
            case .warning:
                let percent = MenuModel.budgetPercent(counts.spendUSD, budget: budget)
                parts.append(
                    L10n.format("%@ (%lld %% of today's budget)", against, percent))
            case .nominal:
                parts.append(against)
            }
        } else {
            parts.append(spend)
        }
        return MenuRow(
            kind: level == .over ? .problem : .status,
            glyph: level == .nominal ? .tally : .budget,
            text: parts.joined(separator: " · ")
        )
    }

    /// The share of the budget spent, as a whole number, for the warning band only. Clamped into
    /// 80…99: `SpendLevel.warning` starts at 80 % by definition, and a spend a cent short of the
    /// budget must not round up to a "100 %" the `.over` wording is the one to say.
    static func budgetPercent(_ spend: Double, budget: Double) -> Int {
        guard budget > 0 else { return 0 }
        let percent = Int((spend / budget * 100).rounded())
        return min(99, max(Int(SpendLevel.warningFraction * 100), percent))
    }

    /// `60 s`, `5 min` — whichever reads better at that length.
    public static func cadence(_ seconds: Int, locale: Locale = Format.fixed) -> String {
        Format.cadence(seconds, locale: locale)
    }

    /// The cadence that is actually being used: the configured interval (or the meeting one),
    /// after `PowerPolicy` has stretched it for the battery (#145).
    static func effectiveInterval(_ state: MenuState) -> Int {
        let configured = state.inMeeting ? state.meetingIntervalSeconds : state.captureIntervalSeconds
        return PowerPolicy.decide(
            power: state.power, mode: state.batteryMode, baseIntervalSeconds: configured
        ).captureIntervalSeconds
    }

    /// `On battery · capturing every 5 min`, or nil while the policy is changing nothing (#145).
    ///
    /// The whole point of the line is that a slower cadence is never mistaken for a fault, so it
    /// names the reason first and stays a statement — nothing here is a warning, and there is
    /// nothing to fix.
    public static func batteryLine(_ state: MenuState) -> String? {
        guard PowerPolicy.isEasedOff(power: state.power, mode: state.batteryMode) else { return nil }
        // Low Power Mode is named when it is the reason, because switching it off is the answer.
        let reason = state.power.onBattery
            ? L10n.string("On battery")
            : L10n.string("Low Power Mode")
        let cadence = MenuModel.cadence(
            MenuModel.effectiveInterval(state), locale: state.locale
        )
        let line = L10n.format("%@ · capturing every %@", reason, cadence)
        guard state.batteryMode == .describeLater else { return line }
        return L10n.format("%@ · describing when plugged in", line)
    }

    /// Two decimals down to a cent, four below it — `$0.19`, `$0.0042`. `Format` owns the
    /// arithmetic; the menu passes the user's locale so a Brazilian Mac reads `US$ 0,19` (#157).
    public static func money(_ usd: Double, locale: Locale = Format.fixed) -> String {
        Format.money(usd, locale: locale)
    }

    /// Whether a pause deadline is the next local midnight — the "until tomorrow" pause, whoever
    /// set it. Used for the words in the status row, so a restored pause does not come back as a
    /// bare `00:00`.
    static func isMidnight(_ date: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
    }

    static func clock(
        _ date: Date, timeZone: TimeZone, locale: Locale = Format.fixed
    ) -> String {
        Format.clock(date, timeZone: timeZone, locale: locale)
    }
}
