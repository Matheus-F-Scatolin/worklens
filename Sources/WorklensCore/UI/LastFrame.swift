import Foundation

/// What became of the newest frame Worklens wrote (#151).
///
/// The menu rows that drew this went with #299; the MCP `now` tool still reads `at` to say how
/// long ago the last screenshot was taken.
///
/// Pure data and pure functions. The store reads a row and `outcome(...)` decides which of the
/// ten endings it was — nothing here touches SwiftUI or a database.
public struct LastFrame: Equatable, Sendable {
    /// How the frame ended up, mapped straight from `describe_status`, `skip_reason` and the two
    /// privacy flags.
    public enum Outcome: String, Sendable, Equatable, CaseIterable {
        /// The vision model read it, or it inherited the reading of the frame before it.
        case described
        /// Queued for the vision model.
        case pending
        /// Three attempts, or nothing left to describe it from.
        case failed
        /// A blocklist matched the app, the window title or the host, so only the minute is on
        /// disk: no picture, no title, no URL.
        case blocked
        /// The model flagged the content sensitive. The summary is kept either way; whether the
        /// screenshot is deleted is `DELETE_SENSITIVE_SCREENSHOTS`, which Settings explains.
        case sensitive
        /// You were away from the keyboard.
        case idle
        /// The screen was locked.
        case locked
        /// The same window as the frame before it.
        case unchanged
        /// Today's budget was already spent when it came up for describing.
        case overBudget
        /// `CAPTURE_SOURCE=accessibility`, and the focused window exposed nothing to read.
        case noText
    }

    /// When the frame was taken.
    public var at: Date
    /// The app in front, as the row stored it. Nil for a blocked frame, which stores no name.
    public var appName: String?
    public var outcome: Outcome
    /// The stored summary, if the frame has one at all.
    public var summary: String?

    public init(at: Date, appName: String? = nil, outcome: Outcome, summary: String? = nil) {
        self.at = at
        self.appName = appName
        self.outcome = outcome
        self.summary = summary
    }

    /// The one place a stored row becomes an outcome.
    ///
    /// Blocked wins over everything: such a frame never reached the model, so its
    /// `describe_status` says nothing worth saying. Sensitive wins over described, because it is
    /// the half of the news a privacy-minded reader wants.
    public static func outcome(
        describeStatus: DescribeStatus,
        skipReason: SkipReason?,
        isRedacted: Bool,
        isSensitive: Bool
    ) -> Outcome {
        if isRedacted || skipReason?.isBlocked == true { return .blocked }
        if isSensitive { return .sensitive }
        switch describeStatus {
        case .described, .inherited: return .described
        case .pending: return .pending
        case .failed: return .failed
        case .skipped:
            switch skipReason {
            case .idle: return .idle
            case .locked, .asleep: return .locked
            case .budget: return .overBudget
            case .noText: return .noText
            default: return .unchanged
            }
        }
    }
}
