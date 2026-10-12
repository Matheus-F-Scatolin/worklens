import Foundation

/// What one read of one agent log says (#321): ids, instants, the working folder, the branch,
/// PR links and how many edits a tool call made. Never a prompt's text, a command, a tool's
/// output, a file's contents or a session title: those keys are not decoded at all, except the
/// first characters of a user record, which are looked at in memory to tell a typed prompt from
/// a wrapper the harness wrote, and dropped.
public struct AgentChunk: Sendable, Equatable {
    public struct Prompt: Sendable, Equatable {
        public var recordId: String
        public var at: Date
    }

    public struct PRLink: Sendable, Equatable {
        /// `github.com/<owner>/<name>/pull/<n>`, the shape `outputs.resource_key` has.
        public var key: String
        /// What the desktop app last said about it, lowercased; nil from a `pr-link` record.
        public var state: String?
    }

    public var sessionId: String?
    /// The Claude Code session a desktop Code-tab record describes.
    public var linkedSessionId: String?
    public var tool: String
    public var host: String?
    public var cwd: String?
    public var branch: String?
    /// `owner/name` from a Codex rollout's `git.repository_url`.
    public var vcsRepo: String?
    public var firstAt: Date?
    public var lastAt: Date?
    public var prompts: [Prompt] = []
    /// Closed stretches of agent work, and the start of the one still open at the chunk's end.
    public var turns: [DateInterval] = []
    public var openTurnAt: Date?
    public var prs: [PRLink] = []
    /// Tool calls that edit a file (`Edit`, `Write`, `apply_patch`…).
    public var edited = 0
    /// Records whose `type` this parser knows, and the rest.
    public var known = 0
    public var unknown = 0

    public init(tool: String) { self.tool = tool }

    mutating func see(_ at: Date) {
        firstAt = min(firstAt ?? at, at)
        lastAt = max(lastAt ?? at, at)
    }
}

/// The three stores' parsers (#321). Pure: bytes in, an `AgentChunk` out. `version` is stored on
/// every file read, and a build with a newer one reads every file again from the start.
public enum AgentStoreParsers {
    public static let version = 1

    public static let claudeCode = "claude_code"
    public static let codex = "codex"
    /// The desktop app's Code tab: enriches a Claude Code session, never a session of its own.
    public static let claudeDesktop = "claude_desktop"

    /// Tool names that change a file.
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch"]

    static let claudeKnownTypes: Set<String> = [
        "user", "assistant", "attachment", "system", "summary", "pr-link", "last-prompt",
        "custom-title", "agent-name", "queue-operation", "file-history-snapshot", "mode",
        "cost-state", "bridge-session", "atis-latch", "progress",
    ]
    static let codexKnownTypes: Set<String> = [
        "session_meta", "event_msg", "response_item", "turn_context", "world_state",
        "token_usage_record", "compacted",
    ]

    // MARK: Claude Code

    /// One chunk of a `~/.claude/projects/<folder>/<session>.jsonl` (or a subagent's file, which
    /// the caller folds into its parent by passing the parent's id).
    ///
    /// - Parameters:
    ///   - openTurnAt: the turn left open by the previous chunk of this file.
    ///   - keep: false for an instant that aged out or was deleted; such a record is skipped.
    public static func claudeCode(
        _ data: Data, sessionId: String, openTurnAt: Date? = nil, keep: (Date) -> Bool = { _ in true }
    ) -> AgentChunk {
        var chunk = AgentChunk(tool: claudeCode)
        chunk.sessionId = sessionId
        var turns = TurnBuilder(open: openTurnAt)
        let decoder = JSONDecoder()
        for line in lines(data) {
            guard let record = try? decoder.decode(ClaudeLine.self, from: line),
                  let type = record.type, claudeKnownTypes.contains(type)
            else { chunk.unknown += 1; continue }
            chunk.known += 1

            if type == "pr-link", let key = prKey(url: record.prUrl, repo: record.prRepository, number: record.prNumber) {
                chunk.prs.append(.init(key: key, state: nil))
            }
            guard let at = record.timestamp.flatMap(parseDate) else { continue }
            // A skipped instant ends the turn it fell in: a turn is never rebuilt across a stretch
            // that aged out or was erased.
            guard keep(at) else { turns.close(); continue }
            chunk.see(at)
            if chunk.host == nil { chunk.host = record.entrypoint?.nonEmpty }
            if chunk.cwd == nil { chunk.cwd = record.cwd?.nonEmpty }
            if let branch = record.gitBranch?.nonEmpty, branch != "HEAD" { chunk.branch = branch }

            if type == "assistant" {
                chunk.edited += record.toolNames.filter { editTools.contains($0) }.count
            }
            // Only the agent's own records stretch a turn: its replies and its tools' results.
            // An attachment, a queued message, a system note or a PR link marks the session's span
            // and nothing else, or a turn would run on until the next prompt.
            if record.isInterrupt {
                turns.extendIfOpen(at)
                turns.close()
            } else if record.isTrigger {
                turns.start(at)
            } else if type == "assistant" || record.isToolResult {
                turns.extend(at)
            }
            if record.isPrompt, let uuid = record.uuid?.nonEmpty {
                chunk.prompts.append(.init(recordId: uuid, at: at))
            }
        }
        (chunk.turns, chunk.openTurnAt) = turns.finish()
        return chunk
    }

    // MARK: Codex

    /// One chunk of a Codex rollout. `host` is what an earlier chunk's `session_meta` said, for a
    /// chunk that starts after it.
    public static func codex(
        _ data: Data, sessionId: String?, host: String? = nil, openTurnAt: Date? = nil,
        keep: (Date) -> Bool = { _ in true }
    ) -> AgentChunk {
        var chunk = AgentChunk(tool: codex)
        chunk.sessionId = sessionId
        chunk.host = host
        var turns = TurnBuilder(open: openTurnAt)
        var pendingPrompts: [Date] = []
        let decoder = JSONDecoder()
        for line in lines(data) {
            guard let record = try? decoder.decode(CodexLine.self, from: line),
                  let type = record.type, codexKnownTypes.contains(type)
            else { chunk.unknown += 1; continue }
            chunk.known += 1
            let payload = record.payload

            if type == "session_meta", let payload {
                if let id = payload.id?.nonEmpty { chunk.sessionId = id }
                chunk.host = codexHost(originator: payload.originator, source: payload.source)
                if let cwd = payload.cwd?.nonEmpty { chunk.cwd = cwd }
                if let branch = payload.git?.branch?.nonEmpty { chunk.branch = branch }
                if let url = payload.git?.repositoryURL { chunk.vcsRepo = RepoMap.repo(remoteURL: url) }
            }
            guard let at = record.timestamp.flatMap(parseDate) else { continue }
            guard keep(at) else { turns.close(); continue }
            if type == "session_meta" { chunk.see(at); continue }
            chunk.see(at)

            switch (type, payload?.type) {
            case ("event_msg", "task_started"):
                turns.start(at)
            case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                turns.extendIfOpen(at)
                turns.close()
            case ("event_msg", "user_message"):
                pendingPrompts.append(at)
                if !turns.isOpen { turns.start(at) }
            case ("event_msg", "item_completed"):
                // Codex Desktop writes what you typed as a completed `UserMessage` item, and an
                // edit as a `FileChange` one; only the item's type and its time are decoded.
                switch payload?.item?.type {
                case "UserMessage":
                    let typed = payload?.completedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? at
                    pendingPrompts.append(typed)
                    if !turns.isOpen { turns.start(typed) }
                case "FileChange":
                    chunk.edited += 1
                    turns.extendIfOpen(at)
                default:
                    turns.extendIfOpen(at)
                }
            case ("response_item", "custom_tool_call"), ("response_item", "function_call"):
                if let name = payload?.name, editTools.contains(name) { chunk.edited += 1 }
                turns.extendIfOpen(at)
            default:
                turns.extendIfOpen(at)
            }
        }
        (chunk.turns, chunk.openTurnAt) = turns.finish()
        // Only a person typing in the Codex app is a prompt: `codex exec` and a subagent are
        // something else asking (#321).
        if chunk.host == codexDesktopHost, let id = chunk.sessionId {
            chunk.prompts = pendingPrompts.map {
                .init(recordId: "codex:\(id):\(Int64(($0.timeIntervalSince1970 * 1000).rounded()))", at: $0)
            }
        }
        return chunk
    }

    public static let codexDesktopHost = "codex-desktop"

    static func codexHost(originator: String?, source: CodexSource?) -> String {
        switch source {
        case .name("exec"): return "codex-exec"
        case .name("subagent"): return "codex-subagent"
        case let .object(keys) where keys.contains("subagent"): return "codex-subagent"
        default: break
        }
        switch originator {
        case "Codex Desktop": return codexDesktopHost
        case "codex_exec": return "codex-exec"
        case let other?: return other.lowercased().replacingOccurrences(of: " ", with: "-")
        case nil: return "codex"
        }
    }

    // MARK: Claude desktop Code tab

    /// One file under `claude-code-sessions/`: the Code tab's own record of a session. Only
    /// `cliSessionId`, `worktreePath`, `cwd`, `prs[]` and its times are decoded; `title` and every
    /// `prompt*` key are not read at all. A file holding no `cliSessionId` is an unknown record.
    public static func claudeDesktop(_ data: Data) -> [AgentChunk] {
        let decoder = JSONDecoder()
        var objects: [DesktopSession] = []
        if let one = try? decoder.decode(DesktopSession.self, from: data), one.cliSessionId != nil {
            objects = [one]
        } else if let many = try? decoder.decode([DesktopSession].self, from: data) {
            objects = many
        } else if let wrapped = try? decoder.decode(DesktopSessionList.self, from: data) {
            objects = wrapped.sessions ?? []
        } else {
            objects = lines(data).compactMap { try? decoder.decode(DesktopSession.self, from: $0) }
        }
        let known = objects.filter { $0.cliSessionId?.nonEmpty != nil }
        guard !known.isEmpty else {
            var chunk = AgentChunk(tool: claudeDesktop)
            chunk.unknown = max(1, objects.count)
            return [chunk]
        }
        return known.map { session in
            var chunk = AgentChunk(tool: claudeDesktop)
            chunk.known = 1
            chunk.linkedSessionId = session.cliSessionId
            chunk.host = "claude-desktop"
            chunk.cwd = session.worktreePath?.nonEmpty ?? session.cwd?.nonEmpty
            chunk.branch = session.branch?.nonEmpty
            chunk.prs = (session.prs ?? []).compactMap { pr in
                prKey(url: pr.url, repo: pr.repo, number: pr.number).map { .init(key: $0, state: pr.state?.lowercased()) }
            }
            for at in [session.createdAt, session.updatedAt].compactMap({ $0?.date }) { chunk.see(at) }
            return chunk
        }
    }

    // MARK: Shared

    /// `github.com/<owner>/<name>/pull/<n>` from a URL, or from a repo and a number.
    public static func prKey(url: String?, repo: String?, number: Int?) -> String? {
        if let url, let match = url.firstMatch(of: #/github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)/#) {
            return "github.com/\(match.1)/\(match.2)/pull/\(match.3)"
        }
        if let repo = repo.flatMap({ RepoMap.repo(remoteURL: $0) ?? $0.nonEmpty }), let number,
           repo.contains("/")
        {
            return "github.com/\(repo)/pull/\(number)"
        }
        return nil
    }

    /// The `owner/name` a PR key names.
    public static func repo(ofPRKey key: String) -> String? {
        let parts = key.split(separator: "/")
        guard parts.count >= 5, parts[0] == "github.com" else { return nil }
        return "\(parts[1])/\(parts[2])"
    }

    static func lines(_ data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    static func parseDate(_ text: String) -> Date? {
        if let date = isoFractional.date(from: text) { return date }
        return iso.date(from: text)
    }

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// A leading `<tag>` or `<tag attr…>`: a task notification, a slash command's wrapper, a
    /// CI event, a hook's reminder. Looked at in memory and never kept.
    static func startsWithWrapperTag(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        return trimmed.prefix(64).firstMatch(of: #/^<[A-Za-z][A-Za-z0-9_-]*[\s>/]/#) != nil
    }
}

// MARK: - Turn building

/// Splits a file's records into turns: a trigger (a prompt, a notification, a peer's message,
/// `task_started`) opens one, every later record extends it, the next trigger closes it.
struct TurnBuilder {
    private var open: Date?
    private var last: Date?
    private var closed: [DateInterval] = []

    init(open: Date?) {
        self.open = open
        last = open
    }

    var isOpen: Bool { open != nil }

    mutating func start(_ at: Date) {
        close()
        open = at
        last = at
    }

    mutating func extend(_ at: Date) {
        if open == nil { open = at }
        last = max(last ?? at, at)
    }

    mutating func extendIfOpen(_ at: Date) {
        if open != nil { extend(at) }
    }

    mutating func close() {
        if let open, let last, last >= open { closed.append(DateInterval(start: open, end: last)) }
        open = nil
        last = nil
    }

    /// The closed turns, plus the open one written out as far as it got (the next chunk extends
    /// the same row), and where that open one started.
    func finish() -> ([DateInterval], Date?) {
        var turns = closed
        if let open, let last, last >= open { turns.append(DateInterval(start: open, end: last)) }
        return (turns, open)
    }
}

// MARK: - Decoding whitelists

/// The keys of a Claude Code record that are decoded. Anything not named here is skipped by
/// the decoder, which is what keeps a tool's output or a file's contents out of memory longer
/// than the parse.
private struct ClaudeLine: Decodable {
    var type: String?
    var uuid: String?
    var timestamp: String?
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var isCompactSummary: Bool?
    var isVisibleInTranscriptOnly: Bool?
    var userType: String?
    var originKind: String?
    var content: Content?
    var prUrl: String?
    var prRepository: String?
    var prNumber: Int?

    enum Content {
        case text(String)
        case blocks([Block])
    }

    struct Block: Decodable {
        var type: String?
        var name: String?
        var text: String?
    }

    private enum Keys: String, CodingKey {
        case type, uuid, timestamp, cwd, gitBranch, entrypoint, isSidechain, isMeta, userType
        case isCompactSummary, isVisibleInTranscriptOnly
        case origin, message, prUrl, prRepository, prNumber
    }

    private enum OriginKeys: String, CodingKey { case kind }
    private enum MessageKeys: String, CodingKey { case content }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = c.loose(String.self, .type)
        uuid = c.loose(String.self, .uuid)
        timestamp = c.loose(String.self, .timestamp)
        cwd = c.loose(String.self, .cwd)
        gitBranch = c.loose(String.self, .gitBranch)
        entrypoint = c.loose(String.self, .entrypoint)
        isSidechain = c.loose(Bool.self, .isSidechain)
        isMeta = c.loose(Bool.self, .isMeta)
        isCompactSummary = c.loose(Bool.self, .isCompactSummary)
        isVisibleInTranscriptOnly = c.loose(Bool.self, .isVisibleInTranscriptOnly)
        userType = c.loose(String.self, .userType)
        prUrl = c.loose(String.self, .prUrl)
        prRepository = c.loose(String.self, .prRepository)
        prNumber = c.loose(Int.self, .prNumber) ?? c.loose(String.self, .prNumber).flatMap { Int($0) }
        if let origin = try? c.nestedContainer(keyedBy: OriginKeys.self, forKey: .origin) {
            originKind = origin.loose(String.self, .kind)
        }
        if type == "user" || type == "assistant",
           let message = try? c.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
        {
            if let text = message.loose(String.self, .content) {
                content = .text(text)
            } else if let blocks = message.loose([Block].self, .content) {
                content = .blocks(blocks)
            }
        }
    }

    var toolNames: [String] {
        guard case let .blocks(blocks) = content else { return [] }
        return blocks.filter { $0.type == "tool_use" }.compactMap(\.name)
    }

    var isToolResult: Bool {
        guard case let .blocks(blocks) = content else { return false }
        return blocks.contains { $0.type == "tool_result" }
    }

    /// Something asked the agent to start working: a prompt, a task notification, a peer. A
    /// compaction summary is the harness talking to itself, and an interrupt stops a turn.
    var isTrigger: Bool {
        type == "user" && isMeta != true && !isToolResult && !isHarnessNote && !isInterrupt
    }

    /// A compaction summary, or a record only the transcript view shows.
    var isHarnessNote: Bool {
        isCompactSummary == true || isVisibleInTranscriptOnly == true
    }

    /// `[Request interrupted by user…]`: you pressing Escape, not a prompt.
    var isInterrupt: Bool {
        guard type == "user" else { return false }
        let text: String? = switch content {
        case let .text(text): text
        case let .blocks(blocks): blocks.first(where: { $0.type == "text" })?.text
        case nil: nil
        }
        return text?.drop { $0.isWhitespace }.hasPrefix("[Request interrupted") ?? false
    }

    /// You typing (#321): `origin.kind == "human"`; without an origin, an external user record on
    /// the main thread that is not a tool's result and does not start with a wrapper tag.
    var isPrompt: Bool {
        guard type == "user" else { return false }
        if let originKind { return originKind == "human" }
        guard userType == "external", isSidechain != true, isMeta != true, !isHarnessNote, !isInterrupt
        else { return false }
        switch content {
        case let .text(text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !AgentStoreParsers.startsWithWrapperTag(text)
        case let .blocks(blocks):
            if isToolResult { return false }
            if let first = blocks.first(where: { $0.type == "text" })?.text {
                return !AgentStoreParsers.startsWithWrapperTag(first)
            }
            return !blocks.isEmpty
        case nil:
            return false
        }
    }
}

/// `source` in a Codex `session_meta`: a plain name (`vscode`, `exec`, `subagent`), or an object
/// whose keys name it (`{"subagent": …}`).
enum CodexSource: Decodable, Equatable {
    case name(String)
    case object(Set<String>)

    init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = .name(name.lowercased())
        } else {
            let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map { $0.stringValue.lowercased() }
            self = .object(Set(keys))
        }
    }
}

private struct CodexLine: Decodable {
    var type: String?
    var timestamp: String?
    var payload: Payload?

    struct Payload: Decodable {
        var type: String?
        var id: String?
        var cwd: String?
        var originator: String?
        var source: CodexSource?
        var git: Git?
        var name: String?
        var item: Item?
        var completedAtMs: Int64?

        /// An `item_completed`'s item: its type only, never its content or a change's paths.
        struct Item: Decodable {
            var type: String?
            private enum Keys: String, CodingKey { case type }
            init(from decoder: any Decoder) throws {
                type = try decoder.container(keyedBy: Keys.self).loose(String.self, .type)
            }
        }

        private enum Keys: String, CodingKey {
            case type, id, cwd, originator, source, git, name, item
            case completedAtMs = "completed_at_ms"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = c.loose(String.self, .type)
            id = c.loose(String.self, .id)
            cwd = c.loose(String.self, .cwd)
            originator = c.loose(String.self, .originator)
            source = c.loose(CodexSource.self, .source)
            git = c.loose(Git.self, .git)
            name = c.loose(String.self, .name)
            item = c.loose(Item.self, .item)
            completedAtMs = c.loose(Int64.self, .completedAtMs)
        }
    }

    struct Git: Decodable {
        var branch: String?
        var repositoryURL: String?
        private enum Keys: String, CodingKey {
            case branch
            case repositoryURL = "repository_url"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            branch = c.loose(String.self, .branch)
            repositoryURL = c.loose(String.self, .repositoryURL)
        }
    }

    private enum Keys: String, CodingKey { case type, timestamp, payload }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = c.loose(String.self, .type)
        timestamp = c.loose(String.self, .timestamp)
        payload = c.loose(Payload.self, .payload)
    }
}

private struct DesktopSessionList: Decodable {
    var sessions: [DesktopSession]?
}

/// The Code tab's record. `title` and `prompt*` are deliberately absent from `Keys`.
private struct DesktopSession: Decodable {
    var cliSessionId: String?
    var worktreePath: String?
    var cwd: String?
    var branch: String?
    var prs: [DesktopPR]?
    var createdAt: FlexibleDate?
    var updatedAt: FlexibleDate?

    private enum Keys: String, CodingKey {
        case cliSessionId, worktreePath, cwd, branch, gitBranch, prs, createdAt, updatedAt, lastActivityAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cliSessionId = c.loose(String.self, .cliSessionId)
        worktreePath = c.loose(String.self, .worktreePath)
        cwd = c.loose(String.self, .cwd)
        branch = c.loose(String.self, .branch) ?? c.loose(String.self, .gitBranch)
        prs = c.loose([DesktopPR].self, .prs)
        createdAt = c.loose(FlexibleDate.self, .createdAt)
        updatedAt = c.loose(FlexibleDate.self, .lastActivityAt) ?? c.loose(FlexibleDate.self, .updatedAt)
    }
}

private struct DesktopPR: Decodable {
    var url: String?
    var repo: String?
    var number: Int?
    var state: String?

    private enum Keys: String, CodingKey {
        case url, prUrl, htmlUrl, repo, repository, number, prNumber, state, status
    }

    init(from decoder: any Decoder) throws {
        if let url = try? decoder.singleValueContainer().decode(String.self) {
            self.url = url
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        url = c.loose(String.self, .url) ?? c.loose(String.self, .prUrl) ?? c.loose(String.self, .htmlUrl)
        repo = c.loose(String.self, .repo) ?? c.loose(String.self, .repository)
        number = c.loose(Int.self, .number) ?? c.loose(Int.self, .prNumber)
        state = c.loose(String.self, .state) ?? c.loose(String.self, .status)
    }
}

/// An ISO 8601 string, or seconds or milliseconds since 1970.
private struct FlexibleDate: Decodable {
    var date: Date?

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            date = AgentStoreParsers.parseDate(text)
        } else if let number = try? c.decode(Double.self) {
            date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer {
    /// A value of the wrong type reads as absent instead of failing the whole record.
    func loose<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
