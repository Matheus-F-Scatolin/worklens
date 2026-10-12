import Foundation

/// Why a banner is about to be posted (#246).
///
/// One of these earns the notifications dialog, because it is the moment a banner is the only
/// thing that reaches somebody who is not looking at the menu bar: a Screen Recording grant that
/// has gone. A report that was ready was the second, until the reports were cut (2026-10-05).
/// Everything else Worklens posts — a pause reminder, a stalled describe worker, an integration that needs reconnecting — is a line the
/// menu carries anyway, and none of them is worth a dialog nobody asked for.
public enum NotificationMoment: String, Sendable, CaseIterable, Equatable {
    /// Screen Recording has gone, so capture has stopped until it comes back (#117).
    case screenRecordingOutage
    /// Any other banner. Never asks; posts when macOS has already said yes.
    case other

    /// Whether a banner of this kind is worth raising the macOS dialog for.
    public var earnsTheDialog: Bool {
        switch self {
        case .screenRecordingOutage: return true
        case .other: return false
        }
    }
}

/// Whether to ask macOS for Notifications, post, or stay quiet (#246).
///
/// A value, not a service: given what macOS has been told, whether Worklens has already asked,
/// whether the welcome window is on screen and what is about to be posted, it answers one of
/// three things. `AppModel.postBanner` is the one caller, which is what makes "never at launch,
/// never during the welcome, never twice" a tested rule rather than a habit of the call sites.
///
/// Before this, the only place in the app that ever asked was the welcome's optional-permissions
/// page — and #232 deleted that page, so a fresh install never asked at all and the whole
/// outage-recovery story from #117 had nothing to announce itself with. The other way round is
/// what #131 was fixing: a dialog as the first act of a first launch, before anything had said
/// what Worklens records.
public enum NotificationConsent {
    /// What macOS has been told, as this decision needs it. `UNAuthorizationStatus` has five
    /// cases and two of them deliver; the app maps them onto these three and `WorklensCore`
    /// stays free of `UserNotifications`.
    public enum SystemState: String, Sendable, CaseIterable, Equatable {
        /// macOS has never been asked. A banner posted now draws nothing at all.
        case notAsked
        /// `.authorized` or `.provisional` — a banner reaches the screen.
        case allowed
        /// The user said no, here or in System Settings. Asking again does nothing: macOS asks
        /// once, and after that only System Settings changes the answer.
        case denied
    }

    public enum Answer: String, Sendable, CaseIterable, Equatable {
        /// Raise the macOS dialog now, and post once it has been answered.
        case ask
        /// Post. macOS has already said yes.
        case post
        /// Post nothing and ask nothing — a banner under this state reaches no screen, so the
        /// menu line the caller raises anyway is the whole of what the user sees.
        case quiet
    }

    /// - Parameters:
    ///   - moment: what is about to be posted.
    ///   - system: what macOS has been told.
    ///   - alreadyAsked: whether Worklens has raised the dialog from this path before, on this
    ///     Mac. macOS answers the second request without showing anything, so asking twice is
    ///     only ever a banner silently lost — and a user who dismissed the dialog without
    ///     answering has answered enough.
    ///   - welcomeOnScreen: whether the welcome window is up. A dialog stacked on top of the
    ///     window that is explaining the app is the first-launch pile-up #131 removed.
    public static func decide(
        moment: NotificationMoment,
        system: SystemState,
        alreadyAsked: Bool,
        welcomeOnScreen: Bool
    ) -> Answer {
        switch system {
        case .allowed:
            return .post
        case .denied:
            // Nothing to ask and nothing that would be drawn. The caller's menu line stands in.
            return .quiet
        case .notAsked:
            guard moment.earnsTheDialog, !alreadyAsked, !welcomeOnScreen else { return .quiet }
            return .ask
        }
    }

    /// The welcome's last page, in one line: what will happen, and when, so the dialog that
    /// arrives days later is not a surprise.
    public static let welcomeLine = L10n.string(
        "Worklens will offer notifications the first time it has something to tell you, such as a permission that has gone.")

    /// Settings → Permissions, under the row that is the permanent way in.
    public static let settingsNote = L10n.string(
        "Worklens offers notifications the first time one would be worth reading.")
}
