import Foundation
import Testing
@testable import WorklensCore

/// Log lines in the shapes Claude Code, the Claude app's Code tab and Codex write. The text in
/// them is a marker the tests look for in every table afterwards.
enum AgentFixtures {
    static let secret = "SECRET-PROMPT-TEXT"
    static let cwd = "/Users/me/code/worklens"

    static func date(_ text: String) -> Date { AgentStoreParsers.parseDate(text)! }

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func user(
        _ uuid: String, at: String, text: String? = nil, origin: String? = nil, toolResult: Bool = false,
        sidechain: Bool = false, cwd: String = cwd, branch: String = "main", entrypoint: String = "claude-desktop"
    ) -> String {
        var record: [String: Any] = [
            "type": "user", "uuid": uuid, "timestamp": at, "sessionId": "s", "cwd": cwd,
            "gitBranch": branch, "entrypoint": entrypoint, "userType": "external", "isSidechain": sidechain,
        ]
        if let origin { record["origin"] = ["kind": origin] }
        if toolResult {
            record["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": secret]]]
        } else {
            record["message"] = ["role": "user", "content": text ?? "\(secret) please fix the build"]
        }
        return line(record)
    }

    static func assistant(_ uuid: String, at: String, tools: [String] = []) -> String {
        line([
            "type": "assistant", "uuid": uuid, "timestamp": at, "sessionId": "s", "cwd": cwd,
            "gitBranch": "main", "entrypoint": "claude-desktop", "userType": "external", "isSidechain": false,
            "message": ["role": "assistant", "content": tools.map { ["type": "tool_use", "name": $0, "input": ["file_path": secret]] }
                + [["type": "text", "text": secret]]],
        ])
    }

    static func prLink(at: String, url: String) -> String {
        line(["type": "pr-link", "sessionId": "s", "prNumber": 12, "prUrl": url, "prRepository": "acme/widgets", "timestamp": at])
    }

    static func codexMeta(
        id: String, at: String, originator: String = "Codex Desktop", source: Any = "vscode",
        cwd: String = cwd, repoURL: String? = "https://github.com/acme/widgets.git"
    ) -> String {
        var payload: [String: Any] = [
            "id": id, "timestamp": at, "cwd": cwd, "originator": originator, "source": source,
            "base_instructions": secret,
        ]
        if let repoURL { payload["git"] = ["branch": "feature", "repository_url": repoURL, "commit_hash": "abc"] }
        return line(["type": "session_meta", "timestamp": at, "payload": payload])
    }

    static func codexEvent(_ type: String, at: String) -> String {
        var payload: [String: Any] = ["type": type]
        if type == "user_message" { payload["message"] = secret }
        return line(["type": "event_msg", "timestamp": at, "payload": payload])
    }

    /// Codex Desktop's `item_completed`, in the shape its rollouts have: what you typed is a
    /// `UserMessage` item, an edit a `FileChange` one.
    static func codexItem(_ type: String, at: String, completedAtMs: Int64? = nil) -> String {
        var item: [String: Any] = ["type": type, "id": "item-1", "content": [["type": "text", "text": secret]]]
        if type == "FileChange" { item["changes"] = ["/Users/me/\(secret).swift": ["type": "update"]] }
        var payload: [String: Any] = ["type": "item_completed", "thread_id": "t", "turn_id": "u", "item": item]
        if let completedAtMs { payload["completed_at_ms"] = completedAtMs }
        return line(["type": "event_msg", "timestamp": at, "payload": payload])
    }

    static func compactSummary(_ uuid: String, at: String) -> String {
        line([
            "type": "user", "uuid": uuid, "timestamp": at, "sessionId": "s", "cwd": cwd, "userType": "external",
            "isSidechain": false, "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
            "message": ["role": "user", "content": "This session is being continued. \(secret)"],
        ])
    }

    static func codexTool(_ name: String, at: String) -> String {
        line(["type": "response_item", "timestamp": at, "payload": ["type": "custom_tool_call", "name": name, "input": secret]])
    }

    static func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
}

@Suite("AgentStoreParsers")
struct AgentStoreParsersTests {
    typealias F = AgentFixtures

    @Test("human prompts count; task notifications, peers, tool results, sidechains and wrappers do not")
    func claudePrompts() {
        let chunk = AgentStoreParsers.claudeCode(F.data([
            F.user("p1", at: "2026-10-07T09:00:00.000Z", origin: "human"),
            F.assistant("a1", at: "2026-10-07T09:00:05.000Z", tools: ["Edit", "Bash"]),
            F.user("r1", at: "2026-10-07T09:00:06.000Z", toolResult: true),
            F.user("p2", at: "2026-10-07T09:05:00.000Z"),
            F.user("n1", at: "2026-10-07T09:10:00.000Z", text: "<task-notification>done</task-notification>", origin: "task-notification"),
            F.user("n2", at: "2026-10-07T09:11:00.000Z", text: "<task-notification>done</task-notification>"),
            F.user("peer", at: "2026-10-07T09:12:00.000Z", origin: "peer"),
            F.user("side", at: "2026-10-07T09:13:00.000Z", sidechain: true),
            F.user("cmd", at: "2026-10-07T09:14:00.000Z", text: "<command-name>/compact</command-name>"),
            F.prLink(at: "2026-10-07T09:15:00.000Z", url: "https://github.com/acme/widgets/pull/12"),
            #"{"type":"brand-new-kind","timestamp":"2026-10-07T09:16:00.000Z"}"#,
            "not json",
        ]), sessionId: "s1")

        #expect(chunk.prompts.map(\.recordId) == ["p1", "p2"])
        #expect(chunk.edited == 1)
        #expect(chunk.prs == [.init(key: "github.com/acme/widgets/pull/12", state: nil)])
        #expect(chunk.host == "claude-desktop")
        #expect(chunk.branch == "main")
        #expect(chunk.cwd == F.cwd)
        #expect(chunk.unknown == 2)
        #expect(chunk.known == 10)
        // Every trigger opens a turn: two prompts, two notifications, a peer, a sidechain and a
        // command; the last one is still open when the chunk ends.
        #expect(chunk.turns.count == 7)
        #expect(chunk.turns.first == DateInterval(start: F.date("2026-10-07T09:00:00.000Z"), end: F.date("2026-10-07T09:00:06.000Z")))
        #expect(chunk.openTurnAt == F.date("2026-10-07T09:14:00.000Z"))
        #expect(!String(describing: chunk).contains(F.secret))
    }

    @Test("records the keep filter rejects are skipped")
    func keepFilter() {
        let cutoff = F.date("2026-10-07T09:01:00.000Z")
        let chunk = AgentStoreParsers.claudeCode(F.data([
            F.user("old", at: "2026-10-07T09:00:00.000Z"),
            F.user("new", at: "2026-10-07T09:02:00.000Z"),
        ]), sessionId: "s1", keep: { $0 > cutoff })
        #expect(chunk.prompts.map(\.recordId) == ["new"])
        #expect(chunk.firstAt == F.date("2026-10-07T09:02:00.000Z"))
    }

    @Test("Codex: the desktop app's user messages count; exec and subagent runs do not")
    func codexPrompts() {
        let lines = { (meta: String) in
            F.data([
                meta,
                F.codexEvent("task_started", at: "2026-10-07T10:00:00.000Z"),
                F.codexItem("UserMessage", at: "2026-10-07T10:00:01.500Z", completedAtMs: 1_791_367_201_000),
                F.codexItem("AgentMessage", at: "2026-10-07T10:01:00.000Z"),
                F.codexTool("exec", at: "2026-10-07T10:01:30.000Z"),
                F.codexItem("FileChange", at: "2026-10-07T10:02:00.000Z"),
                F.codexEvent("task_complete", at: "2026-10-07T10:05:00.000Z"),
            ])
        }
        let desktop = AgentStoreParsers.codex(lines(F.codexMeta(id: "c1", at: "2026-10-07T10:00:00.000Z")), sessionId: nil)
        #expect(desktop.sessionId == "c1")
        #expect(desktop.host == AgentStoreParsers.codexDesktopHost)
        #expect(desktop.prompts.map(\.at) == [Date(timeIntervalSince1970: 1_791_367_201)])
        #expect(desktop.edited == 1)
        #expect(desktop.vcsRepo == "acme/widgets")
        #expect(desktop.branch == "feature")
        #expect(desktop.turns == [DateInterval(start: F.date("2026-10-07T10:00:00.000Z"), end: F.date("2026-10-07T10:05:00.000Z"))])
        #expect(desktop.openTurnAt == nil)

        let exec = AgentStoreParsers.codex(
            lines(F.codexMeta(id: "c2", at: "2026-10-07T10:00:00.000Z", originator: "codex_exec", source: "exec")),
            sessionId: nil
        )
        #expect(exec.prompts.isEmpty)
        #expect(exec.host == "codex-exec")
        let subagent = AgentStoreParsers.codex(
            lines(F.codexMeta(id: "c3", at: "2026-10-07T10:00:00.000Z", source: ["subagent": ["other": "guardian_review"]])),
            sessionId: nil
        )
        #expect(subagent.prompts.isEmpty)
        #expect(subagent.host == "codex-subagent")
        #expect(!String(describing: desktop).contains(F.secret))
    }

    @Test("Codex: an older rollout's user_message still counts")
    func codexOlderPrompts() {
        let chunk = AgentStoreParsers.codex(F.data([
            F.codexMeta(id: "c1", at: "2026-10-07T10:00:00.000Z"),
            F.codexEvent("user_message", at: "2026-10-07T10:00:01.000Z"),
        ]), sessionId: nil)
        #expect(chunk.prompts.map(\.at) == [F.date("2026-10-07T10:00:01.000Z")])
    }

    @Test("a turn ends at the agent's last record, not at a later attachment, queued message or note")
    func turnsEndAtTheAgent() {
        let chunk = AgentStoreParsers.claudeCode(F.data([
            F.user("p1", at: "2026-10-07T09:00:00.000Z", origin: "human"),
            F.assistant("a1", at: "2026-10-07T09:00:30.000Z"),
            F.line(["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-10-07T11:00:00.000Z"]),
            F.line(["type": "attachment", "timestamp": "2026-10-07T11:05:00.000Z"]),
            F.line(["type": "system", "subtype": "away_summary", "timestamp": "2026-10-07T11:10:00.000Z"]),
            F.prLink(at: "2026-10-07T11:15:00.000Z", url: "https://github.com/acme/widgets/pull/12"),
        ]), sessionId: "s1")
        #expect(chunk.turns == [DateInterval(start: F.date("2026-10-07T09:00:00.000Z"), end: F.date("2026-10-07T09:00:30.000Z"))])
        #expect(chunk.lastAt == F.date("2026-10-07T11:15:00.000Z"))
    }

    @Test("a compaction summary and an interrupt are not prompts; an interrupt ends the turn")
    func harnessNotes() {
        let chunk = AgentStoreParsers.claudeCode(F.data([
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.assistant("a1", at: "2026-10-07T09:01:00.000Z"),
            F.user("i1", at: "2026-10-07T09:02:00.000Z", text: "[Request interrupted by user]"),
            F.compactSummary("c1", at: "2026-10-07T09:10:00.000Z"),
            F.assistant("a2", at: "2026-10-07T09:11:00.000Z"),
        ]), sessionId: "s1")
        #expect(chunk.prompts.map(\.recordId) == ["p1"])
        #expect(chunk.turns == [
            DateInterval(start: F.date("2026-10-07T09:00:00.000Z"), end: F.date("2026-10-07T09:02:00.000Z")),
            DateInterval(start: F.date("2026-10-07T09:11:00.000Z"), end: F.date("2026-10-07T09:11:00.000Z")),
        ])
        #expect(!String(describing: chunk).contains(F.secret))
    }

    @Test("a turn is never rebuilt across records the keep filter skips")
    func keepSplitsTurns() {
        let from = F.date("2026-10-07T09:10:00.000Z"), to = F.date("2026-10-07T09:20:00.000Z")
        let keep: (Date) -> Bool = { $0 < from || $0 > to }
        let claude = AgentStoreParsers.claudeCode(F.data([
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.assistant("a1", at: "2026-10-07T09:05:00.000Z"),
            F.assistant("a2", at: "2026-10-07T09:15:00.000Z"),
            F.assistant("a3", at: "2026-10-07T09:25:00.000Z"),
        ]), sessionId: "s1", keep: keep)
        #expect(claude.turns == [
            DateInterval(start: F.date("2026-10-07T09:00:00.000Z"), end: F.date("2026-10-07T09:05:00.000Z")),
            DateInterval(start: F.date("2026-10-07T09:25:00.000Z"), end: F.date("2026-10-07T09:25:00.000Z")),
        ])
        let codex = AgentStoreParsers.codex(F.data([
            F.codexMeta(id: "c1", at: "2026-10-07T09:00:00.000Z"),
            F.codexEvent("task_started", at: "2026-10-07T09:00:00.000Z"),
            F.codexItem("AgentMessage", at: "2026-10-07T09:05:00.000Z"),
            F.codexItem("AgentMessage", at: "2026-10-07T09:15:00.000Z"),
            F.codexEvent("task_complete", at: "2026-10-07T09:25:00.000Z"),
        ]), sessionId: nil, keep: keep)
        #expect(codex.turns == [
            DateInterval(start: F.date("2026-10-07T09:00:00.000Z"), end: F.date("2026-10-07T09:05:00.000Z")),
        ])
    }

    @Test("the desktop Code tab's title and prompts are never decoded")
    func desktop() throws {
        let file = try JSONSerialization.data(withJSONObject: [
            "cliSessionId": "s1", "title": F.secret, "prompt": F.secret, "promptPreview": F.secret,
            "worktreePath": "/Users/me/code/worklens/.claude/worktrees/x",
            "prs": [["url": "https://github.com/acme/widgets/pull/12", "state": "MERGED"]],
            "createdAt": 1_759_827_600_000,
        ])
        let chunks = AgentStoreParsers.claudeDesktop(file)
        #expect(chunks.count == 1)
        #expect(chunks[0].linkedSessionId == "s1")
        #expect(chunks[0].prs == [.init(key: "github.com/acme/widgets/pull/12", state: "merged")])
        #expect(chunks[0].firstAt == Date(timeIntervalSince1970: 1_759_827_600))
        #expect(!String(describing: chunks).contains(F.secret))

        let strange = AgentStoreParsers.claudeDesktop(Data(#"{"something":"else"}"#.utf8))
        #expect(strange.allSatisfy { $0.known == 0 })
        #expect(strange.reduce(0) { $0 + $1.unknown } > 0)
    }

    @Test("PR keys and remote URLs normalize to one shape")
    func keys() {
        #expect(AgentStoreParsers.prKey(url: "https://github.com/o/r/pull/7", repo: nil, number: nil) == "github.com/o/r/pull/7")
        #expect(AgentStoreParsers.prKey(url: nil, repo: "o/r", number: 7) == "github.com/o/r/pull/7")
        #expect(AgentStoreParsers.repo(ofPRKey: "github.com/o/r/pull/7") == "o/r")
        #expect(RepoMap.repo(remoteURL: "git@github.com:o/r.git") == "o/r")
        #expect(RepoMap.repo(remoteURL: "https://github.com/o/r") == "o/r")
        #expect(RepoMap.repo(remoteURL: "https://gitlab.com/o/r.git") == nil)
    }
}
