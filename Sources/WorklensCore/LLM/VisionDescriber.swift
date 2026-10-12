import Foundation

/// One frame in, one JSON document out. Everything the describe worker needs from a vision
/// model, so the model behind it (Gemini today, the Interactions API, Anthropic vision or a local
/// model tomorrow) can be swapped without touching #9.
public protocol VisionDescriber: Sendable {
    /// What this client writes into `llm_calls.provider` — the client knows, so nothing has to
    /// be told (#87 retired `DESCRIBE_PROVIDER`, which only ever labelled the row).
    var provider: String { get }
    func describe(_ request: DescribeRequest) async throws -> DescribeResponse
}

public struct DescribeRequest: Sendable {
    /// Nil for a frame described from the focused window's text alone (#54), which is most of
    /// them once `CAPTURE_SOURCE` stops taking pictures of fully covered windows.
    public let imageJPEG: Data?
    public let systemInstruction: String
    public let userPrompt: String
    /// JSON Schema the answer must satisfy. Built per request so the `app_key`/`task_key`
    /// enums can be exactly the keys this frame is allowed to use.
    public let schema: JSONValue
    public let maxOutputTokens: Int

    public init(
        imageJPEG: Data?,
        systemInstruction: String,
        userPrompt: String,
        schema: JSONValue,
        maxOutputTokens: Int = 400
    ) {
        self.imageJPEG = imageJPEG
        self.systemInstruction = systemInstruction
        self.userPrompt = userPrompt
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct DescribeResponse: Sendable {
    /// The raw JSON text the model produced. Decoding it is the caller's job.
    public let json: String
    public let usage: LLMUsage
    public let costUSD: Double
    public let latencyMs: Int
    public let model: String

    public init(json: String, usage: LLMUsage, costUSD: Double, latencyMs: Int, model: String) {
        self.json = json
        self.usage = usage
        self.costUSD = costUSD
        self.latencyMs = latencyMs
        self.model = model
    }
}

/// Injected so retry tests do not actually wait 1 + 2 + 4 seconds.
public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

public let realSleeper: Sleeper = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}
