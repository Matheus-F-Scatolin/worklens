import Foundation

/// The way back in when the menu-bar icon cannot be reached (#147).
///
/// A menu-bar app whose only affordance is a status item has no door left when the item is
/// hidden behind the notch, buried under a dozen other items, or tucked away by Bartender. There
/// are three doors now — re-opening the bundle, the Dock icon, and `worklens settings` — and two
/// of the three can be a *second process* asking the running one to show something. This is the
/// channel they ask over: `worklens settings` for Settings — since #286 a page of the reader
/// window rather than a window of its own — and a second copy of the app for the home window
/// (#279).
///
/// It is a `DistributedNotificationCenter` name and a one-string payload, deliberately: an Apple
/// event is the other obvious mechanism, and `make sign` passes `--options runtime`, so that one
/// would need the automation entitlement and a TCC consent dialog to do what a notification does
/// for free. Nothing is sent back — the sender exits, and the running app either shows Settings or
/// is not there to hear it.
///
/// It lives in `WorklensCore` because all three ends are in the app target (`SingleInstance`, the
/// `settings` subcommand and `AppDelegate`) and none of them should own the spelling.
public enum SettingsReveal {
    /// The notification name, keyed to the bundle identifier so a build of something else cannot
    /// be mistaken for a Worklens asking to be shown.
    public static let notificationName = Notification.Name(
        "\(Config.bundleIdentifier).show-settings"
    )

    /// The one key in the payload: which section to open on, by `SettingsSection.rawValue` — or,
    /// from an older build, by one of the old panes' names, which `SettingsSection.target(named:)`
    /// still folds into a section.
    public static let tabKey = "tab"

    /// The payload for a request, empty when no section was named — an absent tab means "the
    /// section you were last on", which is what `AppModel.openSettings()` already does with nil.
    ///
    /// Distributed notifications carry property-list values only, so this is `[String: String]`
    /// rather than anything richer.
    public static func userInfo(tab: SettingsSection?) -> [String: String] {
        guard let tab else { return [:] }
        return [tabKey: tab.rawValue]
    }

    /// Where a received request lands, or nil for "no preference" — including the case where the
    /// sender named something this build does not know.
    public static func target(in userInfo: [AnyHashable: Any]?) -> SettingsTarget? {
        guard let raw = userInfo?[tabKey] as? String else { return nil }
        return target(named: raw)
    }

    /// Where a `--tab` argument lands: one of the seven sections, or an old pane's name. Matching
    /// is case-insensitive and ignores surrounding spaces; anything else is nil, and the caller
    /// says what the accepted names are.
    public static func target(named text: String) -> SettingsTarget? {
        SettingsSection.target(named: text)
    }

    /// Whether a running process is a Worklens that would hear one of these requests.
    ///
    /// A bundled app answers by identifier. One started straight from a checkout
    /// (`swift run Worklens run`) has no bundle identifier at all, yet it registers the same
    /// observer, so its executable name is the only thing left to recognise it by (#147).
    public static func isWorklens(bundleIdentifier: String?, executableName: String?) -> Bool {
        if let bundleIdentifier { return bundleIdentifier == Config.bundleIdentifier }
        return executableName == "Worklens"
    }

    /// The accepted `--tab` values, for a help string and an error message. The old panes' names
    /// still work, but they are not advertised.
    public static var tabNames: [String] { SettingsSection.allCases.map(\.rawValue) }

    /// Ask the running copy of Worklens — if there is one — to bring its window to the front on
    /// Settings. Fire and forget: there is no reply, and nothing listening is not an error.
    public static func post(tab: SettingsSection? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: userInfo(tab: tab),
            deliverImmediately: true
        )
    }

    /// Listen for those requests. The returned token is the observer; drop it to stop listening.
    ///
    /// The handler runs on the main queue because everything it can do — activating the app,
    /// opening a window — is AppKit.
    @discardableResult
    public static func observe(_ handler: @escaping (SettingsTarget?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            handler(target(in: notification.userInfo))
        }
    }

    /// #279: what a second copy of the app asks for — the home window, not Settings. It asked for
    /// Settings when that was the only window a menu-bar app had to show; since #233 the reader
    /// is the home window, and a second launch should land where the Dock tile and ⌥⇧W do.
    /// On a machine with the app in two places, `open -b` and a Spotlight launch start the other
    /// copy rather than re-opening this one, so this is a door as often as the reopen message is.
    public static let homeNotificationName = Notification.Name(
        "\(Config.bundleIdentifier).show-home"
    )

    /// Ask the running copy to bring its home window to the front. Fire and forget, like `post`.
    public static func postHome() {
        DistributedNotificationCenter.default().postNotificationName(
            homeNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Listen for `postHome` requests, on the main queue, as `observe` does for Settings.
    @discardableResult
    public static func observeHome(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: homeNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }
}
