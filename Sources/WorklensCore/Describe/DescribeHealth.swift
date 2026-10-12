import Foundation

/// Whether the describe queue is moving, and — when it is not — the one sentence that says why.
///
/// #125: every describe failure used to end in `llm_calls` and the log, so a mistyped API key
/// looked exactly like a healthy day: the menu kept saying "Capturing", frames drained out of
/// `pending`, and $0.00 was spent. `DescribeWorker` raises one of these instead, `AppModel`
/// stores it on `MenuState`, and the menu says it in words.
///
/// The message is always an error *class* — "Gemini rejected the key" — never the provider's
/// response body, which can quote the request back. The body still reaches `llm_calls`, which is
/// local and already holds the rest of the call.
public enum DescribeHealth: Sendable, Equatable {
    /// Frames are being summarized, or there are none waiting.
    case ok
    /// Nothing is wrong with the provider's answer — it never arrived. The queue is waiting out
    /// a backoff and will try again by itself, so this never touches the menu-bar icon.
    case holding(until: Date, reason: String)
    /// The provider answered and would not do the work, or the same failure keeps repeating.
    /// Nothing is being summarized until something changes.
    case failing(message: String, httpStatus: Int?)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    /// Only `.failing` earns the attention icon: a hold clears itself, and a badge for a laptop
    /// that was offline for a minute is noise.
    public var isFailing: Bool {
        if case .failing = self { return true }
        return false
    }

    /// Whether moving from `was` to this state is the moment the user is owed a banner.
    ///
    /// The gate is the *failing* edge, not the `.ok` edge: a stall reached the long way round —
    /// offline for a while, so `.holding`, and then a key the provider will not accept — is
    /// still the first moment nothing is being summarized, and the banner is the only surface
    /// the user sees with the menu closed. One stretch of `.failing` announces itself once,
    /// however many times the message changes inside it.
    public func startsStall(after was: DescribeHealth) -> Bool {
        isFailing && !was.isFailing
    }

    /// The HTTP status the provider answered with, when there was one.
    public var httpStatus: Int? {
        if case let .failing(_, status) = self { return status }
        return nil
    }

    /// Whether this is the provider saying no to the key itself, which is the one describe
    /// failure with an obvious fix. A 400 is here because Gemini answers `API_KEY_INVALID`
    /// with one.
    public var isKeyRejection: Bool {
        guard let status = httpStatus else { return false }
        return status == 400 || status == 401 || status == 403
    }

    /// The menu row. Nil while summarizing normally — there is nothing to say about a working
    /// pipeline that the counts line does not already say.
    public func line(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        switch self {
        case .ok:
            return nil
        case let .holding(until, reason):
            guard until > now else { return "Not summarizing: \(reason); trying again now" }
            return "Not summarizing: \(reason); trying again at "
                + DescribeHealth.clock(until, timeZone: timeZone)
        case let .failing(message, status):
            guard let status else { return "Not summarizing: \(message)" }
            return "Not summarizing: \(message) (HTTP \(status))"
        }
    }

    /// What Settings → Models & cost puts next to "Summarizing". Settings has room for a calm
    /// sentence when nothing is wrong; the menu does not.
    public func settingsLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        line(now: now, timeZone: timeZone) ?? "Running normally"
    }

    /// When the last frame was summarized, in words. Nil is a machine that has never described
    /// anything, which is a different sentence from "not lately".
    public static func lastSummaryLine(
        _ at: Date?, now: Date = Date(), timeZone: TimeZone = .current
    ) -> String {
        guard let at else { return "No frames summarized yet" }
        let clock = DescribeHealth.clock(at, timeZone: timeZone)
        let day = DayBoundaries.dayString(at, timeZone: timeZone)
        return day == DayBoundaries.dayString(now, timeZone: timeZone)
            ? "Today at \(clock)"
            : "\(day) at \(clock)"
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Classifying a failure

    /// One describe failure, named by class. Built from the error and nothing else, so the same
    /// value can be logged, shown and compared without ever carrying a response body.
    public struct Failure: Sendable, Equatable {
        /// The sentence fragment the menu shows: "Gemini rejected the key".
        public let reason: String
        public let httpStatus: Int?
        /// The provider looked at the request and said no for a reason that is not about this
        /// frame — a key it will not accept, a quota that is spent. Retrying the frame cannot
        /// help, and spending its three attempts on it would throw the frame away.
        public let isRefusal: Bool
        /// The provider was never reached.
        public let isUnreachable: Bool

        public init(reason: String, httpStatus: Int?, isRefusal: Bool, isUnreachable: Bool) {
            self.reason = reason
            self.httpStatus = httpStatus
            self.isRefusal = isRefusal
            self.isUnreachable = isUnreachable
        }
    }

    /// `gemini` → `Gemini`. The provider string is a ledger value; the menu is a sentence.
    public static func providerName(_ provider: String) -> String {
        guard let first = provider.first else { return provider }
        return first.uppercased() + provider.dropFirst()
    }

    /// The answer arrived twice and did not fit the schema either time. Evidence about the model,
    /// not about the key or the network.
    public static func schemaFailure(provider: String) -> Failure {
        Failure(
            reason: "\(providerName(provider))'s answers did not fit the schema",
            httpStatus: nil, isRefusal: false, isUnreachable: false
        )
    }

    /// What went wrong, in the words the user reads. Never quotes the response body: a 400 body
    /// is matched for Gemini's `API_KEY_INVALID` marker and then thrown away.
    public static func classify(_ error: Error, provider: String) -> Failure {
        let name = providerName(provider)
        guard let llm = error as? LLMError else {
            if error is URLError {
                return Failure(
                    reason: "\(name) is unreachable", httpStatus: nil,
                    isRefusal: false, isUnreachable: true
                )
            }
            return Failure(
                reason: "the describe call failed", httpStatus: nil,
                isRefusal: false, isUnreachable: false
            )
        }
        switch llm {
        case let .missingAPIKey(key):
            return Failure(
                reason: "\(key) is not set", httpStatus: nil,
                isRefusal: true, isUnreachable: false
            )
        case let .badRequest(status, body):
            if status == 401 || status == 403 || DescribeHealth.saysKeyInvalid(body) {
                return Failure(
                    reason: "\(name) rejected the key", httpStatus: status,
                    isRefusal: true, isUnreachable: false
                )
            }
            if status == 429 {
                return Failure(
                    reason: "\(name)'s quota is spent", httpStatus: status,
                    isRefusal: true, isUnreachable: false
                )
            }
            return Failure(
                reason: "\(name) refused the request", httpStatus: status,
                isRefusal: false, isUnreachable: false
            )
        case .rateLimited:
            // The client has already spent its own retries on this one (`GeminiClient`), so the
            // queue is not going to talk its way past it in the next fifteen seconds.
            return Failure(
                reason: "\(name)'s quota is spent", httpStatus: 429,
                isRefusal: true, isUnreachable: false
            )
        case let .serverError(status):
            return Failure(
                reason: "\(name) is having trouble", httpStatus: status,
                isRefusal: false, isUnreachable: false
            )
        case .network:
            return Failure(
                reason: "\(name) is unreachable", httpStatus: nil,
                isRefusal: false, isUnreachable: true
            )
        case .truncated, .refused, .decode:
            return Failure(
                reason: "\(name)'s answers could not be used", httpStatus: nil,
                isRefusal: false, isUnreachable: false
            )
        }
    }

    /// Gemini answers a bad key with a 400 whose body names `API_KEY_INVALID`; the marker is what
    /// separates it from a 400 about the request itself. Matched here and nowhere else, so the
    /// body never travels any further.
    static func saysKeyInvalid(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("api_key_invalid")
            || lowered.contains("api key not valid")
            || lowered.contains("invalid api key")
    }

    /// Whether one `llm_calls` row is evidence that the **credential** was rejected, rather than
    /// that this particular request was (#189).
    ///
    /// The same line `classify` draws, asked afterwards of a stored row instead of live of an
    /// error, and it is the whole basis of `DescribeQueries.requeueRejectedFailures`: a frame is
    /// only worth describing again on a corrected key if the old key is what stopped it.
    ///
    /// - 401 and 403 are about the caller by definition.
    /// - A 400 is not. Gemini answers an oversized image, an unsupported part or a malformed
    ///   request with a 400 too, and those are about the frame — a new key changes nothing about
    ///   them. Only the `API_KEY_INVALID` marker in the stored `error` text makes a 400 a
    ///   credential rejection.
    /// - Everything else — 429, 5xx, a row with no status at all — is no.
    ///
    /// Treating every 400 as a rejected key is what re-queued a frame that could never succeed at
    /// every launch and every configuration reload: three more paid describe calls each time, and
    /// each round wrote the very 400 row that triggered the next one.
    ///
    /// Pure: it reads nothing and keeps nothing. The `error` text it is handed is local ledger
    /// text and, as everywhere else, goes no further than the match.
    public static func keyWasRejected(httpStatus: Int?, error: String?) -> Bool {
        switch httpStatus {
        case 401, 403: return true
        case 400: return error.map(saysKeyInvalid) ?? false
        default: return false
        }
    }
}
