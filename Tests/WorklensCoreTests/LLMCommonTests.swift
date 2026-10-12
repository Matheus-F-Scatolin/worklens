import Foundation
import Testing
@testable import WorklensCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round trips through JSONEncoder and JSONDecoder")
    func roundTrip() throws {
        let value: JSONValue = [
            "type": "object",
            "properties": ["app_key": ["type": "string"]],
            "required": ["app_key"],
            "maxItems": 3,
            "temperature": 0.2,
            "strict": true,
            "nothing": nil,
        ]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("encodes to the JSON a provider expects")
    func encodesCleanly() throws {
        let schema: JSONValue = ["type": "object", "properties": ["n": ["type": "integer"]]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(schema), as: UTF8.self)
        #expect(text == #"{"properties":{"n":{"type":"integer"}},"type":"object"}"#)
    }

    @Test("decodes arbitrary provider JSON, including nesting and null")
    func decodesResponses() throws {
        let raw = #"{"candidates":[{"content":{"parts":[{"text":"hi"}]}}],"note":null,"n":3}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        #expect(value["candidates"]?[0]?["content"]?["parts"]?[0]?["text"]?.stringValue == "hi")
        #expect(value["note"]?.isNull == true)
        #expect(value["n"]?.intValue == 3)
        #expect(value["missing"] == nil)
        #expect(value[9] == nil)
    }

    @Test("accessors return nil for the wrong case")
    func accessors() {
        let value: JSONValue = "text"
        #expect(value.stringValue == "text")
        #expect(value.numberValue == nil)
        #expect(value.objectValue == nil)
        #expect(value.arrayValue == nil)
        #expect(value.boolValue == nil)
        #expect(value.isNull == false)
    }
}

@Suite("LLMUsage and ModelPricing")
struct PricingTests {
    @Test("thought tokens are billed as output; image tokens are not billed twice")
    func billedOutput() {
        let usage = LLMUsage(promptTokens: 1200, outputTokens: 150, thoughtTokens: 50, imageTokens: 560)
        #expect(usage.billedOutputTokens == 200)
        // 1200/1e6*0.30 + 200/1e6*2.50 = 0.00036 + 0.0005
        let cost = ModelPricing.default.cost(model: "gemini-3.5-flash-lite", usage: usage)
        #expect(abs(cost - 0.00086) < 1e-9)
    }

    @Test("the table carries the verified prices")
    func table() throws {
        let pricing = ModelPricing.default
        #expect(pricing.rate(for: "gemini-3.5-flash-lite") == .init(inputPerM: 0.30, outputPerM: 2.50))
        #expect(pricing.rate(for: "gemini-2.5-flash-lite") == .init(inputPerM: 0.10, outputPerM: 0.40))
        #expect(pricing.rate(for: "claude-opus-5") == .init(inputPerM: 5, outputPerM: 25))
    }

    @Test("a daily report prices out around twenty cents")
    func opusReport() {
        let usage = LLMUsage(promptTokens: 25_000, outputTokens: 3_000)
        let cost = ModelPricing.default.cost(model: "claude-opus-5", usage: usage)
        // 25k * $5/M + 3k * $25/M = 0.125 + 0.075
        #expect(abs(cost - 0.20) < 1e-9)
    }

    @Test("an unknown model costs zero rather than throwing")
    func unknownModel() {
        let cost = ModelPricing.default.cost(
            model: "some-model-that-does-not-exist",
            usage: LLMUsage(promptTokens: 1_000_000, outputTokens: 1_000_000)
        )
        #expect(cost == 0)
    }

    @Test("a custom table overrides the defaults")
    func customTable() {
        let pricing = ModelPricing(table: ["local-model": .init(inputPerM: 0, outputPerM: 0)])
        #expect(pricing.cost(model: "local-model", usage: LLMUsage(promptTokens: 10_000)) == 0)
        #expect(pricing.rate(for: "claude-opus-5") == nil)
    }

    @Test("zero usage costs nothing")
    func zero() {
        #expect(ModelPricing.default.cost(model: "claude-opus-5", usage: .zero) == 0)
    }
}

@Suite("LLMError")
struct LLMErrorTests {
    @Test("errors carry the HTTP status the ledger needs")
    func httpStatus() {
        #expect(LLMError.badRequest(400, "bad body").httpStatus == 400)
        #expect(LLMError.rateLimited.httpStatus == 429)
        #expect(LLMError.serverError(503).httpStatus == 503)
        #expect(LLMError.network("timed out").httpStatus == nil)
        #expect(LLMError.refused("harmful").httpStatus == nil)
    }

    @Test("descriptions name the problem without leaking a prompt")
    func descriptions() {
        #expect(LLMError.missingAPIKey("GEMINI_API_KEY").description == "GEMINI_API_KEY is not set")
        #expect(LLMError.truncated("MAX_TOKENS").description.contains("MAX_TOKENS"))
        #expect(LLMError.refused("unknown").description.contains("refused"))
    }
}

@Suite("URLSession configuration")
struct SessionTests {
    @Test("the describe session times out in a minute")
    func short() {
        let config = URLSession.worklens.configuration
        #expect(config.timeoutIntervalForRequest == 60)
        #expect(config.waitsForConnectivity == false)
    }
}

@Suite("CostGate")
struct CostGateTests {
    @Test("the placeholder gate always allows a call")
    func alwaysAllows() async {
        let gate: any CostGate = AlwaysAllowCostGate()
        #expect(await gate.isOverBudget == false)
    }
}
