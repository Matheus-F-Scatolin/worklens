import Foundation

/// The words around the sample week (#349, #350). Second person, no dashes (`docs/copy.md`).
public enum SampleWeekCopy {
    /// The ribbon on the Today and Weeks pages while the sample is shown.
    public static var ribbon: String { L10n.string("Sample week: invented, not yours.") }

    /// The ribbon's button, and the VoiceOver name it is read by.
    public static var leave: String { L10n.string("Leave sample week") }

    /// The ribbon's status line once the welcome is finished and nothing is in the way.
    public static var firstMoments: String { L10n.string("Your first moments show up in about a minute.") }

    /// Settings → Advanced.
    public static var settingTitle: String { L10n.string("Sample week") }
    public static var settingDetail: String {
        L10n.string("An invented week to look around in. It is never sent to Claude.")
    }
    public static var show: String { L10n.string("Show sample week") }

    /// The one notification, on your first real summary.
    public static var startedTitle: String { L10n.string("Your day has started.") }
    public static var startedBody: String {
        L10n.string("The sample week is gone. Your own day is on the Today page: choose Open Worklens in the menu bar.")
    }
}
