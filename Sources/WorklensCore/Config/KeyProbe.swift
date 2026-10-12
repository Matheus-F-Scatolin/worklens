import Foundation

public enum KeyProvider: String, Sendable, Equatable, CaseIterable {
    case gemini

    public var envKey: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        }
    }

    /// What a key of this kind starts with. A mismatch is a warning, never a failure: providers
    /// change their prefixes and a check that calls a working key invalid is worse than none.
    public var expectedPrefix: String {
        switch self {
        case .gemini: return "AIza"
        }
    }
}

public enum KeyVerdict: Sendable, Equatable {
    case accepted
    case rejected(String)
    /// The request never got an answer — offline, a proxy, a timeout. Not the key's fault.
    case unreachable(String)
}

/// One key check, with the two facts a ledger row needs on top of the verdict (#124): the status
/// the provider answered with, and how long it took. Settings → Connections records the whole
/// thing in `llm_calls`.
public struct KeyProbe: Sendable, Equatable {
    public let verdict: KeyVerdict
    /// Nil when there was no HTTP answer at all — offline, DNS, a timeout.
    public let httpStatus: Int?
    public let latencyMs: Int?

    public init(verdict: KeyVerdict, httpStatus: Int? = nil, latencyMs: Int? = nil) {
        self.verdict = verdict
        self.httpStatus = httpStatus
        self.latencyMs = latencyMs
    }
}

/// The network seam behind `Verify`, so the unit tests run with no network at all (`make test`,
/// never bare `swift test`).
public protocol KeyProbing: Sendable {
    /// Only ever called by a `Verify` press in Settings (#124), and only with a key that is
    /// actually set.
    func probeKey(_ provider: KeyProvider, key: String) async -> KeyProbe
}

public struct LiveKeyProbe: KeyProbing {
    public init() {}

    /// The **free** models-list endpoint at the provider, never a completion: a one-token call
    /// would be billable, and a check that quietly spends money is not one. Nothing is generated
    /// and nothing is logged. The key travels in a header, never in the URL.
    ///
    /// #124's `Verify` button keeps the status, and writes a $0 `llm_calls` row carrying the
    /// status and nothing else.
    public func probeKey(_ provider: KeyProvider, key: String) async -> KeyProbe {
        var request: URLRequest
        switch provider {
        case .gemini:
            request = URLRequest(
                url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!
            )
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        let started = Date()
        do {
            let (_, response) = try await URLSession.worklens.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let verdict: KeyVerdict
            switch code {
            case 200: verdict = .accepted
            case 401, 403: verdict = .rejected("HTTP \(code): the provider refused this key")
            case 429: verdict = .accepted  // rate-limited is still a key it recognised
            default: verdict = .unreachable("HTTP \(code)")
            }
            return KeyProbe(verdict: verdict, httpStatus: code, latencyMs: elapsed)
        } catch {
            // No status: there was no answer. The message is Foundation's, and carries the host
            // at worst — never the key, which only ever went into a header.
            return KeyProbe(
                verdict: .unreachable(error.localizedDescription),
                latencyMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        }
    }
}
