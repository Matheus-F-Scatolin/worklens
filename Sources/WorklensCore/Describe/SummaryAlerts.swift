import Foundation

/// Which system notifications about summarizing through a plan are due (Part 4), and the
/// memory that makes each one go out once per occurrence. Pure: the app reads the memory from
/// `app_state`, asks `due`, posts what it answers and writes the new memory back.
///
/// - **Sign-in ending**: once with three days left and once with one, from the `loginExpiresAt`
///   `claude auth status` reports. A new expiry date means the person signed in again, which
///   starts both over. Codex reports no expiry, so a ChatGPT plan gets only the next one.
/// - **Sign-in ended**: once when a sign-in stops working (the expiry passed, a status check or
///   a call said signed out), and again only after a status check found it working in between,
///   so a skip running out and being recorded again is not a second occurrence.
/// - **Screenshots waiting**: once when the past-due backlog reaches
///   `SummaryNotices.backlogThreshold`, and again only after it dropped below it.
public enum SummaryAlerts {
    /// `app_state` key holding `Memory` as JSON.
    public static let memoryKey = "summary_alerts"
    /// The two warnings before a sign-in ends, furthest first.
    public static let expiryWarnings: [TimeInterval] = [3 * 86_400, 86_400]

    public enum Alert: Sendable, Equatable {
        case signInEnding(SubscriptionTool, expiresAt: Date)
        case signInEnded(SubscriptionTool)
        case screenshotsWaiting(Int)
    }

    public struct Memory: Codable, Sendable, Equatable {
        public struct Expiry: Codable, Sendable, Equatable {
            public var expiresAt: Date
            /// The tightest warning already sent: an entry of `expiryWarnings`.
            public var warned: TimeInterval
        }

        /// By `SubscriptionTool.rawValue`.
        public var expiry: [String: Expiry] = [:]
        public var signedOut: Set<String> = []
        public var backlog = false

        public init() {}

        public static func decode(_ raw: String?) -> Memory {
            guard let data = raw?.data(using: .utf8),
                  let memory = try? JSONDecoder().decode(Memory.self, from: data) else { return Memory() }
            return memory
        }

        public var encoded: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    /// What to post now, and the memory to keep.
    ///
    /// - Parameters:
    ///   - order: `SummaryProviders.effective`; a plan not in it says nothing.
    ///   - statuses: the last `claude auth status` / `codex login status`.
    ///   - signedOut: the plans whose sign-in is not working right now, whichever noticed first.
    ///   - waiting: past-due screenshots, or nil when not counted this time.
    public static func due(
        memory: Memory, order: [SummaryProvider], statuses: [SubscriptionTool: SubscriptionStatus],
        signedOut: Set<SubscriptionTool>, waiting: Int?, now: Date
    ) -> (alerts: [Alert], memory: Memory) {
        var memory = memory
        var alerts: [Alert] = []
        for tool in order.compactMap(\.tool) {
            let key = tool.rawValue
            if signedOut.contains(tool) {
                if !memory.signedOut.contains(key) {
                    memory.signedOut.insert(key)
                    alerts.append(.signInEnded(tool))
                }
                continue
            }
            if statuses[tool]?.isUsable(now: now) == true { memory.signedOut.remove(key) }

            guard let expiresAt = endingSoon(tool, statuses: statuses, now: now) else { continue }
            if memory.expiry[key]?.expiresAt != expiresAt { memory.expiry[key] = nil }
            let left = expiresAt.timeIntervalSince(now)
            guard let warning = expiryWarnings.last(where: { left <= $0 }) else { continue }
            if let sent = memory.expiry[key]?.warned, sent <= warning { continue }
            memory.expiry[key] = Memory.Expiry(expiresAt: expiresAt, warned: warning)
            alerts.append(.signInEnding(tool, expiresAt: expiresAt))
        }
        // A plan taken out of the order is forgotten, so putting it back starts clean.
        let inOrder = Set(order.compactMap(\.tool).map(\.rawValue))
        memory.signedOut = memory.signedOut.intersection(inOrder)
        memory.expiry = memory.expiry.filter { inOrder.contains($0.key) }

        if let waiting {
            if waiting >= SummaryNotices.backlogThreshold {
                if !memory.backlog {
                    memory.backlog = true
                    alerts.append(.screenshotsWaiting(waiting))
                }
            } else {
                memory.backlog = false
            }
        }
        return (alerts, memory)
    }

    /// When the plan's sign-in ends, if that is within the first warning and still ahead.
    public static func endingSoon(
        _ tool: SubscriptionTool, statuses: [SubscriptionTool: SubscriptionStatus], now: Date
    ) -> Date? {
        guard let status = statuses[tool], status.login == .subscription,
              let expiresAt = status.loginExpiresAt, expiresAt > now,
              expiresAt.timeIntervalSince(now) <= expiryWarnings[0] else { return nil }
        return expiresAt
    }

    /// The plans whose sign-in is not working now: a skip the chain recorded for it, or a status
    /// check that says signed out, including an expiry that has passed since.
    public static func signedOutTools(
        order: [SummaryProvider], skips: [SummaryNotices.Skip],
        statuses: [SubscriptionTool: SubscriptionStatus], now: Date
    ) -> Set<SubscriptionTool> {
        var tools: Set<SubscriptionTool> = []
        for provider in order {
            guard let tool = provider.tool else { continue }
            let skipped = skips.contains { skip in
                guard skip.provider == provider else { return false }
                switch skip.kind {
                case .signedOut, .notSubscription: return true
                default: return false
                }
            }
            if skipped || statuses[tool]?.blockingError(now: now) == .signedOut(tool) { tools.insert(tool) }
        }
        return tools
    }

    /// The first summarizer in the order that is not blocked, for "ChatGPT is summarizing".
    public static func summarizing(
        order: [SummaryProvider], skips: [SummaryNotices.Skip], signedOut: Set<SubscriptionTool>, now: Date
    ) -> SummaryProvider? {
        order.first { provider in
            if let tool = provider.tool, signedOut.contains(tool) { return false }
            return !skips.contains { $0.provider == provider && SummaryNotices.blocks($0, now: now) }
        }
    }

    /// Why screenshots still waiting at the day's rollover are waiting: `budget` when Gemini
    /// could have summarized them (or there is no plan at all, as before Part 4), `unavailable`
    /// when every summarizer in the order is out of reach.
    public static func staleReason(
        order: [SummaryProvider], skips: [SummaryNotices.Skip], signedOut: Set<SubscriptionTool>, now: Date
    ) -> SkipReason {
        guard order.contains(where: { $0.tool != nil }) else { return .budget }
        let free = summarizing(order: order, skips: skips, signedOut: signedOut, now: now)
        return free == nil ? .unavailable : .budget
    }
}
