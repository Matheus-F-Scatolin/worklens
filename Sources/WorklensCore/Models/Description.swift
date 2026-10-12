import Foundation
import GRDB

/// The vision model's reading of one capture.
public struct Description: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "descriptions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var captureId: String
    public var provider: String
    public var model: String
    public var appKey: String
    public var taskKey: String
    public var summaryMd: String
    /// `{document, people[], project_hint, ...}` as JSON text.
    public var detailsJson: String?
    public var isMeeting: Bool
    public var isSensitive: Bool
    public var confidence: Double?
    /// Copied from the previous frame instead of costing an LLM call.
    public var isInherited: Bool
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var thoughtTokens: Int?
    public var costUsd: Double?
    public var latencyMs: Int?
    public var rawJson: String?
    public var createdAt: Date

    public init(
        id: String = Identifiers.new(),
        captureId: String,
        provider: String,
        model: String,
        appKey: String,
        taskKey: String,
        summaryMd: String,
        detailsJson: String? = nil,
        isMeeting: Bool = false,
        isSensitive: Bool = false,
        confidence: Double? = nil,
        isInherited: Bool = false,
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        thoughtTokens: Int? = nil,
        costUsd: Double? = nil,
        latencyMs: Int? = nil,
        rawJson: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.captureId = captureId
        self.provider = provider
        self.model = model
        self.appKey = appKey
        self.taskKey = taskKey
        self.summaryMd = summaryMd
        self.detailsJson = detailsJson
        self.isMeeting = isMeeting
        self.isSensitive = isSensitive
        self.confidence = confidence
        self.isInherited = isInherited
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.costUsd = costUsd
        self.latencyMs = latencyMs
        self.rawJson = rawJson
        self.createdAt = createdAt
    }
}

/// A description joined with the capture columns the UI and reports need most.
public struct DescriptionWithCapture: Codable, FetchableRecord, Sendable, Equatable {
    public var description: Description
    public var capturedAt: Date
    public var appName: String?
    public var windowTitle: String?
}
