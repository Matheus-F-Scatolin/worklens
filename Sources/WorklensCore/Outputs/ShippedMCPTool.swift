import Foundation

/// `shipped` (#314): what you shipped on GitHub between two local days. Kept beside the ledger
/// rather than in `WorklensMCPTools.swift` so the registry gains one line and nothing else.
/// Read-only, like every tool there, and it never logs.
extension WorklensMCPTools {
    static func shippedTool(
        config: Config, db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone
    ) -> MCPTool {
        MCPTool(
            name: "shipped",
            title: "What you shipped",
            description: """
                The PRs you merged or closed, the issues you opened or closed, the reviews you \
                submitted on others' PRs, and the company memos your merged PRs published or \
                updated in the repos MEMO_REPOS lists, from GitHub through `gh`, between two \
                local days inclusive, both YYYY-MM-DD and at most \(spanMaxDays) days apart. \
                Counts are per kind, then the sync status, then one line per item with its time, \
                repo#number, title and URL; a memo line names the company and the PR that \
                published it. A PR or issue line can end in `· on your screen` and the minutes its \
                page was in front of you over the 30 days up to that day. Under a PR, an indented \
                `sessions:` line lists, as JSON, the Claude Code and Codex sessions that linked it, \
                with your minutes and the agents' minutes kept apart; it appears once per PR, \
                never under that PR's memo lines or reviews. `project` narrows to a project name \
                or a repo. Everything this returns is your own GitHub activity, synced and stored \
                locally by Worklens.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "from": .object(["type": "string", "description": "First local day, YYYY-MM-DD."]),
                    "to": .object(["type": "string", "description": "Last local day, inclusive, YYYY-MM-DD."]),
                    "project": .object([
                        "type": "string",
                        "description": "Optional: a project name, or a repo as owner/name or name.",
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
                    "\(from) to \(to) is \(days) days, and shipped covers at most \(spanMaxDays) "
                        + "at a time: ask for a shorter range."
                )
            }
            return try shippedText(
                from: from, to: to, start: start, end: end,
                project: arguments.optionalString("project"),
                config: config, db: db, projects: taxonomy.projects, timeZone: timeZone
            )
        }
    }

    static func shippedText(
        from: String, to: String, start: Date, end: Date, project: String?,
        config: Config, db: Database, projects: [ProjectEntry], timeZone: TimeZone
    ) throws -> String {
        var rows = try OutputStore(db).outputs(from: start, to: end)
        if let project, !project.isEmpty {
            rows = rows.filter { ShippedSection.matches($0, filter: project, projects: projects) }
        }
        let scope = project.map { " for \($0)" } ?? ""
        let status = OutputSyncStatus.load(db).sentence(enabled: config.githubShipped, timeZone: timeZone)
        guard !rows.isEmpty else {
            return "Nothing shipped\(scope) between \(from) and \(to).\n\(status)"
        }
        let onScreen = try screenSeconds(rows, from: from, to: to, db: db, timeZone: timeZone)
        // #321: the Claude Code and Codex sessions that linked each PR, with your minutes and the
        // agents' kept apart.
        // Memo and review rows carry the PR's key too, so only the latest PR row per key prints
        // the line: printed once, the minutes cannot be summed twice.
        let carriers = sessionCarriers(rows)
        let sessions = (try? AgentLedger(db: db, timeZone: timeZone).sessions(
            forPRKeys: Set(carriers.keys)
        )) ?? [:]
        var out = ["Shipped\(scope) between \(from) and \(to): \(ShippedSection.countsLine(rows)).", status]
        for group in ShippedSection.groups(rows, projects: projects) {
            out += ["", "\(group.name): \(ShippedSection.countsLine(group.outputs))"]
            for row in group.outputs {
                out.append(
                    ShippedSection.line(row, timeZone: timeZone, format: "yyyy-MM-dd HH:mm", withURL: true)
                        + OutputViewTime.suffix(seconds: onScreen[row.id] ?? 0)
                )
                if let key = row.resourceKey, carriers[key] == row.id, let linked = sessions[key], !linked.isEmpty {
                    out.append("  sessions: \(sessionsJSON(linked))")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// PR key → the id of the one row that carries its sessions line: the latest merged or
    /// closed GitHub PR row with that key. Memo rows (#317) and reviews share the key and get none.
    static func sessionCarriers(_ rows: [Output]) -> [String: String] {
        var latest: [String: Output] = [:]
        for row in rows where row.source == Output.github && (row.kind == .prMerged || row.kind == .prClosed) {
            guard let key = row.resourceKey else { continue }
            if let current = latest[key], (current.at, current.id) >= (row.at, row.id) { continue }
            latest[key] = row
        }
        return latest.mapValues(\.id)
    }

    /// #319: seconds each GitHub row's page was on your screen, over `from - 29 … to`. Reads no
    /// day at all when nothing in `rows` is a GitHub PR or issue.
    static func screenSeconds(
        _ rows: [Output], from: String, to: String, db: Database, timeZone: TimeZone
    ) throws -> [String: Double] {
        guard rows.contains(where: { $0.source == Output.github && $0.number != nil }),
              let first = OutputViewTime.firstDay(from: from, timeZone: timeZone)
        else { return [:] }
        let service = StatsService(db, timeZone: timeZone)
        var perDay: [String: [ArtifactKey: Double]] = [:]
        for day in StatsService.days(from: first, to: to, timeZone: timeZone) {
            perDay[day] = try service.documentSeconds(day: day)
        }
        return OutputViewTime.seconds(outputs: rows, perDay: perDay, timeZone: timeZone)
    }

    /// `[{"agent_minutes":40,"id":"…","tool":"claude_code","your_minutes":12}]` on one line.
    static func sessionsJSON(_ sessions: [AgentLedger.SessionMinutes]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(sessions)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
