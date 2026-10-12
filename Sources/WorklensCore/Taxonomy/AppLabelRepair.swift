import Foundation
import GRDB

/// Brings an existing install up to the apps a later seed added (#312), in two steps.
///
/// `mergeIfDue` adds the new bundle ids to `taxonomy.json` once, through `TaxonomyMerge`, so a
/// frame captured from now on resolves to its own app. `relabelIfDue` then fixes the frames
/// already described under a borrowed key: it rewrites their `descriptions.app_key` and
/// rebuilds the days they sit on, so the stored blocks, the stats and the search all agree
/// without any reader re-resolving. Nothing is re-described, so a fixed frame's task becomes
/// `other` unless its old task also exists under the new app.
///
/// Each step records the seed revision it reached in `app_state`, so it runs once per
/// revision, and an app you delete by hand afterwards stays deleted.
public struct AppLabelRepair: Sendable {
    /// `app_state` key: the last `TaxonomySeed.appsRevision` merged into `taxonomy.json`.
    public static let taxonomyRevisionKey = "taxonomy_apps_revision"
    /// `app_state` key: the last revision whose past frames were relabelled.
    public static let labelsRevisionKey = "app_labels_revision"
    /// `app_state` key: days a relabel touched whose rebuild has not succeeded yet, so a retry
    /// rebuilds them even though their rows no longer need changing.
    public static let pendingDaysKey = "app_labels_pending_days"
    /// What an install that never recorded a revision has: the seed every install started with.
    static let baseRevision = 1

    /// What one relabel changed.
    public struct Relabel: Sendable, Equatable {
        /// Descriptions that took a new app key.
        public let frames: Int
        /// The local days rebuilt, `YYYY-MM-DD`, ascending.
        public let days: [String]
    }

    private let db: Database
    private let taxonomy: TaxonomyStore
    private let timeZone: TimeZone

    public init(db: Database, taxonomy: TaxonomyStore, timeZone: TimeZone = .current) {
        self.db = db
        self.taxonomy = taxonomy
        self.timeZone = timeZone
    }

    // MARK: Merge

    /// Adds the bundle ids of every seed revision above the recorded one to `taxonomy.json`,
    /// saving only when something was added, then records the revision. Returns the ids added.
    @discardableResult
    public func mergeIfDue() throws -> [String] {
        let state = AppStateStore(db)
        let recorded = try revision(state, Self.taxonomyRevisionKey)
        guard recorded < TaxonomySeed.appsRevision else { return [] }

        let ids = TaxonomySeed.additions(after: recorded)
        let (merged, added) = TaxonomyMerge.apply(taxonomy.current, bundleIDs: ids)
        if !added.isEmpty {
            try taxonomy.save(merged)
            Log.describe.info("taxonomy.json: added \(added.count) app id(s) from the seed")
        }
        try state.set(Self.taxonomyRevisionKey, String(TaxonomySeed.appsRevision))
        return added
    }

    // MARK: Relabel

    /// Moves the past descriptions of each newly listed bundle id to the key it resolves to now,
    /// in one write, then calls `rebuild` once per local day touched. The revision is recorded
    /// only after every rebuild succeeded; a failure leaves it unrecorded and the touched days
    /// pending, so the next call retries them. Nil when nothing was due or nothing changed.
    ///
    /// Waits for `mergeIfDue`: until the file lists the new ids, they resolve to nothing (or to
    /// the borrowed key), and recording the revision then would skip the relabel for good.
    public func relabelIfDue(
        rebuild: @Sendable (String) async throws -> Void
    ) async throws -> Relabel? {
        let state = AppStateStore(db)
        let recorded = try revision(state, Self.labelsRevisionKey)
        guard recorded < TaxonomySeed.appsRevision,
              try revision(state, Self.taxonomyRevisionKey) >= TaxonomySeed.appsRevision
        else { return nil }

        var targets: [(bundleID: String, appKey: String)] = []
        for id in TaxonomySeed.additions(after: recorded) {
            guard let key = taxonomy.resolve(bundleID: id, url: nil)?.appKey else { continue }
            targets.append((id, key))
        }

        let (frames, days) = try relabel(targets)
        for day in days {
            try await rebuild(day)
        }
        try state.delete(Self.pendingDaysKey)
        try state.set(Self.labelsRevisionKey, String(TaxonomySeed.appsRevision))
        return frames == 0 && days.isEmpty ? nil : Relabel(frames: frames, days: days)
    }

    /// The single write: every description of a target bundle whose app key differs takes the
    /// new key, and the days it touched join the pending set. Returns the rows changed and the
    /// full pending set, sorted.
    private func relabel(_ targets: [(bundleID: String, appKey: String)]) throws -> (Int, [String]) {
        try db.writer.write { db in
            var days = Set(try Self.pendingDays(db))
            var frames = 0
            for target in targets {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT d.id AS id, d.task_key AS task_key, c.captured_at AS captured_at
                        FROM descriptions d JOIN captures c ON c.id = d.capture_id
                        WHERE c.app_bundle_id = ? AND d.app_key != ?
                        """,
                    arguments: [target.bundleID, target.appKey]
                )
                for row in rows {
                    let oldTask: String = row["task_key"]
                    let task = taxonomy.canonicalTask(appKey: target.appKey, taskKey: oldTask) ?? "other"
                    try db.execute(
                        sql: "UPDATE descriptions SET app_key = ?, task_key = ? WHERE id = ?",
                        arguments: [target.appKey, task, row["id"] as String]
                    )
                    days.insert(DayBoundaries.dayString(row["captured_at"] as Date, timeZone: timeZone))
                    frames += 1
                }
            }
            let sorted = days.sorted()
            if !sorted.isEmpty {
                let json = String(decoding: try JSONEncoder().encode(sorted), as: UTF8.self)
                try db.execute(
                    sql: """
                        INSERT INTO app_state (key, value, updated_at) VALUES (?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                        """,
                    arguments: [Self.pendingDaysKey, json, Date()]
                )
            }
            return (frames, sorted)
        }
    }

    private static func pendingDays(_ db: GRDB.Database) throws -> [String] {
        guard let json = try String.fetchOne(
            db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [pendingDaysKey]
        ) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private func revision(_ state: AppStateStore, _ key: String) throws -> Int {
        try state.get(key).flatMap { Int($0) } ?? Self.baseRevision
    }
}
