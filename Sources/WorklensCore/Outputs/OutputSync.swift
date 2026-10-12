import Foundation

/// Where the GitHub ledger's last round stands, kept in `app_state` so a relaunch, the CLI and
/// the MCP tool all read the same answer.
public struct OutputSyncStatus: Codable, Sendable, Equatable {
    public static let key = "outputs.github.status"

    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// The sentence for the last failure; nil after a success.
    public var lastError: String?
    public var consecutiveFailures: Int = 0
    public var retryAfter: Date?
    /// Rows the last successful round wrote or removed.
    public var lastChanged: Int?

    public init() {}

    public static func load(_ db: Database) -> OutputSyncStatus {
        (try? AppStateStore(db).getCodable(key)) ?? OutputSyncStatus()
    }

    /// One line for the CLI and the MCP tool. Timestamps in `yyyy-MM-dd HH:mm`, local.
    public func sentence(enabled: Bool = true, timeZone: TimeZone = .current) -> String {
        guard enabled else { return "GitHub sync is off (GITHUB_SHIPPED=false)." }
        let clock = DateFormatter()
        clock.calendar = Calendar(identifier: .gregorian)
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "yyyy-MM-dd HH:mm"
        let last = lastSuccessAt.map { "last synced \(clock.string(from: $0))" } ?? "never synced"
        guard let lastError else { return "GitHub \(last)." }
        return "GitHub \(last); the last try failed: \(lastError)"
    }
}

/// What one round found.
public struct OutputSyncResult: Sendable, Equatable {
    public var since: Date
    /// Rows the answers mapped to, before deduplication against the table.
    public var found: Int
    /// Rows inserted or changed.
    public var changed: Int
    /// Terminal rows dropped because the PR or issue is open again.
    public var removed: Int
    /// What the memo pass did (#317); nil when no pass is wired.
    public var memo: MemoApplyResult? = nil
}

/// Fills `outputs` from `gh search` (#314). Not a `ContextSyncSource`: it has no window of
/// events to fetch and no credential of its own, so `ContextSyncScheduler` just awaits it once
/// per round.
///
/// The first round looks back 30 days; every later one starts a day before the last success, so
/// a merge late in the day is never between two windows. A failure — `gh` missing, logged out,
/// rate-limited — is a status line and the scheduler's 1/5/15/60-minute backoff, never a throw.
public actor OutputSync {
    public static let firstSyncDays = 30
    public static let overlap: TimeInterval = 24 * 3600

    public enum LogLevel: Sendable { case info, warn }

    private let db: Database
    private let store: OutputStore
    private let appState: AppStateStore
    private let runner: any GHRunning
    private let memo: MemoOutputs?
    private let now: @Sendable () -> Date
    private let log: @Sendable (LogLevel, String) -> Void
    private var status: OutputSyncStatus
    private var login: String?

    /// - Parameter log: where the round's one line goes. Never handed a title, URL or repo.
    public init(
        db: Database,
        runner: any GHRunning = GHRunner(),
        memo: MemoOutputs? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (LogLevel, String) -> Void = { level, line in
            switch level {
            case .info: Log.net.info(line)
            case .warn: Log.net.warn(line)
            }
        }
    ) {
        self.db = db
        store = OutputStore(db)
        appState = AppStateStore(db)
        self.runner = runner
        self.memo = memo
        self.now = now
        self.log = log
        status = OutputSyncStatus.load(db)
    }

    /// The sync the app wires in when `GITHUB_SHIPPED` is on. When it is off, the ledger's rows
    /// and status are deleted and nil comes back: turning it off stops it and removes it.
    public static func forConfig(_ config: Config, db: Database) -> OutputSync? {
        guard config.githubShipped else {
            forget(db: db)
            return nil
        }
        return OutputSync(db: db, memo: MemoOutputs.forConfig(config, db: db))
    }

    /// Deletes every GitHub row, every memo row (#317) and the sync status. Returns how many
    /// rows went.
    @discardableResult
    public static func forget(db: Database) -> Int {
        let removed = (try? OutputStore(db).deleteAll(source: Output.github)) ?? 0
        try? AppStateStore(db).delete(OutputSyncStatus.key)
        return removed + MemoOutputs.forget(db: db)
    }

    public var currentStatus: OutputSyncStatus { status }

    /// The scheduler's call: a round unless the last failure's backoff has not run out.
    @discardableResult
    public func syncIfDue() async -> Result<OutputSyncResult, any Error>? {
        status = OutputSyncStatus.load(db)
        if let retryAfter = status.retryAfter, now() < retryAfter { return nil }
        return await sync()
    }

    /// One round. `days` overrides the window, for `worklens shipped sync --days N`.
    @discardableResult
    public func sync(days: Int? = nil) async -> Result<OutputSyncResult, any Error> {
        // Re-read what is stored: a CLI `shipped forget` or `shipped sync` in another process
        // changes it, and the copy from init would write a forgotten status back.
        status = OutputSyncStatus.load(db)
        let at = now()
        let since: Date
        if let days {
            since = at.addingTimeInterval(-Double(max(1, days)) * 24 * 3600)
        } else if let last = status.lastSuccessAt {
            since = last.addingTimeInterval(-Self.overlap)
        } else {
            since = at.addingTimeInterval(-Double(Self.firstSyncDays) * 24 * 3600)
        }
        status.lastAttemptAt = at
        do {
            let result = try await round(since: since, at: at)
            status.lastSuccessAt = at
            status.lastError = nil
            status.consecutiveFailures = 0
            status.retryAfter = nil
            status.lastChanged = result.changed + result.removed
            persist()
            log(.info, "github shipped sync: \(result.found) found, \(result.changed) written, \(result.removed) removed")
            return .success(result)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            status.lastError = (error as? GHError)?.description ?? ContextSyncScheduler.describe(error)
            status.consecutiveFailures += 1
            status.retryAfter = at.addingTimeInterval(ContextSyncScheduler.backoff(after: status.consecutiveFailures))
            persist()
            log(.warn, "github shipped sync failed: \(status.lastError ?? "")")
            return .failure(error)
        }
    }

    private func round(since: Date, at: Date) async throws -> OutputSyncResult {
        var mapped = GitHubOutputs.Mapped()
        for search in GitHubOutputs.searches(since: since, now: at) {
            try Task.checkCancellation()
            let items = try GitHubOutputs.decodeItemsOrThrow(try await call(search.arguments))
            switch search.scope {
            case .authoredPRs:
                let page = GitHubOutputs.pullRequests(items, provenance: search.provenance, syncedAt: at)
                mapped.outputs += page.outputs
                mapped.reopened += page.reopened
            case .authoredIssues:
                let page = GitHubOutputs.issues(items, provenance: search.provenance, syncedAt: at)
                mapped.outputs += page.outputs
                mapped.reopened += page.reopened
            case .reviewedPRs:
                guard !items.isEmpty else { continue }
                let me = try await currentLogin()
                for pr in GitHubOutputs.reviewCandidates(items, login: me) {
                    try Task.checkCancellation()
                    let lines = try await call(GitHubOutputs.reviewArguments(repo: pr.repo, number: pr.number))
                    mapped.outputs += GitHubOutputs.reviews(
                        lines, of: pr, login: me,
                        provenance: search.provenance + " + reviews", syncedAt: at
                    )
                }
            }
        }

        // #317: before the write, so the pass can tell which merged PRs are new to the ledger. It
        // never fails the round: the ledger's rows are written either way.
        var memoResult: MemoApplyResult?
        do {
            memoResult = try await memo?.apply(changed: mapped.outputs, runner: runner, syncedAt: at)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Re-arm the backfill, so the PRs this pass did not record are read on the next one.
            try? appState.delete(MemoOutputs.backfillKey)
            log(.warn, "memo outputs failed:\((error as? GHError)?.description ?? "a database step failed")")
        }
        let changed = try store.upsert(mapped.outputs)
        var removed = 0
        for id in Set(mapped.reopened) {
            removed += try store.delete(source: Output.github, externalId: id)
        }
        return OutputSyncResult(
            since: since, found: mapped.outputs.count, changed: changed, removed: removed, memo: memoResult
        )
    }

    private func currentLogin() async throws -> String {
        if let login { return login }
        let answer = String(decoding: try await call(GitHubOutputs.loginArguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw GHError.unreadable }
        login = answer
        return answer
    }

    private func call(_ arguments: [String]) async throws -> Data {
        let output = try await runner.run(arguments)
        if let error = GHError.classify(output) { throw error }
        return output.stdout
    }

    private func persist() {
        try? appState.setCodable(OutputSyncStatus.key, status)
    }
}

extension GitHubOutputs {
    /// `decodeItems`, with an unreadable answer as a `GHError`.
    static func decodeItemsOrThrow(_ data: Data) throws -> [Item] {
        do { return try decodeItems(data) } catch { throw GHError.unreadable }
    }
}
