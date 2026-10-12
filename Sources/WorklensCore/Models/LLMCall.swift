import Foundation
import GRDB

/// What an LLM call was for. Every network call to a model lands in `llm_calls` with one of these.
public enum LLMPurpose: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case describe
    case reportDaily = "report_daily"
    case reportWeekly = "report_weekly"
    case chat
    case taxonomy
    case rangeResolve = "range_resolve"
    /// #124: a `Verify` press in Settings → Models & cost → Accounts. The free models-list `GET`
    /// at a provider: no prompt, no tokens, always `costUsd: 0`. It is in the ledger because a
    /// call that left this Mac carrying your API key is exactly the kind of thing the ledger
    /// exists to make auditable. `purpose` is a plain `TEXT` column with no constraint, so this
    /// case needs no migration; an older build reading a newer database simply skips rows whose
    /// purpose it does not know (`LLMCallStore.summary`).
    case verify
}

/// One row per LLM call — successful or not — so spend is always auditable.
public struct LLMCall: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "llm_calls"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var provider: String
    public var model: String
    public var purpose: LLMPurpose
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var thoughtTokens: Int?
    public var cachedTokens: Int?
    public var costUsd: Double
    public var latencyMs: Int?
    public var httpStatus: Int?
    public var error: String?
    /// Which price table `costUsd` was computed with — `ModelPricing.pricingVersion`. Stamped by
    /// `LLMCallStore.insert` when the caller leaves it nil, so a price change is auditable
    /// afterwards instead of quietly rewriting history. Nil on rows written before migration v2.
    public var pricingVersion: String?
    public var createdAt: Date

    public init(
        id: String = Identifiers.new(),
        provider: String,
        model: String,
        purpose: LLMPurpose,
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        thoughtTokens: Int? = nil,
        cachedTokens: Int? = nil,
        costUsd: Double = 0,
        latencyMs: Int? = nil,
        httpStatus: Int? = nil,
        error: String? = nil,
        pricingVersion: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.purpose = purpose
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedTokens = cachedTokens
        self.costUsd = costUsd
        self.latencyMs = latencyMs
        self.httpStatus = httpStatus
        self.error = error
        self.pricingVersion = pricingVersion
        self.createdAt = createdAt
    }

    /// A call that came back with an error and cost nothing.
    public var isFailure: Bool { error != nil }
}

/// One purpose's slice of a day.
public struct PurposeSpend: Sendable, Equatable {
    public var purpose: LLMPurpose
    public var costUsd: Double
    public var calls: Int
    public var failures: Int

    public init(purpose: LLMPurpose, costUsd: Double = 0, calls: Int = 0, failures: Int = 0) {
        self.purpose = purpose
        self.costUsd = costUsd
        self.calls = calls
        self.failures = failures
    }
}

/// One day's spend, split by purpose, for the cost display and the budget gate.
///
/// Days are **local** calendar days, like everything else a person reads in Worklens — the
/// budget rolls over at local midnight, so a spend table on UTC days would disagree with the
/// menu's "Today" line for the last few hours of every evening.
public struct DailySpend: Sendable, Equatable, Identifiable {
    /// `YYYY-MM-DD`, local.
    public var day: String
    /// The day is the identity: `summary(days:)` returns one row per day. `Table` in Settings →
    /// Models & budget needs it (#133).
    public var id: String { day }
    public var costUsd: Double
    public var calls: Int
    /// Calls that came back an error. They cost nothing but they are the reason a quiet day can
    /// still be a broken one.
    public var failures: Int
    /// Only the purposes that actually appear, in `LLMPurpose.allCases` order.
    public var purposes: [PurposeSpend]

    public init(
        day: String,
        costUsd: Double = 0,
        calls: Int = 0,
        failures: Int = 0,
        purposes: [PurposeSpend] = []
    ) {
        self.day = day
        self.costUsd = costUsd
        self.calls = calls
        self.failures = failures
        self.purposes = purposes
    }

    public func usd(_ purpose: LLMPurpose) -> Double {
        purposes.first { $0.purpose == purpose }?.costUsd ?? 0
    }

    /// The three columns the Settings table shows. `other` carries the retired purposes —
    /// `taxonomy` (#86) and `chat`/`rangeResolve` (#95) — so the columns still sum to `costUsd`
    /// on a day whose ledger predates their removal.
    public var describeUSD: Double { usd(.describe) }
    public var reportsUSD: Double { usd(.reportDaily) + usd(.reportWeekly) }
    /// `verify` (#124) is in here for the same reason: it is always $0, so it moves no number,
    /// and leaving it out of every column would be the one way the three could stop summing.
    public var otherUSD: Double {
        usd(.taxonomy) + usd(.chat) + usd(.rangeResolve) + usd(.verify)
    }
}
