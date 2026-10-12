import Foundation
import GRDB

/// What `agent_sessions` (MCP), `worklens agents` and `shipped` read (#321): per repo, your
/// prompts, your minutes near them, the agent's minutes and the PRs; then each session with what
/// came out of it. Your minutes and agent minutes are two numbers and are never added together.
public struct AgentLedger: Sendable {
    public struct PRRow: Codable, Sendable, Equatable {
        public var key: String
        public var state: String
    }

    public struct RepoRow: Codable, Sendable, Equatable {
        /// `owner/name`, a folder name, or nil when no rule could name one.
        public var repo: String?
        public var prompts: Int
        public var yourMinutes: Int
        /// The wall-clock union of the agents' turns: two agents at once count once.
        public var agentMinutes: Int
        /// Distinct PRs by state.
        public var prs: [String: Int]

        enum CodingKeys: String, CodingKey {
            case repo, prompts, prs
            case yourMinutes = "your_minutes"
            case agentMinutes = "agent_minutes"
        }
    }

    public struct SessionRow: Codable, Sendable, Equatable {
        public var id: String
        public var tool: String
        public var host: String?
        public var repo: String?
        public var branch: String?
        public var start: String?
        public var end: String?
        public var prompts: Int
        public var yourMinutes: Int
        public var agentMinutes: Int
        /// `pr_merged`, `pr_closed`, `pr_<desktop state>`, `pr_linked`, `files_edited` or
        /// `no_change`.
        public var outcome: String
        public var prs: [PRRow]

        enum CodingKeys: String, CodingKey {
            case id, tool, host, repo, branch, start, end, prompts, outcome, prs
            case yourMinutes = "your_minutes"
            case agentMinutes = "agent_minutes"
        }
    }

    public struct Report: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
        public var status: String
        public var repos: [RepoRow]
        public var sessions: [SessionRow]
    }

    /// The `sessions` a `shipped` PR row gains.
    public struct SessionMinutes: Codable, Sendable, Equatable {
        public var id: String
        public var tool: String
        public var yourMinutes: Int
        public var agentMinutes: Int

        enum CodingKeys: String, CodingKey {
            case id, tool
            case yourMinutes = "your_minutes"
            case agentMinutes = "agent_minutes"
        }
    }

    private let db: Database
    private let timeZone: TimeZone

    public init(db: Database, timeZone: TimeZone = .current) {
        self.db = db
        self.timeZone = timeZone
    }

    // MARK: Report

    public func report(
        from: String, to: String, start: Date, end: Date, repo filter: String?, status: String
    ) throws -> Report {
        let store = AgentSessionStore(db)
        let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
        let tally = try minutes(start: start, end: end, sessions: sessions)
        let prsBySession = try prStates(sessions: sessions)

        var rows: [SessionRow] = []
        for id in Set(tally.prompts.keys).union(tally.turns.keys).sorted() {
            guard let session = sessions[id] else { continue }
            if let filter, !Self.matches(session.repo, filter: filter) { continue }
            let prs = (prsBySession[id] ?? []).sorted { $0.key < $1.key }
            rows.append(SessionRow(
                id: id, tool: session.tool, host: session.host, repo: session.repo, branch: session.branch,
                start: session.startAt.map(clock), end: session.endAt.map(clock),
                prompts: tally.prompts[id] ?? 0,
                yourMinutes: Self.minutes(tally.yours[id] ?? 0),
                agentMinutes: Self.minutes(PromptWindows.coveredSeconds(tally.turns[id] ?? [], from: start, to: end)),
                outcome: Self.outcome(prs: prs, edited: tally.edited[id] ?? session.edited),
                prs: prs
            ))
        }
        rows.sort { ($0.start ?? "", $0.id) < ($1.start ?? "", $1.id) }

        var repos: [RepoRow] = []
        let grouped = Dictionary(grouping: rows) { $0.repo ?? "" }
        for key in grouped.keys.sorted() {
            let group = grouped[key] ?? []
            var states: [String: Set<String>] = [:]
            for pr in group.flatMap(\.prs) { states[pr.state, default: []].insert(pr.key) }
            repos.append(RepoRow(
                repo: key.isEmpty ? nil : key,
                prompts: group.reduce(0) { $0 + $1.prompts },
                yourMinutes: Self.minutes(group.reduce(0) { $0 + (tally.yours[$1.id] ?? 0) }),
                agentMinutes: Self.minutes(PromptWindows.coveredSeconds(
                    group.flatMap { tally.turns[$0.id] ?? [] }, from: start, to: end
                )),
                prs: states.mapValues(\.count)
            ))
        }
        return Report(from: from, to: to, status: status, repos: repos, sessions: rows)
    }

    // MARK: Shipped

    /// For each PR key, the sessions that linked it, with your minutes and the agent's over the
    /// whole of each session.
    public func sessions(forPRKeys keys: Set<String>) throws -> [String: [SessionMinutes]] {
        guard !keys.isEmpty else { return [:] }
        let store = AgentSessionStore(db)
        let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
        var linked: [String: Set<String>] = [:]
        for pr in try store.prs() where keys.contains(pr.prKey) {
            let id = sessions[pr.sessionId]?.parentId ?? pr.sessionId
            linked[pr.prKey, default: []].insert(id)
        }
        let ids = Set(linked.values.flatMap { $0 })
        let spans = ids.compactMap { sessions[$0] }.compactMap { s -> (Date, Date)? in
            guard let start = s.startAt else { return nil }
            return (start, s.endAt ?? start)
        }
        guard let first = spans.map(\.0).min(), let last = spans.map(\.1).max() else { return [:] }
        // A prompt's window opens before it and closes after it: take both edges in.
        let start = first.addingTimeInterval(-PromptWindows.before)
        let end = last.addingTimeInterval(PromptWindows.after + 1)
        let tally = try minutes(start: start, end: end, sessions: sessions)
        return linked.mapValues { ids in
            ids.sorted().compactMap { id in
                guard let session = sessions[id] else { return nil }
                return SessionMinutes(
                    id: id, tool: session.tool,
                    yourMinutes: Self.minutes(tally.yours[id] ?? 0),
                    agentMinutes: Self.minutes(PromptWindows.coveredSeconds(tally.turns[id] ?? [], from: start, to: end))
                )
            }
        }
    }

    // MARK: Internals

    private struct Tally {
        var prompts: [String: Int] = [:]
        var yours: [String: TimeInterval] = [:]
        var turns: [String: [DateInterval]] = [:]
        var edited: [String: Int] = [:]
    }

    /// Everything keyed by the session a row counts for: a Codex consult's parent, else itself.
    private func minutes(start: Date, end: Date, sessions: [String: AgentSession]) throws -> Tally {
        let store = AgentSessionStore(db)
        func counted(_ id: String) -> String { sessions[id]?.parentId ?? id }
        var tally = Tally()

        let prompts = try store.prompts(from: start.addingTimeInterval(-PromptWindows.after), to: end)
        for prompt in prompts where prompt.at >= start {
            tally.prompts[counted(prompt.sessionId), default: 0] += 1
        }
        let windows = prompts.map { prompt in
            let id = counted(prompt.sessionId)
            return PromptWindows.Prompt(
                at: prompt.at, sessionId: id, repo: sessions[id]?.repo, host: sessions[prompt.sessionId]?.host
            )
        }
        let lookFrom = start.addingTimeInterval(-PromptWindows.after - PromptWindows.before)
        let foreground = try ForegroundSessionStore(db).fetch(overlapping: lookFrom, to: end)
        let active = try ActivityBlockStore(db)
            .fetchRange(
                from: DayBoundaries.dayString(lookFrom, timeZone: timeZone),
                to: DayBoundaries.dayString(end, timeZone: timeZone)
            )
            .filter { !StatsAggregator.isInactive($0) }
            .map { DateInterval(start: $0.startAt, end: max($0.startAt, $0.endAt)) }
        for piece in PromptWindows.attribute(
            prompts: windows, foreground: foreground, active: active, timeZone: timeZone
        ) {
            let clipped = min(piece.end, end).timeIntervalSince(max(piece.start, start))
            if clipped > 0 { tally.yours[piece.sessionId, default: 0] += clipped }
        }

        for turn in try store.turns(from: start, to: end) {
            tally.turns[counted(turn.sessionId), default: []].append(turn.interval)
        }
        for (id, session) in sessions { tally.edited[counted(id), default: 0] += session.edited }
        return tally
    }

    /// Each session's PRs with a state: `outputs` first (merged or closed), then what the
    /// desktop app said, then `linked`.
    private func prStates(sessions: [String: AgentSession]) throws -> [String: [PRRow]] {
        let links = try AgentSessionStore(db).prs()
        let shipped: [String: String] = try db.writer.read { db in
            var out: [String: String] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT resource_key, kind FROM outputs WHERE resource_key IS NOT NULL AND kind IN (?, ?)",
                arguments: [OutputKind.prMerged.rawValue, OutputKind.prClosed.rawValue]
            )
            for row in rows {
                let key: String = row["resource_key"]
                let kind: String = row["kind"]
                out[key] = kind == OutputKind.prMerged.rawValue ? "merged" : (out[key] ?? "closed")
            }
            return out
        }
        var out: [String: [String: String]] = [:]
        for link in links {
            let id = sessions[link.sessionId]?.parentId ?? link.sessionId
            let state = shipped[link.prKey] ?? link.state?.nonEmpty ?? "linked"
            let previous = out[id]?[link.prKey]
            if previous == nil || Self.rank(state) < Self.rank(previous!) { out[id, default: [:]][link.prKey] = state }
        }
        return out.mapValues { $0.map { PRRow(key: $0.key, state: $0.value) } }
    }

    static func rank(_ state: String) -> Int {
        switch state {
        case "merged": 0
        case "closed": 1
        case "linked": 3
        default: 2
        }
    }

    static func outcome(prs: [PRRow], edited: Int) -> String {
        if let best = prs.min(by: { rank($0.state) < rank($1.state) }) { return "pr_\(best.state)" }
        return edited > 0 ? "files_edited" : "no_change"
    }

    /// `owner/name` exactly, or just its name.
    static func matches(_ repo: String?, filter: String) -> Bool {
        guard let repo else { return false }
        let wanted = filter.lowercased()
        let have = repo.lowercased()
        return have == wanted || have.split(separator: "/").last.map(String.init) == wanted
    }

    static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
