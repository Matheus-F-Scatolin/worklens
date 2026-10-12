import Foundation
import GRDB

/// When the sample week shows itself, and when it hands over to your own day (#349, #350).
///
/// The whole rule, as pure functions over a few facts, so "leave now / notify now / never again"
/// is tested without a window, a notification centre or a describe worker.
public enum SampleWeekHandoff {
    /// `app_state` keys, on the **real** ledger: these are facts about your install.
    public enum Key {
        /// When your first real summary arrived and the sample handed over. Once ever.
        public static let handedOffAt = "sample_week_handed_off_at"
        /// When you left the sample week with its button. It is not shown by itself again.
        public static let leftAt = "sample_week_left_at"
    }

    /// What the real ledger says, read once.
    public struct Facts: Sendable, Equatable {
        /// The handoff already happened, or this install had summaries before the sample existed.
        public var handedOff: Bool
        /// You left the sample week yourself.
        public var left: Bool
        /// The real ledger holds at least one summarized screenshot.
        public var hasSummaries: Bool
        /// When the earliest summarized screenshot was taken, or nil when there is none.
        public var firstSummaryAt: Date?

        public init(
            handedOff: Bool = false, left: Bool = false, hasSummaries: Bool = false,
            firstSummaryAt: Date? = nil
        ) {
            self.handedOff = handedOff
            self.left = left
            self.hasSummaries = hasSummaries
            self.firstSummaryAt = firstSummaryAt
        }

        /// Reads the three facts off the real ledger.
        public static func read(_ db: Database) -> Facts {
            let store = AppStateStore(db)
            let first = (try? db.writer.read { db in
                try Date.fetchOne(db, sql: """
                    SELECT MIN(captured_at) FROM captures WHERE describe_status IN (?, ?)
                    """, arguments: [DescribeStatus.described.rawValue, DescribeStatus.inherited.rawValue])
            }) ?? nil
            return Facts(
                handedOff: ((try? store.getDate(Key.handedOffAt)) ?? nil) != nil,
                left: ((try? store.getDate(Key.leftAt)) ?? nil) != nil,
                hasSummaries: first != nil,
                firstSummaryAt: first
            )
        }
    }

    /// What the app should do at launch.
    public enum LaunchDecision: Sendable, Equatable {
        /// Nothing: the handoff is behind this install.
        case nothing
        /// The real ledger already has summaries from before the sample existed: record the
        /// handoff without a notification, so nobody with months of history is told their day
        /// has started.
        case recordSilently
        /// The real ledger's first summaries are recent, written while the app was not watching
        /// (`worklens describe-pending`, or a quit right after the first one): this is still your
        /// first day, so record the handoff and post the one notification.
        case handOver
        /// Show the sample week, because there is nothing of yours to show yet.
        case show
        /// Nothing of yours yet, but you left the sample week yourself: leave it closed.
        case stayClosed
    }

    /// How recent your earliest summary has to be for a launch to still count as your first
    /// day. Older than this, the summaries predate the sample week and the handoff is silent.
    public static let firstDayWindow: TimeInterval = 24 * 60 * 60

    public static func atLaunch(_ facts: Facts, now: Date = Date()) -> LaunchDecision {
        if facts.handedOff { return .nothing }
        if facts.hasSummaries {
            if let first = facts.firstSummaryAt, now.timeIntervalSince(first) < firstDayWindow {
                return .handOver
            }
            return .recordSilently
        }
        return facts.left ? .stayClosed : .show
    }

    /// What one summarized screenshot means.
    public struct Decision: Sendable, Equatable {
        /// Point the reader back at the real ledger.
        public var leave: Bool
        /// Post "Your day has started."
        public var notify: Bool
        /// Persist the handoff, so none of this happens again.
        public var record: Bool

        public init(leave: Bool = false, notify: Bool = false, record: Bool = false) {
            self.leave = leave
            self.notify = notify
            self.record = record
        }

        public static let none = Decision()
    }

    /// A screenshot was summarized into the real ledger by `provider`.
    ///
    /// - The first one from a real provider hands over: leave the sample if it is showing,
    ///   notify once, and record it, whether or not you had already left the sample yourself.
    /// - Every one after that (or any at all once the handoff is recorded) does nothing, which
    ///   is what keeps a sample you re-open from Settings from being closed under you.
    /// - The offline fake never counts: it is not your day.
    public static func onSummary(provider: String, isShowingSample: Bool, handedOff: Bool) -> Decision {
        guard !handedOff, provider != FakeProvider.name else { return .none }
        return Decision(leave: isShowingSample, notify: true, record: true)
    }

    /// The ribbon's second line once the welcome is finished: what happens next, or what is
    /// stopping it, in the menu's own words. It covers the gap between pressing Done and your
    /// first real summary, so it is nil while the welcome is still open and nil once the handoff
    /// is behind you (a sample re-opened from Settings has nothing to promise).
    public static func statusLine(
        setup: SetupProgress,
        handedOff: Bool,
        scheduler: SchedulerState,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard setup.onboarded, !handedOff else { return nil }
        if !setup.screenRecording {
            return MenuModel.statusRow(menuState(.permissionMissing, locale), now: now, timeZone: timeZone).text
        }
        if !setup.geminiKey { return MenuModel.firstRunText }
        switch scheduler {
        // Stopped (start-on-launch off, or capture never started): nothing arrives in a minute,
        // so the menu's own word, not a promise.
        case .paused, .budgetExceeded, .permissionMissing, .stopped:
            return MenuModel.statusRow(menuState(scheduler, locale), now: now, timeZone: timeZone).text
        case .running, .idle, .locked, .asleep:
            return SampleWeekCopy.firstMoments
        }
    }

    private static func menuState(_ scheduler: SchedulerState, _ locale: Locale) -> MenuState {
        var state = MenuState(locale: locale)
        state.scheduler = scheduler
        return state
    }
}
