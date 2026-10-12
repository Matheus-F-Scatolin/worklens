import Foundation
import GRDB

public enum ContextSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case granola, calendar
}

/// Something that happened outside the screen: a meeting, a calendar event, a message you sent.
public struct ContextEvent: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "context_events"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var source: ContextSource
    /// The id this event has in its source system. Unique together with `source`.
    public var externalId: String
    public var startAt: Date
    public var endAt: Date?
    public var title: String?
    public var participantsJson: String?
    public var bodyMd: String?
    /// Relative to `DATA_DIR`, for bodies too large to keep inline (Granola transcripts).
    public var bodyPath: String?
    public var isMeeting: Bool
    public var rawJson: String?
    public var syncedAt: Date
    /// A Granola meeting's next steps and decisions, as `MeetingOutcomes` JSON (#316). Nil on
    /// calendar rows and on Granola rows the sync has not parsed yet.
    public var outcomesJson: String?

    public init(
        id: String = Identifiers.new(),
        source: ContextSource,
        externalId: String,
        startAt: Date,
        endAt: Date? = nil,
        title: String? = nil,
        participantsJson: String? = nil,
        bodyMd: String? = nil,
        bodyPath: String? = nil,
        isMeeting: Bool = false,
        rawJson: String? = nil,
        syncedAt: Date = Date(),
        outcomesJson: String? = nil
    ) {
        self.id = id
        self.source = source
        self.externalId = externalId
        self.startAt = startAt
        self.endAt = endAt
        self.title = title
        self.participantsJson = participantsJson
        self.bodyMd = bodyMd
        self.bodyPath = bodyPath
        self.isMeeting = isMeeting
        self.rawJson = rawJson
        self.syncedAt = syncedAt
        self.outcomesJson = outcomesJson
    }
}
