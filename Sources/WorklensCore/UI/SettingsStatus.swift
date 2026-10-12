import Foundation

/// General's status line (#286): one row, one clause, and the condition behind the needs-you dot
/// on the rail's gear and beside a section's name.
///
/// The priority is the issue's, in this order:
/// 1. the most urgent thing that needs you — a missing grant or an open notice — with its remedy;
/// 2. everything is working: what capture is doing.
///
/// It reads `MenuState`, the same facts the menu-bar menu draws from, so the menu and Settings
/// cannot disagree about what is wrong.
public struct SettingsStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case needsYou
        case working
    }

    /// What the one button beside the line does.
    public enum Remedy: Equatable, Sendable {
        /// Jump to a row of Settings and light it up.
        case review(SettingsTarget)
        /// Run the notice's own remedy.
        case perform(NoticeAction)
    }

    public let kind: Kind
    /// The bold words: `One thing needs you`, `Capturing`, `Everything is working`.
    public let headline: String
    /// The muted clause after them.
    public let detail: String
    /// The button's label and what it does, or nil for none.
    public let remedyLabel: String?
    public let remedy: Remedy?
    /// How many things want you, counting the one the line names.
    public let needs: Int
    /// The section whose name, and whose gear, carries the dot. Nil unless `kind == .needsYou`.
    public let dotSection: SettingsSection?
}

/// One thing that needs you, most urgent first.
public struct SettingsNeed: Equatable, Sendable {
    public let sentence: String
    public let remedy: SettingsStatus.Remedy
    /// The notice behind it, when there is one, so the list under the line can offer Dismiss and
    /// say when it was raised. Nil for a condition (a grant, a rejected key), which goes away
    /// only when it is fixed.
    public let noticeID: UUID?
    public let at: Date?

    public init(sentence: String, remedy: SettingsStatus.Remedy, noticeID: UUID? = nil, at: Date? = nil) {
        self.sentence = sentence
        self.remedy = remedy
        self.noticeID = noticeID
        self.at = at
    }

    /// The section the dot goes on.
    public var section: SettingsSection {
        switch remedy {
        case let .review(target): return target.section
        case let .perform(action): return SettingsNeed.section(for: action)
        }
    }

    /// Where a notice's remedy lives now: the rows the old panes' actions opened.
    static func section(for action: NoticeAction) -> SettingsSection {
        switch action {
        case .openAccountSettings, .reconnectGoogle, .reconnectClaude, .syncIntegrations: return .connections
        case .grantScreenRecording, .grantAccessibility, .relaunchWorklens: return .capture
        case .openEnvFile, .reloadConfig, .openLogFile: return .advanced
        case .retryDailyReport, .retryWeeklyReport: return .general
        }
    }
}

extension SettingsStatus {
    /// Every thing that needs you, most urgent first: the grant capture cannot run without, the
    /// open problems newest first, a source that wants reconnecting, then the optional grants you
    /// have not said "don't remind me" about.
    public static func needs(
        state: MenuState, now: Date = Date(), timeZone: TimeZone = .current
    ) -> [SettingsNeed] {
        var needs: [SettingsNeed] = []
        if state.scheduler == .permissionMissing {
            needs.append(SettingsNeed(
                sentence: L10n.string("Screen Recording is off, so nothing is being captured"),
                remedy: .review(SettingsTarget(.access))
            ))
        }
        // A rejected key stops every summary, and the menu says so as its problem line. Only the
        // key's fault earns a place: a 503 or a schema failure is a stall with nothing to fix.
        var healthLine: String?
        if state.describeHealth.isKeyRejection, let line = state.describeHealth.line(now: now, timeZone: timeZone) {
            healthLine = line
            needs.append(SettingsNeed(sentence: clause(line), remedy: .review(SettingsTarget(.providers))))
        }
        // The same condition raised as a notice is one thing, not two.
        let open = state.notices.filter(\.isOpen).sorted { $0.at > $1.at }
            .filter { $0.message != healthLine }
        for notice in open {
            let remedy: Remedy
            if let action = notice.action {
                remedy = action.reviewTarget.map { .review($0) } ?? .perform(action)
            } else {
                remedy = .review(SettingsTarget(.status))
            }
            needs.append(SettingsNeed(
                sentence: SettingsStatus.clause(notice.message), remedy: remedy,
                noticeID: notice.id, at: notice.at
            ))
        }
        for name in state.integrationsNeedingAttention {
            needs.append(SettingsNeed(
                sentence: L10n.format("%@ needs connecting again", name),
                remedy: .review(SettingsTarget(.sources))
            ))
        }
        if state.accessibilityMissing, !state.accessibilityAdvisorySkipped {
            needs.append(SettingsNeed(
                sentence: L10n.string("Accessibility is off, so Worklens reads no window text"),
                remedy: .review(SettingsTarget(.access))
            ))
        }
        if !state.browserAdvisorySkipped {
            if !state.browsersNotAsked.isEmpty {
                let names = SettingsStatus.list(state.browsersNotAsked)
                needs.append(SettingsNeed(
                    sentence: state.browsersNotAsked.count == 1
                        ? L10n.format("%@ hasn't been asked to share page addresses", names)
                        : L10n.format("%@ haven't been asked to share page addresses", names),
                    remedy: .review(SettingsTarget(.access))
                ))
            }
            if !state.browsersMissingURLs.isEmpty {
                let names = SettingsStatus.list(state.browsersMissingURLs)
                needs.append(SettingsNeed(
                    sentence: state.browsersMissingURLs.count == 1
                        ? L10n.format("%@ isn't allowed to share page addresses", names)
                        : L10n.format("%@ aren't allowed to share page addresses", names),
                    remedy: .review(SettingsTarget(.access))
                ))
            }
        }
        return needs
    }

    /// The line itself.
    ///
    /// - `firstActivity`: when today's first screenshot was taken (`CaptureStore.firstCaptureAt`);
    ///   nil before there is one, and then the line says the cadence instead.
    /// - `captureLine`: the menu's own status row (`Paused until 14:30`), used when capture is
    ///   not simply running — the menu already words every one of those states.
    public static func make(
        state: MenuState,
        firstActivity: Date?,
        captureLine: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> SettingsStatus {
        let needs = needs(state: state, now: now, timeZone: timeZone)
        if let first = needs.first {
            let label: String
            switch first.remedy {
            case .review: label = L10n.string("Review")
            case let .perform(action): label = action.label
            }
            return SettingsStatus(
                kind: .needsYou,
                headline: needs.count == 1
                    ? L10n.string("One thing needs you")
                    : L10n.format("%@ things need you", Format.count(needs.count, locale: locale)),
                detail: first.sentence,
                remedyLabel: label,
                remedy: first.remedy,
                needs: needs.count,
                dotSection: first.section
            )
        }
        let capture = captureClause(
            state: state, firstActivity: firstActivity, captureLine: captureLine,
            timeZone: timeZone, locale: locale
        )
        // "Everything is working" only while capture is running; a pause or a stop leads with the
        // menu's own words for it, so the line never says "working · paused".
        let running = state.scheduler == .running
        return SettingsStatus(
            kind: .working,
            headline: running ? L10n.string("Everything is working") : capture.headline,
            detail: running ? capture.clause : "",
            remedyLabel: nil,
            remedy: nil,
            needs: 0,
            dotSection: nil
        )
    }

    /// `capturing since 09:02`, `capturing every 30 s`, or the menu's own words for anything else.
    static func captureClause(
        state: MenuState, firstActivity: Date?, captureLine: String,
        timeZone: TimeZone, locale: Locale
    ) -> (headline: String, clause: String) {
        guard state.scheduler == .running else {
            return (captureLine, clause(captureLine))
        }
        let clause: String
        if let firstActivity {
            clause = L10n.format(
                "capturing since %@", Format.clock(firstActivity, timeZone: timeZone, locale: locale)
            )
        } else {
            clause = L10n.format(
                "capturing every %@", Format.cadence(state.captureIntervalSeconds, locale: locale)
            )
        }
        return (L10n.string("Capturing"), clause)
    }

    /// A notice's sentence as the clause after an interpunct: its first letter lowered unless the
    /// first word is a name ("Screen Recording", "Gemini"), and no closing full stop.
    static func clause(_ sentence: String) -> String {
        var text = sentence.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.prefix { $0 != " " }
        // A word with a second capital, or a one-word proper noun the sentence starts with, is a
        // name; lowering it would misspell it. Most notices start with an ordinary word.
        if word.dropFirst().contains(where: \.isUppercase) { return text }
        if SettingsStatus.names.contains(String(word)) { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// The names a notice can start with.
    static let names: Set<String> = [
        "Worklens", "Gemini", "Claude", "Anthropic", "Google", "Granola", "Screen", "Accessibility",
        "Chrome", "Safari", "Arc", "Brave", "Edge", "Firefox",
    ]

    /// `Safari`, `Safari and Arc`, `Safari, Arc and Brave`.
    static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }
}

extension NoticeAction {
    /// The row of Settings a notice's action used to open a pane for (#286), or nil when the
    /// action does its own thing — a retry, a relaunch, a file.
    var reviewTarget: SettingsTarget? {
        switch self {
        case .openAccountSettings: return SettingsTarget(.providers)
        case .reconnectGoogle: return SettingsTarget(.sources)
        case .reconnectClaude: return SettingsTarget(.assistants)
        case .grantScreenRecording, .grantAccessibility: return SettingsTarget(.access)
        default: return nil
        }
    }
}
