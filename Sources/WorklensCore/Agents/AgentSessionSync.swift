import Foundation

/// Where the agent logs live. The standard places, or a test's temporary folders.
public struct AgentStoreRoots: Sendable, Equatable {
    /// `~/.claude/projects`
    public var claudeProjects: URL
    /// `~/Library/Application Support/Claude/claude-code-sessions`
    public var claudeDesktop: URL
    /// `~/.codex/sessions` and `~/.codex/archived_sessions`
    public var codex: [URL]

    public init(claudeProjects: URL, claudeDesktop: URL, codex: [URL]) {
        self.claudeProjects = claudeProjects
        self.claudeDesktop = claudeDesktop
        self.codex = codex
    }

    public static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentStoreRoots {
        AgentStoreRoots(
            claudeProjects: home.appendingPathComponent(".claude/projects", isDirectory: true),
            claudeDesktop: home.appendingPathComponent(
                "Library/Application Support/Claude/claude-code-sessions", isDirectory: true
            ),
            codex: [
                home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            ]
        )
    }
}

/// Where the agent-session sync's last round stands, in `app_state`.
public struct AgentSyncStatus: Codable, Sendable, Equatable {
    public static let key = "agents.sessions.status"

    public var lastSuccessAt: Date?
    /// The last round that left nothing unread: the next routine round looks back from here.
    public var lastCompleteAt: Date?
    public var lastError: String?
    /// True when the last round stopped at its byte budget with files still to read.
    public var pending = false
    /// Stores whose records were all of an unknown shape on the last round.
    public var unrecognized: [String] = []

    public init() {}

    public static func load(_ db: Database) -> AgentSyncStatus {
        (try? AppStateStore(db).getCodable(key)) ?? AgentSyncStatus()
    }

    /// One line for the CLI and the MCP tool.
    public func sentence(enabled: Bool = true, timeZone: TimeZone = .current) -> String {
        guard enabled else { return "Agent sessions are off (AGENT_SESSIONS=false)." }
        let clock = DateFormatter()
        clock.calendar = Calendar(identifier: .gregorian)
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "yyyy-MM-dd HH:mm"
        var parts = [lastSuccessAt.map { "Agent sessions last read \(clock.string(from: $0))" } ?? "Agent sessions never read"]
        if pending { parts.append("more to read on the next sync") }
        if !unrecognized.isEmpty {
            parts.append("format not recognized for \(unrecognized.map(AgentSessionSync.storeName).joined(separator: " and ")), so nothing was read from it")
        }
        if let lastError { parts.append("the last try failed: \(lastError)") }
        return parts.joined(separator: "; ") + "."
    }
}

/// What one round read and wrote.
public struct AgentSyncResult: Sendable, Equatable {
    public var files = 0
    public var bytes: Int64 = 0
    public var prompts = 0
    public var pending = false
    public var unrecognized: [String] = []
}

/// Reads Claude Code, the Claude app's Code tab and Codex logs into the agent tables (#321).
///
/// Each file is read from where the last round stopped to its last newline, so a half-written
/// line waits for the next round; a file that shrank, or a newer parser, reads it again from the
/// start, which the tables absorb (prompts are keyed by their record, turns by their start). The
/// first round looks back 30 days and a round reads at most 256 MB. No `git` call, no read under
/// `~/Documents`, no model call: the folder a session ran in is a string the log holds.
public actor AgentSessionSync {
    public static let firstSyncDays = 30
    public static let roundBytes: Int64 = 256 * 1024 * 1024
    public static let overlap: TimeInterval = 24 * 3600

    public enum LogLevel: Sendable { case info, warn }

    private let config: Config
    private let db: Database
    private let roots: AgentStoreRoots
    private let budget: Int64
    private let now: @Sendable () -> Date
    private let log: @Sendable (LogLevel, String) -> Void

    /// - Parameter log: where the round's one line goes. Never handed a path, a repo or a branch.
    public init(
        config: Config,
        db: Database,
        roots: AgentStoreRoots = .standard(),
        roundBytes: Int64 = AgentSessionSync.roundBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (LogLevel, String) -> Void = { level, line in
            switch level {
            case .info: Log.storage.info(line)
            case .warn: Log.storage.warn(line)
            }
        }
    ) {
        self.config = config
        self.db = db
        self.roots = roots
        budget = roundBytes
        self.now = now
        self.log = log
    }

    /// The sync the app wires in when `AGENT_SESSIONS` is on. Off deletes the tables and the
    /// status and returns nil.
    public static func forConfig(_ config: Config, db: Database) -> AgentSessionSync? {
        guard config.agentSessions else {
            forget(db: db)
            return nil
        }
        return AgentSessionSync(config: config, db: db)
    }

    /// Deletes every agent row and the status. Returns how many sessions went.
    @discardableResult
    public static func forget(db: Database) -> Int {
        let removed = (try? AgentSessionStore(db).deleteAll()) ?? 0
        try? AppStateStore(db).delete(AgentSyncStatus.key)
        return removed
    }

    public static func storeName(_ store: String) -> String {
        switch store {
        case AgentStoreParsers.claudeCode: "Claude Code"
        case AgentStoreParsers.claudeDesktop: "the Claude app's Code tab"
        case AgentStoreParsers.codex: "Codex"
        default: store
        }
    }

    /// One round. `days` overrides how far back an unread file may be, for
    /// `worklens agents sync --days N`.
    @discardableResult
    public func sync(days: Int? = nil) async -> Result<AgentSyncResult, any Error> {
        var status = AgentSyncStatus.load(db)
        let at = now()
        let since: Date
        if let days {
            since = at.addingTimeInterval(-Double(max(1, days)) * 24 * 3600)
        } else if let complete = status.lastCompleteAt {
            since = complete.addingTimeInterval(-Self.overlap)
        } else {
            since = at.addingTimeInterval(-Double(Self.firstSyncDays) * 24 * 3600)
        }
        let round = Round(
            config: config, db: db, roots: roots, budget: budget, since: since, now: at
        )
        do {
            let result = try await Task.detached(priority: .utility) { try round.run() }.value
            status.lastSuccessAt = at
            if !result.pending { status.lastCompleteAt = at }
            status.pending = result.pending
            status.unrecognized = result.unrecognized
            status.lastError = nil
            try? AppStateStore(db).setCodable(AgentSyncStatus.key, status)
            log(.info, "agent sessions sync: \(result.files) files, \(result.bytes / 1024) KB, "
                + "\(result.prompts) new prompts\(result.pending ? ", more next round" : "")")
            for store in result.unrecognized {
                log(.warn, "agent sessions sync: \(Self.storeName(store)) format not recognized; nothing written")
            }
            return .success(result)
        } catch {
            status.lastError = ContextSyncScheduler.describe(error)
            try? AppStateStore(db).setCodable(AgentSyncStatus.key, status)
            log(.warn, "agent sessions sync failed: \(status.lastError ?? "")")
            return .failure(error)
        }
    }
}

// MARK: - One round

/// The file walk and the parse, off the actor: a first round reads hundreds of megabytes.
private struct Round: Sendable {
    let config: Config
    let db: Database
    let roots: AgentStoreRoots
    let budget: Int64
    let since: Date
    let now: Date

    private struct Candidate {
        var url: URL
        var store: String
        var size: Int64
        var mtime: Date
        var stored: AgentSourceFile?
    }

    func run() throws -> AgentSyncResult {
        let store = AgentSessionStore(db)
        let stored = try store.files()
        let keep = keepFilter()
        var result = AgentSyncResult()
        var remaining = budget

        var candidates: [Candidate] = []
        candidates += files(under: [roots.claudeProjects], store: AgentStoreParsers.claudeCode, stored: stored)
        candidates += files(under: [roots.claudeDesktop], store: AgentStoreParsers.claudeDesktop, stored: stored)
        candidates += files(under: roots.codex, store: AgentStoreParsers.codex, stored: stored)
        candidates.sort { $0.mtime > $1.mtime }

        // A store that once said something this parser understands is not called unrecognized
        // because a round only touched its other files (a backlog, a settings file).
        let recognized = Set(stored.values.map(\.store))
        var writes: [String: AgentWrite] = [:]
        var known: [String: Int] = [:]
        var unknown: [String: Int] = [:]
        var hostCache: [String: String?] = [:]

        for candidate in candidates {
            guard remaining > 0 else { result.pending = true; break }
            let isLog = candidate.store != AgentStoreParsers.claudeDesktop
            let reusable = candidate.stored.map { $0.parser == AgentStoreParsers.version && $0.offset <= candidate.size } ?? false
            let offset = isLog && reusable ? candidate.stored!.offset : 0
            let openTurnAt = offset > 0 ? candidate.stored?.openTurnAt : nil
            let wanted = candidate.size - offset
            guard wanted > 0 else { continue }
            let length = min(wanted, remaining)
            if length < wanted { result.pending = true }
            guard var data = read(candidate.url, offset: offset, length: length) else { continue }
            if isLog {
                // A half-written last line waits for the next round.
                guard let newline = data.lastIndex(of: 0x0A) else { continue }
                data = data.prefix(through: newline)
            } else if length < wanted {
                continue
            }
            remaining -= Int64(data.count)
            result.bytes += Int64(data.count)
            result.files += 1

            var write = writes[candidate.store] ?? AgentWrite()
            var sessionId = candidate.stored?.sessionId
            var nextOpen: Date?
            var edited = 0
            switch candidate.store {
            case AgentStoreParsers.claudeCode:
                let id = claudeSessionId(candidate.url)
                sessionId = id
                let chunk = AgentStoreParsers.claudeCode(data, sessionId: id, openTurnAt: openTurnAt, keep: keep)
                known[candidate.store, default: 0] += chunk.known
                unknown[candidate.store, default: 0] += chunk.unknown
                add(chunk, as: id, to: &write)
                nextOpen = chunk.openTurnAt
                edited = chunk.edited
            case AgentStoreParsers.codex:
                var host: String?
                if let id = sessionId {
                    if let cached = hostCache[id] { host = cached } else {
                        host = try store.session(id: id)?.host
                        hostCache[id] = host
                    }
                }
                let chunk = AgentStoreParsers.codex(
                    data, sessionId: sessionId ?? codexSessionId(candidate.url), host: host,
                    openTurnAt: openTurnAt, keep: keep
                )
                known[candidate.store, default: 0] += chunk.known
                unknown[candidate.store, default: 0] += chunk.unknown
                if let id = chunk.sessionId {
                    sessionId = id
                    hostCache[id] = chunk.host
                    add(chunk, as: id, to: &write)
                }
                nextOpen = chunk.openTurnAt
                edited = chunk.edited
            default:
                for chunk in AgentStoreParsers.claudeDesktop(data) {
                    known[candidate.store, default: 0] += chunk.known
                    unknown[candidate.store, default: 0] += chunk.unknown
                    if let id = chunk.linkedSessionId { add(chunk, as: id, to: &write) }
                }
            }
            write.files.append(AgentSourceFile(
                path: candidate.url.path, store: candidate.store, sessionId: sessionId,
                size: candidate.size, mtime: candidate.mtime,
                offset: isLog ? offset + Int64(data.count) : candidate.size,
                openTurnAt: nextOpen,
                // The file's running count: a re-read from the start replaces it, never adds.
                edited: (offset > 0 ? candidate.stored?.edited ?? 0 : 0) + edited
            ))
            writes[candidate.store] = write
        }

        var total = AgentWrite()
        for (name, write) in writes {
            // A store that said nothing this parser understands writes nothing, not even where it
            // stopped: a build that does understand it reads it all.
            if (known[name] ?? 0) == 0, (unknown[name] ?? 0) > 0, !recognized.contains(name) {
                result.unrecognized.append(name)
                continue
            }
            total.sessions += write.sessions
            total.prompts += write.prompts
            total.turns += write.turns
            total.prs += write.prs
            total.files += write.files
        }
        result.unrecognized.sort()
        result.prompts = try store.apply(total)
        if !total.sessions.isEmpty || !total.prs.isEmpty { try store.resolveRepos() }
        return result
    }

    private func add(_ chunk: AgentChunk, as id: String, to write: inout AgentWrite) {
        let tool = chunk.tool == AgentStoreParsers.claudeDesktop ? AgentStoreParsers.claudeCode : chunk.tool
        // `edited` is summed from the source files by `apply`, not added here.
        write.sessions.append(AgentSession(
            id: id, tool: tool, host: chunk.host, startAt: chunk.firstAt, endAt: chunk.lastAt,
            cwd: chunk.cwd, vcsRepo: chunk.vcsRepo, branch: chunk.branch, edited: 0
        ))
        write.prompts += chunk.prompts.map { AgentPrompt(recordId: $0.recordId, sessionId: id, at: $0.at) }
        write.turns += chunk.turns.map { AgentTurn(sessionId: id, startAt: $0.start, endAt: $0.end) }
        write.prs += chunk.prs.map { AgentSessionPR(sessionId: id, prKey: $0.key, state: $0.state) }
    }

    /// False for an instant that retention already aged out or that any delete covered, so a
    /// re-read never brings either back.
    private func keepFilter() -> @Sendable (Date) -> Bool {
        let cutoff = Retention(config: config, db: db, now: { now }).cutoff()?.lastCondemnedInstant
        var erased = AgentSessionStore(db).erasedRanges()
        if let last: LastErase = try? AppStateStore(db).getCodable(DataEraser.lastEraseKey) { erased.append(last) }
        let ranges = erased
        return { at in
            if let cutoff, at <= cutoff { return false }
            return !ranges.contains { at >= $0.from && at <= $0.to }
        }
    }

    private func files(under roots: [URL], store: String, stored: [String: AgentSourceFile]) -> [Candidate] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let extensions: Set<String> = store == AgentStoreParsers.claudeDesktop ? ["json", "jsonl"] : ["jsonl"]
        var out: [Candidate] = []
        for root in roots {
            guard let walker = manager.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker {
                // A workflow's `journal.jsonl` sits under a session's folder but is not a session.
                guard extensions.contains(url.pathExtension),
                      store != AgentStoreParsers.claudeCode || url.lastPathComponent != "journal.jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let size = values.fileSize, let mtime = values.contentModificationDate
                else { continue }
                let previous = stored[url.path]
                if previous == nil, mtime < since { continue }
                if let previous, previous.parser == AgentStoreParsers.version {
                    let unchanged = store == AgentStoreParsers.claudeDesktop
                        // The stored time keeps milliseconds; the file system's has more.
                        ? previous.size == Int64(size) && abs(previous.mtime.timeIntervalSince(mtime)) < 0.01
                        : previous.offset == Int64(size)
                    if unchanged { continue }
                }
                out.append(Candidate(url: url, store: store, size: Int64(size), mtime: mtime, stored: previous))
            }
        }
        return out
    }

    private func read(_ url: URL, offset: Int64, length: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }

    /// `<folder>/<session>.jsonl`, or `<folder>/<session>/subagents/…/agent-x.jsonl` folded into
    /// its parent.
    private func claudeSessionId(_ url: URL) -> String {
        let parts = url.pathComponents
        if let index = parts.lastIndex(of: "subagents"), index > 0 { return parts[index - 1] }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `rollout-<date>-<uuid>.jsonl` → the trailing UUID.
    private func codexSessionId(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return nil }
        let tail = String(name.suffix(36))
        return UUID(uuidString: tail) != nil ? tail.lowercased() : nil
    }
}
