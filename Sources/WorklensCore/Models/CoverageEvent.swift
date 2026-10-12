import Foundation
import GRDB

/// A change in whether Worklens was watching at all (#146).
///
/// `captures` rows say what was on screen; they cannot say anything about time when no tick ran.
/// A pause, a quit and a revoked Screen Recording grant all look identical to every reader of
/// that table — an afternoon with no rows — which is exactly the shape of an afternoon spent away
/// from the machine. One row per transition makes the difference answerable.
public enum CoverageKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// The scheduler's loop began: from here on, the day is covered.
    case started
    /// The loop is up but deliberately taking nothing. `reason` says why.
    case paused
    /// Back to capturing after a pause.
    case resumed
    /// The loop stopped — Stop in the menu, or the app on its way out.
    case stopped
}

/// Why capture stopped, for the `paused` transitions. These are the states the scheduler can
/// actually be in (`SchedulerState`): there is no battery pause and no low-power pause anywhere
/// in it, and the budget writes its own `captures` row rather than a transition.
public enum CoverageReason: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// The user asked: the ⌥⇧P hotkey, or Pause in the menu.
    case user
    /// Screen Recording was revoked or never granted, so every tick fails.
    case permissionMissing = "permission_missing"
}

/// One row of `coverage_events`. Content-free by construction: a timestamp, a transition and, for
/// a pause, which of two reasons it was. Nothing about what was on screen — the same promise
/// `PRIVACY.md` already makes for a pause, which until this issue nothing kept.
public struct CoverageEvent: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable,
    Identifiable
{
    public static let databaseTableName = "coverage_events"

    public var id: String
    public var at: Date
    /// A `CoverageKind` raw value, kept as a string for the reason `foreground_sessions.source`
    /// is one: a later issue can add a transition without a migration.
    public var kind: String
    /// A `CoverageReason` raw value, and only meaningful beside `paused`.
    public var reason: String?

    public init(
        id: String = Identifiers.new(),
        at: Date,
        kind: CoverageKind,
        reason: CoverageReason? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind.rawValue
        self.reason = reason?.rawValue
    }

    public var coverageKind: CoverageKind? { CoverageKind(rawValue: kind) }
    public var coverageReason: CoverageReason? { reason.flatMap(CoverageReason.init(rawValue:)) }

    /// What this transition means for the record: the gap it opens, or nil when it closes one.
    /// An unknown `kind` reads as "covered" rather than as a gap — a row this build cannot
    /// understand must not invent an afternoon Worklens was not watching.
    public var opensGap: CoverageGapReason? {
        switch coverageKind {
        case .stopped: return .notRunning
        case .paused: return coverageReason == .permissionMissing ? .permissionMissing : .paused
        case .started, .resumed, .none: return nil
        }
    }
}
