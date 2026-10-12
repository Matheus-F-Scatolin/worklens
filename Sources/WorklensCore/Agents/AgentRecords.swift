import Foundation
import GRDB

/// A Claude Code or Codex session (#321): a row in `agent_sessions`. Metadata only; `cwd` is a
/// path the log named, never read and never logged at `info`.
public struct AgentSession: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "agent_sessions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    /// `claude_code` or `codex`.
    public var tool: String
    /// Where it ran: `claude-desktop`, `cli`, `sdk-cli`, `codex-desktop`, `codex-exec`…
    public var host: String?
    /// The Claude Code session a Codex consult ran inside.
    public var parentId: String?
    public var startAt: Date?
    public var endAt: Date?
    public var cwd: String?
    public var vcsRepo: String?
    public var repo: String?
    /// Which `RepoMap` rule named `repo`.
    public var repoRule: String?
    public var branch: String?
    /// Tool calls that edited a file.
    public var edited: Int
    public var parser: Int

    public init(
        id: String, tool: String, host: String? = nil, parentId: String? = nil,
        startAt: Date? = nil, endAt: Date? = nil, cwd: String? = nil, vcsRepo: String? = nil,
        repo: String? = nil, repoRule: String? = nil, branch: String? = nil, edited: Int = 0,
        parser: Int = AgentStoreParsers.version
    ) {
        self.id = id
        self.tool = tool
        self.host = host
        self.parentId = parentId
        self.startAt = startAt
        self.endAt = endAt
        self.cwd = cwd
        self.vcsRepo = vcsRepo
        self.repo = repo
        self.repoRule = repoRule
        self.branch = branch
        self.edited = edited
        self.parser = parser
    }
}

/// One instant you typed a prompt. Never its text.
public struct AgentPrompt: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_prompts"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// The record's own `uuid`, so a forked session that copies it adds no second row.
    public var recordId: String
    public var sessionId: String
    public var at: Date

    public init(recordId: String, sessionId: String, at: Date) {
        self.recordId = recordId
        self.sessionId = sessionId
        self.at = at
    }
}

/// A stretch the agent was working.
public struct AgentTurn: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_turns"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var sessionId: String
    public var startAt: Date
    public var endAt: Date

    public init(sessionId: String, startAt: Date, endAt: Date) {
        self.sessionId = sessionId
        self.startAt = startAt
        self.endAt = endAt
    }

    public var interval: DateInterval { DateInterval(start: startAt, end: max(startAt, endAt)) }
}

/// A PR a session linked.
public struct AgentSessionPR: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_session_prs"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var sessionId: String
    /// `github.com/<owner>/<name>/pull/<n>`, joined to `outputs.resource_key`.
    public var prKey: String
    /// The desktop app's last word on it; nil from a `pr-link` record.
    public var state: String?

    public init(sessionId: String, prKey: String, state: String? = nil) {
        self.sessionId = sessionId
        self.prKey = prKey
        self.state = state
    }
}

/// How far into one log file the sync has read.
public struct AgentSourceFile: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "agent_source_files"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var path: String
    public var store: String
    public var sessionId: String?
    public var size: Int64
    public var mtime: Date
    /// The byte after the last whole line read.
    public var offset: Int64
    /// Where the turn still open at `offset` started.
    public var openTurnAt: Date?
    public var parser: Int
    /// File-editing tool calls read from this file so far.
    public var edited: Int

    public init(
        path: String, store: String, sessionId: String?, size: Int64, mtime: Date, offset: Int64,
        openTurnAt: Date?, parser: Int = AgentStoreParsers.version, edited: Int = 0
    ) {
        self.path = path
        self.store = store
        self.sessionId = sessionId
        self.size = size
        self.mtime = mtime
        self.offset = offset
        self.openTurnAt = openTurnAt
        self.parser = parser
        self.edited = edited
    }
}
