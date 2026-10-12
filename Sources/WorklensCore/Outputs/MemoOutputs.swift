import Foundation
import GRDB

/// What one memo pass did (#317). Counts only: this is what the `info` line and the CLI print.
public struct MemoApplyResult: Sendable, Equatable {
    /// PRs whose file list was read.
    public var prsRead = 0
    /// Memo rows inserted or changed.
    public var written = 0
    public var published = 0
    public var updated = 0
    /// Company entries added to the catalog.
    public var created = 0
    /// Folders that named more than one entry, left unlinked.
    public var ambiguous = 0
    /// Rows whose project or name was re-resolved.
    public var relinked = 0
    /// PRs `gh` says do not exist, or whose answer is not a file list; not tried again.
    public var skipped = 0

    public init() {}
}

/// Memo rows from your merged memo-repo PRs (#317): for each merged PR of yours in a repo
/// listed in `MEMO_REPOS`, one `memo_published` or `memo_updated` row per company folder whose
/// memo it added or changed (`MemoPathRule`), linked to the catalog's company entry
/// (`MemoCompanyMatcher`), or to a `company` entry created for it (D2).
///
/// `OutputSync` calls `apply` once per round, before it writes the round's rows, with the rows it
/// found: a PR is read the round its merged row first lands, and once more never. Rows already in
/// the ledger when the rule (or the repo list) is new are read by a one-time backfill gated by
/// `app_state.memo_rule_backfilled`. No row, slug or path goes anywhere but `outputs`: not into a
/// Gemini request, and not into a log line above `debug`.
public struct MemoOutputs: Sendable {
    public enum LogLevel: Sendable { case debug, info }

    /// Rows the ledger counts as memo rows.
    public static let source = Output.memo
    /// The `app_state` key of the backfill gate. Its value is the rule version and the repo list,
    /// so a new rule or a newly listed repo backfills once more.
    public static let backfillKey = "memo_rule_backfilled"
    public static let ruleVersion = 1

    /// `owner/name`, as `MEMO_REPOS` lists them. Empty means off.
    public let repos: [String]
    private let db: Database
    private let taxonomy: @Sendable () throws -> TaxonomyStore
    private let log: @Sendable (LogLevel, String) -> Void

    /// - Parameter taxonomy: the catalog, opened fresh each pass so an edit made elsewhere since
    ///   the last one is what a created entry is checked against.
    /// - Parameter log: `info` gets counts only; slugs, names and paths go to `debug`.
    public init(
        repos: [String],
        db: Database,
        taxonomy: @escaping @Sendable () throws -> TaxonomyStore,
        log: @escaping @Sendable (LogLevel, String) -> Void = { level, line in
            switch level {
            case .debug: Log.net.debug(line)
            case .info: Log.net.info(line)
            }
        }
    ) {
        self.repos = repos.map(Self.repoName).filter { !$0.isEmpty }
        self.db = db
        self.taxonomy = taxonomy
        self.log = log
    }

    /// The pass the ledger wires in, reading `MEMO_REPOS` and the catalog in `DATA_DIR`.
    public static func forConfig(_ config: Config, db: Database) -> MemoOutputs {
        let dataDir = config.dataDir
        return MemoOutputs(repos: config.memoRepos, db: db, taxonomy: { try TaxonomyStore(dataDir: dataDir) })
    }

    /// `owner/name` from a `MEMO_REPOS` entry written as a GitHub URL, or with a trailing `.git`
    /// or slash. A value with no `/` comes back as it is and matches no repo; the config warns.
    public static func repoName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www.", "github.com/"] where name.lowercased().hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        while name.hasSuffix("/") { name.removeLast() }
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    /// Deletes every memo row and the backfill gate. Returns how many rows went.
    @discardableResult
    public static func forget(db: Database) -> Int {
        let removed = (try? OutputStore(db).deleteAll(source: source)) ?? 0
        try? AppStateStore(db).delete(backfillKey)
        return removed
    }

    var gate: String {
        "\(Self.ruleVersion) " + repos.map { $0.lowercased() }.sorted().joined(separator: ",")
    }

    private func listed(_ repo: String?) -> Bool {
        guard let repo else { return false }
        return repos.contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// One pass: the merged PRs in `changed` the ledger does not hold yet (plus, once, the ones it
    /// does), each read with `gh pr view --json files`, then every memo row re-resolved against
    /// the catalog. With `MEMO_REPOS` empty it reads nothing and the memo rows are deleted.
    ///
    /// One PR `gh` says does not exist is skipped. Any other `gh` failure (missing, logged out,
    /// rate-limited, timing out, a 5xx or a network error), or a catalog that will not open, ends
    /// the pass and re-arms the backfill, so the next pass reads those PRs again.
    @discardableResult
    public func apply(changed: [Output], runner: any GHRunning, syncedAt: Date) async throws -> MemoApplyResult {
        var result = MemoApplyResult()
        guard !repos.isEmpty else {
            Self.forget(db: db)
            return result
        }
        let appState = AppStateStore(db)
        guard let store = try? taxonomy() else {
            // Rows written now could never get their company, so read nothing and backfill once
            // the catalog opens again.
            try? appState.delete(Self.backfillKey)
            log(.info, "memo outputs stopped: the project catalog did not open")
            return result
        }
        let backfill = (try? appState.get(Self.backfillKey)) != gate

        var prs = try fresh(changed.filter { $0.kind == .prMerged && $0.source == Output.github && listed($0.repo) })
        if backfill {
            let stored = try await db.writer.read { db in
                try Output
                    .filter(Column("source") == Output.github && Column("kind") == OutputKind.prMerged)
                    .order(Column("at").asc)
                    .fetchAll(db)
            }
            let seen = Set(prs.map(\.externalId))
            prs += stored.filter { listed($0.repo) && !seen.contains($0.externalId) }
        }

        var rows: [Output] = []
        var stopped: (any Error)?
        reading: for pr in prs {
            try Task.checkCancellation()
            guard let repo = pr.repo, let number = pr.number else { continue }
            let files: [MemoPathRule.File]
            do {
                files = try await readFiles(repo: repo, number: number, runner: runner)
            } catch let error as MemoReadSkip {
                // This PR alone: gone, or an answer that is not a file list.
                result.skipped += 1
                log(.debug, "memo files of \(repo)#\(number) not read: \(error)")
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                stopped = error
                break reading
            }
            result.prsRead += 1
            for event in MemoPathRule.events(files: files) {
                if event.kind == .memoPublished { result.published += 1 } else { result.updated += 1 }
                let (entry, rule) = resolve(slug: event.slug, store: store, result: &result)
                log(.debug, "memo \(event.kind) \(repo)#\(number) \(event.path) -> \(entry?.name ?? "no company")")
                rows.append(Output(
                    source: Self.source, kind: event.kind, at: pr.at, repo: repo, number: number,
                    url: pr.url, title: entry?.name ?? MemoCompanyMatcher.displayName(slug: event.slug),
                    path: event.path, resourceKey: pr.resourceKey,
                    externalId: "memo:\(repo)#\(number):\(event.slug)",
                    projectKey: entry?.key, projectRule: rule,
                    provenance: MemoPathRule.provenance, syncedAt: syncedAt
                ))
            }
        }
        result.written = try OutputStore(db).upsert(rows)
        if let stopped {
            // gh as a whole is not answering. The ledger still writes its rows, so the PRs not read
            // here are re-read by a backfill on the next pass rather than lost.
            try? appState.delete(Self.backfillKey)
            log(.info, "memo outputs stopped: \((stopped as? GHError)?.description ?? "the pass failed")")
        } else if backfill {
            try appState.set(Self.backfillKey, gate)
        }
        result.relinked = try relink(store: store, result: &result)

        log(.info, "memo outputs: \(result.prsRead) PRs read, \(result.written) written "
            + "(\(result.published) published, \(result.updated) updated), \(result.created) companies created, "
            + "\(result.ambiguous) ambiguous, \(result.skipped) skipped, \(result.relinked) relinked")
        return result
    }

    private func readFiles(repo: String, number: Int, runner: any GHRunning) async throws -> [MemoPathRule.File] {
        let output = try await runner.run(MemoPathRule.filesArguments(repo: repo, number: number))
        if output.status != 0, output.stderr.lowercased().contains("could not resolve to a pullrequest") {
            throw MemoReadSkip.gone
        }
        if let error = GHError.classify(output) { throw error }
        do { return try MemoPathRule.decodeFiles(output.stdout) } catch { throw MemoReadSkip.unreadable }
    }

    /// The merged PRs whose ledger row is not stored yet, or is stored with another merge time:
    /// the ones this round's write is about to change.
    private func fresh(_ prs: [Output]) throws -> [Output] {
        guard !prs.isEmpty else { return [] }
        let stored = try db.writer.read { db in
            try Output
                .filter(Column("source") == Output.github && prs.map(\.externalId).contains(Column("external_id")))
                .fetchAll(db)
        }
        let at = Dictionary(stored.map { ($0.externalId, $0.at) }, uniquingKeysWith: { first, _ in first })
        // A PR found by two search windows is one PR.
        var seen: Set<String> = []
        return prs.filter { at[$0.externalId] != $0.at && seen.insert($0.externalId).inserted }
    }

    /// The entry a folder names, creating a `company` entry when none does. Ambiguity links nothing.
    private func resolve(
        slug: String, store: TaxonomyStore, result: inout MemoApplyResult
    ) -> (ProjectEntry?, String?) {
        switch MemoCompanyMatcher.match(slug: slug, in: store.projects) {
        case let .one(entry):
            return (entry, "memo_slug")
        case .ambiguous:
            result.ambiguous += 1
            return (nil, nil)
        case .none:
            guard let entry = create(slug: slug, store: store) else { return (nil, nil) }
            result.created += 1
            return (entry, "memo_created")
        }
    }

    private func create(slug: String, store: TaxonomyStore) -> ProjectEntry? {
        do {
            return try ProjectCatalog.addCompany(
                name: MemoCompanyMatcher.displayName(slug: slug), aliases: [slug], in: store
            )
        } catch {
            log(.debug, "memo company for \(slug) not created: \(error)")
            return nil
        }
    }

    /// Re-resolves every memo row against the catalog: a row whose entry was merged away follows
    /// it to the target, an unlinked row is matched again, and a renamed entry's name reaches the
    /// row. A row whose company a pass created, and which no entry answers for any more (a stale
    /// catalog save dropped it, or you forgot it), gets that entry back. Returns how many rows
    /// changed.
    func relink(store: TaxonomyStore, result: inout MemoApplyResult) throws -> Int {
        var projects = store.projects
        let created = try db.writer.read { db in
            try Output
                .filter(Column("source") == Self.source && Column("project_rule") == "memo_created")
                .fetchAll(db)
        }
        for row in created {
            guard let slug = row.path.flatMap(MemoPathRule.slug(of:)),
                  row.projectKey.flatMap({ ProjectEntry.lookup(key: $0, in: projects) }) == nil,
                  case .none = MemoCompanyMatcher.match(slug: slug, in: projects),
                  create(slug: slug, store: store) != nil
            else { continue }
            result.created += 1
            projects = store.projects
        }
        return try db.writer.write { [projects] db in
            let rows = try Output.filter(Column("source") == Self.source).fetchAll(db)
            var changed = 0
            for row in rows {
                guard let slug = row.path.flatMap(MemoPathRule.slug(of:)) else { continue }
                var entry: ProjectEntry?
                var rule = row.projectRule
                if let key = row.projectKey, let exact = projects.first(where: { $0.key == key }) {
                    entry = exact
                } else if let key = row.projectKey, let followed = ProjectEntry.lookup(key: key, in: projects) {
                    entry = followed
                } else if case let .one(found) = MemoCompanyMatcher.match(slug: slug, in: projects) {
                    entry = found
                    rule = "memo_slug"
                }
                if entry == nil { rule = nil }
                let title = entry?.name ?? MemoCompanyMatcher.displayName(slug: slug)
                guard entry?.key != row.projectKey || title != row.title else { continue }
                try db.execute(
                    sql: "UPDATE outputs SET project_key = ?, project_rule = ?, title = ? WHERE id = ?",
                    arguments: [entry?.key, rule, title, row.id]
                )
                changed += 1
            }
            return changed
        }
    }
}

/// Why one PR's file list is skipped for good, rather than the pass stopped.
private enum MemoReadSkip: Error {
    /// `gh` says the PR does not exist.
    case gone
    /// `gh` answered with something that is not a file list.
    case unreadable
}
