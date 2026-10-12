import Foundation

/// The pure half of the GitHub shipped ledger (#314): which `gh` commands to run, and what their
/// answers become as `outputs` rows. `OutputSync` runs the commands; nothing here touches a
/// process, the network or the database.
///
/// Three searches, chunked into 30-day `--updated` windows so no one query nears the search API's
/// 1,000-result cap: your PRs, your issues, and the PRs you reviewed. Search has no `mergedAt`,
/// so a merged PR's `closedAt` is its merge. A review's time comes from the PR's reviews list,
/// one call per PR that someone else wrote; reviews on your own PRs are not counted.
public enum GitHubOutputs {
    public static let chunkDays = 30
    public static let searchLimit = 1000

    public enum Scope: String, Sendable, CaseIterable {
        case authoredPRs, authoredIssues, reviewedPRs
    }

    public struct Search: Sendable, Equatable {
        public let scope: Scope
        public let arguments: [String]
        /// The command as it is stored in `provenance`: `gh` plus everything but the field list.
        public var provenance: String {
            "gh " + arguments.prefix { $0 != "--json" }.joined(separator: " ")
        }
    }

    static let prFields = "number,title,url,repository,state,closedAt,createdAt,author"
    static let issueFields = "number,title,url,repository,state,closedAt,createdAt"

    // MARK: Commands

    /// Every search for the stretch since `since`, in 30-day chunks: closed ranges, then an
    /// open-ended `>=` for the last one so nothing that changes during the round falls out.
    public static func searches(since: Date, now: Date) -> [Search] {
        windows(since: since, now: now).flatMap { window in
            [
                Search(scope: .authoredPRs, arguments: search("prs", "--author=@me", window, prFields)),
                Search(scope: .authoredIssues, arguments: search("issues", "--author=@me", window, issueFields)),
                Search(scope: .reviewedPRs, arguments: search("prs", "--reviewed-by=@me", window, prFields)),
            ]
        }
    }

    private static func search(_ kind: String, _ who: String, _ window: String, _ fields: String) -> [String] {
        ["search", kind, who, "--updated", window, "--limit", String(searchLimit), "--json", fields]
    }

    /// `--updated` values, in UTC days.
    static func windows(since: Date, now: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        var start = calendar.startOfDay(for: min(since, now))
        var out: [String] = []
        while let next = calendar.date(byAdding: .day, value: chunkDays, to: start), next <= today {
            let last = calendar.date(byAdding: .day, value: chunkDays - 1, to: start)!
            out.append("\(utcDay(start))..\(utcDay(last))")
            start = next
        }
        out.append(">=\(utcDay(start))")
        return out
    }

    /// Who you are on GitHub, so a reviews list can be narrowed to yours.
    public static let loginArguments = ["api", "user", "--jq", ".login"]

    /// One PR's reviews, one compact JSON object per line, without the review body.
    public static func reviewArguments(repo: String, number: Int) -> [String] {
        [
            "api", "--paginate", "repos/\(repo)/pulls/\(number)/reviews",
            "--jq", ".[] | {id, login: .user.login, submitted_at, html_url}",
        ]
    }

    // MARK: Answers

    /// One search result, PR or issue.
    public struct Item: Decodable, Sendable, Equatable {
        public struct Repository: Decodable, Sendable, Equatable {
            public let nameWithOwner: String
        }
        public struct Author: Decodable, Sendable, Equatable {
            public let login: String
        }
        public let number: Int
        public let title: String?
        public let url: String
        public let repository: Repository
        public let state: String
        public let closedAt: String?
        public let createdAt: String?
        public let author: Author?

        var closed: Date? { GitHubOutputs.date(closedAt) }
        var created: Date? { GitHubOutputs.date(createdAt) }
        var repo: String { repository.nameWithOwner }
    }

    public static func decodeItems(_ data: Data) throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: data)
    }

    /// What a page of results means for the table: rows to upsert, and the external ids whose
    /// terminal row has to go because the PR or issue is open again.
    public struct Mapped: Sendable, Equatable {
        public var outputs: [Output] = []
        public var reopened: [String] = []
    }

    /// Merged → `pr_merged` at `closedAt`, closed → `pr_closed`, open → nothing, and the
    /// terminal row it may have had is dropped.
    public static func pullRequests(_ items: [Item], provenance: String, syncedAt: Date) -> Mapped {
        var mapped = Mapped()
        for item in items {
            let id = "pr:\(item.repo)#\(item.number)"
            let kind: OutputKind
            switch item.state.lowercased() {
            case "merged": kind = .prMerged
            case "closed": kind = .prClosed
            default:
                mapped.reopened.append(id)
                continue
            }
            guard let at = item.closed else { continue }
            mapped.outputs.append(Output(
                kind: kind, at: at, repo: item.repo, number: item.number, url: item.url,
                title: item.title, resourceKey: pullKey(item.repo, item.number), externalId: id,
                provenance: provenance, syncedAt: syncedAt
            ))
        }
        return mapped
    }

    /// Every issue you opened is `issue_opened` at `createdAt`; a closed one is also
    /// `issue_closed` at `closedAt`, and an open one loses the closed row it may have had.
    public static func issues(_ items: [Item], provenance: String, syncedAt: Date) -> Mapped {
        var mapped = Mapped()
        for item in items {
            let base = "issue:\(item.repo)#\(item.number)"
            let key = "github.com/\(item.repo)/issues/\(item.number)"
            if let created = item.created {
                mapped.outputs.append(Output(
                    kind: .issueOpened, at: created, repo: item.repo, number: item.number,
                    url: item.url, title: item.title, resourceKey: key, externalId: base + ":opened",
                    provenance: provenance, syncedAt: syncedAt
                ))
            }
            if item.state.lowercased() == "closed", let closed = item.closed {
                mapped.outputs.append(Output(
                    kind: .issueClosed, at: closed, repo: item.repo, number: item.number,
                    url: item.url, title: item.title, resourceKey: key, externalId: base + ":closed",
                    provenance: provenance, syncedAt: syncedAt
                ))
            } else {
                mapped.reopened.append(base + ":closed")
            }
        }
        return mapped
    }

    /// The reviewed PRs worth asking for reviews: someone else's. A review on your own PR is a
    /// reply in your own thread, not a review you shipped.
    public static func reviewCandidates(_ items: [Item], login: String) -> [Item] {
        items.filter { $0.author.map { $0.login.lowercased() != login.lowercased() } ?? true }
    }

    struct Review: Decodable {
        let id: Int64
        let login: String?
        let submitted_at: String?
        let html_url: String?
    }

    /// One `review_submitted` row per review of yours on this PR, at `submitted_at`. A pending
    /// review has no submission time and is skipped.
    public static func reviews(
        _ lines: Data, of pr: Item, login: String, provenance: String, syncedAt: Date
    ) -> [Output] {
        let decoder = JSONDecoder()
        return String(decoding: lines, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(Review.self, from: Data($0.utf8)) }
            .compactMap { review in
                guard review.login?.lowercased() == login.lowercased(),
                      let at = date(review.submitted_at)
                else { return nil }
                return Output(
                    kind: .reviewSubmitted, at: at, repo: pr.repo, number: pr.number,
                    url: review.html_url ?? pr.url, title: pr.title,
                    resourceKey: pullKey(pr.repo, pr.number), externalId: "review:\(review.id)",
                    provenance: provenance, syncedAt: syncedAt
                )
            }
    }

    // MARK: Helpers

    static func pullKey(_ repo: String, _ number: Int) -> String {
        "github.com/\(repo)/pull/\(number)"
    }

    /// ISO 8601 from GitHub. Search answers an open item's `closedAt` with year 1, which is
    /// "no date", not a date.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        var parsed = formatter.date(from: text)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            parsed = formatter.date(from: text)
        }
        guard let parsed, parsed > Date(timeIntervalSince1970: 0) else { return nil }
        return parsed
    }

    static func utcDay(_ date: Date) -> String {
        DayBoundaries.dayString(date, timeZone: TimeZone(identifier: "UTC")!)
    }
}
