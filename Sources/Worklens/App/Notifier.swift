import AppKit
import Foundation
import UserNotifications
import WorklensCore

/// The notifications Worklens sends — "Screen Recording permission is gone" first among them —
/// plus the authorization dance around them.
///
/// Every call is a no-op outside an app bundle: `UNUserNotificationCenter.current()` traps when
/// the process has no bundle identifier, which is exactly what `swift run Worklens` is.
enum Notifier {
    /// Attached to a notification so the click handler knows to open the Screen Recording pane.
    static let permissionCategory = "dev.worklens.permission"
    /// The banner raised when the database had to be replaced, which carries the path it was
    /// moved to so "Show in Finder" has something to reveal.
    static let databaseCategory = "dev.worklens.database"
    /// #350: "Your day has started.", posted once ever, on your first real summary. A request
    /// identifier rather than a category: it has no buttons, and a second post would replace it.
    static let sampleWeekHandoff = "dev.worklens.sample-week-handoff"
    /// A banner whose click opens the reader on the Today page: the handoff above, which quotes
    /// your first summary and so is worth seeing in place.
    static let todayCategory = "dev.worklens.today"

    /// Action identifiers. A category with no registered actions is a banner with no buttons —
    /// and, before #149, a banner whose click did nothing at all.
    static let showInFinderAction = "dev.worklens.show-in-finder"

    /// `userInfo` keys, so the click handler and the post site agree on one spelling.
    enum Key {
        static let path = "path"
    }

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Registers the categories at launch, before anything can post one: macOS reads the
    /// category off the content when the notification is delivered, and a category it has never
    /// been told about is a banner with no buttons.
    static func registerCategories() {
        guard isAvailable else { return }
        let database = UNNotificationCategory(
            identifier: databaseCategory,
            actions: [
                UNNotificationAction(
                    identifier: showInFinderAction, title: String(localized: "Show in Finder", comment: "Notification action"), options: [.foreground]
                )
            ],
            intentIdentifiers: []
        )
        // The permission banner has always been click-to-open with no button, and stays that way.
        let permission = UNNotificationCategory(
            identifier: permissionCategory, actions: [], intentIdentifiers: []
        )
        // Click-to-open as well: the click is the whole action.
        let today = UNNotificationCategory(
            identifier: todayCategory, actions: [], intentIdentifiers: []
        )
        UNUserNotificationCenter.current()
            .setNotificationCategories([database, permission, today])
    }

    static func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.ui.warn("notification authorization failed: \(error.localizedDescription)")
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .notDetermined }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Whether a banner posted under this status actually reaches the screen.
    ///
    /// `.notDetermined` is not "probably fine": macOS asks once, the app only asks from the
    /// welcome's Notifications row and from Settings → Permissions, and an install that skipped
    /// both sits in `.notDetermined` for good. `add` then answers with an error and nothing is
    /// drawn — which is the same outcome as `.denied`, so `postBanner` has to mirror it onto the
    /// menu the same way. `.provisional` is the one non-`.authorized` status that does deliver.
    static func delivers(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: return true
        default: return false
        }
    }

    /// Opens System Settings → Notifications (#117). The row in Settings → Permissions can say
    /// "Not asked yet" for the rest of a launch — macOS asks once, at startup — and without this
    /// there was nothing on the pane that could change the answer.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        // NSWorkspace is AppKit: hop to the main thread rather than whatever thread called us.
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Posts a banner. `identifier` deduplicates: posting the same id twice replaces the first,
    /// which is what keeps "permission lost" from stacking up once per retry.
    static func post(
        title: String,
        body: String,
        identifier: String,
        category: String? = nil,
        userInfo: [String: String] = [:]
    ) {
        guard isAvailable else {
            Log.ui.info("notification (no bundle, not shown): \(title)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.ui.warn("could not post a notification: \(error.localizedDescription)") }
        }
    }
}
