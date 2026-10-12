import Foundation
import GRDB

/// One uninterrupted stretch with a single app in front, as the OS reported it.
///
/// The seam this sits on: **sessions are time, frames are meaning.** An activation event names a
/// process to the second but knows nothing about what was on screen; a described frame knows the
/// task and the site but only exists once a tick. #46 records both and lets `StatsAggregator`
/// take the exact totals from here and the split within an app from the frames.
public struct ForegroundSession: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable,
                                Identifiable {
    public static let databaseTableName = "foreground_sessions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// What wrote the row. A plain string rather than an enum: the column exists so #47 can add
    /// imported rows without a schema change, and an unknown value must read back rather than
    /// fail to decode. This issue only ever writes `nsworkspace`.
    public static let nsworkspaceSource = "nsworkspace"

    public var id: String
    public var startAt: Date
    /// Nil while the interval is still open. Exactly one row is open at a time.
    public var endAt: Date?
    /// Nil for a blocked app: the interval is kept so the day still adds up, the identity is not.
    public var appBundleId: String?
    public var appName: String?
    public var isBlocked: Bool
    public var source: String
    public var createdAt: Date

    public init(
        id: String = Identifiers.new(),
        startAt: Date,
        endAt: Date? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        isBlocked: Bool = false,
        source: String = ForegroundSession.nsworkspaceSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.appBundleId = appBundleId
        self.appName = appName
        self.isBlocked = isBlocked
        self.source = source
        self.createdAt = createdAt
    }

    public var isOpen: Bool { endAt == nil }

    /// Seconds the interval covers, or nil while it is still open.
    public var seconds: Double? {
        endAt.map { max(0, $0.timeIntervalSince(startAt)) }
    }
}
