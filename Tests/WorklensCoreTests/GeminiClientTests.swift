import Foundation
import Testing
@testable import WorklensCore

// MARK: - URLProtocol stub

/// Answers requests from a queue of canned replies and records what was sent.
///
/// Swift Testing runs suites in parallel, so replies are keyed by a per-`Stub` id carried in a
/// header the session adds to every request — a single global queue would have tests answering
/// each other's calls.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var error: URLError?

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: headers)
        }

        static func failure(_ code: URLError.Code) -> Reply {
            Reply(status: 0, body: Data(), error: URLError(code))
        }
    }

    static let idHeader = "X-Worklens-Stub"
    fileprivate static let registry = LockedBox<[String: (replies: [Reply], sent: [URLRequest])]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol moves httpBody into httpBodyStream, so re-read it for assertions.
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            recorded.httpBody = data
        }

        let id = request.value(forHTTPHeaderField: StubProtocol.idHeader) ?? ""
        let reply: Reply? = StubProtocol.registry.withLock { registry in
            guard var entry = registry[id] else { return nil }
            entry.sent.append(recorded)
            let next = entry.replies.isEmpty ? nil : entry.replies.removeFirst()
            registry[id] = entry
            return next
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One test's canned conversation.
final class Stub {
    let id = UUID().uuidString
    let session: URLSession

    init(_ replies: [StubProtocol.Reply]) {
        let key = id
        StubProtocol.registry.withLock { $0[key] = (replies, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = [StubProtocol.idHeader: id]
        session = URLSession(configuration: configuration)
    }

    var sent: [URLRequest] { StubProtocol.registry.withLock { $0[id]?.sent ?? [] } }

    deinit {
        let key = id
        StubProtocol.registry.withLock { $0[key] = nil }
    }
}

// MARK: - Fixtures

private let successBody = """
{
  "candidates": [{
    "content": {"parts": [
      {"text": "{\\"app_key\\":\\"slack\\"", "thoughtSignature": "Cg4KDAgB"},
      {"text": ",\\"task_key\\":\\"reading_messages\\"}"}
    ], "role": "model"},
    "finishReason": "STOP"
  }],
  "usageMetadata": {
    "promptTokenCount": 1180,
    "candidatesTokenCount": 140,
    "totalTokenCount": 1320,
    "promptTokensDetails": [
      {"modality": "TEXT", "tokenCount": 620},
      {"modality": "IMAGE", "tokenCount": 560}
    ]
  },
  "modelVersion": "gemini-3.5-flash-lite"
}
"""

private func client(
    session: URLSession,
    maxAttempts: Int = 5,
    sleeps: LockedBox<[TimeInterval]>? = nil
) -> GeminiClient {
    GeminiClient(
        apiKey: "test-key",
        model: "gemini-3.5-flash-lite",
        session: session,
        maxAttempts: maxAttempts,
        sleeper: { seconds in sleeps?.withLock { $0.append(seconds) } }
    )
}

private let request = DescribeRequest(
    imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
    systemInstruction: "You are Worklens.",
    userPrompt: "Describe the screenshot.",
    schema: .object(["type": .string("object")]),
    maxOutputTokens: 400
)

// MARK: - Tests

@Suite("GeminiClient request")
struct GeminiClientRequestTests {
    @Test("the body matches the shape verified in docs/api-shapes.md")
    func bodyShape() async throws {
        let stub = Stub([.json(successBody)])
        _ = try await client(session: stub.session).describe(request)

        let sent = try #require(stub.sent.last)
        #expect(sent.url?.absoluteString ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        #expect(body["systemInstruction"]?["parts"]?[0]?["text"]?.stringValue == "You are Worklens.")
        let parts = try #require(body["contents"]?[0]?["parts"])
        #expect(parts[0]?["inline_data"]?["mime_type"]?.stringValue == "image/jpeg")
        #expect(parts[0]?["inline_data"]?["data"]?.stringValue == request.imageJPEG?.base64EncodedString())
        #expect(parts[1]?["text"]?.stringValue == "Describe the screenshot.")

        let generation = try #require(body["generationConfig"])
        #expect(generation["thinkingConfig"]?["thinkingLevel"]?.stringValue == "minimal")
        #expect(generation["mediaResolution"]?.stringValue == "MEDIA_RESOLUTION_MEDIUM")
        #expect(generation["responseMimeType"]?.stringValue == "application/json")
        #expect(generation["responseJsonSchema"]?["type"]?.stringValue == "object")
        #expect(generation["maxOutputTokens"]?.intValue == 400)
        #expect(generation["temperature"]?.numberValue == 0.2)
    }

    @Test("a text-only frame sends no inline_data part at all")
    func textOnlyBody() async throws {
        let stub = Stub([.json(successBody)])
        let textOnly = DescribeRequest(
            imageJPEG: nil,
            systemInstruction: "You are Worklens.",
            userPrompt: "Describe what the person is doing, from the window text above.",
            schema: .object(["type": .string("object")]),
            maxOutputTokens: 400
        )
        _ = try await client(session: stub.session).describe(textOnly)

        let sent = try #require(stub.sent.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        let parts = try #require(body["contents"]?[0]?["parts"])
        // One part, and it is the text: not an image part with an empty payload beside it.
        #expect(parts[1] == nil)
        #expect(parts[0]?["inline_data"] == nil)
        #expect(parts[0]?["text"]?.stringValue == textOnly.userPrompt)
        // `mediaResolution` is sent either way — the API ignores it with no pixels.
        #expect(body["generationConfig"]?["mediaResolution"]?.stringValue == "MEDIA_RESOLUTION_MEDIUM")
    }

    @Test("an empty API key fails before any request goes out")
    func missingKey() async {
        let stub = Stub([])
        let bare = GeminiClient(
            apiKey: "", model: "gemini-3.5-flash-lite", session: stub.session
        )
        await #expect(throws: LLMError.missingAPIKey("GEMINI_API_KEY")) {
            _ = try await bare.describe(request)
        }
    }
}

@Suite("GeminiClient response parsing")
struct GeminiClientParsingTests {
    @Test("text is concatenated, thoughtSignature ignored, usage and cost read off usageMetadata")
    func successParsing() async throws {
        let stub = Stub([.json(successBody)])
        let response = try await client(session: stub.session).describe(request)

        #expect(response.json == #"{"app_key":"slack","task_key":"reading_messages"}"#)
        #expect(response.usage.promptTokens == 1180)
        #expect(response.usage.outputTokens == 140)
        #expect(response.usage.thoughtTokens == 0)   // absent in the payload
        #expect(response.usage.imageTokens == 560)
        #expect(response.model == "gemini-3.5-flash-lite")
        #expect(response.latencyMs >= 0)

        // 1180/1e6 * 0.30 + 140/1e6 * 2.50
        #expect(abs(response.costUSD - (0.000354 + 0.00035)) < 1e-9)
    }

    @Test("thought parts are dropped and thought tokens are billed at the output rate")
    func thoughtTokens() async throws {
        let body = """
        {"candidates":[{"content":{"parts":[
            {"text":"private reasoning","thought":true},
            {"text":"{\\"ok\\":true}"}
        ]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":1000,"candidatesTokenCount":100,"thoughtsTokenCount":50}}
        """
        let stub = Stub([.json(body)])
        let response = try await client(session: stub.session).describe(request)

        #expect(response.json == #"{"ok":true}"#)
        #expect(response.usage.thoughtTokens == 50)
        #expect(response.usage.billedOutputTokens == 150)
        #expect(abs(response.costUSD - (0.0003 + 0.000375)) < 1e-9)
    }

    @Test("finishReason MAX_TOKENS is a truncation, not a decode failure")
    func truncated() async {
        let body = """
        {"candidates":[{"content":{"parts":[{"text":"{\\"app"}]},"finishReason":"MAX_TOKENS"}],
         "usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":400}}
        """
        let stub = Stub([.json(body)])
        await #expect(throws: LLMError.truncated("MAX_TOKENS")) {
            _ = try await client(session: stub.session).describe(request)
        }
    }

    @Test("a safety stop is a refusal, so the frame is not retried")
    func safetyIsRefusal() async {
        let body = #"{"candidates":[{"content":{"parts":[]},"finishReason":"SAFETY"}]}"#
        let stub = Stub([.json(body)])
        await #expect(throws: LLMError.refused("SAFETY")) {
            _ = try await client(session: stub.session).describe(request)
        }
    }

    @Test("a blocked prompt surfaces as a refusal")
    func blockedPrompt() async {
        let stub = Stub([.json(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#)])
        await #expect(throws: LLMError.refused("SAFETY")) {
            _ = try await client(session: stub.session).describe(request)
        }
    }

    @Test("an unparseable payload is a decode error")
    func decodeFailure() async {
        let stub = Stub([.json("not json at all")])
        await #expect(throws: LLMError.self) {
            _ = try await client(session: stub.session).describe(request)
        }
    }
}

@Suite("GeminiClient retries")
struct GeminiClientRetryTests {
    @Test("429 then 200 succeeds after one backoff")
    func retriesRateLimit() async throws {
        let sleeps = LockedBox<[TimeInterval]>([])
        let stub = Stub([.json("{}", status: 429), .json(successBody)])

        let response = try await client(session: stub.session, sleeps: sleeps).describe(request)
        #expect(response.usage.promptTokens == 1180)
        #expect(stub.sent.count == 2)

        let waited = sleeps.withLock { $0 }
        #expect(waited.count == 1)
        #expect(waited[0] >= 0.8 && waited[0] <= 1.2)
    }

    @Test("Retry-After wins over the exponential schedule")
    func honorsRetryAfter() async throws {
        let sleeps = LockedBox<[TimeInterval]>([])
        let stub = Stub([
            .json("{}", status: 503, headers: ["Retry-After": "7"]),
            .json(successBody),
        ])
        _ = try await client(session: stub.session, sleeps: sleeps).describe(request)
        #expect(sleeps.withLock { $0 } == [7])
    }

    @Test("backoff doubles and gives up after maxAttempts")
    func givesUp() async {
        let sleeps = LockedBox<[TimeInterval]>([])
        let stub = Stub(Array(repeating: .json("{}", status: 500), count: 5))

        await #expect(throws: LLMError.serverError(500)) {
            _ = try await client(session: stub.session, maxAttempts: 5, sleeps: sleeps).describe(request)
        }
        #expect(stub.sent.count == 5)
        let waited = sleeps.withLock { $0 }
        #expect(waited.count == 4)
        #expect(waited[0] < waited[1] && waited[1] < waited[2] && waited[2] < waited[3])
        #expect(waited[3] >= 6.4 && waited[3] <= 9.6)   // 8 s ±20 %
    }

    @Test("400 is not retried and carries a body snippet")
    func badRequestNoRetry() async {
        let sleeps = LockedBox<[TimeInterval]>([])
        let long = String(repeating: "x", count: 900)
        let stub = Stub([.json(#"{"error":{"message":"\#(long)"}}"#, status: 400)])

        do {
            _ = try await client(session: stub.session, sleeps: sleeps).describe(request)
            Issue.record("expected a badRequest")
        } catch let error as LLMError {
            guard case let .badRequest(status, snippet) = error else {
                Issue.record("expected badRequest, got \(error)")
                return
            }
            #expect(status == 400)
            #expect(snippet.count <= 500)
            #expect(snippet.contains("error"))
            #expect(error.httpStatus == 400)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(stub.sent.count == 1)
        #expect(sleeps.withLock { $0 }.isEmpty)
    }

    @Test("a cancelled request surfaces as CancellationError, not as a retried network failure")
    func cancellationIsNotRetried() async {
        let sleeps = LockedBox<[TimeInterval]>([])
        let stub = Stub([StubProtocol.Reply(status: 0, body: Data(), error: URLError(.cancelled))])

        await #expect(throws: CancellationError.self) {
            _ = try await client(session: stub.session, sleeps: sleeps).describe(request)
        }
        #expect(stub.sent.count == 1)
        #expect(sleeps.withLock { $0 }.isEmpty)
    }

    @Test("a network failure retries and then reports the transport error")
    func networkRetries() async {
        let sleeps = LockedBox<[TimeInterval]>([])
        let stub = Stub(Array(repeating:
            StubProtocol.Reply(status: 0, body: Data(), error: URLError(.timedOut)), count: 3))

        await #expect(throws: LLMError.self) {
            _ = try await client(session: stub.session, maxAttempts: 3, sleeps: sleeps).describe(request)
        }
        #expect(stub.sent.count == 3)
        #expect(sleeps.withLock { $0 }.count == 2)
    }
}
