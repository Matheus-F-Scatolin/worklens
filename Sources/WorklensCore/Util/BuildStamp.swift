import Foundation

/// What the running app was built from: `scripts/bundle.sh` stamps the commit, the pull request
/// that merged it, its subject and the build time into the bundle's `Info.plist`, and this reads
/// them back.
///
/// The bundle carries its own answer on purpose. A checkout's HEAD moves the moment you pull, so
/// asking git at runtime would report the code you *could* be running; the menu's version line
/// and the auto-updater both need the code you *are* running. `.build/release/Worklens` run
/// straight from SwiftPM has no `Info.plist` and so no stamp — `isStamped` is false there and
/// every line falls back to `WorklensVersion.short`.
public struct BuildStamp: Equatable, Sendable {
    /// The full SHA the bundle was built from — what the auto-updater compares against `origin/main`.
    public let commit: String?
    public let shortCommit: String?
    /// The pull request that merged this commit, when the subject named one.
    public let pullRequest: Int?
    /// The human sentence for this commit: for a merge on main, the merged PR's own subject.
    public let subject: String?
    public let builtAt: Date?
    /// The checkout had uncommitted changes when it was bundled, so `commit` is only half the
    /// story. Shown as a `+` and worth showing: it is the difference between "this is main" and
    /// "this is main plus whatever I was editing".
    public let dirty: Bool
    /// The repository this bundle was built from — `git remote get-url origin`, normalised to its
    /// https form. The app links to its own `PRIVACY.md` through this rather than through a URL
    /// compiled into the binary, so a fork's build points at the fork.
    public let repositoryURL: String?
    /// #119: the absolute path of the checkout this bundle was built from, stamped by
    /// `scripts/bundle.sh`.
    ///
    /// Without it, a bundle copied to `/Applications` has no way back to its own repository —
    /// `AppModel.repoRoot` used to derive it from the bundle's grandparent, which is only true
    /// while the app sits in `<repo>/build/`, so installing the app silently turned off
    /// "Update and restart…". The stamp travels with the copy; the grandparent lookup stays as
    /// the fallback for bundles built before this key existed.
    public let repoPath: String?

    public init(
        commit: String? = nil,
        shortCommit: String? = nil,
        pullRequest: Int? = nil,
        subject: String? = nil,
        builtAt: Date? = nil,
        dirty: Bool = false,
        repositoryURL: String? = nil,
        repoPath: String? = nil
    ) {
        self.commit = commit
        self.shortCommit = shortCommit
        self.pullRequest = pullRequest
        self.subject = subject
        self.builtAt = builtAt
        self.dirty = dirty
        self.repositoryURL = repositoryURL
        self.repoPath = repoPath
    }

    /// Reads the `WL*` keys `scripts/bundle.sh` writes. Every one of them is optional: an
    /// unstamped bundle, or one built outside a git checkout, still has to produce a version line.
    public init(info: [String: Any]?) {
        func string(_ key: String) -> String? {
            guard let value = info?[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        commit = string("WLCommit")
        shortCommit = string("WLCommitShort")
        pullRequest = string("WLPullRequest").flatMap(Int.init)
        subject = string("WLCommitSubject")
        builtAt = string("WLBuildDate").flatMap(BuildStamp.parseTimestamp)
        dirty = string("WLDirty") == "true"
        repositoryURL = string("WLRepositoryURL")
        repoPath = string("WLRepoPath")
    }

    /// Not `Bundle.main.infoDictionary`: since #119 the CLI can be reached through the
    /// `worklens` symlink, where `Bundle.main` is the symlink's directory and carries no
    /// `Info.plist` at all — `worklens version` would then report an unstamped build for a
    /// bundle that is stamped. `BundleLayout` resolves the executable first and reads the
    /// `.app` it actually lives in; `Bundle.main` is still the answer for an unbundled run.
    public static let current = BuildStamp(
        info: BundleLayout.infoDictionary(forExecutable: BundleLayout.resolvedExecutableURL())
            ?? Bundle.main.infoDictionary
    )

    public var isStamped: Bool { commit != nil }

    /// `#105` when a pull request merged it, the short SHA otherwise, `+` when the tree was dirty.
    public var label: String {
        let base = pullRequest.map { "#\($0)" } ?? shortCommit ?? WorklensVersion.short
        return dirty ? "\(base)+" : base
    }

    /// Which commit this is and how old — `#105 · 0ae882e · updated 3 hours ago`, and just
    /// `updated 3 hours ago` for a release bundle built outside a checkout, which has no pull
    /// request and no SHA to name. Empty when the bundle carries no stamp at all.
    ///
    /// Split out of `menuLine` in #130 so `worklens version` can print the version on its own
    /// first line and this underneath it without saying the version twice.
    public func buildLine(now: Date = Date()) -> String {
        var parts: [String] = []
        if isStamped {
            parts.append(label)
            // Redundant when the label is already the SHA, which is the no-pull-request case.
            if pullRequest != nil, let shortCommit { parts.append(shortCommit) }
        }
        if let builtAt { parts.append("updated \(BuildStamp.relative(builtAt, now: now))") }
        return parts.joined(separator: " · ")
    }

    /// The menu's version row: `0.1.0 · #105 · 0ae882e · updated 3 hours ago`. Deliberately one
    /// line and no wider than the items around it — it answers "what am I running" and nothing
    /// else.
    ///
    /// The version leads (#130). Until releases existed the version was a frozen `0.1.0` that
    /// told you nothing and the pull request told you everything, so the PR led; now the version
    /// is derived from the tag and is the first thing a bug report needs. The `#PR · SHA` stays
    /// behind it for checkout builds, because saying *which* build is running is this line's
    /// whole job — a release bundle simply has no PR to show.
    /// The guard is on `buildLine` and not on `isStamped`, so a bundle built outside a git
    /// checkout — a tarball, or a release cut from an exported tree — still reads
    /// `0.1.0 · updated 3 hours ago` rather than claiming to be unstamped. It has a version and a
    /// build date; it just has no commit to name.
    public func menuLine(now: Date = Date()) -> String {
        let build = buildLine(now: now)
        guard !build.isEmpty else { return "Worklens \(WorklensVersion.short) · unstamped build" }
        return "\(WorklensVersion.short) · \(build)"
    }

    // MARK: Formatting

    /// Coarse on purpose: nobody needs "2 hours and 14 minutes", and a menu line that changes
    /// every minute draws the eye for no reason.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // A build in the future means the clock moved, not that the future arrived.
        if seconds < 90 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days) days ago" }
        return "on \(absolute(date))"
    }

    /// `Sep 10, 14:05`, or whatever that date and time look like where the user lives.
    ///
    /// Before #157 this set a fixed `MMM d, HH:mm` pattern with no locale at all, which is the
    /// one combination that is wrong everywhere: `DateFormatter` then spelt the month in the
    /// user's language while the clock stayed 24-hour whatever their Mac was set to.
    public static func absolute(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        if Format.isFixed(locale) {
            formatter.locale = Format.fixed
            formatter.dateFormat = "MMM d, HH:mm"
        } else {
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        }
        return formatter.string(from: date)
    }

    /// The `date -u '+%Y-%m-%dT%H:%M:%SZ'` that `bundle.sh` writes.
    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
