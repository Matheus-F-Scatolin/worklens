import Foundation
import GRDB

public enum ReportKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case daily, weekly
}

/// A generated daily or weekly report, plus the stats it was written from.
public struct Report: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "reports"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var kind: ReportKind
    /// `YYYY-MM-DD`, inclusive.
    public var periodStart: String
    /// `YYYY-MM-DD`, inclusive.
    public var periodEnd: String
    public var provider: String
    public var model: String
    public var contentMd: String
    /// #249: the report's own opening sentence, lifted out when the report is written, so a list
    /// of days can say what each one was about without loading every `content_md`. Nil on every
    /// row written before that migration, and on a report whose lede was not usable.
    public var headline: String?
    public var statsJson: String?
    /// Relative to `DATA_DIR`.
    public var filePath: String?
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var costUsd: Double?
    public var createdAt: Date

    public init(
        id: String = Identifiers.new(),
        kind: ReportKind,
        periodStart: String,
        periodEnd: String,
        provider: String,
        model: String,
        contentMd: String,
        headline: String? = nil,
        statsJson: String? = nil,
        filePath: String? = nil,
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        costUsd: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.provider = provider
        self.model = model
        self.contentMd = contentMd
        self.headline = headline
        self.statsJson = statsJson
        self.filePath = filePath
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.costUsd = costUsd
        self.createdAt = createdAt
    }
}
