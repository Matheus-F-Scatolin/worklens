import Foundation

/// When the two scheduler-owned banners are allowed to fire (#149).
///
/// `NotificationCopy` holds what those banners say; this holds whether they are said at all.
/// Both decisions used to sit inline in `AppModel`, where no test can reach them, and both are
/// the kind of thing that is wrong quietly: a pause banner that fires on a manual resume is
/// noise, and a budget banner with no latch is one banner per frame for the rest of the day.
///
/// Pure functions over values the caller already has. Nothing here reads a clock, a database or
/// a scheduler.
public enum BannerLatch {
    /// Whether a timed pause that has just stopped being in force deserves its "your pause has
    /// ended" banner.
    ///
    /// - `until` is the deadline of the pause that was in force, nil for "until I resume" —
    ///   which never runs out on its own and so never gets a banner.
    /// - The deadline has to have actually arrived: resuming from the menu is something the user
    ///   just did, and telling them about it is noise.
    /// - `permissionIncident` is the Screen Recording incident, which ends with its own
    ///   "Capturing again". Two banners for one resumption is one too many.
    public static func announcesPauseEnded(
        until: Date?, now: Date, permissionIncident: Bool
    ) -> Bool {
        guard let until, !permissionIncident else { return false }
        return now >= until
    }

    /// The local day to latch the "daily budget reached" banner on, or nil when it has already
    /// been posted for that day.
    ///
    /// `CaptureScheduler` sets `.budgetExceeded` per frame and puts it back to `.running` on the
    /// next under-budget one, so the state transition flaps and cannot be the latch. The day can:
    /// the caller stores what comes back, so a relaunch inside the same day stays quiet too.
    public static func budgetBannerDay(
        lastPosted: String?, now: Date, timeZone: TimeZone = .current
    ) -> String? {
        let today = DayBoundaries.dayString(now, timeZone: timeZone)
        return lastPosted == today ? nil : today
    }
}
