import Foundation
import Testing
@testable import WorklensCore

/// The same instant `WLBuildDate` carries below, so the two cannot drift apart.
private let built = BuildStamp.parseTimestamp("2026-09-10T12:26:40Z")!

@Suite("Build stamp")
struct BuildStampTests {
    private func info(
        commit: String? = "0ae882ecafe1234567890abcdef1234567890abc",
        short: String? = "0ae882e",
        pr: String? = "105",
        subject: String? = "Remove the Ask window; Claude Desktop is the chat surface (#95)",
        date: String? = "2026-09-10T12:26:40Z",
        dirty: String? = "false",
        repositoryURL: String? = "https://github.com/owner/worklens",
        repoPath: String? = "/Users/x/worklens"
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        if let commit { info["WLCommit"] = commit }
        if let short { info["WLCommitShort"] = short }
        if let pr { info["WLPullRequest"] = pr }
        if let subject { info["WLCommitSubject"] = subject }
        if let date { info["WLBuildDate"] = date }
        if let dirty { info["WLDirty"] = dirty }
        if let repositoryURL { info["WLRepositoryURL"] = repositoryURL }
        if let repoPath { info["WLRepoPath"] = repoPath }
        return info
    }

    /// #119: the checkout path travels with the bundle, so a copy in /Applications can still
    /// find the repository it came from. Absent in a bundle built before the key existed.
    @Test("the stamp carries the checkout it was built from")
    func readsRepoPath() {
        #expect(BuildStamp(info: info()).repoPath == "/Users/x/worklens")
        #expect(BuildStamp(info: info(repoPath: nil)).repoPath == nil)
        #expect(BuildStamp(info: info(repoPath: "")).repoPath == nil)
    }

    @Test("reads what bundle.sh stamps")
    func readsStamp() {
        let stamp = BuildStamp(info: info())
        #expect(stamp.isStamped)
        #expect(stamp.commit?.hasPrefix("0ae882e") == true)
        #expect(stamp.pullRequest == 105)
        #expect(stamp.dirty == false)
        #expect(stamp.builtAt == built)
        #expect(stamp.label == "#105")
        #expect(stamp.repositoryURL == "https://github.com/owner/worklens")
    }

    @Test("a bundle built outside a checkout, or from one with no remote, has no repository URL")
    func withoutRepositoryURL() {
        // The app falls back to its own constant here rather than building a link out of nothing.
        #expect(BuildStamp(info: info(repositoryURL: nil)).repositoryURL == nil)
        #expect(BuildStamp(info: info(repositoryURL: "")).repositoryURL == nil)
    }

    /// #130: the version leads, because it is the first thing a bug report needs and it is no
    /// longer a frozen `0.1.0`. The `#PR · SHA` stays behind it — telling the owner which build is
    /// running is this line's whole job.
    @Test("the menu line leads with the version, then the pull request, commit and age")
    func menuLine() {
        let stamp = BuildStamp(info: info())
        #expect(stamp.menuLine(now: built.addingTimeInterval(3 * 3600))
            == "\(WorklensVersion.short) · #105 · 0ae882e · updated 3 hours ago")
    }

    /// `worklens version` prints the version on its own first line and this underneath, so the
    /// build half has to be sayable without the version in front of it.
    @Test("the build line is the same facts without the version")
    func buildLine() {
        let stamp = BuildStamp(info: info())
        #expect(stamp.buildLine(now: built.addingTimeInterval(3 * 3600))
            == "#105 · 0ae882e · updated 3 hours ago")
        #expect(BuildStamp(info: [:]).buildLine(now: built).isEmpty)
    }

    /// A release bundle built outside a checkout has a build date and nothing else to say: no
    /// pull request, no SHA. The version carries the line on its own.
    @Test("a bundle with only a build date still produces both lines")
    func releaseBundleWithoutGit() {
        let stamp = BuildStamp(
            info: info(commit: nil, short: nil, pr: nil, subject: nil, repoPath: nil)
        )
        #expect(!stamp.isStamped)
        #expect(stamp.buildLine(now: built.addingTimeInterval(3 * 3600)) == "updated 3 hours ago")
        // It has a version and a build date, so it does not get to call itself unstamped.
        #expect(stamp.menuLine(now: built.addingTimeInterval(3 * 3600))
            == "\(WorklensVersion.short) · updated 3 hours ago")
    }

    @Test("a commit with no pull request falls back to the SHA, and does not repeat it")
    func withoutPullRequest() {
        let stamp = BuildStamp(info: info(pr: nil))
        #expect(stamp.label == "0ae882e")
        #expect(stamp.menuLine(now: built.addingTimeInterval(60))
            == "\(WorklensVersion.short) · 0ae882e · updated just now")
    }

    @Test("a dirty tree is marked, because the commit alone would be a half-truth")
    func dirtyTree() {
        let stamp = BuildStamp(info: info(dirty: "true"))
        #expect(stamp.label == "#105+")
    }

    @Test("an unstamped bundle says so instead of inventing a version")
    func unstamped() {
        let stamp = BuildStamp(info: [:])
        #expect(!stamp.isStamped)
        #expect(stamp.menuLine(now: built) == "Worklens \(WorklensVersion.short) · unstamped build")
        // Never a crash and never an empty line, whatever the plist holds.
        #expect(BuildStamp(info: nil).menuLine(now: built).isEmpty == false)
    }

    @Test("relative time stays coarse")
    func relativeTime() {
        func ago(_ seconds: TimeInterval) -> String {
            BuildStamp.relative(built, now: built.addingTimeInterval(seconds))
        }
        #expect(ago(0) == "just now")
        #expect(ago(89) == "just now")
        #expect(ago(15 * 60) == "15 min ago")
        #expect(ago(3600) == "1 hour ago")
        #expect(ago(5 * 3600) == "5 hours ago")
        #expect(ago(30 * 3600) == "yesterday")
        #expect(ago(4 * 86_400) == "4 days ago")
        #expect(ago(90 * 86_400).hasPrefix("on "))
        // A clock that moved backwards must not produce "-3 hours ago".
        #expect(ago(-3600) == "just now")
    }
}
