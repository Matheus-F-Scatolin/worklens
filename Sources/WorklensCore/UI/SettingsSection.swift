import Foundation

/// The sections of Settings, which since #286 is a page inside the reader rather than a window of
/// its own: six sections, a hairline, then Advanced.
///
/// It lives in `WorklensCore` rather than beside the SwiftUI that draws it because the section
/// list, the deep links from the menu and from `worklens settings --tab`, and the row `app_state`
/// remembers are all the same list, and the only target with tests is this one.
///
/// The eleven panes of the old window folded into these seven. Their names are still out there —
/// in `app_state` under `settings_tab`, in a shell history's `worklens settings --tab
/// permissions`, in a second copy that posts `SettingsReveal` from an older build — so every one of
/// them still resolves, through `legacy(_:)`, to the section that holds what it used to.
public enum SettingsSection: String, Sendable, CaseIterable, Equatable, Hashable, Identifiable {
    /// The status line, launching, the shortcuts and updates.
    case general
    /// What Worklens looks at, how often, picture quality, and the Access card.
    case capture
    /// The one "Never look at" list, what is kept, and deleting a range.
    case privacy
    /// The projects your time is grouped under. It was Reports until the reports were cut
    /// (2026-10-05), then Log until it was named for what it holds; a stored `reports` or `log`
    /// still lands here, through `target(named:)`.
    case projects
    /// The AI provider, Claude as a client of Worklens, and the context sources.
    case connections
    /// Today's spend against the budget, the last 30 days, and the disk.
    case usage
    /// Tuning, the read-only facts, the log level and where each value comes from.
    case advanced

    public var id: String { rawValue }

    /// The rows above the hairline, in list order. Advanced is always below it and always shown:
    /// #286 removed the "Show advanced settings" switch.
    public static let primary: [SettingsSection] = allCases.filter { $0 != .advanced }

    /// The list row and the page's serif title.
    public var title: String {
        switch self {
        case .general: return L10n.string("General")
        case .capture: return L10n.string("Capture")
        case .privacy: return L10n.string("Privacy")
        case .projects: return L10n.string("Projects")
        case .connections: return L10n.string("Connections")
        case .usage: return L10n.string("Usage")
        case .advanced: return L10n.string("Advanced")
        }
    }

    /// The page behind the page title's **Learn more…** (#153): tested here so a re-mapping is a
    /// deliberate act, and so the CLI could print it.
    public var helpDoc: HelpDoc {
        switch self {
        // The layers, and which file each value is read from.
        case .general, .advanced: return .configuration
        // The Access card is most of what a person comes to Capture to fix.
        case .capture: return .permissions
        case .privacy: return .privacy
        // The projects are configuration, and that page says which layer each one comes from.
        case .projects: return .configuration
        case .connections: return .integrations
        case .usage: return .cost
        }
    }
}

/// A row a route can land on and light up, inside its section (#286). "Review" on the status
/// line, the old `permissions` pane and a notice's "Add a key" all mean one row, not the top of
/// a page.
public enum SettingsAnchor: String, Sendable, CaseIterable, Equatable, Hashable {
    /// Capture → Access: the grants.
    case access
    /// Connections → AI providers: the Gemini key.
    case providers
    /// Connections → Use Worklens from Claude or Codex.
    case assistants
    /// Connections → Sources.
    case sources
    /// Projects → the list of projects.
    case projects
    /// General → the status line and the notices under it.
    case status

    /// The section the row is on.
    public var section: SettingsSection {
        switch self {
        case .access: return .capture
        case .providers, .assistants, .sources: return .connections
        case .projects: return .projects
        case .status: return .general
        }
    }
}

/// Where a route into Settings lands: a section, and optionally one row on it.
public struct SettingsTarget: Sendable, Equatable, Hashable {
    public let section: SettingsSection
    public let anchor: SettingsAnchor?

    public init(_ section: SettingsSection, anchor: SettingsAnchor? = nil) {
        self.section = section
        self.anchor = anchor
    }

    /// A row, on the section it belongs to.
    public init(_ anchor: SettingsAnchor) {
        self.init(anchor.section, anchor: anchor)
    }
}

extension SettingsSection {
    /// Every raw value the old window's `SettingsPane` had (#112, #133, #248, #251). Kept as data
    /// so a test can prove none of them is left unmapped.
    public static let legacyValues: [String] = [
        "general", "capture", "privacy", "reports", "cost", "permissions", "projects",
        "integrations", "activity", "assistant", "advanced",
    ]

    /// The section a stored or typed name means: one of today's seven, or one of the old panes,
    /// folded into the section that now holds what it did. Case-insensitive, and blind to the
    /// spaces around it, so `--tab Permissions ` is the same request as `--tab permissions`.
    ///
    /// - `cost` → Usage (the budget and the spend). A route that is about a *key* names
    ///   `SettingsTarget(.providers)` itself; a bare stored `cost` cannot know which it meant.
    /// - `permissions` → Capture, on the Access card.
    /// - `reports` and `log` → Projects, on the list: Reports was this section's name until the
    ///   reports were cut (2026-10-05), and Log after that.
    /// - `integrations` → Connections, on Sources; `assistant` → Connections, on the Claude rows.
    /// - `activity` → General, where the notices are now listed under the status line.
    public static func target(named text: String) -> SettingsTarget? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let section = SettingsSection(rawValue: wanted) { return SettingsTarget(section) }
        switch wanted {
        case "cost": return SettingsTarget(.usage)
        case "permissions": return SettingsTarget(.access)
        case "reports", "log": return SettingsTarget(SettingsAnchor.projects)
        case "integrations": return SettingsTarget(.sources)
        case "assistant": return SettingsTarget(.assistants)
        case "activity": return SettingsTarget(.status)
        default: return nil
        }
    }

    /// The section a stored `settings_tab` restores to, or nil for a value no build ever wrote.
    public static func restoring(_ stored: String) -> SettingsSection? {
        target(named: stored)?.section
    }
}
