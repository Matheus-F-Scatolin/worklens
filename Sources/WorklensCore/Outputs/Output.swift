import Foundation
import GRDB

/// What kind of thing you shipped (#314).
///
/// A string rather than an enum on purpose: a later build that adds a kind (#317's memos) writes
/// rows an older build still has to read, and an enum would refuse to decode them. Unknown kinds
/// are kept, counted under their own name and printed with their raw spelling.
public struct OutputKind: RawRepresentable, Codable, Hashable, Sendable, DatabaseValueConvertible,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let prMerged = OutputKind(rawValue: "pr_merged")
    public static let prClosed = OutputKind(rawValue: "pr_closed")
    public static let issueOpened = OutputKind(rawValue: "issue_opened")
    public static let issueClosed = OutputKind(rawValue: "issue_closed")
    public static let reviewSubmitted = OutputKind(rawValue: "review_submitted")
    /// #317: a merged PR of yours that added or changed a company memo.
    public static let memoPublished = OutputKind(rawValue: "memo_published")
    public static let memoUpdated = OutputKind(rawValue: "memo_updated")

    /// Every kind this build writes, in the order counts are printed.
    public static let known: [OutputKind] = [
        .prMerged, .prClosed, .issueOpened, .issueClosed, .reviewSubmitted, .memoPublished, .memoUpdated,
    ]

    /// A memo row (#317): printed as a sentence about the company, not as a PR.
    public var isMemo: Bool { self == .memoPublished || self == .memoUpdated }

    public var description: String { rawValue }

    /// The verb a row is printed with: `merged owner/worklens#312`.
    public var verb: String {
        switch self {
        case .prMerged: "merged"
        case .prClosed: "closed unmerged"
        case .issueOpened: "opened"
        case .issueClosed: "closed"
        case .reviewSubmitted: "reviewed"
        case .memoPublished: "published the memo for"
        case .memoUpdated: "updated the memo for"
        default: rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// `3 PRs merged`, `1 issue opened`. Counts are per kind only: a PR and a review are not the
    /// same unit, so nothing adds them up.
    public func count(_ n: Int) -> String {
        switch self {
        case .prMerged: "\(n) \(n == 1 ? "PR" : "PRs") merged"
        case .prClosed: "\(n) \(n == 1 ? "PR" : "PRs") closed unmerged"
        case .issueOpened: "\(n) \(n == 1 ? "issue" : "issues") opened"
        case .issueClosed: "\(n) \(n == 1 ? "issue" : "issues") closed"
        case .reviewSubmitted: "\(n) \(n == 1 ? "review" : "reviews")"
        case .memoPublished: "\(n) \(n == 1 ? "memo" : "memos") published"
        case .memoUpdated: "\(n) \(n == 1 ? "memo" : "memos") updated"
        default: "\(n) \(verb)"
        }
    }
}

/// One thing you shipped: a merged PR, an issue you opened or closed, a review you submitted on
/// someone else's PR. A row in `outputs` (#314).
///
/// Only the title is kept, the way a window title is: never a body, review text, diff or commit
/// message.
public struct Output: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "outputs"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// `source` for everything `gh` found.
    public static let github = "github"
    /// `source` for memo rows (#317): read through `gh` too, but one row per company a PR touched.
    public static let memo = "memo"

    public var id: String
    public var source: String
    public var kind: OutputKind
    /// When it happened: a merged PR's merge, an issue's opening or closing, a review's submission.
    public var at: Date
    /// `owner/name`.
    public var repo: String?
    public var number: Int?
    public var url: String?
    public var title: String?
    /// For memo rows (#317), the memo file; nil for GitHub. A memo row's `title` is the company's
    /// name and its `repo`, `number` and `url` are the PR's.
    public var path: String?
    /// `github.com/<owner>/<name>/pull/<n>`: what a later link to a session or a project keys on.
    public var resourceKey: String?
    /// Unique together with `source`; a re-sync updates the row it names.
    public var externalId: String
    /// Nil in v1 (#319 and #321 fill them).
    public var projectKey: String?
    public var projectRule: String?
    /// The query that found it.
    public var provenance: String
    public var syncedAt: Date

    public init(
        id: String = Identifiers.new(),
        source: String = Output.github,
        kind: OutputKind,
        at: Date,
        repo: String? = nil,
        number: Int? = nil,
        url: String? = nil,
        title: String? = nil,
        path: String? = nil,
        resourceKey: String? = nil,
        externalId: String,
        projectKey: String? = nil,
        projectRule: String? = nil,
        provenance: String,
        syncedAt: Date
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.at = at
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.path = path
        self.resourceKey = resourceKey
        self.externalId = externalId
        self.projectKey = projectKey
        self.projectRule = projectRule
        self.provenance = provenance
        self.syncedAt = syncedAt
    }

    /// `owner/name#12`, or the repo alone, or the path.
    public var reference: String {
        switch (repo, number) {
        case let (repo?, number?): "\(repo)#\(number)"
        case let (repo?, nil): repo
        default: path ?? externalId
        }
    }
}
