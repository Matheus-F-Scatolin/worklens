import Foundation
import Testing
@testable import WorklensCore

/// What `gh` prints for the three searches, the login and one PR's reviews (#314). Shared with
/// `OutputSyncTests` and `ShippedSectionTests`.
enum GHFixtures {
    static let syncedAt = date("2026-09-07T18:00:00Z")

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func pr(
        _ number: Int, state: String, closedAt: String = "0001-01-01T00:00:00Z",
        repo: String = "acme/widgets", author: String = "me"
    ) -> String {
        """
        {"number":\(number),"title":"Add the ledger \(number)","url":"https://github.com/\(repo)/pull/\(number)",\
        "repository":{"name":"\(repo.split(separator: "/").last!)","nameWithOwner":"\(repo)"},\
        "state":"\(state)","closedAt":"\(closedAt)","createdAt":"2026-09-06T10:00:00Z",\
        "author":{"login":"\(author)"}}
        """
    }

    static func issue(_ number: Int, state: String, closedAt: String = "0001-01-01T00:00:00Z") -> String {
        """
        {"number":\(number),"title":"Fix the thing \(number)","url":"https://github.com/acme/widgets/issues/\(number)",\
        "repository":{"name":"widgets","nameWithOwner":"acme/widgets"},\
        "state":"\(state)","closedAt":"\(closedAt)","createdAt":"2026-09-07T09:00:00Z"}
        """
    }

    static func list(_ items: [String]) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

    static let authoredPRs = list([
        pr(12, state: "merged", closedAt: "2026-09-07T13:00:00Z"),
        pr(13, state: "closed", closedAt: "2026-09-07T14:00:00Z"),
        pr(14, state: "open"),
    ])
    static let authoredIssues = list([
        issue(5, state: "closed", closedAt: "2026-09-07T15:00:00Z"),
        issue(6, state: "open"),
    ])
    /// One of your own PRs and one of Ana's.
    static let reviewedPRs = list([
        pr(12, state: "merged", closedAt: "2026-09-07T13:00:00Z"),
        pr(40, state: "open", repo: "other/thing", author: "ana"),
    ])
    static let reviews = Data("""
        {"id":1,"login":"me","submitted_at":"2026-09-07T16:00:00Z","html_url":"https://github.com/other/thing/pull/40#pullrequestreview-1"}
        {"id":2,"login":"ana","submitted_at":"2026-09-07T16:30:00Z","html_url":"https://github.com/other/thing/pull/40#pullrequestreview-2"}
        {"id":3,"login":"Me","submitted_at":"2026-09-07T17:00:00Z","html_url":"https://github.com/other/thing/pull/40#pullrequestreview-3"}
        {"id":4,"login":"me","submitted_at":null,"html_url":null}

        """.utf8)
}

/// A `gh` that answers from fixtures and records what it was asked.
final class FakeGHRunner: GHRunning, @unchecked Sendable {
    enum Mode { case ok, missing, loggedOut, rateLimited }

    private let lock = NSLock()
    private var _mode: Mode = .ok
    private var _calls: [[String]] = []
    private var _authoredPRs = GHFixtures.authoredPRs
    private var _authoredIssues = GHFixtures.authoredIssues

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var calls: [[String]] { lock.withLock { _calls } }
    func setAuthored(prs: Data? = nil, issues: Data? = nil) {
        lock.withLock {
            if let prs { _authoredPRs = prs }
            if let issues { _authoredIssues = issues }
        }
    }

    /// Every `--updated` value the searches were given, in order, once per window.
    var windows: [String] {
        calls.filter { $0.first == "search" && $0.contains("--author=@me") && $0[1] == "prs" }
            .compactMap { call in call.firstIndex(of: "--updated").map { call[$0 + 1] } }
    }

    func run(_ arguments: [String]) async throws -> GHOutput {
        let (mode, prs, issues) = lock.withLock {
            _calls.append(arguments)
            return (_mode, _authoredPRs, _authoredIssues)
        }
        switch mode {
        case .missing: throw GHError.missing
        case .loggedOut:
            return GHOutput(status: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login")
        case .rateLimited:
            return GHOutput(status: 1, stderr: "HTTP 403: API rate limit exceeded for user")
        case .ok: break
        }
        if arguments == GitHubOutputs.loginArguments { return GHOutput(status: 0, stdout: Data("me\n".utf8)) }
        if arguments.first == "api" { return GHOutput(status: 0, stdout: GHFixtures.reviews) }
        if arguments.contains("--reviewed-by=@me") { return GHOutput(status: 0, stdout: GHFixtures.reviewedPRs) }
        if arguments[1] == "issues" { return GHOutput(status: 0, stdout: issues) }
        return GHOutput(status: 0, stdout: prs)
    }
}

@Suite("GitHubOutputs")
struct GitHubOutputsTests {
    private let provenance = "gh search"

    @Test("a merged PR is pr_merged at closedAt, a closed one pr_closed, an open one nothing")
    func pullRequests() throws {
        let mapped = GitHubOutputs.pullRequests(
            try GitHubOutputs.decodeItems(GHFixtures.authoredPRs),
            provenance: provenance, syncedAt: GHFixtures.syncedAt
        )
        #expect(mapped.outputs.map(\.kind) == [.prMerged, .prClosed])
        let merged = try #require(mapped.outputs.first)
        #expect(merged.at == GHFixtures.date("2026-09-07T13:00:00Z"))
        #expect(merged.repo == "acme/widgets")
        #expect(merged.number == 12)
        #expect(merged.resourceKey == "github.com/acme/widgets/pull/12")
        #expect(merged.externalId == "pr:acme/widgets#12")
        #expect(merged.provenance == provenance)
        // The open PR names the terminal row it would drop.
        #expect(mapped.reopened == ["pr:acme/widgets#14"])
    }

    @Test("an issue is opened at createdAt, and a closed one is closed at closedAt too")
    func issues() throws {
        let mapped = GitHubOutputs.issues(
            try GitHubOutputs.decodeItems(GHFixtures.authoredIssues),
            provenance: provenance, syncedAt: GHFixtures.syncedAt
        )
        #expect(mapped.outputs.map(\.kind) == [.issueOpened, .issueClosed, .issueOpened])
        #expect(mapped.outputs[0].at == GHFixtures.date("2026-09-07T09:00:00Z"))
        #expect(mapped.outputs[1].at == GHFixtures.date("2026-09-07T15:00:00Z"))
        #expect(mapped.outputs[1].resourceKey == "github.com/acme/widgets/issues/5")
        #expect(mapped.reopened == ["issue:acme/widgets#6:closed"])
    }

    @Test("a review on your own PR is none; on another's it is one row per submitted review")
    func reviews() throws {
        let reviewed = try GitHubOutputs.decodeItems(GHFixtures.reviewedPRs)
        let candidates = GitHubOutputs.reviewCandidates(reviewed, login: "me")
        #expect(candidates.map(\.number) == [40])

        let rows = GitHubOutputs.reviews(
            GHFixtures.reviews, of: candidates[0], login: "me",
            provenance: provenance, syncedAt: GHFixtures.syncedAt
        )
        // Ana's review is not yours, and a pending one has no time.
        #expect(rows.map(\.externalId) == ["review:1", "review:3"])
        #expect(rows.allSatisfy { $0.kind == .reviewSubmitted && $0.repo == "other/thing" })
        #expect(rows[0].at == GHFixtures.date("2026-09-07T16:00:00Z"))
        #expect(rows[0].resourceKey == "github.com/other/thing/pull/40")
    }

    @Test("the searches cover the stretch in 30-day chunks, the last one open-ended")
    func searches() {
        let now = GHFixtures.date("2026-09-07T18:00:00Z")
        let thirty = GitHubOutputs.searches(since: now.addingTimeInterval(-30 * 86_400), now: now)
        #expect(thirty.count == 6)
        #expect(thirty.map(\.scope) == [.authoredPRs, .authoredIssues, .reviewedPRs,
                                        .authoredPRs, .authoredIssues, .reviewedPRs])
        #expect(thirty[0].arguments.prefix(5) == ["search", "prs", "--author=@me", "--updated", "2026-08-08..2026-09-06"])
        #expect(thirty[3].arguments[4] == ">=2026-09-07")
        #expect(thirty[1].arguments[1] == "issues")
        #expect(thirty[2].arguments[2] == "--reviewed-by=@me")
        #expect(thirty[0].provenance == "gh search prs --author=@me --updated 2026-08-08..2026-09-06 --limit 1000")
        // Never a body.
        #expect(thirty.allSatisfy { !$0.arguments.joined().contains("body") })

        let day = GitHubOutputs.searches(since: now.addingTimeInterval(-86_400), now: now)
        #expect(day.map { $0.arguments[4] } == [">=2026-09-06", ">=2026-09-06", ">=2026-09-06"])
    }

    @Test("the reviews call asks for no review body")
    func reviewArguments() {
        let arguments = GitHubOutputs.reviewArguments(repo: "other/thing", number: 40)
        #expect(arguments.contains("repos/other/thing/pulls/40/reviews"))
        #expect(!arguments.joined(separator: " ").contains("body"))
    }

    @Test("gh's failures are told apart by exit status and message")
    func classify() {
        #expect(GHError.classify(GHOutput(status: 0)) == nil)
        #expect(GHError.classify(GHOutput(status: 4)) == .loggedOut)
        #expect(GHError.classify(GHOutput(status: 1, stderr: "API rate limit exceeded")) == .rateLimited)
        #expect(GHError.classify(GHOutput(status: 1, stderr: "boom")) == .failed(status: 1))
    }

    @Test("gh is found in Homebrew's places first, then on PATH")
    func locate() {
        #expect(GHRunner.locate(environment: ["PATH": "/x/bin"], isExecutable: { $0 == "/x/bin/gh" }) == "/x/bin/gh")
        #expect(GHRunner.locate(environment: ["PATH": "/x/bin"], isExecutable: { _ in true }) == "/opt/homebrew/bin/gh")
        #expect(GHRunner.locate(environment: [:], isExecutable: { _ in false }) == nil)
    }
}
