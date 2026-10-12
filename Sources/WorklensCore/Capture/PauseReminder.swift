import Foundation

/// The "you are still paused" reminder (#113).
///
/// A pause now outlives a quit, a crash and the app's own auto-update, which is exactly what the
/// kill switch has to promise — and exactly how an afternoon ends up with no data because nobody
/// remembered. Pure, so the timing and the wording are tested without a notification centre.
public enum PauseReminder {
    /// Whether it is time to say it again. `everyHours <= 0` turns the reminder off.
    public static func isDue(since: Date, now: Date, everyHours: Int) -> Bool {
        guard everyHours > 0 else { return false }
        return now.timeIntervalSince(since) >= Double(everyHours) * 3600
    }

    public static var title: String { L10n.string("Worklens is still paused") }

    /// Always names the deadline, so the notification answers "until when?" on its own.
    public static func body(until: Date?, timeZone: TimeZone = .current) -> String {
        guard let until else {
            return L10n.string(
                "Nothing is being captured until you resume, from the menu or with the pause hotkey.")
        }
        return L10n.format(
            "Nothing is being captured until %@.", MenuModel.clock(until, timeZone: timeZone))
    }
}
