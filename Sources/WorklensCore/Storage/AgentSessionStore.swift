import Foundation
import GRDB

/// What one sync round writes, in one transaction.
public struct AgentWrite: Sendable {
    public var sessions: [AgentSession] = []
    public var prompts: [AgentPrompt] = []
    public var turns: [AgentTurn] = []
    public var prs: [AgentSessionPR] = []
    public var files: [AgentSourceFile] = []

    public init() {}

    public var isEmpty: Bool {
        sessions.isEmpty && prompts.isEmpty && turns.isEmpty && prs.isEmpty && files.isEmpty
    }
}

/// Reads and writes the agent-session tables (#321).
///
/// `DataEraser` and `Retention` call `deleteActivity`: a prompt's instant and an agent's turn are
/// time on this Mac, so they go with the screenshots of the same stretch. The sessions, their
/// branch and their PR links stay, the way `outputs` does. `deleteAll` is what
/// `worklens agents forget` and `AGENT_SESSIONS=false` call.
public struct AgentSessionStore: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    // MARK: Writing

    /// Merges a round into the tables. A session's span only grows; a prompt already stored —
    /// by this session or by the fork it was copied from — is left alone. Returns the prompts
    /// inserted.
    @discardableResult
    public func apply(_ write: AgentWrite) throws -> Int {
        guard !write.isEmpty else { return 0 }
        return try db.writer.write { db in
            for session in write.sessions {
                try db.execute(
                    sql: """
                        INSERT INTO agent_sessions
                          (id, tool, host, start_at, end_at, cwd, vcs_repo, branch, edited, parser)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          host = COALESCE(agent_sessions.host, excluded.host),
                          start_at = MIN(COALESCE(agent_sessions.start_at, excluded.start_at),
                                         COALESCE(excluded.start_at, agent_sessions.start_at)),
                          end_at = MAX(COALESCE(agent_sessions.end_at, excluded.end_at),
                                       COALESCE(excluded.end_at, agent_sessions.end_at)),
                          cwd = COALESCE(agent_sessions.cwd, excluded.cwd),
                          vcs_repo = COALESCE(excluded.vcs_repo, agent_sessions.vcs_repo),
                          branch = COALESCE(excluded.branch, agent_sessions.branch),
                          edited = agent_sessions.edited,
                          parser = excluded.parser
                        """,
                    arguments: [
                        session.id, session.tool, session.host, session.startAt, session.endAt,
                        session.cwd, session.vcsRepo, session.branch, session.edited, session.parser,
                    ]
                )
            }
            var inserted = 0
            for prompt in write.prompts {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO agent_prompts (record_id, session_id, at) VALUES (?, ?, ?)",
                    arguments: [prompt.recordId, prompt.sessionId, prompt.at]
                )
                inserted += db.changesCount
            }
            for turn in write.turns {
                try db.execute(
                    sql: """
                        INSERT INTO agent_turns (session_id, start_at, end_at) VALUES (?, ?, ?)
                        ON CONFLICT(session_id, start_at) DO UPDATE SET
                          end_at = MAX(agent_turns.end_at, excluded.end_at)
                        """,
                    arguments: [turn.sessionId, turn.startAt, turn.endAt]
                )
            }
            for pr in write.prs {
                try db.execute(
                    sql: """
                        INSERT INTO agent_session_prs (session_id, pr_key, state) VALUES (?, ?, ?)
                        ON CONFLICT(session_id, pr_key) DO UPDATE SET
                          state = COALESCE(excluded.state, agent_session_prs.state)
                        """,
                    arguments: [pr.sessionId, pr.prKey, pr.state]
                )
            }
            for file in write.files { try file.save(db) }
            // A session's edits are its files' counts, each file once: a rollout moved to
            // `archived_sessions` keeps its name, so the larger of the two copies counts.
            let touched = Set(write.files.compactMap(\.sessionId))
            for id in touched {
                let files = try AgentSourceFile.filter(Column("session_id") == id).fetchAll(db)
                var byName: [String: Int] = [:]
                for file in files {
                    let name = (file.path as NSString).lastPathComponent
                    byName[name] = max(byName[name] ?? 0, file.edited)
                }
                try db.execute(
                    sql: "UPDATE agent_sessions SET edited = ? WHERE id = ?",
                    arguments: [byName.values.reduce(0, +), id]
                )
            }
            return inserted
        }
    }

    /// Runs `RepoMap` over every stored session and writes back what changed.
    @discardableResult
    public func resolveRepos() throws -> Int {
        try db.writer.write { db in
            let sessions = try AgentSession.fetchAll(db)
            let prs = try AgentSessionPR.fetchAll(db)
            var prRepos: [String: [String]] = [:]
            for pr in prs {
                if let repo = AgentStoreParsers.repo(ofPRKey: pr.prKey) { prRepos[pr.sessionId, default: []].append(repo) }
            }
            let resolved = RepoMap.resolve(sessions.map {
                RepoMap.Session(
                    id: $0.id, tool: $0.tool, cwd: $0.cwd, start: $0.startAt, end: $0.endAt,
                    prRepos: prRepos[$0.id] ?? [], vcsRepo: $0.vcsRepo
                )
            })
            var changed = 0
            for session in sessions {
                let next = resolved[session.id] ?? RepoMap.Resolution(repo: nil, rule: nil)
                guard next.repo != session.repo || next.rule != session.repoRule
                    || next.parentId != session.parentId
                else { continue }
                try db.execute(
                    sql: "UPDATE agent_sessions SET repo = ?, repo_rule = ?, parent_id = ? WHERE id = ?",
                    arguments: [next.repo, next.rule, next.parentId, session.id]
                )
                changed += 1
            }
            return changed
        }
    }

    // MARK: Reading

    public func files() throws -> [String: AgentSourceFile] {
        try db.writer.read { db in
            Dictionary(uniqueKeysWithValues: try AgentSourceFile.fetchAll(db).map { ($0.path, $0) })
        }
    }

    public func sessions() throws -> [AgentSession] {
        try db.writer.read { db in try AgentSession.order(Column("start_at")).fetchAll(db) }
    }

    public func session(id: String) throws -> AgentSession? {
        try db.writer.read { db in try AgentSession.fetchOne(db, key: id) }
    }

    /// Prompts in `[from, to)`, oldest first.
    public func prompts(from: Date, to: Date) throws -> [AgentPrompt] {
        try db.writer.read { db in
            try AgentPrompt
                .filter(Column("at") >= from && Column("at") < to)
                .order(Column("at"))
                .fetchAll(db)
        }
    }

    /// Turns that overlap `[from, to)`.
    public func turns(from: Date, to: Date) throws -> [AgentTurn] {
        try db.writer.read { db in
            try AgentTurn
                .filter(Column("start_at") < to && Column("end_at") >= from)
                .order(Column("start_at"))
                .fetchAll(db)
        }
    }

    public func prs() throws -> [AgentSessionPR] {
        try db.writer.read { db in try AgentSessionPR.fetchAll(db) }
    }

    /// Row counts per table, for `worklens agents sync` and the tests.
    public func counts() throws -> (sessions: Int, prompts: Int, turns: Int, prs: Int, files: Int) {
        try db.writer.read { db in
            (
                try AgentSession.fetchCount(db), try AgentPrompt.fetchCount(db),
                try AgentTurn.fetchCount(db), try AgentSessionPR.fetchCount(db),
                try AgentSourceFile.fetchCount(db)
            )
        }
    }

    // MARK: Deleting

    /// Every range an erase covered, which the sync skips on any later read.
    public static let erasedKey = "agents.sessions.erased"

    public func erasedRanges() -> [LastErase] {
        (try? AppStateStore(db).getCodable(Self.erasedKey)) ?? []
    }

    /// Deletes the prompts in `[from, to]` and the turns that overlap it, and forgets a turn still
    /// open from before `to` so the next read cannot stretch it across the gap. `remember` keeps
    /// the range for later reads (an erase; retention has its own cutoff). Returns the rows gone.
    @discardableResult
    public func deleteActivity(from: Date, to: Date, remember: Bool = false) throws -> Int {
        if remember {
            try AppStateStore(db).setCodable(Self.erasedKey, erasedRanges() + [LastErase(from: from, to: to, at: Date())])
        }
        return try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM agent_prompts WHERE at >= ? AND at <= ?", arguments: [from, to]
            )
            var removed = db.changesCount
            try db.execute(
                sql: "DELETE FROM agent_turns WHERE start_at <= ? AND end_at >= ?", arguments: [to, from]
            )
            removed += db.changesCount
            try db.execute(
                sql: "UPDATE agent_source_files SET open_turn_at = NULL WHERE open_turn_at <= ?", arguments: [to]
            )
            return removed
        }
    }

    /// Empties every agent table. Returns how many sessions went.
    @discardableResult
    public func deleteAll() throws -> Int {
        try db.writer.write { db in
            let sessions = try AgentSession.fetchCount(db)
            for table in [
                "agent_sessions", "agent_prompts", "agent_turns", "agent_session_prs", "agent_source_files",
            ] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            return sessions
        }
    }
}
