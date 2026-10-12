import Foundation
import GRDB

/// Where a block of time came from.
public enum ActivitySource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case screen, calendar, granola
}

/// A contiguous stretch of one activity, coalesced from captures or from a context source.
public struct ActivityBlock: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "activity_blocks"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    /// `YYYY-MM-DD`, local time.
    public var day: String
    public var startAt: Date
    public var endAt: Date
    public var appKey: String
    public var taskKey: String
    /// Meeting title, or the dominant window title.
    public var title: String?
    public var summaryMd: String?
    public var captureCount: Int
    public var source: ActivitySource
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = Identifiers.new(),
        day: String,
        startAt: Date,
        endAt: Date,
        appKey: String,
        taskKey: String,
        title: String? = nil,
        summaryMd: String? = nil,
        captureCount: Int = 0,
        source: ActivitySource = .screen,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.day = day
        self.startAt = startAt
        self.endAt = endAt
        self.appKey = appKey
        self.taskKey = taskKey
        self.title = title
        self.summaryMd = summaryMd
        self.captureCount = captureCount
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
