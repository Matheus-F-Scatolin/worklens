import Foundation

/// One way Worklens can summarize a screenshot.
public enum SummaryProvider: String, CaseIterable, Codable, Sendable {
    /// The person's Claude plan, through their signed-in `claude` command.
    case claude
    /// The person's ChatGPT plan, through their signed-in `codex` command.
    case codex
    /// The Gemini API, with `GEMINI_API_KEY`.
    case gemini

    public var tool: SubscriptionTool? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .gemini: nil
        }
    }
}

/// `SUMMARY_PROVIDERS` and the summarizer it builds: the one place the app, the CLI and the
/// tests turn the configuration into a `VisionDescriber`.
public enum SummaryProviders {
    public static let claudeModels = ["sonnet", "haiku"]
    /// Families only. Terra and Astra are deliberately absent: they are the large models, and a
    /// screenshot summary is a small job on someone's plan.
    public static let codexModels = ["sol", "luna"]
    /// The order offered when someone connects more than one.
    public static let defaultOrder: [SummaryProvider] = [.claude, .codex, .gemini]

    /// Parses `claude,codex,gemini`. Repeats are dropped; an unknown name is an error, like any
    /// other value Worklens does not know.
    static func parse(_ value: String?) throws -> [SummaryProvider] {
        guard let parts = Config.list(value, separators: [",", ";"]) else { return [] }
        var seen: [SummaryProvider] = []
        for part in parts {
            guard let provider = SummaryProvider(rawValue: part.lowercased()) else {
                throw ConfigError.invalidEnum(
                    key: "SUMMARY_PROVIDERS", value: part, allowed: SummaryProvider.allCases.map(\.rawValue)
                )
            }
            if !seen.contains(provider) { seen.append(provider) }
        }
        return seen
    }

    static func choice(_ key: String, _ value: String?, from allowed: [String]) throws -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard allowed.contains(trimmed) else {
            throw ConfigError.invalidEnum(key: key, value: value ?? "", allowed: allowed)
        }
        return trimmed
    }

    /// The summarizers in effect, in order. Gemini counts only with a key. An empty
    /// `SUMMARY_PROVIDERS` is Gemini alone, so an install from before this key behaves as it did.
    public static func effective(_ config: Config) -> [SummaryProvider] {
        let hasGeminiKey = !(config.geminiAPIKey ?? "").isEmpty
        let listed = config.summaryProviders.isEmpty ? [.gemini] : config.summaryProviders
        return listed.filter { $0 != .gemini || hasGeminiKey }
    }

    /// The model a provider's calls are recorded under before an answer names the exact one.
    public static func model(for provider: SummaryProvider, config: Config) -> String {
        switch provider {
        case .claude: config.claudeSummaryModel
        case .codex: config.codexSummaryModel
        case .gemini: config.describeModel
        }
    }

    /// The summarizer for this configuration: nil when none is set up, a lone Gemini exactly as
    /// the `GeminiClient` it always was, and a `DescriberChain` otherwise.
    public static func describer(
        config: Config,
        cli: any SubscriptionCLI = SubscriptionCLIRunner(),
        only: SummaryProvider? = nil,
        budget: (any CostGate)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> (any VisionDescriber)? {
        let providers = only.map { [$0] } ?? effective(config)
        let workspace = SubscriptionWorkspace(dataDir: config.dataDir)
        let links: [DescriberChain.Link] = providers.compactMap { provider in
            let describer: any VisionDescriber
            switch provider {
            case .claude:
                describer = ClaudeDescriber(
                    cli: cli, model: config.claudeSummaryModel, workspace: workspace,
                    headroomPercent: config.subscriptionHeadroomPercent, now: now
                )
            case .codex:
                describer = CodexDescriber(cli: cli, family: config.codexSummaryModel, workspace: workspace, now: now)
            case .gemini:
                guard let key = config.geminiAPIKey, !key.isEmpty else { return nil }
                describer = GeminiClient(apiKey: key, model: config.describeModel)
            }
            return DescriberChain.Link(describer, model: model(for: provider, config: config))
        }
        guard let first = links.first else { return nil }
        // A subscription alone still goes through the chain, for its skip memory and so its
        // failure rows name the right model.
        if links.count == 1, first.describer is GeminiClient { return first.describer }
        // `budget` is asked before each link that costs money; a plan link is never held by it.
        return DescriberChain(links, budget: budget, now: now)
    }
}
