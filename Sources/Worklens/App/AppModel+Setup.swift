import Foundation
import WorklensCore

/// What the welcome window asks `AppModel`, and nothing else (#232).
///
/// Split out of `AppModel.swift` for the same reason `AppModel+Reader.swift` was: that file is
/// 195 k. Everything the six pages need beyond the members they already had is here.
@MainActor
extension AppModel {
    /// Whether the window's primary button may move off this page.
    ///
    /// Two pages hold Continue back until the thing they asked for has happened: Screen
    /// Recording, and the Gemini key without which Worklens captures screenshots it can never
    /// describe. Neither is a wall — both offer a plain button that says in its own words what
    /// leaving without it means, because a page nobody can leave is a page people force-quit.
    func setupCanContinue(from page: SetupPage) -> Bool {
        switch page {
        case .screenRecording: return screenRecording == .granted
        case .keys: return setupProgress.geminiKey
        case .appearance, .privacy, .tour, .ready: return true
        }
    }

    /// The plain button beside Continue, or nil where the page has nothing to skip past.
    func setupSkipLabel(for page: SetupPage) -> String? {
        switch page {
        case .screenRecording:
            return screenRecording == .granted ? nil : SetupCopy.screenRecordingSkip
        case .keys:
            return setupProgress.geminiKey ? nil : SetupCopy.keysLater
        case .appearance, .privacy, .tour, .ready:
            // #357: the tour is part of setting up. Its page has Take the tour, and
            // Continue once a tour has ended (`setupTourTaken`), never a Skip.
            return nil
        }
    }

    /// Whether a tour has ever ended on this Mac, finished or not (`TourMemory`).
    ///
    /// The tour page's one button is **Take the tour** for anyone who has never taken it
    /// (#357). Once one has ended, the page also offers Continue, so going Back to reread the
    /// privacy page does not mean sitting through the whole tour again to reach Screen Recording.
    var setupTourTaken: Bool {
        guard let db else { return false }
        return TourMemory.outcome(in: AppStateStore(db)) != nil
    }

    /// The last page's opening line: capture is already running, or it starts when this window
    /// closes. `setupPending` is the launch gate that holds the scheduler until `finishSetup()`.
    var setupReadyLine: String {
        setupPending ? SetupCopy.readyStartsOnClose : SetupCopy.readyCapturing
    }

    // MARK: - Surviving the relaunch (#246)

    /// `app_state` key holding the page the welcome window is on, by name.
    ///
    /// Written whenever the page changes and deleted when the window is finished or asked for
    /// from Settings, so its presence means exactly "a sequence was left unfinished on this
    /// page". A name, never a number: a page added or removed later degrades to page one rather
    /// than resuming on the wrong one. Nothing about the person is in it.
    static let setupPageKey = "setup_page"

    /// Moves the window to `page` and remembers it, which is what makes the relaunch macOS
    /// forces for Screen Recording survivable.
    ///
    /// The only mover: `SetupWindowView`'s Back, Continue and skip buttons all come here, and
    /// the launch gate's `resume` sets the page directly because there is nothing new to write.
    func setupMove(to page: SetupPage) {
        setupPage = page
        // The confirming line belongs to the page that was come back to, and this is a move off
        // it — one sentence about the relaunch, once.
        setupResumedPage = nil
        guard let db else { return }
        try? AppStateStore(db).set(AppModel.setupPageKey, page.rawValue)
    }

    /// The card the first page rings when it opens (#357 second pass): what `app_state` already
    /// holds, or else what the app is showing — light on a new install, System on an older one
    /// that never chose and opened the welcome again from Settings.
    var setupAppearancePreselection: AppearanceChoice {
        let stored = db.flatMap { (try? AppStateStore($0).get(AppModel.appearanceKey)) ?? nil }
        return AppearanceChoice.preselected(stored: stored, showing: appearance)
    }

    /// A card clicked, or Return on the ringed one: applied at once, the same way Settings →
    /// General applies it, and the window goes on to the next page.
    func chooseSetupAppearance(_ choice: AppearanceChoice) {
        setAppearance(choice)
        // `setAppearance` writes nothing when the value is already showing; a choice made here
        // is a choice, so it is stored either way and the next opening rings it.
        if let db { try? AppStateStore(db).set(AppModel.appearanceKey, choice.rawValue) }
        recheckPermissions()
        if let next = SetupPage.appearance.next { setupMove(to: next) }
    }

    /// Forgets the page. `openSetup()` calls it — "show me the welcome again" means from the
    /// beginning — and so does finishing the window, which leaves nothing to come back to.
    func clearSetupPage() {
        setupResumedPage = nil
        guard let db else { return }
        try? AppStateStore(db).delete(AppModel.setupPageKey)
    }

    /// The one sentence above a resumed page's heading, or nil on a page nobody came back to.
    ///
    /// `SetupGate.resumeLine` owns the words; this is only the question of whether they still
    /// apply, which they do until the user moves off the page they were returned to.
    var setupResumeNote: String? {
        guard let resumed = setupResumedPage, resumed == setupPage else { return nil }
        return SetupGate.resumeLine(screenRecording: screenRecording == .granted)
    }

    // MARK: - Asking for Notifications when they pay off (#246)

    /// `app_state` key stamped the one time Worklens raises the notifications dialog itself.
    ///
    /// macOS answers a second request without drawing anything, so asking twice is a banner
    /// silently lost — and somebody who dismissed the dialog without answering has answered
    /// enough. Settings → Permissions keeps its own button for a deliberate second go.
    static let notificationsAskedKey = "notifications_asked_at"

    /// Whether the dialog has already been raised from the banner path on this Mac.
    var notificationsAskedBefore: Bool {
        guard let db else { return false }
        return ((try? AppStateStore(db).get(AppModel.notificationsAskedKey)) ?? nil) != nil
    }

    /// What macOS has been told, as `NotificationConsent` needs it. `Notifier.delivers` stays
    /// the one place that decides which statuses reach a screen.
    var notificationSystemState: NotificationConsent.SystemState {
        if notifications == .notDetermined { return .notAsked }
        return Notifier.delivers(notifications) ? .allowed : .denied
    }

    /// Ask, post, or stay quiet — the whole rule is `NotificationConsent.decide`, and this is
    /// the app's side of it: the two states that are not a value (no app bundle, the welcome
    /// window on screen) and the stamp that makes "never twice" true across launches.
    func notificationConsent(for moment: NotificationMoment) -> NotificationConsent.Answer {
        // `swift run Worklens` has no bundle, so `UNUserNotificationCenter` traps and nothing
        // could be drawn anyway.
        guard Notifier.isAvailable else { return .quiet }
        return NotificationConsent.decide(
            moment: moment,
            system: notificationSystemState,
            alreadyAsked: notificationsAskedBefore,
            welcomeOnScreen: setupPending || setupWindowVisible
        )
    }

    /// Stamps that the dialog has been raised. Written before the dialog rather than after it,
    /// because a user who closes it without answering leaves the status `.notDetermined`.
    func recordNotificationAsk() {
        guard let db else { return }
        try? AppStateStore(db).setDate(AppModel.notificationsAskedKey, Date())
    }
}
