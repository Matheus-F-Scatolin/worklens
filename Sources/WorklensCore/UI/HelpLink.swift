import Foundation

/// One name per answered symptom in `docs/user/troubleshooting.md`, so the menu, the settings
/// panes and the CLI can all send you to the same paragraph (#142).
///
/// It is a plain `String` enum on purpose: the anchors have to be usable from `WorklensCore`,
/// from the app and from a CLI subcommand that prints to stderr, and none of that may import
/// SwiftUI. `HelpLinkTests` asserts every case below is a heading in that page, so a renamed
/// section fails a test rather than quietly pointing at nothing.
///
/// Resolution has two answers because the repository is private: a `github.com` URL opens only
/// for someone signed in with access, while the checked-out Markdown file opens for anyone
/// running a build made from a checkout. `url(inCheckout:)` prefers the local file when there is
/// one — the same "is the app running from the checkout it was built from?" question
/// `CheckoutLocator` already answers for "Update and restart…" — and falls back to the web URL.
public enum HelpLink: String, CaseIterable, Sendable {
    /// The icon went red: the daily budget, or capture having stopped.
    case redIcon = "the-menu-bar-icon-is-red"
    /// Screen Recording is off, was never granted, or was silently lost.
    case screenRecordingOff = "nothing-is-being-captured"
    /// Frames are captured and kept, but nothing describes them.
    case framesNotDescribed = "frames-pile-up-as-pending-or-over-budget"
    /// Today's counts look like they reset: two data directories, one of them not the one you
    /// were looking at.
    case dataDirectoryChanged = "todays-counts-reset-after-a-make-run"
    /// The timeline names the browser but never the page: the per-browser Automation grant.
    case browserURLMissing = "the-timeline-says-chrome-but-never-which-page"
    /// A grant that did not survive a rebuild, because the signature changed.
    case permissionAskedAgain = "macos-asks-for-a-permission-again-after-a-rebuild"
    /// The Google keychain item's per-build partition list.
    case keychainPrompt = "a-keychain-dialog-on-every-new-build"
    /// The menu offers no "Update and restart…" item.
    case noUpdateItem = "there-is-no-update-and-restart-item"
    /// An update that stopped partway.
    case updateFailed = "the-update-failed"
    /// `DATA_DIR` is inside iCloud Drive, Dropbox or another file provider's folder.
    case syncedDataDirectory = "the-menu-says-the-data-directory-is-in-a-synced-folder"
    /// The status item is not where it can be clicked: a full menu bar, the notch, or an item
    /// hider (#147).
    case menuBarIconMissing = "i-cannot-find-the-menu-bar-icon"
    /// An MCP client that lists none of the Worklens tools.
    case mcpToolsMissing = "claude-desktop-does-not-show-the-worklens-tools"

    /// The page every anchor above lives in, relative to the repository root.
    public static let page = "docs/user/troubleshooting.md"

    /// Where a build with no stamp at all — `swift run`, or a bundle assembled outside a
    /// checkout — sends someone.
    public static let fallbackRepositoryURL = "https://github.com/Matheus-F-Scatolin/worklens"

    /// `https://github.com/<owner>/<repo>` — the same repository `AutoUpdater` polls.
    /// `scripts/bundle.sh` stamps the repository the build came from, so a fork's build links to
    /// the fork's copy of the page; a remote that is not a web URL (a local mirror) is ignored.
    /// The same rule as `AppModel.privacyDocURL`.
    public static var repositoryURL: String {
        BuildStamp.current.repositoryURL.flatMap { $0.hasPrefix("http") ? $0 : nil }
            ?? fallbackRepositoryURL
    }

    /// The anchor alone, without the `#`.
    public var anchor: String { rawValue }

    /// What an error message prints: short enough for one line of stderr, and the thing to
    /// search for when neither URL below can be opened.
    public var repoRelativePath: String { "\(Self.page)#\(anchor)" }

    /// Where the page is on GitHub. Opens only for an account with access to a private
    /// repository, which is why it is the fallback rather than the answer.
    public var webURL: URL {
        URL(string: "\(Self.repositoryURL)/blob/main/\(Self.page)#\(anchor)")!
    }

    /// The page on GitHub with no anchor, for the menu item that is not about one symptom.
    public static var pageWebURL: URL {
        URL(string: "\(repositoryURL)/blob/main/\(page)")!
    }

    /// The whole page, resolved the same way `url(inCheckout:)` resolves one anchor: what the
    /// menu's **Troubleshooting…** item opens.
    public static func pageURL(
        inCheckout checkout: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        guard let checkout else { return pageWebURL }
        let local = checkout.appendingPathComponent(page)
        return fileExists(local) ? local : pageWebURL
    }

    /// The file inside a checkout, whether or not it exists.
    public func fileURL(inCheckout checkout: URL) -> URL {
        checkout.appendingPathComponent(Self.page)
    }

    /// The local Markdown file when this build came from a checkout that still has the page,
    /// the GitHub URL otherwise.
    ///
    /// - Parameters:
    ///   - checkout: `CheckoutLocator.resolve(…)`, nil for an installed or downloaded bundle.
    ///   - fileExists: the existence test, injected so this is testable without a checkout.
    public func url(
        inCheckout checkout: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        guard let checkout else { return webURL }
        let local = fileURL(inCheckout: checkout)
        return fileExists(local) ? local : webURL
    }
}

/// The bundled copy of the page, which an installed app has and a checkout-less one needs (#153).
///
/// `scripts/bundle.sh` ships `docs/user/` inside `Contents/Resources` under the same
/// repo-relative paths, so the resolution order becomes bundle → checkout → GitHub. The two
/// methods below are overloads rather than a new default argument: the existing
/// `url(inCheckout:)` is what the CLI calls, where there is no bundle to look in.
extension HelpLink {
    /// One symptom, from the bundle first.
    public func url(
        bundledIn resources: URL?,
        inCheckout checkout: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        if let bundled = Self.bundledPage(in: resources, fileExists: fileExists) { return bundled }
        return url(inCheckout: checkout, fileExists: fileExists)
    }

    /// The whole page, from the bundle first — what the Help menu's **Troubleshooting…** opens.
    public static func pageURL(
        bundledIn resources: URL?,
        inCheckout checkout: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        if let bundled = bundledPage(in: resources, fileExists: fileExists) { return bundled }
        return pageURL(inCheckout: checkout, fileExists: fileExists)
    }

    /// `Contents/Resources/docs/user/troubleshooting.md`, when it is there.
    static func bundledPage(in resources: URL?, fileExists: (URL) -> Bool) -> URL? {
        guard let resources else { return nil }
        let local = resources.appendingPathComponent(page)
        return fileExists(local) ? local : nil
    }
}
