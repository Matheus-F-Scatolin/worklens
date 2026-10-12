import Foundation

/// The small HTTP client every context source shares: JSON in, `JSONValue` out, one request at a
/// time with a minimum gap between them.
///
/// An actor rather than a struct because the spacing *is* the rate limiter: Granola and Google
/// both publish per-token limits, and serializing requests behind one actor is both the
/// simplest way to honor them and the reason no source needs a token bucket of its own.
public actor ContextHTTP {
    /// Minimum gap between two requests. Granola and Google are happy at 200 ms.
    public let minimumSpacing: TimeInterval
    /// How many times a 429 or a 5xx is retried before the sync gives up on this round.
    public let maxRetries: Int

    private let session: URLSession
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date
    private var lastRequestAt: Date?

    public init(
        session: URLSession = .worklens,
        minimumSpacing: TimeInterval = 0.2,
        maxRetries: Int = 3,
        sleeper: @escaping Sleeper = realSleeper,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.minimumSpacing = minimumSpacing
        self.maxRetries = maxRetries
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: Requests

    public func get(
        _ url: URL, headers: [String: String] = [:], unauthorizedHint: String? = nil
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, unauthorizedHint: unauthorizedHint)
    }

    /// `application/x-www-form-urlencoded` POST — what OAuth token endpoints want.
    public func postForm(
        _ url: URL, fields: [String: String], headers: [String: String] = [:],
        unauthorizedHint: String? = nil
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(ContextHTTP.formEncoded(fields).utf8)
        return try await send(request, unauthorizedHint: unauthorizedHint)
    }

    public func send(_ request: URLRequest, unauthorizedHint: String? = nil) async throws -> JSONValue {
        var attempt = 0
        while true {
            try await pace()
            let (data, http) = try await once(request)

            switch http.statusCode {
            case 200...299:
                return try decode(data)
            case 401, 403:
                // Carry the provider's own words through. "Run: google connect" is useless advice
                // when the real cause is an API that was never enabled on the Cloud project.
                let hint = unauthorizedHint ?? "the credential was rejected (HTTP \(http.statusCode))"
                throw ContextSyncError.unauthorized(
                    "\(hint) [HTTP \(http.statusCode): \(ContextHTTP.reason(data))]"
                )
            case 429, 500...599:
                let retryAfter = ContextHTTP.retryAfter(http)
                guard attempt < maxRetries else {
                    throw http.statusCode == 429
                        ? ContextSyncError.rateLimited(retryAfter: retryAfter)
                        : ContextSyncError.http(http.statusCode, ContextHTTP.snippet(data))
                }
                attempt += 1
                let delay = retryAfter ?? pow(2.0, Double(attempt)) * Double.random(in: 0.8...1.2)
                // Never the URL: a query string can carry the user's own data.
                Log.net.warn("context request got HTTP \(http.statusCode); retrying in \(Int(delay))s")
                try await sleeper(delay)
            default:
                throw ContextSyncError.http(http.statusCode, ContextHTTP.snippet(data))
            }
        }
    }

    // MARK: Internals

    private func pace() async throws {
        guard let last = lastRequestAt else { return }
        let waited = now().timeIntervalSince(last)
        if waited < minimumSpacing { try await sleeper(minimumSpacing - waited) }
    }

    private func once(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequestAt = now()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ContextSyncError.unavailable("no HTTP response")
            }
            return (data, http)
        } catch let error as ContextSyncError {
            throw error
        } catch {
            throw ContextSyncError.unavailable("network error: \(error.localizedDescription)")
        }
    }

    private func decode(_ data: Data) throws -> JSONValue {
        guard !data.isEmpty else { return .object([:]) }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ContextSyncError.decode(ContextHTTP.snippet(data))
        }
    }

    /// Seconds, or an HTTP date. Both forms appear in the wild.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    /// The `error.message` out of a Google-style error body, or a raw snippet.
    static func reason(_ data: Data) -> String {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return snippet(data)
        }
        let message = json["error"]?["message"]?.stringValue
            ?? json["error_description"]?.stringValue
            ?? json["error"]?.stringValue
        return message.map { String($0.prefix(300)) } ?? snippet(data)
    }

    static func snippet(_ data: Data) -> String {
        String((String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>").prefix(300))
    }

    public static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let value = (fields[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(value)"
        }.joined(separator: "&")
    }
}

/// Parsing helpers every source needs, in one place so no source grows its own
/// slightly different ISO-8601 handling.
public enum ContextDates {
    /// Accepts both `2026-01-27T15:30:00Z` and `2026-01-27T15:30:00.123Z`.
    public static func parseISO8601(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
