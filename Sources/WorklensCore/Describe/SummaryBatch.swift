import Foundation

/// `SUMMARY_BATCH`: how many screenshots go into one summary call.
public enum SummaryBatchMode: String, CaseIterable, Codable, Sendable {
    /// One screenshot per call, the way Worklens always worked.
    case each
    /// Whatever was captured over `SUMMARY_BATCH_MINUTES`, in one call.
    case every
    /// One call per stretch in one app: the batch closes when the frontmost app changes, at an
    /// idle or redacted row, or after `SUMMARY_BATCH_MINUTES` at the latest.
    case appSwitch = "app_switch"
}

/// The batch settings and the arithmetic around them. The planner itself is `BatchPlanner`.
public enum SummaryBatching {
    /// What `SUMMARY_BATCH_MINUTES` may say.
    public static let minuteChoices = [1, 5, 15, 30]
    public static let defaultMinutes = 5
    public static let defaultMaxSize = 10
    public static let maxSizeRange = 1...20

    /// The mode in effect. An unset `SUMMARY_BATCH` follows the first summarizer: a subscription
    /// summarizes per batch (`app_switch`), and Gemini alone keeps one screenshot per call, so an
    /// install with only a Gemini key behaves exactly as it did before batching existed.
    public static func mode(_ config: Config) -> SummaryBatchMode {
        if let chosen = config.summaryBatch { return chosen }
        switch SummaryProviders.effective(config).first {
        case .claude?, .codex?: return .appSwitch
        case .gemini?, nil: return .each
        }
    }

    /// `SUMMARY_BATCH_MAX`, held to its range whatever the file says.
    public static func maxSize(_ config: Config) -> Int {
        min(max(config.summaryBatchMax, maxSizeRange.lowerBound), maxSizeRange.upperBound)
    }

    static func minutes(_ key: String, _ value: String?) throws -> Int {
        let minutes = try Config.int(key, value, default: defaultMinutes)
        guard minuteChoices.contains(minutes) else {
            throw ConfigError.invalidEnum(key: key, value: value ?? "", allowed: minuteChoices.map(String.init))
        }
        return minutes
    }

    /// One call's usage, shared out over the `count` screenshots it described: each gets the
    /// same integer share, and the remainder goes one token at a time to the first ones, so the
    /// shares always add up to the call. Cost the same way, without the rounding.
    public static func shares(of usage: LLMUsage, costUSD: Double, count: Int) -> [(usage: LLMUsage, costUSD: Double)] {
        guard count > 0 else { return [] }
        func split(_ total: Int) -> [Int] {
            let base = total / count
            let extra = total % count
            return (0..<count).map { base + ($0 < extra ? 1 : 0) }
        }
        let prompt = split(usage.promptTokens)
        let output = split(usage.outputTokens)
        let thought = split(usage.thoughtTokens)
        let cached = split(usage.cachedTokens)
        let image = split(usage.imageTokens)
        return (0..<count).map { index in
            (
                LLMUsage(
                    promptTokens: prompt[index], outputTokens: output[index],
                    thoughtTokens: thought[index], cachedTokens: cached[index],
                    imageTokens: image[index]
                ),
                costUSD / Double(count)
            )
        }
    }
}

/// Which pending screenshots form the next summary calls, and when the next one is due.
///
/// Pure: the worker hands it the pending frames, oldest first, with the facts the database knows
/// about the rows between them, and sends whatever comes back as due. A batch that is not due
/// waits for a later cycle; a due one goes out whole.
public enum BatchPlanner {
    public struct Frame: Sendable, Equatable {
        public let id: String
        public let capturedAt: Date
        /// The frontmost app's bundle id.
        public let app: String?
        /// An idle, locked or redacted row, or a row from another app, sits between this frame
        /// and the pending frame before it: the same breaks `DescribeQueries.runContext` stops at.
        public let breakBefore: Bool
        /// The frame was in a call before and came back without a summary, so it goes alone.
        public let retryAlone: Bool

        public init(id: String, capturedAt: Date, app: String?, breakBefore: Bool = false, retryAlone: Bool = false) {
            self.id = id
            self.capturedAt = capturedAt
            self.app = app
            self.breakBefore = breakBefore
            self.retryAlone = retryAlone
        }
    }

    public struct Plan: Sendable, Equatable {
        /// The batches to send now, oldest first, each as frame ids in capture order.
        public let due: [[String]]
        /// When the first batch that is not due yet will be, or nil when nothing waits.
        public let nextDue: Date?
    }

    /// - Parameters:
    ///   - frames: every pending frame the worker looked at, oldest first.
    ///   - closedAfter: `app_switch` only: the app already changed (or an idle or redacted row
    ///     came) after the last of `frames`, so the run it ends is over.
    ///   - flush: every batch is due now, whatever its timer says. What `describe-pending` asks
    ///     for, since someone running it by hand wants the queue summarized, not scheduled.
    public static func plan(
        _ frames: [Frame],
        mode: SummaryBatchMode,
        minutes: Int,
        maxSize: Int,
        now: Date,
        closedAfter: Bool = false,
        flush: Bool = false
    ) -> Plan {
        let limit = max(1, maxSize)
        let window = TimeInterval(max(1, minutes) * 60)
        var due: [[String]] = []
        var index = 0
        while index < frames.count {
            let first = frames[index]
            if mode == .each || first.retryAlone || limit == 1 {
                due.append([first.id])
                index += 1
                continue
            }
            let windowEnd = first.capturedAt.addingTimeInterval(window)
            var batch = [first.id]
            var next = index + 1
            var closed = false
            while next < frames.count {
                let frame = frames[next]
                if batch.count == limit || frame.retryAlone || frame.capturedAt >= windowEnd {
                    closed = true
                    break
                }
                if mode == .appSwitch, frame.breakBefore || frame.app != first.app {
                    closed = true
                    break
                }
                batch.append(frame.id)
                next += 1
            }
            if batch.count == limit || now >= windowEnd || flush
                || (mode == .appSwitch && closedAfter && next == frames.count) {
                closed = true
            }
            guard closed else { return Plan(due: due, nextDue: windowEnd) }
            due.append(batch)
            index = next
        }
        return Plan(due: due, nextDue: nil)
    }
}
