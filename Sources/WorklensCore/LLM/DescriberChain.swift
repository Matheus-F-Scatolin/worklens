import Foundation

/// Several summarizers tried in the order the person picked (`SUMMARY_PROVIDERS`), the first
/// that answers wins. A link that fails for a reason about the account rather than the
/// screenshot (not installed, signed out, the plan's limit, a key Gemini will not take, no
/// network) is skipped for a while, so a signed-out Claude costs one quick check every quarter
/// hour rather than one per screenshot: until the plan's reset time when the command named one,
/// otherwise `skipFor`.
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

    public static let skipFor: TimeInterval = 15 * 60
    /// A reset time further out than this is not believed.
    static let longestSkip: TimeInterval = 7 * 24 * 60 * 60

    public let links: [Link]
    private let now: @Sendable () -> Date
    private let skips = LockedBox([String: (until: Date, error: Error)]())

    public init(_ links: [Link], now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(!links.isEmpty, "a describer chain needs at least one link")
        self.links = links
        self.now = now
    }

    /// The first link's: what a row is labelled with when nothing more specific is known.
    public var provider: String { links[0].describer.provider }

    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        var first: Failed?
        var aboutTheFrame: Failed?
        for link in links {
            let name = link.describer.provider
            let instant = now()
            if let skip = skips.withLock({ $0[name] }), skip.until > instant {
                if first == nil { first = Failed(provider: name, model: link.model, underlying: skip.error) }
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
        if let failed = aboutTheFrame ?? first { throw failed }
        throw LLMError.missingAPIKey("SUMMARY_PROVIDERS")
    }

    /// When a failed link may be tried again, or nil for a failure about this screenshot, which
    /// says nothing about the next one.
    static func skipUntil(_ error: Error, provider: String, now: Date) -> Date? {
        if let subscription = error as? SubscriptionError {
            switch subscription {
            case let .usageLimit(_, resetsAt?) where resetsAt > now:
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
