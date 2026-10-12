import Foundation
import Testing
@testable import WorklensCore

@Suite("agent_sessions MCP tool")
struct AgentSessionsMCPTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-07 09:00 UTC.
    let nine = Date(timeIntervalSince1970: 1_791_363_600)
    let key = "github.com/acme/widgets/pull/12"

    /// A Claude session in a worktree that linked PR 12, a Codex consult inside it, and an hour of
    /// you in the Claude app.
    private func registry() throws -> (MCPToolRegistry, Database) {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("worklens-agents-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.dataDir = dataDir
        let db = try Database.inMemory()
        let tree = "/Users/me/code/widgets/.claude/worktrees/fix"
        var write = AgentWrite()
        write.sessions = [
            AgentSession(id: "claude-1", tool: AgentStoreParsers.claudeCode, host: "claude-desktop",
                         startAt: nine, endAt: nine + 3_000, cwd: tree, branch: "fix", edited: 3),
            AgentSession(id: "codex-1", tool: AgentStoreParsers.codex, host: AgentStoreParsers.codexDesktopHost,
                         startAt: nine + 600, endAt: nine + 1_200, cwd: tree, vcsRepo: "acme/widgets"),
        ]
        write.prompts = [
            AgentPrompt(recordId: "p1", sessionId: "claude-1", at: nine),
            AgentPrompt(recordId: "p2", sessionId: "claude-1", at: nine + 1_800),
        ]
        write.turns = [
            AgentTurn(sessionId: "claude-1", startAt: nine, endAt: nine + 1_200),
            AgentTurn(sessionId: "codex-1", startAt: nine + 600, endAt: nine + 1_800),
        ]
        write.prs = [AgentSessionPR(sessionId: "claude-1", prKey: key)]
        _ = try AgentSessionStore(db).apply(write)
        _ = try AgentSessionStore(db).resolveRepos()
        try ForegroundSessionStore(db).insert(ForegroundSession(
            startAt: nine - 600, endAt: nine + 3_600, appBundleId: "com.anthropic.claudefordesktop"
        ))
        try ActivityBlockStore(db).upsert(ActivityBlock(
            day: "2026-10-07", startAt: nine - 600, endAt: nine + 3_600, appKey: "claude", taskKey: "coding"
        ))
        try OutputStore(db).upsert(Output(
            kind: .prMerged, at: nine + 3_000, repo: "acme/widgets", number: 12,
            url: "https://github.com/acme/widgets/pull/12", title: "Fix the thing", resourceKey: key,
            externalId: "pr12", provenance: "gh search prs", syncedAt: nine + 4_000
        ))
        let registry = WorklensMCPTools.registry(
            config: config, db: db, taxonomy: try TaxonomyStore(dataDir: dataDir), timeZone: utc
        )
        return (registry, db)
    }

    @Test("agent_sessions is read-only, last in the list, and says the minutes are kept apart")
    func declared() throws {
        let (registry, _) = try registry()
        #expect(registry.tools.last?.name == "agent_sessions")
        let tool = try #require(registry.tool(named: "agent_sessions"))
        #expect(tool.annotations == .read)
        #expect(tool.description.contains("YYYY-MM-DD"))
    }

    @Test("agent_sessions refuses from after to, and more than 31 days")
    func bounds() throws {
        let (registry, _) = try registry()
        let backwards = try registry.call(name: "agent_sessions", arguments: .object(["from": "2026-10-08", "to": "2026-10-07"]))
        #expect(backwards.isError)
        #expect(backwards.text.contains("from must not be after to"))
        let long = try registry.call(name: "agent_sessions", arguments: .object(["from": "2026-08-01", "to": "2026-10-07"]))
        #expect(long.isError)
        #expect(long.text.contains("31"))
        let month = try registry.call(name: "agent_sessions", arguments: .object(["from": "2026-09-07", "to": "2026-10-07"]))
        #expect(!month.isError)
    }

    @Test("the report folds a Codex consult into its Claude session and keeps your minutes apart from the agent's")
    func report() throws {
        let (registry, _) = try registry()
        let result = try registry.call(name: "agent_sessions", arguments: .object(["from": "2026-10-07", "to": "2026-10-07"]))
        #expect(!result.isError)
        let report = try JSONDecoder().decode(AgentLedger.Report.self, from: Data(result.text.utf8))
        #expect(report.sessions.map(\.id) == ["claude-1"])
        let session = try #require(report.sessions.first)
        #expect(session.repo == "acme/widgets")
        #expect(session.prompts == 2)
        // Two windows: 08:57 to 09:10 and 09:27 to 09:40.
        #expect(session.yourMinutes == 26)
        // The agents ran 09:00 to 09:30, the consult's turn included.
        #expect(session.agentMinutes == 30)
        #expect(session.outcome == "pr_merged")
        #expect(report.repos.first?.prs == ["merged": 1])
        #expect(!result.text.contains("score"))

        let none = try registry.call(name: "agent_sessions", arguments: .object([
            "from": "2026-10-07", "to": "2026-10-07", "repo": "other",
        ]))
        #expect(try JSONDecoder().decode(AgentLedger.Report.self, from: Data(none.text.utf8)).sessions.isEmpty)
    }

    @Test("shipped lists the sessions behind each PR")
    func shipped() throws {
        let (registry, _) = try registry()
        let result = try registry.call(name: "shipped", arguments: .object(["from": "2026-10-07", "to": "2026-10-07"]))
        #expect(!result.isError)
        #expect(result.text.contains(#"  sessions: [{"agent_minutes":30,"id":"claude-1","tool":"claude_code","your_minutes":26}]"#), "\(result.text)")
    }

    @Test("memo and review rows that share the PR's key do not repeat its sessions line")
    func shippedSessionsOnce() throws {
        let (registry, db) = try registry()
        for (slug, kind) in [("acme", OutputKind.memoPublished), ("globex", .memoUpdated)] {
            try OutputStore(db).upsert(Output(
                source: Output.memo, kind: kind, at: nine + 3_000, repo: "acme/widgets", number: 12,
                url: "https://github.com/acme/widgets/pull/12", title: slug.capitalized,
                path: "memos/\(slug).md", resourceKey: key,
                externalId: "memo:acme/widgets#12:\(slug)", provenance: "test", syncedAt: nine + 4_000
            ))
        }
        try OutputStore(db).upsert(Output(
            kind: .reviewSubmitted, at: nine + 2_000, repo: "acme/widgets", number: 12,
            url: "https://github.com/acme/widgets/pull/12", title: "Fix the thing", resourceKey: key,
            externalId: "review12", provenance: "test", syncedAt: nine + 4_000
        ))
        let result = try registry.call(name: "shipped", arguments: .object(["from": "2026-10-07", "to": "2026-10-07"]))
        #expect(!result.isError)
        #expect(result.text.components(separatedBy: "  sessions: ").count == 2, "\(result.text)")
    }
}
