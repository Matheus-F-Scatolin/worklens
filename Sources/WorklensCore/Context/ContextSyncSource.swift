import Foundation

/// One external system Worklens pulls the user's own activity from.
///
/// Naming note: `ContextSource` was already taken by the persisted enum on `context_events`
/// (`granola | calendar`), so the protocol issue #19 sketches is spelled
/// `ContextSyncSource` and its `id` is that enum rather than a free-form string — the two can
/// then never disagree about what a row's `source` column may contain.
public protocol ContextSyncSource: Sendable {
    var id: ContextSource { get }
    var displayName: String { get }

    /// Whether the credentials this source needs are present. No network.
    func isConfigured(_ config: Config) -> Bool

    /// Pulls everything in `window` into `store`, idempotently.
    ///
    /// Implementations must upsert on `(source, external_id)` and must never store anyone's
    /// content but the user's own.
    func sync(window: DateInterval, into store: ContextEventStore, config: Config) async throws -> SyncResult
}

/// What one `sync` did. `warnings` are shown in Settings → Integrations; they describe a partial
/// success (a page that failed, a scope that is missing for one call), not a thrown error.
public struct SyncResult: Sendable, Equatable, Codable {
    public var inserted: Int
    public var updated: Int
    public var skipped: Int
    public var warnings: [String]

    public init(inserted: Int = 0, updated: Int = 0, skipped: Int = 0, warnings: [String] = []) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.warnings = warnings
    }

    public var touched: Int { inserted + updated }

    public static func + (lhs: SyncResult, rhs: SyncResult) -> SyncResult {
        SyncResult(
            inserted: lhs.inserted + rhs.inserted,
            updated: lhs.updated + rhs.updated,
            skipped: lhs.skipped + rhs.skipped,
            warnings: lhs.warnings + rhs.warnings
        )
    }

    public static func += (lhs: inout SyncResult, rhs: SyncResult) { lhs = lhs + rhs }

    /// `3 new, 1 updated, 12 unchanged`.
    public var summary: String {
        "\(inserted) new, \(updated) updated, \(skipped) unchanged"
    }
}

/// What Settings → Integrations shows for one source.
public struct SourceStatus: Sendable, Equatable {
    public var id: ContextSource
    public var displayName: String
    public var isConfigured: Bool
    public var lastSyncAt: Date?
    /// The last failure, as a sentence a person can act on. Cleared by the next success.
    public var lastError: String?
    /// Whether that failure was the credential being refused or missing rather than a network or
    /// service problem (#135). The Integrations card shows those as a state of their own —
    /// something to fix with one paste — instead of a red error line.
    public var lastErrorWasCredential: Bool
    /// Whether the last failure is one only you can clear — a refused credential, a grant that
    /// was revoked, a source that used to be configured and is not any more (#141). Those raise a
    /// menu line and one notification; everything else stays on the Integrations tab.
    public var lastErrorIsActionable: Bool
    /// #139: the Google grant this source syncs with has expired, and only a new consent brings
    /// it back. A typed flag rather than a match on `lastError`'s sentence — that string exists
    /// to be read by a person, and rewording it must not silently turn the Reconnect button off.
    public var needsReconnect: Bool
    public var lastWarnings: [String]
    /// Rows this source currently owns in `context_events`.
    public var eventCount: Int
    /// How many events the last successful round added — the `4 new meetings` half of the line.
    public var lastInserted: Int
    public var consecutiveFailures: Int
    /// When the last failure happened. Persisted so `retryAfter` can be re-derived after a
    /// relaunch instead of silently becoming "due now" (#141).
    public var lastFailureAt: Date?
    /// When the current actionable failure was announced, so one incident is announced once.
    public var notifiedFailureAt: Date?
    /// While set, the scheduler leaves this source alone — see `ContextSyncScheduler.backoff`.
    public var retryAfter: Date?

    public init(
        id: ContextSource,
        displayName: String,
        isConfigured: Bool = false,
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        lastErrorWasCredential: Bool = false,
        lastErrorIsActionable: Bool = false,
        needsReconnect: Bool = false,
        lastWarnings: [String] = [],
        eventCount: Int = 0,
        lastInserted: Int = 0,
        consecutiveFailures: Int = 0,
        lastFailureAt: Date? = nil,
        notifiedFailureAt: Date? = nil,
        retryAfter: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isConfigured = isConfigured
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.lastErrorWasCredential = lastErrorWasCredential
        self.lastErrorIsActionable = lastErrorIsActionable
        self.needsReconnect = needsReconnect
        self.lastWarnings = lastWarnings
        self.eventCount = eventCount
        self.lastInserted = lastInserted
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureAt = lastFailureAt
        self.notifiedFailureAt = notifiedFailureAt
        self.retryAfter = retryAfter
    }

    /// What a source whose Google grant expired says — in Settings and in `context status` alike
    /// (#139). It is not an error the user did anything to cause: nothing is broken, the seven
    /// days Google allows a Testing consent screen simply ran out.
    public static let pausedLine = "Paused until you reconnect"

    /// The one line Settings → Integrations prints.
    ///
    /// Two things #141 changed. The stamp is no longer a bare `HH:mm`, which said nothing about
    /// the day it belonged to and read the same at 18:40 yesterday as at 18:40 today; and the
    /// count is the last round's own, because "4 new meetings" is what says the connection is
    /// alive, where a total of 2 314 events looks identical whether the last round worked or has
    /// been failing silently for a fortnight.
    public func line(timeZone: TimeZone = .current, now: Date = Date()) -> String {
        guard isConfigured else { return "Not configured" }
        // #139 before #141: an expired grant is an actionable failure too, so it also carries a
        // `lastError` and a `retryAfter` — but "Error: ... Retrying at 18:40" promises a retry
        // that cannot work, and nothing is broken. The state the user can act on wins the line.
        if needsReconnect { return SourceStatus.pausedLine }
        if let lastError {
            guard let retryAfter, retryAfter > now else { return "Error: \(lastError)" }
            return "Error: \(lastError) \u{b7} Retrying at \(SourceStatus.clock(retryAfter, timeZone))"
        }
        guard let lastSyncAt else { return "Connected \u{b7} never synced" }
        return "\(SourceStatus.stamp(lastSyncAt, now: now, timeZone: timeZone)) \u{b7} \(newLine)"
    }

    /// `4 new meetings`, `0 new`.
    var newLine: String {
        guard lastInserted > 0 else { return "0 new" }
        return "\(lastInserted) new \(SourceStatus.noun(id, count: lastInserted))"
    }

    /// `Synced 3 min ago`, `Yesterday 18:40`, `Sep 12 18:40`.
    ///
    /// Hand-rolled rather than `RelativeDateTimeFormatter`: this string is asserted in tests and
    /// drawn in a menu, and that formatter's wording moves with the user's locale — its
    /// abbreviated style spells "3 min. ago", with a full stop.
    static func stamp(_ at: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(at, inSameDayAs: now) {
            let seconds = max(0, now.timeIntervalSince(at))
            if seconds < 60 { return "Synced just now" }
            if seconds < 3600 { return "Synced \(Int(seconds / 60)) min ago" }
            return "Synced \(Int(seconds / 3600)) h ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(at, inSameDayAs: yesterday) {
            return "Yesterday \(clock(at, timeZone))"
        }
        return "\(date(at, timeZone)) \(clock(at, timeZone))"
    }

    /// What this source's new rows are called, so the line counts the thing it names.
    static func noun(_ source: ContextSource, count: Int) -> String {
        switch source {
        case .granola, .calendar: return count == 1 ? "meeting" : "meetings"
        }
    }

    static func clock(_ at: Date, _ timeZone: TimeZone) -> String {
        formatter("HH:mm", timeZone).string(from: at)
    }

    static func date(_ at: Date, _ timeZone: TimeZone) -> String {
        formatter("MMM d", timeZone).string(from: at)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Persistence (#141)

public extension SourceStatus {
    /// `app_state` keys, one per source, so a relaunch does not show "never synced" for a source
    /// holding thousands of events. Declared on the type that owns the value, per
    /// `docs/architecture.md` -> "Where a key lives".
    static let statusKeyPrefix = "context_sync_status_"

    static func statusKey(_ source: ContextSource) -> String { statusKeyPrefix + source.rawValue }

    /// The half of a status that outlives the process. `isConfigured`, `displayName` and
    /// `eventCount` are re-derived at init from the configuration and the database, so storing
    /// them would only create two answers to the same question.
    struct Persisted: Codable, Sendable, Equatable {
        public var lastSyncAt: Date?
        public var lastInserted: Int
        public var lastError: String?
        public var lastErrorWasCredential: Bool
        public var lastErrorIsActionable: Bool
        /// #139. Persisted for the same reason as the rest: a relaunch must not quietly drop the
        /// Reconnect button and the paused line until the next round happens to fail again.
        public var needsReconnect: Bool
        public var lastWarnings: [String]
        public var consecutiveFailures: Int
        public var lastFailureAt: Date?
        public var notifiedFailureAt: Date?

        public init(
            lastSyncAt: Date? = nil,
            lastInserted: Int = 0,
            lastError: String? = nil,
            lastErrorWasCredential: Bool = false,
            lastErrorIsActionable: Bool = false,
            needsReconnect: Bool = false,
            lastWarnings: [String] = [],
            consecutiveFailures: Int = 0,
            lastFailureAt: Date? = nil,
            notifiedFailureAt: Date? = nil
        ) {
            self.lastSyncAt = lastSyncAt
            self.lastInserted = lastInserted
            self.lastError = lastError
            self.lastErrorWasCredential = lastErrorWasCredential
            self.lastErrorIsActionable = lastErrorIsActionable
            self.needsReconnect = needsReconnect
            self.lastWarnings = lastWarnings
            self.consecutiveFailures = consecutiveFailures
            self.lastFailureAt = lastFailureAt
            self.notifiedFailureAt = notifiedFailureAt
        }

        /// Decoded key by key, every one optional, because this blob outlives the build that
        /// wrote it: #139 adds `needsReconnect` to what #141 already stored, and a synthesised
        /// decoder would throw `keyNotFound` on yesterday's row and silently reset the status.
        /// A missing key means "not known", which is what the default already says.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
            lastInserted = try c.decodeIfPresent(Int.self, forKey: .lastInserted) ?? 0
            lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
            lastErrorWasCredential =
                try c.decodeIfPresent(Bool.self, forKey: .lastErrorWasCredential) ?? false
            lastErrorIsActionable =
                try c.decodeIfPresent(Bool.self, forKey: .lastErrorIsActionable) ?? false
            needsReconnect = try c.decodeIfPresent(Bool.self, forKey: .needsReconnect) ?? false
            lastWarnings = try c.decodeIfPresent([String].self, forKey: .lastWarnings) ?? []
            consecutiveFailures =
                try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
            lastFailureAt = try c.decodeIfPresent(Date.self, forKey: .lastFailureAt)
            notifiedFailureAt = try c.decodeIfPresent(Date.self, forKey: .notifiedFailureAt)
        }
    }

    var persisted: Persisted {
        Persisted(
            lastSyncAt: lastSyncAt,
            lastInserted: lastInserted,
            lastError: lastError,
            lastErrorWasCredential: lastErrorWasCredential,
            lastErrorIsActionable: lastErrorIsActionable,
            needsReconnect: needsReconnect,
            lastWarnings: lastWarnings,
            consecutiveFailures: consecutiveFailures,
            lastFailureAt: lastFailureAt,
            notifiedFailureAt: notifiedFailureAt
        )
    }

    /// The status one source starts a launch with: what the configuration says, what the
    /// database holds, and the last round out of `app_state` (#141).
    ///
    /// Used by `ContextSyncScheduler.init`.
    static func load(source: any ContextSyncSource, config: Config, db: Database) -> SourceStatus {
        let store = ContextEventStore(db)
        var status = SourceStatus(
            id: source.id,
            displayName: source.displayName,
            isConfigured: source.isConfigured(config),
            eventCount: (try? store.count(source: source.id)) ?? 0
        )
        if let stored: Persisted = try? AppStateStore(db).getCodable(statusKey(source.id)) {
            status.restore(stored)
        } else if let seen = try? store.lastSyncedAt(source: source.id) {
            // A grant that predates this: the newest row it stored is the best answer there is to
            // "when did this last work".
            status.lastSyncAt = seen
        }
        return status
    }

    /// Puts a stored round back, and re-derives `retryAfter` from the failure count rather than
    /// storing a deadline that would be meaningless after the Mac slept through it.
    mutating func restore(_ stored: Persisted) {
        lastSyncAt = stored.lastSyncAt
        lastInserted = stored.lastInserted
        lastError = stored.lastError
        lastErrorWasCredential = stored.lastErrorWasCredential
        lastErrorIsActionable = stored.lastErrorIsActionable
        needsReconnect = stored.needsReconnect
        lastWarnings = stored.lastWarnings
        consecutiveFailures = stored.consecutiveFailures
        lastFailureAt = stored.lastFailureAt
        notifiedFailureAt = stored.notifiedFailureAt
        retryAfter = stored.lastFailureAt.map {
            $0.addingTimeInterval(ContextSyncScheduler.backoff(after: stored.consecutiveFailures))
        }
    }
}

/// Failures every source shares, phrased for the Integrations panel rather than for a log.
public enum ContextSyncError: Error, Equatable, CustomStringConvertible {
    case notConfigured(String)
    /// The credential is present but rejected. `detail` names the fix.
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int, String)
    case decode(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case let .notConfigured(key): return "\(key) is not set"
        case let .unauthorized(detail): return detail
        case let .rateLimited(retryAfter):
            return retryAfter.map { "rate limited; retry in \(Int($0))s" } ?? "rate limited"
        case let .http(status, body): return "HTTP \(status): \(body)"
        case let .decode(detail): return "could not decode the response: \(detail)"
        case let .unavailable(detail): return detail
        }
    }
}

// MARK: - Actionable or transient (#141)

public extension ContextSyncError {
    /// Whether a failure is one nothing but you can clear.
    ///
    /// The line this draws is not "was it the credential" — `isCredential` already answers that,
    /// and it is the right question for a card that offers a paste. This is the question the
    /// *menu* asks: is waiting going to fix it? A rate limit, a 5xx and a decode failure all
    /// clear themselves, so they stay on the Integrations tab. A refused token, a revoked grant
    /// and a source that was configured and is not any more never clear themselves, and a
    /// revoked token quietly draining context out of the timeline for a fortnight is the whole
    /// complaint behind #141.
    ///
    /// - Parameter hadSynced: whether this source has ever completed a round. A source that was
    ///   never set up is not a problem to announce — `.notConfigured` is its resting state.
    static func isActionable(_ error: any Error, hadSynced: Bool) -> Bool {
        switch error {
        case let error as ContextSyncError:
            switch error {
            case .unauthorized: return true
            case .notConfigured: return hadSynced
            // 401 and 403 reach us as `.unauthorized` from every source that knows what it got;
            // a raw one still means the same thing.
            case let .http(status, _): return status == 401 || status == 403
            case .rateLimited, .decode, .unavailable: return false
            }
        case let error as GoogleAuth.Failure:
            switch error {
            case .notConnected, .noRefreshToken, .invalidGrant, .declined: return true
            case .notConfigured: return hadSynced
            case .stateMismatch: return false
            }
        default:
            return false
        }
    }
}
