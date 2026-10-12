import Foundation
import os

// MARK: - JSONValue

/// A recursive JSON value, so request bodies (notably JSON Schemas) can be built as values
/// rather than as `[String: Any]` dictionaries that only fail at serialization time.
public enum JSONValue: Sendable, Hashable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public extension JSONValue {
    var objectValue: [String: JSONValue]? { if case let .object(v) = self { return v } else { return nil } }
    var arrayValue: [JSONValue]? { if case let .array(v) = self { return v } else { return nil } }
    var stringValue: String? { if case let .string(v) = self { return v } else { return nil } }
    var numberValue: Double? { if case let .number(v) = self { return v } else { return nil } }
    var intValue: Int? { numberValue.map(Int.init) }
    var boolValue: Bool? { if case let .bool(v) = self { return v } else { return nil } }
    var isNull: Bool { if case .null = self { return true } else { return false } }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Errors

/// Everything an LLM call can fail with. `http_status`-bearing cases exist so the ledger row can
/// record a failure as faithfully as a success.
public enum LLMError: Error, Equatable, CustomStringConvertible {
    /// A 4xx the provider will not change its mind about. Second value is a body snippet (≤500 chars).
    case badRequest(Int, String)
    case rateLimited
    case serverError(Int)
    case network(String)
    /// The model stopped early — Gemini `finishReason`.
    case truncated(String)
    /// The model refused. Do not retry with the same prompt.
    case refused(String)
    case decode(String)
    case missingAPIKey(String)

    /// The HTTP status to record in `llm_calls`, when the failure had one.
    public var httpStatus: Int? {
        switch self {
        case let .badRequest(status, _): return status
        case .rateLimited: return 429
        case let .serverError(status): return status
        case .network, .truncated, .refused, .decode, .missingAPIKey: return nil
        }
    }

    public var description: String {
        switch self {
        case let .badRequest(status, body): return "HTTP \(status): \(body)"
        case .rateLimited: return "rate limited (HTTP 429)"
        case let .serverError(status): return "provider error (HTTP \(status))"
        case let .network(detail): return "network error: \(detail)"
        case let .truncated(reason): return "response truncated (\(reason))"
        case let .refused(category): return "model refused to answer (\(category))"
        case let .decode(detail): return "could not decode the response: \(detail)"
        case let .missingAPIKey(name): return "\(name) is not set"
        }
    }
}

// MARK: - Usage

/// Token counts from one call, normalized across providers.
///
/// `imageTokens` are a *subset* of `promptTokens` (both providers count image tokens inside the
/// input total), so never add them again when pricing.
public struct LLMUsage: Sendable, Codable, Equatable {
    public var promptTokens: Int
    public var outputTokens: Int
    /// Reasoning tokens. Billed at the output rate by both providers.
    public var thoughtTokens: Int
    /// Prompt tokens served from cache.
    public var cachedTokens: Int
    /// How much of `promptTokens` the image accounted for. Informational.
    public var imageTokens: Int

    public init(
        promptTokens: Int = 0,
        outputTokens: Int = 0,
        thoughtTokens: Int = 0,
        cachedTokens: Int = 0,
        imageTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedTokens = cachedTokens
        self.imageTokens = imageTokens
    }

    public static let zero = LLMUsage()

    /// Everything billed at the output rate.
    public var billedOutputTokens: Int { outputTokens + thoughtTokens }
}

// MARK: - Pricing

/// USD per million tokens, per model. The single source of truth for what a call costs —
/// nothing else in Worklens should hardcode a price.
public struct ModelPricing: Sendable {
    public struct Rate: Sendable, Equatable {
        public let inputPerM: Double
        public let outputPerM: Double

        public init(inputPerM: Double, outputPerM: Double) {
            self.inputPerM = inputPerM
            self.outputPerM = outputPerM
        }
    }

    public let table: [String: Rate]

    public init(table: [String: Rate]) {
        self.table = table
    }

    /// The date the prices below were last verified. Stamped onto every `llm_calls` row so a
    /// later price change is visible as a change rather than as a mystery in the totals.
    public static let pricingVersion = "2026-09-07"

    /// Verified 2026-09-07. See `docs/decisions.md` (cost model).
    public static let `default` = ModelPricing(table: [
        "gemini-3.5-flash-lite": Rate(inputPerM: 0.30, outputPerM: 2.50),
        "gemini-2.5-flash-lite": Rate(inputPerM: 0.10, outputPerM: 0.40),
        "claude-opus-5": Rate(inputPerM: 5.00, outputPerM: 25.00),
    ])

    public func rate(for model: String) -> Rate? { table[model] }

    /// USD for one call. An unknown model costs 0 and warns once, so a model swap shows up as a
    /// suspiciously free day rather than as a crash.
    public func cost(model: String, usage: LLMUsage) -> Double {
        guard let rate = rate(for: model) else {
            ModelPricing.warnUnknownOnce(model)
            return 0
        }
        let input = Double(usage.promptTokens) / 1_000_000 * rate.inputPerM
        let output = Double(usage.billedOutputTokens) / 1_000_000 * rate.outputPerM
        return input + output
    }

    private static let warned = OSAllocatedUnfairLock(initialState: Set<String>())

    private static func warnUnknownOnce(_ model: String) {
        let isNew = warned.withLock { $0.insert(model).inserted }
        if isNew {
            Log.net.warn("no price for model \(model); recording its calls as $0")
        }
    }
}

// MARK: - Sessions

public extension URLSession {
    /// For the describe path: one image, a short prompt, an answer within seconds.
    static let worklens: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Worklens/\(WorklensVersion.short)"]
        return URLSession(configuration: configuration)
    }()
}
