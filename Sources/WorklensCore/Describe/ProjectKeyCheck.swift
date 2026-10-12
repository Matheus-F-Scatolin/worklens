import Foundation
import GRDB

/// `worklens projects check` (#315): how many recent house frames the d5 prompt would move, and
/// where to.
///
/// Before d5 the describer named the firm on almost half of its frames, because the firm's name
/// is on every screen of a work machine. d5 tells it to keep the house key for firm-wide work and
/// to pick the entry on screen otherwise. The check re-asks a sample of those frames, text only,
/// and counts the answers; it stores nothing but the `llm_calls` rows the asks cost
/// (`DescribeWorker.probe`). Everything here is pure except `candidates`, which only reads.
public enum ProjectKeyCheck {
    /// How many frames a check asks about unless told otherwise. ~$0.05 at d5's size.
    public static let defaultSample = 100
    /// How far back a check looks for house frames.
    public static let lookbackDays = 30

    /// One described frame that has stored window text, with what it said it was about.
    public struct Candidate: Sendable, Equatable {
        public var captureId: String
        public var capturedAt: Date
        public var observation: ProjectNames.Observation

        public init(captureId: String, capturedAt: Date, observation: ProjectNames.Observation) {
            self.captureId = captureId
            self.capturedAt = capturedAt
            self.observation = observation
        }
    }

    /// The newest `sample` candidates that resolve to the house entry, by key or by hint, the
    /// way the stats would count them. Empty when the catalog has no house entry.
    public static func pick(
        _ candidates: [Candidate], projects: [ProjectEntry], sample: Int = defaultSample
    ) -> [String] {
        guard sample > 0, let house = projects.first(where: { $0.kind == .house }) else { return [] }
        let resolved = ProjectNames.resolve(
            Dictionary(candidates.map { ($0.captureId, $0.observation) }, uniquingKeysWith: { a, _ in a }),
            projects: projects
        )
        return candidates
            .filter { resolved[$0.captureId]?.key == house.key }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.captureId < $1.captureId : $0.capturedAt > $1.capturedAt }
            .prefix(sample)
            .map(\.captureId)
    }

    /// The capture ids a check over the last `lookbackDays` before `now` would ask about, the
    /// newest first. Reads only; what both the dry run and the real run start from.
    public static func toAsk(
        db: Database, projects: [ProjectEntry], sample: Int = defaultSample, now: Date = Date()
    ) throws -> [String] {
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        return pick(try candidates(db: db, since: since), projects: projects, sample: sample)
    }

    /// Where the sampled frames went. Counts only: no key, name or hint is ever in here.
    public struct Tally: Sendable, Equatable, Encodable {
        public var sampled = 0
        public var stayedHouse = 0
        public var company = 0
        public var side = 0
        /// A catalog entry nobody has marked with a kind.
        public var unmarked = 0
        /// `project_key` null: none of the listed entries.
        public var none = 0
        public var failed = 0
        public var costUSD = 0.0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case sampled
            case stayedHouse = "stayed_house"
            case company, side, unmarked, none, failed
            case costUSD = "cost_usd"
        }
    }

    /// Adds up the probes' answers against the catalog's kinds.
    public static func tally(
        _ outcomes: [DescribeWorker.ProbeOutcome], projects: [ProjectEntry]
    ) -> Tally {
        var tally = Tally()
        for outcome in outcomes {
            let key: String?
            switch outcome {
            case .overBudget:
                // Nothing was asked: the budget stopped the check before the call.
                continue
            case let .failed(_, cost):
                tally.sampled += 1
                tally.failed += 1
                tally.costUSD += cost
                continue
            case let .answered(answer, cost):
                tally.sampled += 1
                tally.costUSD += cost
                key = answer
            }
            guard let key else {
                tally.none += 1
                continue
            }
            switch ProjectEntry.lookup(key: key, in: projects)?.kind {
            case .house: tally.stayedHouse += 1
            case .company: tally.company += 1
            case .side: tally.side += 1
            case nil: tally.unmarked += 1
            }
        }
        return tally
    }

    /// Every described frame since `since` with stored window text, newest first, leaving out
    /// frames the describer flagged sensitive so their text is not sent again. Reads
    /// `details_json`, the app name and the window title, never the text itself.
    public static func candidates(db: Database, since: Date) throws -> [Candidate] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.capture_id AS capture_id, d.details_json AS details_json,
                       c.captured_at AS captured_at, c.app_name AS app_name,
                       c.window_title AS window_title
                FROM descriptions d
                JOIN captures c ON c.id = d.capture_id
                JOIN ax_snapshots a ON a.capture_id = d.capture_id
                WHERE c.captured_at >= ? AND d.details_json IS NOT NULL AND NOT d.is_sensitive
                  AND a.text IS NOT NULL AND a.text != ''
                ORDER BY c.captured_at DESC
                """, arguments: [since])
                .map { row in
                    let details = TimelineFrame.details(json: row["details_json"])
                    return Candidate(
                        captureId: row["capture_id"],
                        capturedAt: row["captured_at"],
                        observation: ProjectNames.Observation(
                            hint: details.projectHint, appName: row["app_name"],
                            windowTitle: row["window_title"], projectKey: details.projectKey
                        )
                    )
                }
        }
    }
}
