import Foundation

/// Gemini `generateContent` over plain `URLSession` — no SDK, no third-party JSON.
///
/// The request shape below was verified against the live API on 2026-09-07 and is quoted in
/// `docs/api-shapes.md`; field names are copied from that verification rather than re-derived
/// (note the snake_case `inline_data`/`mime_type` inside `contents`, next to the camelCase
/// `generationConfig` — that mix is what the API actually accepts).
///
/// The client never writes to the ledger: it returns a `DescribeResponse` or throws an
/// `LLMError` carrying `httpStatus`, and #9 records either outcome in `llm_calls`.
public final class GeminiClient: VisionDescriber {
    public static let provider = "gemini"
    /// Image token budget per frame: `_LOW` (~256) | `_MEDIUM` (560) | `_HIGH` (1120). Medium
    /// is what the describe prompt was written and priced against (#87 froze it here).
    public static let mediaResolution = "MEDIA_RESOLUTION_MEDIUM"
    /// Thinking level for the describe call — minimal keeps it cheap and fast.
    public static let thinkingLevel = "minimal"
    public static let endpointBase = "https://generativelanguage.googleapis.com/v1beta/models"

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let pricing: ModelPricing
    private let maxAttempts: Int
    private let sleeper: Sleeper

    public init(
        apiKey: String,
        model: String,
        session: URLSession = .worklens,
        pricing: ModelPricing = .default,
        maxAttempts: Int = 5,
        sleeper: @escaping Sleeper = realSleeper
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.pricing = pricing
        self.maxAttempts = maxAttempts
        self.sleeper = sleeper
    }

    public var endpoint: URL {
        URL(string: "\(GeminiClient.endpointBase)/\(model):generateContent")!
    }

    // MARK: - Request body

    /// The exact body from `docs/api-shapes.md`. Public so `--dry-run` can print it (with the
    /// image elided) without making a call.
    ///
    /// A nil `imageBase64` emits no `inline_data` part at all — a text-only describe (#54) is one
    /// `text` part, not an empty image beside it. `mediaResolution` stays in `generationConfig`
    /// either way: it is a config field, and the API ignores it when nothing carries pixels.
    public func requestBody(for request: DescribeRequest, imageBase64: String?) -> JSONValue {
        var parts: [JSONValue] = []
        if let imageBase64 {
            parts.append(.object([
                "inline_data": .object([
                    "mime_type": .string("image/jpeg"),
                    "data": .string(imageBase64),
                ]),
            ]))
        }
        parts.append(.object(["text": .string(request.userPrompt)]))

        return .object([
            "systemInstruction": .object(["parts": .array([.object(["text": .string(request.systemInstruction)])])]),
            "contents": .array([
                .object([
                    "role": .string("user"),
                    "parts": .array(parts),
                ]),
            ]),
            "generationConfig": .object([
                "thinkingConfig": .object(["thinkingLevel": .string(GeminiClient.thinkingLevel)]),
                "mediaResolution": .string(GeminiClient.mediaResolution),
                "responseMimeType": .string("application/json"),
                "responseJsonSchema": request.schema,
                "maxOutputTokens": .number(Double(request.maxOutputTokens)),
                "temperature": .number(0.2),
            ]),
        ])
    }

    // MARK: - VisionDescriber

    public var provider: String { GeminiClient.provider }

    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey("GEMINI_API_KEY") }

        let body = try JSONEncoder().encode(
            requestBody(for: request, imageBase64: request.imageJPEG?.base64EncodedString())
        )
        let started = Date()
        let data = try await send(body: body)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        return try parse(data, latencyMs: latencyMs)
    }

    // MARK: - Transport

    private func send(body: Data) async throws -> Data {
        var attempt = 1
        while true {
            do {
                return try await sendOnce(body: body)
            } catch let error as LLMError {
                guard let delay = retryDelay(for: error, attempt: attempt), attempt < maxAttempts else {
                    throw error
                }
                // Never logs the body or the key — only the shape of the failure.
                Log.net.warn("gemini attempt \(attempt) failed (\(error.description)); retrying in \(String(format: "%.1f", delay))s")
                try await sleeper(delay)
                attempt += 1
            }
        }
    }

    private func sendOnce(body: Data) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            // The caller gave up (the app is quitting); not a failure of the frame or the provider.
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw LLMError.network(error.localizedDescription)
        } catch {
            throw LLMError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            lastRetryAfter.withLock { $0 = nil }
            return data
        case 429:
            lastRetryAfter.withLock { $0 = GeminiClient.retryAfterSeconds(http) }
            throw LLMError.rateLimited
        case 500...599:
            lastRetryAfter.withLock { $0 = GeminiClient.retryAfterSeconds(http) }
            throw LLMError.serverError(http.statusCode)
        default:
            throw LLMError.badRequest(http.statusCode, GeminiClient.snippet(data))
        }
    }

    /// `Retry-After` from the most recent failure, so the backoff can honor it.
    private let lastRetryAfter = LockedBox<TimeInterval?>(nil)

    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) { return seconds }
        return nil
    }

    /// Exponential 1, 2, 4, 8, 16 s with ±20 % jitter; `Retry-After` wins when the server sent one.
    /// Nil means "do not retry this".
    func retryDelay(for error: LLMError, attempt: Int) -> TimeInterval? {
        switch error {
        case .rateLimited, .serverError, .network:
            let base = pow(2.0, Double(attempt - 1))
            let jittered = base * Double.random(in: 0.8...1.2)
            // Consumed, not just read: a Retry-After from one 429 must not pace a later
            // network failure that came with no header of its own.
            let after = lastRetryAfter.withLock { value -> TimeInterval? in
                defer { value = nil }
                return value
            }
            if let after { return max(after, 0) }
            return jittered
        case .badRequest, .truncated, .refused, .decode, .missingAPIKey:
            return nil
        }
    }

    private static func snippet(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        return String(text.prefix(500))
    }

    // MARK: - Response

    func parse(_ data: Data, latencyMs: Int) throws -> DescribeResponse {
        let decoded: GeminiResponse
        do {
            decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            throw LLMError.decode("\(error)")
        }

        if let blocked = decoded.promptFeedback?.blockReason {
            throw LLMError.refused(blocked)
        }
        guard let candidate = decoded.candidates?.first else {
            throw LLMError.decode("no candidates in the response")
        }

        let finishReason = candidate.finishReason ?? "UNSPECIFIED"
        if finishReason != "STOP" {
            // Safety stops are refusals, not truncation: retrying the same frame will not help.
            if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY"].contains(finishReason) {
                throw LLMError.refused(finishReason)
            }
            throw LLMError.truncated(finishReason)
        }

        // `thoughtSignature` parts carry no text; thought parts carry reasoning we do not want.
        let text = (candidate.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.decode("the candidate carried no text")
        }

        let metadata = decoded.usageMetadata
        let usage = LLMUsage(
            promptTokens: metadata?.promptTokenCount ?? 0,
            outputTokens: metadata?.candidatesTokenCount ?? 0,
            thoughtTokens: metadata?.thoughtsTokenCount ?? 0,
            cachedTokens: metadata?.cachedContentTokenCount ?? 0,
            imageTokens: metadata?.promptTokensDetails?
                .first { $0.modality?.uppercased() == "IMAGE" }?.tokenCount ?? 0
        )

        return DescribeResponse(
            json: text,
            usage: usage,
            costUSD: pricing.cost(model: model, usage: usage),
            latencyMs: latencyMs,
            model: model
        )
    }
}

// MARK: - Wire types

struct GeminiResponse: Decodable {
    struct Part: Decodable {
        let text: String?
        let thought: Bool?
    }

    struct Content: Decodable {
        let parts: [Part]?
    }

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct ModalityTokenCount: Decodable {
        let modality: String?
        let tokenCount: Int?
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let thoughtsTokenCount: Int?
        let cachedContentTokenCount: Int?
        let promptTokensDetails: [ModalityTokenCount]?
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
    let promptFeedback: PromptFeedback?
}

/// Tiny box so a `let` property can hold mutable state without making the client an actor.
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
