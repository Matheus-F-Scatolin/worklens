import Foundation

/// One frame in, one JSON document out. Everything the describe worker needs from a vision
/// model, so the model behind it can be swapped without touching #9: Gemini over HTTP, or the
/// person's own signed-in `claude` or `codex` command (`ClaudeDescriber`, `CodexDescriber`),
/// or several of them in order (`DescriberChain`).
public protocol VisionDescriber: Sendable {
    /// What this client writes into `llm_calls.provider` — the client knows, so nothing has to
    /// be told (#87 retired `DESCRIBE_PROVIDER`, which only ever labelled the row).
    var provider: String { get }
    func describe(_ request: DescribeRequest) async throws -> DescribeResponse
}

/// One screenshot in a request. A single-screenshot request carries one with no label, the way
/// a describe call always looked; a batch (`SUMMARY_BATCH`) carries several, in capture order,
/// each labelled the way the prompt names it ("Screenshot 3 of 7, 14:32:10") so the model can
/// tell which picture is which.
public struct DescribeImage: Sendable, Equatable {
    /// The capture this picture is of. Nil on a single-screenshot request.
    public let frameId: String?
    /// The label the describer puts next to the picture, nil for none.
    public let label: String?
    public let jpeg: Data
    /// Where `jpeg` already sits on disk, when it came from there. `codex exec --image` takes
    /// files, so the Codex summarizer points at the screenshot in place rather than writing a
    /// second copy; every other describer ignores it.
    public let file: URL?

    public init(frameId: String? = nil, label: String? = nil, jpeg: Data, file: URL? = nil) {
        self.frameId = frameId
        self.label = label
        self.jpeg = jpeg
        self.file = file
    }
}

public struct DescribeRequest: Sendable {
    /// The pictures, in order. Empty for a frame described from the focused window's text alone
    /// (#54), which is most of them once `CAPTURE_SOURCE` stops taking pictures of fully covered
    /// windows; in a batch, only the screenshots that send a picture are here.
    public let images: [DescribeImage]
    public let systemInstruction: String
    public let userPrompt: String
    /// JSON Schema the answer must satisfy. Built per request so the `app_key`/`task_key`
    /// enums can be exactly the keys this frame is allowed to use.
    public let schema: JSONValue
    public let maxOutputTokens: Int

    /// The first picture: the only one a single-screenshot request has.
    public var imageJPEG: Data? { images.first?.jpeg }
    /// Where the first picture sits on disk.
    public var imageFile: URL? { images.first?.file }

    public init(
        imageJPEG: Data?,
        imageFile: URL? = nil,
        systemInstruction: String,
        userPrompt: String,
        schema: JSONValue,
        maxOutputTokens: Int = 400
    ) {
        self.init(
            images: imageJPEG.map { [DescribeImage(jpeg: $0, file: imageFile)] } ?? [],
            systemInstruction: systemInstruction, userPrompt: userPrompt, schema: schema,
            maxOutputTokens: maxOutputTokens
        )
    }

    public init(
        images: [DescribeImage],
        systemInstruction: String,
        userPrompt: String,
        schema: JSONValue,
        maxOutputTokens: Int = 400
    ) {
        self.images = images
        self.systemInstruction = systemInstruction
        self.userPrompt = userPrompt
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
    }

    /// Whether the pictures carry labels, which only a batch does.
    public var isBatch: Bool { images.contains { $0.label != nil } }

    /// The same request, noting where its screenshot sits on disk.
    public func withImageFile(_ url: URL?) -> DescribeRequest {
        withImages(images.enumerated().map { index, image in
            index == 0
                ? DescribeImage(frameId: image.frameId, label: image.label, jpeg: image.jpeg, file: url)
                : image
        })
    }

    /// The same request with other pictures.
    public func withImages(_ images: [DescribeImage]) -> DescribeRequest {
        DescribeRequest(
            images: images, systemInstruction: systemInstruction, userPrompt: userPrompt,
            schema: schema, maxOutputTokens: maxOutputTokens
        )
    }
}

public struct DescribeResponse: Sendable {
    /// The raw JSON text the model produced. Decoding it is the caller's job.
    public let json: String
    public let usage: LLMUsage
    public let costUSD: Double
    public let latencyMs: Int
    public let model: String
    /// Which describer answered, when that is not simply the describer that was asked: a
    /// `DescriberChain` fills it in, and it is what lands in `descriptions.provider` and
    /// `llm_calls.provider`. Nil means "the one you called".
    public let provider: String?

    public init(
        json: String, usage: LLMUsage, costUSD: Double, latencyMs: Int, model: String,
        provider: String? = nil
    ) {
        self.json = json
        self.usage = usage
        self.costUSD = costUSD
        self.latencyMs = latencyMs
        self.model = model
        self.provider = provider
    }

    /// The same answer, labelled with the describer that gave it.
    public func answered(by provider: String) -> DescribeResponse {
        DescribeResponse(
            json: json, usage: usage, costUSD: costUSD, latencyMs: latencyMs, model: model,
            provider: provider
        )
    }
}

/// Injected so retry tests do not actually wait 1 + 2 + 4 seconds.
public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

public let realSleeper: Sleeper = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}
