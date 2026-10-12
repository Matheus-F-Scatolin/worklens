import Foundation

/// Time per document (#319): the minutes each `ArtifactKey` was on your screen, from the same
/// screen-active frame weights `byProject` reads. Pure; `StatsAggregator.daily` and
/// `StatsService.documentSeconds` are its two callers.
///
/// A blocked frame gives no key. A redacted frame adds its minutes but never names a row.
enum DocumentTime {
    /// Rows kept before the rest fold into `other`.
    static let limit = 10

    /// The frame weights that count: screen blocks that were not idle, after the day is clipped to
    /// `now` the way `StatsAggregator.daily` clips it.
    static func onScreenWeights(
        blocks: [ActivityBlock], captures: [Capture], now: Date?
    ) -> [StatsAggregator.CaptureWeight] {
        let blocks = StatsAggregator.clippedToNow(blocks, now: now)
            .filter { $0.endAt > $0.startAt }
            .sorted { $0.startAt < $1.startAt }
        return StatsAggregator.captureWeights(blocks: blocks, captures: captures)
            .filter { $0.block.source == .screen && !StatsAggregator.isInactive($0.block) }
    }

    /// A frame's key, or nil for a blocked frame or one whose URLs name no document.
    static func key(_ capture: Capture, documentURLs: [String: String]) -> ArtifactKey? {
        guard capture.skipReason?.isBlocked != true else { return nil }
        return ArtifactKey.resolve(url: capture.browserUrl, documentURL: documentURLs[capture.id])
    }

    /// Seconds per document, uncapped. `documentURLs` is `capture_id` → `ax_snapshots.document_url`.
    static func seconds(
        weights: [StatsAggregator.CaptureWeight], documentURLs: [String: String]
    ) -> [ArtifactKey: Double] {
        var seconds: [ArtifactKey: Double] = [:]
        for weight in weights {
            guard let key = key(weight.capture, documentURLs: documentURLs) else { continue }
            seconds[key, default: 0] += weight.seconds
        }
        return seconds
    }

    /// `byDocument`: the top `limit` documents plus `other`, shared against `total` seconds.
    static func slices(
        weights: [StatsAggregator.CaptureWeight],
        documentURLs: [String: String],
        frameDocuments: [String: String],
        total: Double,
        home: String = NSHomeDirectory()
    ) -> [Slice] {
        var seconds: [ArtifactKey: Double] = [:]
        var documents: [ArtifactKey: [String: Int]] = [:]
        var titles: [ArtifactKey: [String: Int]] = [:]
        for weight in weights {
            guard let key = key(weight.capture, documentURLs: documentURLs) else { continue }
            seconds[key, default: 0] += weight.seconds
            // A redacted frame's minutes count; its words never name anything.
            guard !weight.capture.isRedacted else { continue }
            if let document = clean(frameDocuments[weight.capture.id]) {
                documents[key, default: [:]][document, default: 0] += 1
            }
            if let title = clean(weight.capture.windowTitle) {
                titles[key, default: [:]][title, default: 0] += 1
            }
        }
        let entries = seconds.map { key, value in
            StatsAggregator.Entry(
                key: key.displayKey(home: home),
                name: mostFrequent(documents[key]) ?? mostFrequent(titles[key]) ?? key.shortName,
                seconds: value
            )
        }
        return StatsAggregator.slices(entries, limit: limit, total: total)
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The most frequent string, ties broken alphabetically so a run is stable.
    private static func mostFrequent(_ counts: [String: Int]?) -> String? {
        counts?.min { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }?.key
    }
}
