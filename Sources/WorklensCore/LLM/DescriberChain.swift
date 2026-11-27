import Foundation

/// Several summarizers tried in the order the person picked (`SUMMARY_PROVIDERS`), the first
/// that answers wins. A link that fails for a reason about the account rather than the
/// screenshot (not installed, signed out, the plan's limit, a key Gemini will not take, no
/// network) is skipped for a while, so a signed-out Claude costs one quick check every quarter
/// hour rather than one per screenshot: until the plan's reset time when the command named one,
/// otherwise `skipFor`.
///
/// Two more reasons to pass a link over without calling it (Part 4): a Claude plan fuller than
/// `SUBSCRIPTION_HEADROOM_PERCENT` is left to the person until its window resets, and a link that
/// costs money (Gemini) is not called once `DAILY_BUDGET_USD` is spent. A plan link is never held
/// by the budget.
///
/// A chain of one is never built (`SummaryProviders.describer` returns the link itself), so an
/// install with only Gemini set up behaves exactly as before.
public final class DescriberChain: VisionDescriber {
    public struct Link: Sendable {
        public let describer: any VisionDescriber
        /// The model a failure row in `llm_calls` names, since a failed call has no answer to
        /// read it from.
        public let model: String

        public init(_ describer: any VisionDescriber, model: String) {
            self.describer = describer
            self.model = model
        }
    }

    /// Every link failed. Carries the one that says the most: a failure about the screenshot
    /// when any link gave one, otherwise the first link's.
    public struct Failed: Error, CustomStringConvertible {
        public let provider: String
        public let model: String
        public let underlying: Error

        public var description: String {
            if let llm = underlying as? LLMError { return llm.description }
            return "\(underlying)"
        }
    }

    /// Every link that could have answered was passed over because the daily budget is spent.
    /// The worker leaves the screenshots waiting, exactly as when the budget stops a Gemini-only
    /// install before the call.
    public struct BudgetSpent: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "the daily budget is spent" }
    }

    public static let skipFor: TimeInterval = 15 * 60
    /// A reset time further out than this is not believed.
    static let longestSkip: TimeInterval = 7 * 24 * 60 * 60

    public let links: [Link]
    private let budget: (any CostGate)?
    private let now: @Sendable () -> Date
    private let skips = LockedBox([String: (until: Date, error: Error)]())

    /// - Parameter budget: asked before a link that costs money; nil calls every link.
    public init(
        _ links: [Link], budget: (any CostGate)? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(!links.isEmpty, "a describer chain needs at least one link")
        self.links = links
        self.budget = budget
        self.now = now
    }

    /// False once any link is a plan: the chain can then summarize with the budget spent, and
    /// asks the budget itself before each link that costs money.
    public var costsMoney: Bool { links.allSatisfy { $0.describer.costsMoney } }

    /// The first link's: what a row is labelled with when nothing more specific is known.
    public var provider: String { links[0].describer.provider }

    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        var first: Failed?
        var aboutTheFrame: Failed?
        var overBudget: Failed?
        for link in links {
            let name = link.describer.provider
            let instant = now()
            if let skip = skips.withLock({ $0[name] }), skip.until > instant {
                if first == nil { first = Failed(provider: name, model: link.model, underlying: skip.error) }
                continue
            }
            if let until = link.describer.headroomUntil(now: instant),
               let tool = SummaryProvider(rawValue: name)?.tool {
                let error = SubscriptionError.headroom(tool, resetsAt: until)
                skips.withLock { $0[name] = (until, error) }
                Log.describe.info("\(name) left for your own work until \(Self.stamp(until))")
                if first == nil { first = Failed(provider: name, model: link.model, underlying: error) }
                continue
            }
            if link.describer.costsMoney, let budget, !(await budget.allows(.describe)) {
                if overBudget == nil {
                    overBudget = Failed(provider: name, model: link.model, underlying: BudgetSpent())
                }
                continue
            }
            do {
                let response = try await link.describer.describe(request)
                skips.withLock { $0[name] = nil }
                return response.answered(by: response.provider ?? name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failed = Failed(provider: name, model: link.model, underlying: error)
                if first == nil { first = failed }
                if let until = Self.skipUntil(error, provider: name, now: instant) {
                    skips.withLock { $0[name] = (until, error) }
                    Log.describe.info("\(name) skipped until \(Self.stamp(until)) (\(Self.reason(error, provider: name)))")
                } else if aboutTheFrame == nil {
                    aboutTheFrame = failed
                }
                if link.describer.provider != links.last?.describer.provider {
                    Log.describe.info("\(name) did not summarize; trying the next")
                }
            }
        }
        // A spent budget outranks a sign-in or a plan limit: the screenshots wait on hold, the way
        // they do on a Gemini-only install, and the notices still name the plan.
        if let failed = aboutTheFrame ?? overBudget ?? first { throw failed }
        throw LLMError.missingAPIKey("SUMMARY_PROVIDERS")
    }

    /// When a failed link may be tried again, or nil for a failure about this screenshot, which
    /// says nothing about the next one.
    static func skipUntil(_ error: Error, provider: String, now: Date) -> Date? {
        if let subscription = error as? SubscriptionError {
            switch subscription {
            case let .usageLimit(_, resetsAt?) where resetsAt > now,
                 let .headroom(_, resetsAt) where resetsAt > now:
                return min(resetsAt, now.addingTimeInterval(longestSkip))
            case .failed:
                return nil
            default:
                return now.addingTimeInterval(skipFor)
            }
        }
        if let llm = error as? LLMError, case .serverError = llm {
            return now.addingTimeInterval(skipFor)
        }
        let failure = DescribeHealth.classify(error, provider: provider)
        return failure.isRefusal || failure.isUnreachable ? now.addingTimeInterval(skipFor) : nil
    }

    /// The links being skipped and why, for the notices (Part 2). An entry stays after its time
    /// runs out until a call through that link works, or `forgetSkip` is told the command is
    /// signed in again: a sign-in that stopped working is still a problem a quarter hour later.
    public func skipped() -> [SummaryNotices.Skip] {
        let entries = skips.withLock { $0 }
        return entries.compactMap { name, entry in
            guard let provider = SummaryProvider(rawValue: name) else { return nil }
            return SummaryNotices.Skip(
                provider: provider, until: entry.until,
                kind: DescribeHealth.classify(entry.error, provider: name).kind
            )
        }
    }

    /// Forgets why a link was skipped, so the next screenshot tries it first again. Called when
    /// a status check finds the command signed in with a plan, so signing back in moves the
    /// summaries back without waiting out the quarter hour.
    ///
    /// Room left in a plan is not about the sign-in, so it is kept until its window resets.
    public func forgetSkip(_ provider: SummaryProvider) {
        let instant = now()
        skips.withLock { skips in
            if let entry = skips[provider.rawValue], case .headroom? = entry.error as? SubscriptionError,
               entry.until > instant {
                return
            }
            skips[provider.rawValue] = nil
        }
    }

    /// Whether an error is the chain saying the budget is spent.
    public static func isBudgetSpent(_ error: Error) -> Bool {
        (error as? Failed)?.underlying is BudgetSpent
    }

    /// The link a chain's error came from, for the ledger and the menu. Nil for any other error.
    public static func failedLink(_ error: Error) -> (provider: String, model: String)? {
        guard let failed = error as? Failed else { return nil }
        return (failed.provider, failed.model)
    }

    private static func reason(_ error: Error, provider: String) -> String {
        DescribeHealth.classify(error, provider: provider).reason
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
