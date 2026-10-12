import Foundation

/// The Test button behind a setup sheet: one cheap call that answers "does this credential work?"
/// now, instead of leaving it to a background sync to fail in fifteen minutes (#135).
///
/// It writes nothing. Granola's check is one page of one note: it does not touch the database, and
/// it does not log the credential. The outcome carries a sentence about the *answer*, never about
/// the value that was sent.
public struct IntegrationTester: Sendable {
    /// What one press found out.
    public enum Outcome: Sendable, Equatable {
        /// The provider answered, and this is what it said about you.
        case ok(String)
        /// The provider refused the credential. Fixable here, by pasting a different one — or, in
        /// Granola's case, by a plan that includes API access.
        case refused(String)
        /// Something else got in the way: no network, a rate limit, an outage.
        case failed(String)

        public var line: String {
            switch self {
            case let .ok(detail), let .refused(detail), let .failed(detail): return detail
            }
        }

        public var level: StatusLevel {
            switch self {
            case .ok: return .ok
            case .refused: return .attention
            case .failed: return .problem
            }
        }

        /// What goes in the log: the verdict, never the sentence — a provider's own words could
        /// quote the request.
        public var verdict: String {
            switch self {
            case .ok: return "accepted"
            case .refused: return "refused"
            case .failed: return "could not ask"
            }
        }
    }

    private let granola: GranolaSource

    public init(granola: GranolaSource = GranolaSource()) {
        self.granola = granola
    }

    /// Asks one source about one credential. Never throws: every answer is an `Outcome` the sheet
    /// can show.
    public func test(_ source: ContextSource, credential: String) async -> Outcome {
        let value = IntegrationSetup.normalize(credential)
        guard !value.isEmpty else {
            return .refused("Nothing to test: paste it first.")
        }
        guard IntegrationSetup.isTestable(source) else {
            return .failed("There is nothing to test here: connecting is what proves this one.")
        }
        do {
            switch source {
            case .granola:
                return .ok(try await granola.check(key: value))
            case .calendar:
                return .failed("There is nothing to test here: connecting is what proves this one.")
            }
        } catch {
            let sentence = ContextSyncScheduler.describe(error)
            return ContextSyncError.isCredential(error) ? .refused(sentence) : .failed(sentence)
        }
    }
}

public extension ContextSyncError {
    /// Whether a failure is the credential itself — refused or absent — rather than a network or
    /// service problem.
    ///
    /// It is the line between "fix this here, in one paste" and "try again later", and it is what
    /// lets a rejected Granola key read as a state of its own instead of a red error line. Both
    /// halves of the app's own error vocabulary are covered: the context sources throw
    /// `ContextSyncError`, and Google's OAuth throws `GoogleAuth.Failure`.
    static func isCredential(_ error: any Error) -> Bool {
        switch error {
        case let error as ContextSyncError:
            switch error {
            case .notConfigured, .unauthorized: return true
            case .rateLimited, .http, .decode, .unavailable: return false
            }
        case let error as GoogleAuth.Failure:
            switch error {
            case .notConfigured, .notConnected, .noRefreshToken, .invalidGrant, .declined:
                return true
            case .stateMismatch:
                return false
            }
        default:
            return false
        }
    }

    /// Whether a failure is only "this source was never set up".
    ///
    /// The scheduler always holds every source and returns `.notConfigured` for every unset one,
    /// so a round where the one configured source synced perfectly still came back with a
    /// failure. That is not a failed sync to report at the user — a source that was
    /// configured and is not any more raises its own attention line instead (#141).
    static func isNotConfigured(_ error: any Error) -> Bool {
        switch error {
        case let error as ContextSyncError:
            if case .notConfigured = error { return true }
            return false
        case let error as GoogleAuth.Failure:
            if case .notConfigured = error { return true }
            return false
        default:
            return false
        }
    }
}
