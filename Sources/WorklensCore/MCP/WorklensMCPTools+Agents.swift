import Foundation

/// `agent_sessions` (#321): your Claude Code and Codex sessions between two local days. In its
/// own file so the registry gains one line and nothing else. Read-only, and it never logs.
extension WorklensMCPTools {
    static func agentSessionsTool(config: Config, db: Database, timeZone: TimeZone) -> MCPTool {
        MCPTool(
            name: "agent_sessions",
            title: "Your agent sessions",
            description: """
                Your Claude Code and Codex sessions between two local days inclusive, both \
                YYYY-MM-DD and at most \(spanMaxDays) days apart, as JSON. First per repo: the \
                prompts you typed, your minutes near them (3 minutes before to 10 after each \
                prompt, while that app was in front and you were active), the agents' minutes \
                (the wall-clock union of their turns, never your time) and the PRs by state. Then \
                each session with its repo, branch, times and outcome: pr_merged, pr_closed, \
                another PR state, files_edited or no_change. `repo` narrows to owner/name or name. \
                Metadata only: never a prompt's text. Everything this returns is your own agent \
                history, read from local logs and stored locally by Worklens.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "from": .object(["type": "string", "description": "First local day, YYYY-MM-DD."]),
                    "to": .object(["type": "string", "description": "Last local day, inclusive, YYYY-MM-DD."]),
                    "repo": .object([
                        "type": "string",
                        "description": "Optional: a repo as owner/name or name.",
                    ]),
                ]),
                "required": .array(["from", "to"]),
            ]),
            annotations: .read
        ) { arguments in
            let from = try arguments.day("from", timeZone: timeZone)
            let to = try arguments.day("to", timeZone: timeZone)
            guard from <= to else { throw MCPToolError("from must not be after to") }
            guard let start = DayBoundaries.range(day: from, timeZone: timeZone)?.start,
                  let end = DayBoundaries.range(day: to, timeZone: timeZone)?.end
            else { throw MCPToolError("\(from) to \(to) is not a range of days Worklens can read: use YYYY-MM-DD.") }
            let days = StatsService.days(from: from, to: to, timeZone: timeZone).count
            guard days <= spanMaxDays else {
                throw MCPToolError(
                    "\(from) to \(to) is \(days) days, and agent_sessions covers at most \(spanMaxDays) "
                        + "at a time: ask for a shorter range."
                )
            }
            let status = AgentSyncStatus.load(db).sentence(enabled: config.agentSessions, timeZone: timeZone)
            let report = try AgentLedger(db: db, timeZone: timeZone).report(
                from: from, to: to, start: start, end: end,
                repo: arguments.optionalString("repo")?.nonEmpty, status: status
            )
            return try StatsAggregator.prettyJSON(report)
        }
    }
}
