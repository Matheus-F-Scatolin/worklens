import Foundation

/// Every sentence Worklens says about a Screen Recording grant that is not in force, in one
/// place, because there are two of them and saying the wrong one is the bug this type exists for.
///
/// A Mac that has never been asked and a Mac that was granted and then revoked look identical to
/// `CGPreflightScreenCaptureAccess()` — both answer false — so the app cannot tell them apart by
/// asking macOS. What tells them apart is `screen_recording_granted_at` in `app_state`, written
/// the first time the grant is seen; `everGranted` is that key's presence and nothing else.
///
/// Getting it wrong is not cosmetic. "Worklens lost Screen Recording permission" on the first
/// minute of the first install accuses the user of revoking something they were never offered,
/// and sends them to a System Settings pane that has no Worklens row in it yet.
public enum ScreenRecordingCopy {
    /// The `SetupIssue.screenRecordingDenied` line, in the menu and in Settings → Activity.
    public static func problemMessage(everGranted: Bool) -> String {
        everGranted
            ? "Screen Recording permission was lost: nothing is being captured."
            : "Screen Recording is not on yet: nothing is being captured."
    }

    /// The notification's title. One per incident, never once per retry.
    public static func notificationTitle(everGranted: Bool) -> String {
        everGranted
            ? "Worklens lost Screen Recording permission"
            : "Worklens needs Screen Recording"
    }

    public static func notificationBody(everGranted: Bool) -> String {
        everGranted
            ? "macOS asks to re-confirm this periodically. Click to open settings."
            : "Nothing is captured until you turn it on. Click to do that now."
    }

    /// The one menu row the `.permissionMissing` mode offers, in place of Pause and the rest.
    /// It ends in "Fix…" rather than naming a pane: the button opens Settings → Permissions,
    /// where asking, re-checking and relaunching are all one click from each other.
    public static func menuFixLine(everGranted: Bool) -> String {
        everGranted
            ? "Screen Recording is off: Fix…"
            : "Screen Recording is not on yet: Fix…"
    }

    /// What the button that raises the macOS dialog says. "Ask macOS" rather than "Grant",
    /// because Worklens cannot grant anything: it can only put the question on screen.
    public static var askLabel: String { L10n.string("Ask macOS for Screen Recording…") }

    /// Said after the first grant lands, and the reason the Relaunch action exists at all:
    /// a process that was running when Screen Recording was switched on keeps the old answer
    /// until it is started again.
    public static let relaunchHint =
        "Screen Recording is on. Relaunch Worklens and it starts capturing."

    public static var relaunchLabel: String { L10n.string("Relaunch Worklens") }
}
