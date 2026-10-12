import Foundation

/// The documents the app links to, and where to find each one (#153).
///
/// `HelpLink` answers "which paragraph of the troubleshooting page"; this answers "which page",
/// for the Help menu and for the **Learn more** link every Settings pane carries. Both resolve
/// the same way and for the same reason: the repository is private, so a `github.com` URL opens
/// only for an account with access, and a build that was dragged out of its checkout has no
/// Markdown file beside it either.
///
/// So there are three answers, in this order:
///
/// 1. **The copy inside the bundle.** `scripts/bundle.sh` copies `PRIVACY.md`, `README.md` and
///    `docs/user/` into `Contents/Resources` under the same repo-relative paths, which is what
///    makes the privacy document reachable with no checkout and no network — the whole point of
///    a document that says what the app does with your screen.
/// 2. **The checkout**, when this build came from one that still has the page.
/// 3. **GitHub**, which is the fallback rather than the answer.
///
/// It is a plain `String` enum in `WorklensCore` on purpose, the same as `HelpLink`: the CLI,
/// the menu and the settings panes all need it and none of them may import SwiftUI.
public enum HelpDoc: String, CaseIterable, Sendable {
    /// What Worklens is, in one page. Bundled because `docs/user/index.md` links sideways to it.
    case readme = "README.md"
    /// What is recorded, what never is, and what leaves the Mac.
    case privacy = "PRIVACY.md"
    /// The user pages, in the order someone needs them.
    case index = "docs/user/index.md"
    /// Minute 0 to the first full day.
    case firstDay = "docs/user/first-day.md"
    /// Which permissions macOS asks for, and why each one.
    case permissions = "docs/user/permissions.md"
    /// The configuration layers and `worklens config`.
    case configuration = "docs/user/configuration.md"
    /// What a day costs, and the hard stop.
    case cost = "docs/user/cost.md"
    /// Granola and Google Calendar — what is stored and what is sent.
    case integrations = "docs/user/integrations.md"
    /// The symptom table `HelpLink`'s anchors point into.
    case troubleshooting = "docs/user/troubleshooting.md"
    /// #248: the read-only MCP server — connecting Claude Desktop and Claude Code, and what
    /// they can then ask for. The Claude pane's **Learn more**.
    case claudeDesktop = "docs/user/claude-desktop.md"

    /// The path inside the repository, inside the bundle's `Resources`, and on GitHub — one
    /// spelling for all three, which is why `bundle.sh` keeps the directories.
    public var repoRelativePath: String { rawValue }

    /// The menu item and the **Learn more** help text.
    public var title: String {
        switch self {
        case .readme: return "Read me"
        case .privacy: return "Privacy"
        case .index: return "Worklens help"
        case .firstDay: return "Getting started"
        case .permissions: return "Permissions"
        case .configuration: return "Configuration"
        case .cost: return "What it costs"
        case .integrations: return "Integrations"
        case .troubleshooting: return "Troubleshooting"
        case .claudeDesktop: return "Claude and Worklens"
        }
    }

    /// `Contents/Resources` of the running app bundle, or nil when Worklens is not running from
    /// one — `swift run` and the CLI, where `Bundle.main.resourceURL` is a build directory that
    /// carries none of these files.
    public static var bundledResources: URL? {
        BundleLayout.isBundled ? Bundle.main.resourceURL : nil
    }

    /// Where the page is on GitHub. Opens only for an account with access to a private
    /// repository, which is why it is the last of the three.
    public var webURL: URL {
        URL(string: "\(HelpLink.repositoryURL)/blob/main/\(rawValue)")!
    }

    /// The bundle's copy, the checkout's copy, or GitHub — in that order.
    ///
    /// - Parameters:
    ///   - resources: `HelpDoc.bundledResources`, nil for an unbundled build.
    ///   - checkout: `CheckoutLocator.resolve(…)`, nil for an app with no checkout behind it.
    ///   - fileExists: the existence test, injected so this is testable without either.
    public func url(
        bundledIn resources: URL? = bundledResources,
        inCheckout checkout: URL? = nil,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        for root in [resources, checkout].compactMap({ $0 }) {
            let local = root.appendingPathComponent(rawValue)
            if fileExists(local) { return local }
        }
        return webURL
    }
}
