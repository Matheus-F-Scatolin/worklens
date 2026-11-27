import Foundation

/// Which Worklens this process is: the real app, or the install rehearsal (`make rehearse`).
///
/// The rehearsal is a second app, "Worklens Rehearsal", that walks through everything a new
/// person does on a fresh Mac (welcome window, Screen Recording prompt, connecting Claude or
/// Codex, real summaries) without touching the real app. Everything that ties an install to
/// this Mac hangs off the values here: the bundle identifier (and with it TCC grants,
/// UserDefaults, notification categories, Launch Services), the Application Support folder
/// (`.env`, `settings.json`, `blocklists.json`, `data/`), the keychain service, the CLI link
/// and the MCP server name an AI client knows it by.
///
/// The identity comes from the running bundle and nothing else: `Bundle.main`'s identifier for
/// the app, and for the CLI run through its symlink, the identifier of the bundle
/// `BundleLayout` resolves the executable into. Never from an environment variable or a `.env`,
/// so no setting can point the real app at the rehearsal's folders or the other way round.
/// `swift run`, the tests and any bundle that is neither are `.main`, exactly as before the
/// rehearsal existed.
public enum AppIdentity: String, Sendable, CaseIterable {
    case main
    case rehearsal

    /// The identity of this process. Resolved once: the bundle a process runs from does not
    /// change under it.
    public static let current: AppIdentity = resolve(
        mainBundleIdentifier: Bundle.main.bundleIdentifier,
        executableBundleIdentifier: BundleLayout.infoDictionary(
            forExecutable: BundleLayout.resolvedExecutableURL()
        )?["CFBundleIdentifier"] as? String
    )

    /// The pure rule behind `current`. `Bundle.main` first (the app), then the bundle the
    /// executable resolves into (the CLI through its symlink, where `Bundle.main` is the
    /// symlink's directory). An identifier that is neither of ours is `.main`.
    public static func resolve(
        mainBundleIdentifier: String?,
        executableBundleIdentifier: String?
    ) -> AppIdentity {
        if let known = AppIdentity(bundleIdentifier: mainBundleIdentifier) { return known }
        if let known = AppIdentity(bundleIdentifier: executableBundleIdentifier) { return known }
        return .main
    }

    /// The identity a bundle identifier names, or nil for anybody else's (and for nil).
    public init?(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let match = AppIdentity.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return nil }
        self = match
    }

    /// `CFBundleIdentifier` in the bundle's `Info.plist`; `scripts/bundle.sh` writes the
    /// rehearsal's.
    public var bundleIdentifier: String {
        switch self {
        case .main: return "dev.worklens.app"
        case .rehearsal: return "dev.worklens.rehearsal"
        }
    }

    /// The name Finder, the Dock and the macOS permission prompts show.
    public var displayName: String {
        switch self {
        case .main: return "Worklens"
        case .rehearsal: return "Worklens Rehearsal"
        }
    }

    /// `Worklens.app` / `Worklens Rehearsal.app`, in `build/` and in `/Applications`.
    public var appBundleName: String { displayName + ".app" }

    /// The folder under `~/Library/Application Support`.
    public var appSupportFolderName: String { displayName }

    /// `~/Library/Application Support/<folder>`, for a given home directory.
    public func appSupportDir(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    /// What every keychain service this identity owns starts with: `dev.worklens.google` for
    /// the real app's Google token, `dev.worklens.rehearsal.google` for the rehearsal's.
    public var keychainServicePrefix: String {
        switch self {
        case .main: return "dev.worklens"
        case .rehearsal: return "dev.worklens.rehearsal"
        }
    }

    /// One keychain service, `<prefix>.<name>`.
    public func keychainService(_ name: String) -> String { "\(keychainServicePrefix).\(name)" }

    /// The command `scripts/install.sh` links onto your `PATH`.
    public var commandName: String {
        switch self {
        case .main: return "worklens"
        case .rehearsal: return "worklens-rehearsal"
        }
    }

    /// The key under `mcpServers` (and the MCP server's own name) an AI client knows it by.
    public var mcpServerName: String { commandName }

    /// Whether "Update and restart…" and the auto-update poll exist. The rehearsal is built from
    /// a checkout whose `scripts/update.sh` installs the *real* app, so it never updates itself:
    /// running `make rehearse` again is how it gets a newer build.
    public var updatesInPlace: Bool { self == .main }

    /// Whether an MCP client entry launching `command` is this identity's own, so a renamed entry
    /// can still be found. The real app keeps its old rule, any binary called `Worklens`, minus
    /// the rehearsal's bundle; the rehearsal accepts only a command inside its own bundle. Neither
    /// ever claims the other's key, so connecting the rehearsal never repoints the real entry.
    public func claimsMCPEntry(key: String, command: String?) -> Bool {
        guard let command else { return false }
        if AppIdentity.allCases.contains(where: { $0 != self && $0.mcpServerName == key }) {
            return false
        }
        switch self {
        case .main:
            return command.hasSuffix("/Worklens")
                && !command.contains("/\(AppIdentity.rehearsal.appBundleName)/")
        case .rehearsal:
            return command.hasSuffix("/\(appBundleName)/Contents/MacOS/Worklens")
        }
    }

    /// True when `dataDir` is the real app's Application Support folder or anything inside it,
    /// which the rehearsal refuses to open whatever a `.env` says. Always false for `.main`.
    public func refusesDataDir(_ dataDir: URL, home: URL) -> Bool {
        guard self == .rehearsal else { return false }
        let real = AppIdentity.main.appSupportDir(home: home).standardizedFileURL.path
        let candidates = [
            dataDir.standardizedFileURL.path,
            dataDir.standardizedFileURL.resolvingSymlinksInPath().path,
        ]
        return candidates.contains { $0 == real || $0.hasPrefix(real + "/") }
    }
}
