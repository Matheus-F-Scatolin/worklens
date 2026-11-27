import Foundation

/// Every banner Worklens posts, in one voice (#149).
///
/// The app used to write its notification copy at the nine call sites that posted one, and it
/// showed: two different bodies for the same event, an ISO date and a raw price in one of
/// them, a git SHA in the auto-update banner, and three titles for one hotkey. A banner
/// is the only sentence this app says to someone who is not looking at it, so all of them live
/// here, where a test can read them and where the rules hold by construction:
///
/// - a title is at most four words and never says "Worklens" unless the app itself is the subject
///   (the hotkey and the updater are the two that are);
/// - a body is one sentence, in the second person;
/// - no ISO date, no dollar amount, no commit SHA, no file path — a date is a weekday a person
///   recognises, and money stays on the menu's counts line where `MenuModel.money` formats it.
///
/// Pure strings, in `WorklensCore`, because copy in the app target is copy no test can reach.
public enum NotificationCopy {
    // MARK: - Budget

    public static var budgetReachedTitle: String { L10n.string("Daily budget reached") }
    public static var budgetReachedBody: String {
        L10n.string("Screenshots are still saved and on hold; summarizing resumes after midnight.")
    }

    // MARK: - Pausing

    /// A timed pause running out. Distinct from the hotkey's "capturing" banner, because nobody
    /// pressed anything — this is the app telling you it started again on its own.
    public static var pauseEndedTitle: String { L10n.string("Your pause has ended") }
    public static var pauseEndedBody: String { L10n.string("Worklens is capturing again.") }

    /// The hotkey's two answers (#136 posted three titles under one identifier, so a resume and a
    /// start read as different events when they are the same one).
    public static var pausedTitle: String { L10n.string("Worklens paused") }
    public static var pausedBody: String {
        L10n.string("Nothing is being captured until you resume.")
    }
    public static var capturingTitle: String { L10n.string("Worklens capturing") }
    public static var capturingBody: String { L10n.string("Worklens is capturing again.") }

    // MARK: - Describing

    /// The vision model has stopped answering. The old title — "Worklens is not summarizing your
    /// day" — broke both rules at once: six words, and the app as the subject of something that
    /// is really about the model behind it.
    public static var describeStalledTitle: String { L10n.string("Summaries have stopped") }

    /// `reason` is `DescribeHealth.line()`, which already names what went wrong and for how long.
    public static func describeStalledBody(_ reason: String?) -> String {
        sentence(reason, fallback: L10n.string("Worklens is not summarizing your screenshots."))
    }

    // MARK: - Summarizing through a plan (Part 4)

    public static func signInEndingTitle(_ tool: SubscriptionTool) -> String {
        L10n.format("%@ sign-in ending", DescribeHealth.planName(tool))
    }

    /// `Your Claude sign-in ends on Friday: run claude auth login before then to keep your
    /// screenshots summarized.` A weekday, never a date: it is at most three days away.
    public static func signInEndingBody(
        _ tool: SubscriptionTool, expiresAt: Date, now: Date = Date(),
        timeZone: TimeZone = .current, locale: Locale = Format.fixed
    ) -> String {
        let plan = DescribeHealth.planName(tool)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(expiresAt, inSameDayAs: now) {
            return L10n.format(
                "Your %@ sign-in ends today: run %@ before then to keep your screenshots summarized.",
                plan, tool.loginCommand)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(expiresAt, inSameDayAs: tomorrow) {
            return L10n.format(
                "Your %@ sign-in ends tomorrow: run %@ before then to keep your screenshots summarized.",
                plan, tool.loginCommand)
        }
        return L10n.format(
            "Your %@ sign-in ends on %@: run %@ before then to keep your screenshots summarized.",
            plan, Format.weekday(expiresAt, timeZone: timeZone, locale: locale), tool.loginCommand)
    }

    public static func signInEndedTitle(_ tool: SubscriptionTool) -> String {
        L10n.format("%@ sign-in ended", DescribeHealth.planName(tool))
    }

    /// Names what took over, or says nothing is summarized until the person signs in again.
    public static func signInEndedBody(_ tool: SubscriptionTool, summarizing: SummaryProvider?) -> String {
        let plan = DescribeHealth.planName(tool)
        if let summarizing {
            return L10n.format(
                "Your %@ sign-in ran out, so %@ is summarizing for now: run %@ in Terminal to switch back.",
                plan, SummaryConnection.name(summarizing), tool.loginCommand)
        }
        return L10n.format(
            "Your %@ sign-in ran out, so nothing is summarized until you run %@ in Terminal.",
            plan, tool.loginCommand)
    }

    public static var screenshotsWaitingTitle: String { L10n.string("Screenshots waiting") }

    /// `120 screenshots are waiting to be summarized: Settings → Connections shows …`, the same
    /// sentence as the notice.
    public static func screenshotsWaitingBody(_ waiting: Int, locale: Locale = Format.fixed) -> String {
        SummaryNotices.backlogMessage(waiting: max(waiting, SummaryNotices.backlogThreshold), locale: locale)
            ?? L10n.string("Screenshots are waiting to be summarized.")
    }

    // MARK: - Integrations

    /// `Granola needs attention`. The source names itself, so the app does not have to.
    public static func integrationAttentionTitle(_ source: String) -> String {
        L10n.format("%@ needs attention", source)
    }

    /// The source's own sentence, which never quotes a credential.
    public static func integrationAttentionBody(_ reason: String?) -> String {
        sentence(reason, fallback: L10n.string("Worklens could not sync it."))
    }

    /// Google expires the grant behind Calendar every seven days while the consent
    /// screen stays in Testing (#139).
    public static var googleReconnectTitle: String { L10n.string("Sign in to Google") }
    public static func googleReconnectBody(_ reason: String?) -> String {
        sentence(
            reason, fallback: L10n.string("Calendar is paused until you reconnect."))
    }

    // MARK: - Screen Recording

    /// The other half of the permission incident. The banner that opens it is
    /// `ScreenRecordingCopy`'s, which has more to explain; this one only has to say it is over.
    public static var permissionRestoredTitle: String { L10n.string("Capturing again") }
    public static var permissionRestoredBody: String {
        L10n.string("Screen Recording permission is back.")
    }

    // MARK: - Housekeeping

    public static var updatingTitle: String { L10n.string("Worklens is updating") }
    /// No branch name and no commit SHA: the SHA stays in the log and in Settings → Updates,
    /// where somebody who wants it is already looking at a build number.
    public static var updatingBody: String {
        // swift-format-ignore: LineLength — one key, one literal: a `+` split would hide it
        // from `scripts/strings-extract.sh`, which reads the code with a regex.
        L10n.string("A new build is available: Worklens restarts in about a minute, capturing nothing meanwhile.")
    }

    public static var databaseRecoveredTitle: String { L10n.string("New database started") }
    public static func databaseRecoveredBody(movedTo name: String) -> String {
        L10n.format("The old one could not be opened and was kept as %@.", name)
    }

    // MARK: - Passing a reason through

    /// A reason written elsewhere — a health line, a source's last error — made into a body.
    /// Trimmed, given the full stop the rule wants, and replaced wholesale when there is nothing
    /// to pass through, so no banner can end up with an empty second line.
    static func sentence(_ text: String?, fallback: String) -> String {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return fallback }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}
