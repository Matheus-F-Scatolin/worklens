import Foundation
import GRDB

/// One `ax_snapshots` row: what the focused window exposed to assistive technology at the moment
/// a frame was captured (#53).
///
/// Keyed by `capture_id` rather than by an id of its own — a capture has at most one snapshot,
/// and the foreign key cascades, so an erased frame takes its outline with it.
///
/// `text` is the **redacted** outline and the only column retention ever removes. `textHash`,
/// `redactionsJson` and `coverage` survive it, which is what lets the describe decision and the
/// coverage numbers keep working on a frame whose text has been dropped.
public struct AXSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "ax_snapshots"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var captureId: String
    public var coverage: AXSnapshot.Coverage
    public var nodeCount: Int
    /// Characters in the stored (redacted) outline, kept because `text` may be dropped later.
    public var textChars: Int
    /// How long the walk took, including the messaging timeout on a frozen app.
    public var elapsedMs: Int
    /// SHA-256 of the **redacted** outline — the hash the next tick compares against, so the
    /// stored text and the hash can never disagree.
    public var textHash: String
    /// `AXDocument`: the file or page the window is editing.
    public var documentUrl: String?
    /// The redacted outline. Nil when the walk found nothing, or after retention dropped it.
    public var text: String?
    /// `TextRedactor` counts, as `{"card": 1}`. Nil when nothing was replaced.
    public var redactionsJson: String?
    public var createdAt: Date

    public init(
        captureId: String,
        coverage: AXSnapshot.Coverage,
        nodeCount: Int = 0,
        textChars: Int = 0,
        elapsedMs: Int = 0,
        textHash: String,
        documentUrl: String? = nil,
        text: String? = nil,
        redactionsJson: String? = nil,
        createdAt: Date = Date()
    ) {
        self.captureId = captureId
        self.coverage = coverage
        self.nodeCount = nodeCount
        self.textChars = textChars
        self.elapsedMs = elapsedMs
        self.textHash = textHash
        self.documentUrl = documentUrl
        self.text = text
        self.redactionsJson = redactionsJson
        self.createdAt = createdAt
    }

    /// `{"card":1}` — the same shape `descriptions.details_json` uses under `redactions`, so one
    /// frame's two redaction records read the same way. Nil when nothing was replaced.
    public static func encodeRedactions(_ counts: [TextRedactor.Kind: Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(TextRedactor.countsJSON(counts)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The grade is stored as its raw string, the way `SkipReason` and `DescribeStatus` are. Declared
/// here rather than beside the type so `AccessibilitySnapshotter.swift` stays free of GRDB.
extension AXSnapshot.Coverage: DatabaseValueConvertible {}
