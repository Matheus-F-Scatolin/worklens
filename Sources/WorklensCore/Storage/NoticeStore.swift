import Foundation

/// The notice log: the last `limit` notices, as JSON in one `app_state` row.
///
/// Persisted because the point of #110 is that a message can outlive the moment it appeared —
/// a 07:00 report failure nobody was awake for is still a failure at 09:00, and a relaunch is
/// not an answer to it. Small enough for a key/value row: thirty short strings.
public struct NoticeStore: Sendable {
    /// The `app_state` key holding the log.
    public static let stateKey = "notices"
    /// How many are kept. Enough for the Activity list to be a history, few enough that the row
    /// stays small.
    public static let limit = 30

    private let state: AppStateStore
    public init(_ state: AppStateStore) { self.state = state }
    public init(_ db: Database) { self.init(AppStateStore(db)) }

    /// Newest first. A row that cannot be decoded is treated as no history rather than as a
    /// failure: losing the log is not worth refusing to start.
    public func load() -> [Notice] {
        do {
            let stored: [Notice]? = try state.getCodable(NoticeStore.stateKey)
            return stored ?? []
        } catch {
            Log.ui.warn("the notice log could not be read; starting a new one")
            return []
        }
    }

    public func save(_ notices: [Notice]) {
        do {
            try state.setCodable(NoticeStore.stateKey, NoticeStore.trimmed(notices))
        } catch {
            Log.ui.warn("the notice log could not be written")
        }
    }

    /// The newest `limit`, open problems first so a long quiet day cannot push an unresolved
    /// problem out of the log.
    public static func trimmed(_ notices: [Notice]) -> [Notice] {
        guard notices.count > limit else { return notices }
        let open = notices.filter(\.isOpen)
        let rest = notices.filter { !$0.isOpen }
        let kept = open.prefix(limit)
        let room = limit - kept.count
        let extra = rest.sorted { $0.at > $1.at }.prefix(room)
        return (kept + extra).sorted { $0.at > $1.at }
    }
}
