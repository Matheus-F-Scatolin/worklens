import Foundation
import GRDB
import Testing
@testable import WorklensCore

/// Temporary Claude Code, Code-tab and Codex folders, and the sync pointed at them.
private final class SyncHarness {
    typealias F = AgentFixtures
    let root: URL
    let roots: AgentStoreRoots
    var config: Config
    let db: WorklensCore.Database
    /// 2026-10-07 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_374_400)

    init(retentionDays: Int = 0) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("worklens-agents-\(UUID().uuidString)")
        roots = AgentStoreRoots(
            claudeProjects: root.appendingPathComponent("claude/projects"),
            claudeDesktop: root.appendingPathComponent("claude-code-sessions"),
            codex: [root.appendingPathComponent("codex/sessions"), root.appendingPathComponent("codex/archived_sessions")]
        )
        for folder in ["data/timeline", "data/reports"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        config = Config.defaults()
        config.dataDir = root.appendingPathComponent("data")
        config.retentionDays = retentionDays
        db = try WorklensCore.Database.inMemory()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var sync: AgentSessionSync {
        let now = now
        return AgentSessionSync(config: config, db: db, roots: roots, now: { now }, log: { _, _ in })
    }

    func run(days: Int? = nil) async throws -> AgentSyncResult {
        try await sync.sync(days: days).get()
    }

    @discardableResult
    func write(_ relative: String, under base: URL, _ text: String) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func claude(_ session: String, _ lines: [String], project: String = "-Users-me-code-worklens") throws -> URL {
        try write("\(project)/\(session).jsonl", under: roots.claudeProjects, String(decoding: F.data(lines), as: UTF8.self))
    }

    var store: AgentSessionStore { AgentSessionStore(db) }

    func promptIds() throws -> [String] {
        try db.writer.read { try String.fetchAll($0, sql: "SELECT record_id FROM agent_prompts ORDER BY at, record_id") }
    }

    /// Every value in every agent table, as one string.
    func everything() throws -> String {
        try db.writer.read { db in
            try ["agent_sessions", "agent_prompts", "agent_turns", "agent_session_prs", "agent_source_files"]
                .map { "\(try Row.fetchAll(db, sql: "SELECT * FROM \($0)"))" }
                .joined(separator: "\n")
        }
    }
}

@Suite("AgentSessionSync")
struct AgentSessionSyncTests {
    typealias F = AgentFixtures
    static let session = "11111111-2222-3333-4444-555555555555"
    static let codexId = "019a0000-aaaa-bbbb-cccc-000000000001"

    @Test("a first read keeps metadata only; nothing you typed or the agent wrote reaches a table")
    func firstSync() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [
            F.user("p1", at: "2026-10-07T09:00:00.000Z", origin: "human"),
            F.assistant("a1", at: "2026-10-07T09:01:00.000Z", tools: ["Edit"]),
            F.user("r1", at: "2026-10-07T09:01:30.000Z", toolResult: true),
            F.prLink(at: "2026-10-07T09:02:00.000Z", url: "https://github.com/acme/widgets/pull/12"),
            F.user("n1", at: "2026-10-07T09:20:00.000Z", text: "<task-notification>x</task-notification>", origin: "task-notification"),
        ])
        _ = try h.claude(Self.session + "/subagents/agent-1", [
            F.user("sub", at: "2026-10-07T09:05:00.000Z", sidechain: true),
        ])
        try h.write("2026/10/07/rollout-2026-10-07T10-00-00-\(Self.codexId).jsonl", under: h.roots.codex[0], String(decoding: F.data([
            F.codexMeta(id: Self.codexId, at: "2026-10-07T10:00:00.000Z"),
            F.codexEvent("task_started", at: "2026-10-07T10:00:00.000Z"),
            F.codexEvent("user_message", at: "2026-10-07T10:00:01.000Z"),
            F.codexEvent("task_complete", at: "2026-10-07T10:04:00.000Z"),
        ]), as: UTF8.self))
        try h.write("2026/10/07/rollout-2026-10-07T11-00-00-019a0000-aaaa-bbbb-cccc-000000000002.jsonl", under: h.roots.codex[1], String(decoding: F.data([
            F.codexMeta(id: "019a0000-aaaa-bbbb-cccc-000000000002", at: "2026-10-07T11:00:00.000Z", originator: "codex_exec", source: "exec"),
            F.codexEvent("user_message", at: "2026-10-07T11:00:01.000Z"),
        ]), as: UTF8.self))
        let desktop = try JSONSerialization.data(withJSONObject: [
            "cliSessionId": Self.session, "title": F.secret, "prompt": F.secret, "initialPrompt": F.secret,
            "prs": [["url": "https://github.com/acme/widgets/pull/12", "state": "open"]],
        ])
        try h.write("local_1.json", under: h.roots.claudeDesktop, String(decoding: desktop, as: UTF8.self))

        let result = try await h.run()
        #expect(result.files == 5)
        #expect(result.unrecognized.isEmpty)
        #expect(!result.pending)
        #expect(result.prompts == 2)

        #expect(try h.promptIds() == ["p1", "codex:\(Self.codexId):1791367201000"])
        let sessions = try h.store.sessions()
        #expect(Set(sessions.map(\.id)) == [Self.session, Self.codexId, "019a0000-aaaa-bbbb-cccc-000000000002"])
        let claude = try #require(sessions.first { $0.id == Self.session })
        #expect(claude.host == "claude-desktop")
        #expect(claude.repo == "acme/widgets")
        #expect(claude.repoRule == RepoMap.ruleOwnPR)
        #expect(claude.edited == 1)
        #expect(try h.store.prs().map(\.prKey) == ["github.com/acme/widgets/pull/12"])
        #expect(try h.store.prs().first?.state == "open")

        let all = try h.everything()
        #expect(!all.contains(F.secret))
        #expect(!all.contains("please fix the build"))
        let status = AgentSyncStatus.load(h.db)
        #expect(status.lastCompleteAt == h.now)
        #expect(status.sentence(timeZone: TimeZone(identifier: "UTC")!) == "Agent sessions last read 2026-10-07 12:00.")
    }

    @Test("a second read reads no new bytes; a half line waits; an appended line is read once")
    func incremental() async throws {
        let h = try SyncHarness()
        let url = try h.claude(Self.session, [F.user("p1", at: "2026-10-07T09:00:00.000Z")])
        _ = try await h.run()

        let again = try await h.run()
        #expect(again.bytes == 0)
        #expect(again.files == 0)

        let next = F.user("p2", at: "2026-10-07T09:30:00.000Z")
        try h.append(url, String(next.prefix(40)))
        let half = try await h.run()
        #expect(half.bytes == 0)
        #expect(try h.promptIds() == ["p1"])

        try h.append(url, String(next.dropFirst(40)) + "\n")
        let whole = try await h.run()
        #expect(whole.bytes == Int64(next.utf8.count + 1))
        #expect(try h.promptIds() == ["p1", "p2"])
    }

    @Test("a file that shrank is read again from the start")
    func truncated() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.user("p2", at: "2026-10-07T09:10:00.000Z"),
            F.user("p3", at: "2026-10-07T09:20:00.000Z"),
        ])
        _ = try await h.run()
        let url = try h.claude(Self.session, [F.user("p9", at: "2026-10-07T11:00:00.000Z")])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let result = try await h.run()
        #expect(result.bytes == Int64(size))
        #expect(try h.promptIds() == ["p1", "p2", "p3", "p9"])
    }

    @Test("a fork that repeats its parent's records adds no prompt twice")
    func fork() async throws {
        let h = try SyncHarness()
        let shared = [F.user("p1", at: "2026-10-07T09:00:00.000Z"), F.user("p2", at: "2026-10-07T09:10:00.000Z")]
        _ = try h.claude(Self.session, shared)
        _ = try h.claude("99999999-2222-3333-4444-555555555555", shared + [F.user("p3", at: "2026-10-07T09:20:00.000Z")])
        _ = try await h.run()
        #expect(try h.promptIds() == ["p1", "p2", "p3"])
    }

    @Test("a store in a format this build does not know writes nothing and says so")
    func unrecognized() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [F.user("p1", at: "2026-10-07T09:00:00.000Z")])
        try h.write("2026/10/07/rollout-x-\(Self.codexId).jsonl", under: h.roots.codex[0],
                    #"{"kind":"future","at":"2026-10-07T10:00:00Z"}"# + "\n" + #"{"type":"v9_event"}"# + "\n")
        let result = try await h.run()
        #expect(result.unrecognized == [AgentStoreParsers.codex])
        #expect(try h.store.sessions().map(\.tool) == [AgentStoreParsers.claudeCode])
        #expect(try h.store.files().values.allSatisfy { $0.store == AgentStoreParsers.claudeCode })
        let sentence = AgentSyncStatus.load(h.db).sentence()
        #expect(sentence.contains("format not recognized for Codex"))
        // Nothing was marked read, so the next round looks again.
        let again = try await h.run()
        #expect(again.unrecognized == [AgentStoreParsers.codex])
    }

    @Test("a round stops at its byte budget and the next one carries on")
    func budget() async throws {
        let h = try SyncHarness()
        for index in 0..<3 {
            _ = try h.claude("0000000\(index)-2222-3333-4444-555555555555", [F.user("p\(index)", at: "2026-10-07T09:0\(index):00.000Z")])
        }
        let now = h.now
        // Room for one file's line and a few bytes of the next.
        let line = Int64(F.user("p0", at: "2026-10-07T09:00:00.000Z").utf8.count)
        let small = AgentSessionSync(config: h.config, db: h.db, roots: h.roots, roundBytes: line + 50, now: { now }, log: { _, _ in })
        var rounds = 0
        while rounds < 10 {
            rounds += 1
            let result = try await small.sync().get()
            if !result.pending { break }
        }
        #expect(rounds > 1)
        #expect(try h.promptIds().count == 3)
    }

    @Test("an erase removes prompts and turns, and a later read does not bring them back")
    func erase() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.user("r1", at: "2026-10-07T09:01:00.000Z", toolResult: true),
            F.user("p2", at: "2026-10-07T10:00:00.000Z"),
            F.user("r2", at: "2026-10-07T10:01:00.000Z", toolResult: true),
        ])
        _ = try await h.run()
        let now = h.now
        let eraser = DataEraser(config: h.config, db: h.db, timeZone: TimeZone(identifier: "UTC")!, now: { now })
        try await eraser.erase(from: F.date("2026-10-07T08:30:00.000Z"), to: F.date("2026-10-07T09:30:00.000Z"))
        #expect(try h.promptIds() == ["p2"])
        #expect(try h.store.turns(from: .distantPast, to: .distantFuture).map(\.startAt) == [F.date("2026-10-07T10:00:00.000Z")])

        AgentSessionSync.forget(db: h.db)
        _ = try await h.run()
        #expect(try h.promptIds() == ["p2"])
        #expect(try h.store.turns(from: .distantPast, to: .distantFuture).count == 1)
    }

    @Test("an erase inside a turn: a re-read stops the turn at the gap, and every erase holds")
    func eraseInsideATurn() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [
            F.user("p0", at: "2026-10-07T07:00:00.000Z"),
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.assistant("a1", at: "2026-10-07T09:05:00.000Z"),
            F.assistant("a2", at: "2026-10-07T09:15:00.000Z"),
            F.assistant("a3", at: "2026-10-07T09:25:00.000Z"),
        ])
        _ = try await h.run()
        let now = h.now
        let eraser = DataEraser(config: h.config, db: h.db, timeZone: TimeZone(identifier: "UTC")!, now: { now })
        try await eraser.erase(from: F.date("2026-10-07T06:30:00.000Z"), to: F.date("2026-10-07T07:30:00.000Z"))
        let from = F.date("2026-10-07T09:10:00.000Z"), to = F.date("2026-10-07T09:20:00.000Z")
        try await eraser.erase(from: from, to: to)

        AgentSessionSync.forget(db: h.db)
        _ = try await h.run()
        // The earlier erase holds too, not only the last one.
        #expect(try h.promptIds() == ["p1"])
        let turns = try h.store.turns(from: .distantPast, to: .distantFuture)
        #expect(turns.allSatisfy { $0.endAt < from || $0.startAt > to })
        #expect(turns.map(\.startAt) == [F.date("2026-10-07T09:00:00.000Z"), F.date("2026-10-07T09:25:00.000Z")])
    }

    @Test("an erase while a turn is open across chunks: the next chunk does not stretch it over the gap")
    func eraseWhileATurnIsOpen() async throws {
        let h = try SyncHarness()
        let url = try h.claude(Self.session, [
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.assistant("a1", at: "2026-10-07T09:05:00.000Z"),
        ])
        _ = try await h.run()
        #expect(try h.store.files().values.first?.openTurnAt == F.date("2026-10-07T09:00:00.000Z"))
        let now = h.now
        let eraser = DataEraser(config: h.config, db: h.db, timeZone: TimeZone(identifier: "UTC")!, now: { now })
        let from = F.date("2026-10-07T09:02:00.000Z"), to = F.date("2026-10-07T09:30:00.000Z")
        try await eraser.erase(from: from, to: to)
        #expect(try h.store.files().values.first?.openTurnAt == nil)

        try h.append(url, F.assistant("a2", at: "2026-10-07T10:00:00.000Z") + "\n")
        _ = try await h.run()
        let turns = try h.store.turns(from: .distantPast, to: .distantFuture)
        #expect(turns.allSatisfy { $0.endAt < from || $0.startAt > to })
        #expect(turns.map(\.startAt) == [F.date("2026-10-07T10:00:00.000Z")])
    }

    @Test("edits are counted once per file: an append adds, a re-read and an archived move do not")
    func editsCountedOnce() async throws {
        let h = try SyncHarness()
        let url = try h.claude(Self.session, [
            F.user("p1", at: "2026-10-07T09:00:00.000Z"),
            F.assistant("a1", at: "2026-10-07T09:01:00.000Z", tools: ["Edit"]),
        ])
        let name = "rollout-2026-10-07T10-00-00-\(Self.codexId).jsonl"
        let rollout = try h.write("2026/10/07/\(name)", under: h.roots.codex[0], String(decoding: F.data([
            F.codexMeta(id: Self.codexId, at: "2026-10-07T10:00:00.000Z"),
            F.codexItem("FileChange", at: "2026-10-07T10:01:00.000Z"),
        ]), as: UTF8.self))
        _ = try await h.run()
        try h.append(url, F.assistant("a2", at: "2026-10-07T09:02:00.000Z", tools: ["Write"]) + "\n")
        _ = try await h.run()
        #expect(try h.store.session(id: Self.session)?.edited == 2)

        // Codex moves a finished rollout to archived_sessions under the same name.
        let archived = h.roots.codex[1].appendingPathComponent("2026/10/07/\(name)")
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: rollout, to: archived)
        _ = try await h.run()
        #expect(try h.store.session(id: Self.codexId)?.edited == 1)

        // A file read again from the start replaces its count.
        try await h.db.writer.write { try $0.execute(sql: "UPDATE agent_source_files SET parser = 0") }
        _ = try await h.run()
        #expect(try h.store.session(id: Self.session)?.edited == 2)
        #expect(try h.store.session(id: Self.codexId)?.edited == 1)
    }

    @Test("a store read before is not unrecognized because only its other files changed")
    func otherFilesAreNotUnrecognized() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [F.user("p1", at: "2026-10-07T09:00:00.000Z")])
        let desktop = try JSONSerialization.data(withJSONObject: ["cliSessionId": Self.session])
        try h.write("a/b/local_1.json", under: h.roots.claudeDesktop, String(decoding: desktop, as: UTF8.self))
        #expect(try await h.run().unrecognized.isEmpty)

        try h.write("a/b/backlog/tasks.json", under: h.roots.claudeDesktop, #"{"tasks":[]}"#)
        try h.write("a/b/scheduled-tasks.json", under: h.roots.claudeDesktop, #"[{"id":"x"}]"#)
        // A workflow's journal under a session's folder is not read at all.
        try h.write("-Users-me-code-worklens/\(Self.session)/subagents/workflows/wf_1/journal.jsonl",
                    under: h.roots.claudeProjects, #"{"kind":"step","at":"2026-10-07T09:30:00Z"}"# + "\n")
        let result = try await h.run()
        #expect(result.unrecognized.isEmpty)
        #expect(result.files == 2)
    }

    @Test("retention removes old prompts and turns, and a later read does not bring them back")
    func retention() async throws {
        let h = try SyncHarness(retentionDays: 2)
        _ = try h.claude(Self.session, [
            F.user("old", at: "2026-10-01T09:00:00.000Z"),
            F.user("r0", at: "2026-10-01T09:01:00.000Z", toolResult: true),
            F.user("new", at: "2026-10-07T09:00:00.000Z"),
        ])
        // Read before retention was on, as an older build would have.
        h.config.retentionDays = 0
        _ = try await h.run()
        #expect(try h.promptIds() == ["old", "new"])

        h.config.retentionDays = 2
        let now = h.now
        _ = try Retention(config: h.config, db: h.db, timeZone: TimeZone(identifier: "UTC")!, now: { now }).sweep()
        #expect(try h.promptIds() == ["new"])
        #expect(try h.store.turns(from: .distantPast, to: F.date("2026-10-02T00:00:00.000Z")).isEmpty)

        AgentSessionSync.forget(db: h.db)
        _ = try await h.run()
        #expect(try h.promptIds() == ["new"])
    }

    @Test("AGENT_SESSIONS=false deletes what was read and wires no sync")
    func off() async throws {
        let h = try SyncHarness()
        _ = try h.claude(Self.session, [F.user("p1", at: "2026-10-07T09:00:00.000Z")])
        _ = try await h.run()
        #expect(try h.store.counts().sessions == 1)
        var config = h.config
        config.agentSessions = false
        #expect(AgentSessionSync.forConfig(config, db: h.db) == nil)
        #expect(try h.store.counts().sessions == 0)
        #expect(try h.store.counts().files == 0)
        #expect(AgentSyncStatus.load(h.db) == AgentSyncStatus())
        #expect(AgentSyncStatus().sentence(enabled: false) == "Agent sessions are off (AGENT_SESSIONS=false).")
    }
}
