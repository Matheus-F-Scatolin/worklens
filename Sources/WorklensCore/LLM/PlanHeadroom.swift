import Foundation

/// Leaving room in a Claude plan for the person's own work (`SUBSCRIPTION_HEADROOM_PERCENT`).
///
/// Every `claude -p` call reports the plan's windows (`ClaudeRateLimits`): how full the five-hour
/// and the weekly window are, and when each resets. Once one is at the threshold, Worklens stops
/// summarizing through the plan until that window resets, and the next way of summarizing takes
/// over. The plan is the person's first; screenshots are not worth hitting its limit for.
///
/// Codex reports its windows only over `codex app-server`, a long-lived JSON-RPC session marked
/// experimental, so a ChatGPT plan is left alone until it says it is at its limit
/// (`docs/decisions.md`).
public enum PlanHeadroom {
    public static let defaultPercent = 80
    /// What Settings → Advanced offers, plus the current value when the file set another.
    public static func choices(current: Int) -> [Int] {
        let offered = [50, 60, 70, 80, 90, 100]
        return offered.contains(current) ? offered : (offered + [current]).sorted()
    }

    public static let percentRange = 10...100
    /// A full window that named no reset time is believed for this long after it was read, the
    /// same quarter hour a signed-out link is skipped for.
    public static let unknownResetHold: TimeInterval = DescriberChain.skipFor

    /// Until when the plan should be left alone, or nil to keep summarizing through it.
    ///
    /// A window counts once it is at the threshold or above it, and only until its reset time; a
    /// window past its reset time is a stale reading and says nothing. At 100 nothing is ever
    /// held back: the plan's own limit (`SubscriptionError.usageLimit`) is the only stop.
    public static func until(
        _ limits: ClaudeRateLimits?, observedAt: Date?, percent: Int, now: Date
    ) -> Date? {
        guard let limits, let observedAt else { return nil }
        let percent = min(max(percent, percentRange.lowerBound), percentRange.upperBound)
        guard percent < 100 else { return nil }
        let threshold = Double(percent) / 100
        var latest: Date?
        for window in limits.windows.values where window.utilization >= threshold - 1e-9 {
            let lifts: Date
            if let resetsAt = window.resetsAt {
                guard resetsAt > now else { continue }
                lifts = resetsAt
            } else {
                lifts = observedAt.addingTimeInterval(unknownResetHold)
                guard lifts > now else { continue }
            }
            latest = max(latest ?? lifts, lifts)
        }
        return latest.map { min($0, now.addingTimeInterval(DescriberChain.longestSkip)) }
    }
}
