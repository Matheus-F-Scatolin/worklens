import Foundation
import GRDB

/// Taking an integration back out (#141).
///
/// Worklens promises you can remove what it collected, and until now only Google could be
/// disconnected: Granola left a key and a folder of transcripts behind with nothing in the app or
/// the CLI that could remove any of it.
///
/// Two separate acts, deliberately:
///
/// * **Disconnect** stops the syncing. It removes the credential Worklens itself wrote, forgets
///   and the stored sync status. It leaves the meetings already on your timeline alone, because
///   disconnecting a source is not a request to rewrite your own history.
/// * **Delete synced data** removes that history: the rows, the transcript files under
///   `DATA_DIR/context/<source>/`, and the timeline blocks built from them. It counts first, and
///   the caller redraws each day it touched.
///
/// `PRIVACY.md` records the deliberate choice that `context_events` survive the time-range
/// eraser — "a meeting you attended is not something Worklens watched you do". That is about
/// erasing a *stretch of time*, and this is about removing one *source* entirely, which you asked
/// for by name; both rules can be true, and `PRIVACY.md` now says so.
public enum IntegrationRemoval {
    /// What a delete would remove, or did.
    public struct Plan: Sendable, Equatable {
        public let source: ContextSource
        public let events: Int
        /// Transcripts and other bodies under `DATA_DIR/context/<source>/`.
        public let files: Int
        /// Timeline blocks this source owns.
        public let blocks: Int
        /// The local days those events fell in — each one's timeline file has to be redrawn.
        public let days: [String]

        public init(
            source: ContextSource, events: Int, files: Int, blocks: Int, days: [String]
        ) {
            self.source = source
            self.events = events
            self.files = files
            self.blocks = blocks
            self.days = days
        }

        public var isEmpty: Bool { events == 0 && files == 0 && blocks == 0 }

        /// The sentence the confirmation asks with, in the second person and without a number
        /// dressed up as a judgement: `2,314 meetings, 40 transcript files and 118 timeline
        /// blocks`.
        public var summary: String {
            guard !isEmpty else { return "nothing" }
            var parts: [String] = []
            if events > 0 {
                parts.append("\(events) \(SourceStatus.noun(source, count: events))")
            }
            if files > 0 { parts.append("\(files) transcript file\(files == 1 ? "" : "s")") }
            if blocks > 0 { parts.append("\(blocks) timeline block\(blocks == 1 ? "" : "s")") }
            guard parts.count > 1 else { return parts[0] }
            return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// The timeline blocks a context source owns.
    public static func activitySource(_ source: ContextSource) -> ActivitySource? {
        switch source {
        case .granola: return .granola
        case .calendar: return .calendar
        }
    }

    /// Counts without removing anything, so the confirmation can say what it is about to do.
    public static func plan(
        source: ContextSource, db: Database, config: Config, timeZone: TimeZone = .current
    ) throws -> Plan {
        let store = ContextEventStore(db)
        let days = try store.days(source: source, timeZone: timeZone)
        return Plan(
            source: source,
            events: try store.count(source: source),
            files: try store.bodyPaths(source: source).count,
            blocks: try blockCount(source: source, db: db),
            days: days
        )
    }

    /// Removes the rows, the body files and the blocks, and returns what went. The caller rebuilds
    /// `Plan.days` — `TimelineWriter.rebuild(day:)`, one call per day, because
    /// `rebuildRecentDays()` only covers today and yesterday and this can reach back years.
    @discardableResult
    public static func deleteSyncedData(
        source: ContextSource, db: Database, config: Config, timeZone: TimeZone = .current
    ) throws -> Plan {
        let planned = try plan(source: source, db: db, config: config, timeZone: timeZone)
        let store = ContextEventStore(db)
        for path in try store.bodyPaths(source: source) { ContextBody.delete(path, config: config) }
        // The folder itself, so an emptied integration leaves no directory behind either.
        try? FileManager.default.removeItem(
            at: config.dataDir.appendingPathComponent("context/\(source.rawValue)")
        )
        _ = try store.deleteAll(source: source)
        if let activity = activitySource(source) {
            let blocks = ActivityBlockStore(db)
            for day in planned.days { try blocks.deleteBlocks(day: day, sources: [activity]) }
        }
        Log.net.info("removed \(planned.events) \(source.rawValue) events")
        return planned
    }

    /// Forgets what Worklens cached about the connection itself: the stored sync status. Not the
    /// events — those are `deleteSyncedData`'s, and only when you ask for them.
    public static func clearState(source: ContextSource, db: Database) throws {
        try AppStateStore(db).delete(SourceStatus.statusKey(source))
    }

    /// The credentials Worklens itself can remove for this source — the same keys its setup sheet
    /// writes. Google's pair is deliberately absent: its Disconnect revokes the OAuth *grant*
    /// through `GoogleAuth.disconnect()` and leaves the client id and secret, which are the app
    /// registration rather than the connection.
    public static func credentialKeys(for source: ContextSource) -> [String] {
        switch source {
        case .granola: return IntegrationSetup.fields(for: source).map(\.key)
        case .calendar: return []
        }
    }

    /// Where you go to take the grant away at the other end. Worklens cannot do this for you, so
    /// the card links to the page that can.
    public static func revokeURL(for source: ContextSource) -> URL {
        switch source {
        case .calendar: return URL(string: "https://myaccount.google.com/permissions")!
        case .granola: return URL(string: "https://app.granola.ai/settings")!
        }
    }

    /// `Revoke at Google…` — the menu item's own words.
    public static func revokeTitle(for source: ContextSource) -> String {
        switch source {
        case .calendar: return "Revoke at Google\u{2026}"
        case .granola: return "Revoke at Granola\u{2026}"
        }
    }

    private static func blockCount(source: ContextSource, db: Database) throws -> Int {
        guard let activity = activitySource(source) else { return 0 }
        return try db.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM activity_blocks WHERE source = ?",
                arguments: [activity.rawValue]
            ) ?? 0
        }
    }
}
