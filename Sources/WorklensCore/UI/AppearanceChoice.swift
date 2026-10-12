import Foundation

/// Settings → General → "Appearance": whether Worklens follows the system's light or dark mode or
/// holds one of them regardless. Stored in `app_state` under its raw value; the `Worklens` target
/// turns it into an `NSAppearance` for the whole app, so every window, the menu and the reader's
/// dynamic colours switch together, with no relaunch.
///
/// #357 second pass: a new install starts in light and is asked on the welcome window's first
/// page, where the three are cards and light is the one already ringed. An install that was set
/// up before that page existed, and never chose, keeps following the system.
public enum AppearanceChoice: String, Sendable, Equatable, CaseIterable {
    case system
    case light
    case dark

    /// What `app_state` holds, read back. Absent or unrecognised means `system`: an install that
    /// never chose looks the way the rest of the Mac does. A new install never gets here with
    /// nothing stored, because `firstRunDefault` writes light under it first.
    public init(stored: String?) {
        self = stored.flatMap(AppearanceChoice.init(rawValue:)) ?? .system
    }

    /// The segment's label.
    public var name: String {
        switch self {
        case .system: L10n.string("System")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    /// The welcome window's first page, left to right: light first, because it is what a new
    /// install already shows, then dark, then following the Mac.
    public static let cards: [AppearanceChoice] = [.light, .dark, .system]

    /// What a new install looks like before anything is chosen.
    public static let newInstall: AppearanceChoice = .light

    /// The choice to write at launch, or nil to leave `app_state` alone.
    ///
    /// Light, when the welcome window is about to open (`welcomeShows`: the launch gate answered
    /// show or resume) and nothing valid is stored yet — so the window, and everything after it,
    /// is light before the first page has been answered. Nil for an install that already chose,
    /// and for one the gate does not walk through: that one was set up before this page existed
    /// and keeps what it shows today.
    ///
    /// Nil, too, when the database did not open (`databaseOpen` false): the gate then shows the
    /// welcome to every install because it cannot read `onboarded_at`, and nothing stored could be
    /// read either, so turning an install that is past setup light would be a guess.
    public static func firstRunDefault(
        stored: String?, welcomeShows: Bool, databaseOpen: Bool = true
    ) -> AppearanceChoice? {
        guard databaseOpen, welcomeShows, stored.flatMap(AppearanceChoice.init(rawValue:)) == nil
        else { return nil }
        return newInstall
    }

    /// The card ringed when the first page opens: the choice already stored, or else what the app
    /// is showing. A new install is already light by then (`firstRunDefault`), so light is ringed;
    /// an install that never chose and opens the welcome again from Settings is following the
    /// Mac, so System is ringed and pressing Return through the page changes nothing.
    public static func preselected(stored: String?, showing: AppearanceChoice) -> AppearanceChoice {
        stored.flatMap(AppearanceChoice.init(rawValue:)) ?? showing
    }

    /// The card an arrow key moves the ring to: one along `cards`, stopping at either end.
    public func moved(by step: Int) -> AppearanceChoice {
        let cards = Self.cards
        let here = cards.firstIndex(of: self) ?? 0
        return cards[min(max(here + step, 0), cards.count - 1)]
    }
}
