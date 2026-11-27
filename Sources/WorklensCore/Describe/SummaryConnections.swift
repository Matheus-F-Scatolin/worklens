import Foundation

/// What each way of summarizing looks like to the person: the welcome window's three cards and
/// Settings → Connections' three rows, built from one list rather than a hard-coded "Gemini".
///
/// Everything here is a pure function of the configuration and of what `claude auth status` or
/// `codex login status` last said, so the four states of a card, the order sentence and the
/// edits Connect, Disconnect and the arrows make to `SUMMARY_PROVIDERS` are all testable without
/// a window. Worklens never signs either command in or out: Connect adds a name to the list once
/// the command says it is signed in with a plan, and Disconnect takes the name out again.
public struct SummaryConnection: Sendable, Equatable, Identifiable {
    /// Where a provider stands, in the order a person moves through them.
    public enum State: Sendable, Equatable {
        /// The status command has not answered yet.
        case checking
        /// The command is not on this Mac.
        case notInstalled
        /// Installed, not signed in (or the sign-in ran out).
        case signedOut
        /// Signed in some other way than a plan: an API key, a cloud console.
        case notSubscription
        /// Gemini without a key.
        case needsKey
        /// Ready to connect: signed in with a plan, or Gemini with a key it is not using.
        case ready(plan: String?)
        /// In `SUMMARY_PROVIDERS` and usable: Worklens summarizes with it.
        case connected(plan: String?)
    }

    public let provider: SummaryProvider
    public let state: State
    /// Whether the provider is in the list Worklens tries, usable or not. A connected Claude whose
    /// sign-in ran out is still listed: its row keeps Disconnect and says what went wrong.
    public let listed: Bool
    /// When the sign-in runs out. Only `claude` reports one.
    public let loginExpiresAt: Date?

    public var id: String { provider.rawValue }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    public init(provider: SummaryProvider, state: State, listed: Bool, loginExpiresAt: Date? = nil) {
        self.provider = provider
        self.state = state
        self.listed = listed
        self.loginExpiresAt = loginExpiresAt
    }

    /// One provider's card. `status` is nil until the command has been asked, and is ignored for
    /// Gemini, whose only question is whether a key is saved.
    public static func make(
        _ provider: SummaryProvider, config: Config, status: SubscriptionStatus?, now: Date = Date()
    ) -> SummaryConnection {
        guard let tool = provider.tool else {
            let hasKey = !(config.geminiAPIKey ?? "").isEmpty
            let listed = SummaryProviders.effective(config).contains(.gemini)
            let state: State = !hasKey ? .needsKey : listed ? .connected(plan: nil) : .ready(plan: nil)
            return SummaryConnection(provider: provider, state: state, listed: listed)
        }
        let listed = config.summaryProviders.contains(provider)
        guard let status, status.tool == tool else {
            return SummaryConnection(provider: provider, state: .checking, listed: listed)
        }
        let state: State
        switch status.login {
        case .notInstalled: state = .notInstalled
        case .signedOut: state = .signedOut
        case .notSubscription: state = .notSubscription
        case .subscription:
            if !status.isUsable(now: now) {
                state = .signedOut
            } else {
                state = listed ? .connected(plan: status.plan) : .ready(plan: status.plan)
            }
        }
        return SummaryConnection(
            provider: provider, state: state, listed: listed, loginExpiresAt: status.loginExpiresAt
        )
    }

    /// The three, in the order the welcome window and Settings show them.
    public static func all(
        config: Config, statuses: [SubscriptionTool: SubscriptionStatus], now: Date = Date()
    ) -> [SummaryConnection] {
        SummaryProviders.defaultOrder.map { provider in
            make(provider, config: config, status: provider.tool.flatMap { statuses[$0] }, now: now)
        }
    }

    // MARK: - Words

    /// The card's heading.
    public var title: String {
        switch provider {
        case .claude: L10n.string("Claude subscription")
        case .codex: L10n.string("ChatGPT subscription")
        case .gemini: L10n.string("Gemini API key")
        }
    }

    /// The one line under the heading: what it costs and through what.
    public var subtitle: String {
        switch provider {
        case .claude: L10n.string("Uses your Claude plan through Claude Code")
        case .codex: L10n.string("Uses your ChatGPT plan through Codex")
        case .gemini: L10n.string("Pay Google per screenshot, about $3 a month")
        }
    }

    /// The name the order sentence and the notices use: "Claude", "ChatGPT", "Gemini".
    public static func name(_ provider: SummaryProvider) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    /// `max` → `Max`, `team` → `Team`. The command's own word, capitalised, never translated.
    public static func planLabel(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces), let first = plan.first else { return nil }
        return first.uppercased() + plan.dropFirst()
    }

    /// The sentence that says where this provider stands.
    public var stateLine: String {
        guard let tool = provider.tool else {
            switch state {
            case .ready:
                return L10n.string("Your key is saved, but Worklens is not using it.")
            case .connected:
                return L10n.string("Connected. Worklens summarizes with your Gemini key.")
            default:
                return L10n.string("Paste a key from a billing-enabled Gemini project.")
            }
        }
        switch state {
        case .checking, .needsKey:
            return L10n.string("Checking\u{2026}")
        case .notInstalled:
            return L10n.format("%@ is not installed on this Mac.", DescribeHealth.commandName(tool))
        case .signedOut:
            return L10n.format(
                "%@ is installed but not signed in. Sign in with this command in Terminal, then come back.",
                DescribeHealth.commandName(tool))
        case .notSubscription:
            return L10n.format(
                "%@ is signed in with an API key, not your %@ plan. Sign in with your plan with this command in Terminal.",
                DescribeHealth.commandName(tool), DescribeHealth.planName(tool))
        case let .ready(plan):
            return Self.planSentence(tool, plan: plan, connected: false)
        case let .connected(plan):
            return Self.planSentence(tool, plan: plan, connected: true)
        }
    }

    static func planSentence(_ tool: SubscriptionTool, plan: String?, connected: Bool) -> String {
        let planName = DescribeHealth.planName(tool)
        if let label = planLabel(plan) {
            return connected
                ? L10n.format("Connected. Worklens summarizes with your %@ %@ plan.", planName, label)
                : L10n.format("Signed in with your %@ %@ plan.", planName, label)
        }
        return connected
            ? L10n.format("Connected. Worklens summarizes with your %@ plan.", planName)
            : L10n.format("Signed in with your %@ plan.", planName)
    }

    /// The colour of the state line: green once connected, amber when a sign-in needs the
    /// person, plain otherwise.
    public var level: StatusLevel {
        switch state {
        case .connected: .ok
        case .signedOut, .notSubscription: listed ? .problem : .attention
        case .checking, .notInstalled, .needsKey, .ready: .neutral
        }
    }

    /// When the sign-in runs out, for Claude: `Your sign-in lasts until 17 Dec 2026.`
    public func expiryLine(timeZone: TimeZone = .current, locale: Locale = Format.fixed) -> String? {
        guard let loginExpiresAt else { return nil }
        return L10n.format(
            "Your sign-in lasts until %@.", Format.dateWithYear(loginExpiresAt, timeZone: timeZone, locale: locale)
        )
    }

    /// The command a person runs to sign in, shown with a Copy button. Nil for Gemini.
    public var loginCommand: String? { provider.tool?.loginCommand }

    /// Whether the card should show the sign-in command.
    public var needsSignIn: Bool {
        guard provider.tool != nil else { return false }
        switch state {
        case .signedOut, .notSubscription: return true
        default: return false
        }
    }

    /// `Last summary today at 15:40`, or nil before this provider has written one.
    public static func lastSummaryLine(
        _ at: Date?, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = Format.fixed
    ) -> String? {
        guard let at else { return nil }
        let clock = Format.clock(at, timeZone: timeZone, locale: locale)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(at, inSameDayAs: now) {
            return L10n.format("Last summary today at %@", clock)
        }
        return L10n.format(
            "Last summary on %@ at %@", Format.shortDate(at, timeZone: timeZone, locale: locale), clock
        )
    }
}

// MARK: - Editing SUMMARY_PROVIDERS

extension SummaryProviders {
    /// The list as the person sees it: what is written, or Gemini alone when nothing is written
    /// and a key is saved (the install from before `SUMMARY_PROVIDERS`), or nothing.
    public static func listed(_ config: Config) -> [SummaryProvider] {
        if !config.summaryProviders.isEmpty { return config.summaryProviders }
        return effective(config)
    }

    /// The list after Connect. A list still in the default order keeps it (Claude, then
    /// ChatGPT, then Gemini), so connecting Claude to a Gemini install tries Claude first; a list
    /// the person has reordered gets the new provider at the end, so their order stands.
    public static func connecting(_ provider: SummaryProvider, config: Config) -> [SummaryProvider] {
        let current = listed(config)
        guard !current.contains(provider) else { return current }
        if isInDefaultOrder(current) {
            return defaultOrder.filter { current.contains($0) || $0 == provider }
        }
        return current + [provider]
    }

    /// The list after Disconnect: the name taken out, and nothing else changed. The command
    /// stays signed in; Worklens only stops using it.
    public static func disconnecting(_ provider: SummaryProvider, config: Config) -> [SummaryProvider] {
        listed(config).filter { $0 != provider }
    }

    /// The list after an arrow: one place earlier (`by: -1`) or later (`by: 1`). Unchanged at
    /// either end, or for a provider that is not listed.
    public static func moving(_ provider: SummaryProvider, by offset: Int, config: Config) -> [SummaryProvider] {
        var list = listed(config)
        guard let here = list.firstIndex(of: provider) else { return list }
        let there = here + offset
        guard list.indices.contains(there) else { return list }
        list.swapAt(here, there)
        return list
    }

    /// What `SUMMARY_PROVIDERS` is written as.
    public static func value(_ list: [SummaryProvider]) -> String {
        list.map(\.rawValue).joined(separator: ",")
    }

    static func isInDefaultOrder(_ list: [SummaryProvider]) -> Bool {
        let positions = list.compactMap { defaultOrder.firstIndex(of: $0) }
        return positions == positions.sorted()
    }

    /// The ready page's sentence when two or more are connected: `Worklens tries Claude first,
    /// then ChatGPT. Settings → Connections changes the order.` Nil for one or none.
    public static func orderSentence(_ order: [SummaryProvider]) -> String? {
        let names = order.map(SummaryConnection.name)
        switch names.count {
        case 2:
            return L10n.format(
                "Worklens tries %@ first, then %@. Settings \u{2192} Connections changes the order.",
                names[0], names[1])
        case 3...:
            return L10n.format(
                "Worklens tries %@ first, then %@, then %@. Settings \u{2192} Connections changes the order.",
                names[0], names[1], names[2])
        default:
            return nil
        }
    }
}

// MARK: - Notices

/// The notices about summarizing that come from what the chain has learned, re-derived every
/// time they are asked for so a notice can never outlive its cause.
public enum SummaryNotices {
    /// One provider the chain is skipping, and why.
    public struct Skip: Sendable, Equatable {
        public let provider: SummaryProvider
        public let until: Date
        public let kind: DescribeHealth.Failure.Kind

        public init(provider: SummaryProvider, until: Date, kind: DescribeHealth.Failure.Kind) {
            self.provider = provider
            self.until = until
            self.kind = kind
        }
    }

    /// "N screenshots are waiting" waits for this many.
    public static let backlogThreshold = 100
    /// A screenshot younger than this is waiting for its turn, not stuck: a batch that is not due
    /// yet is not a problem, so it is never counted.
    public static let pastDueAfter: TimeInterval = 60 * 60

    /// The issues `derive` decides. Any of them not in its answer is cleared.
    public static let derivedIssues: [SetupIssue] = [.claudeSignedOut, .codexSignedOut, .subscriptionLimit]

    /// Whether a skip means the provider cannot be used until the person acts or the plan resets.
    /// A sign-in that stopped working stays a problem after its quarter hour runs out: only a
    /// call that works, or a status check that says it is signed in again, clears it.
    static func blocks(_ skip: Skip, now: Date) -> Bool {
        switch skip.kind {
        case .signedOut, .notSubscription, .notInstalled: true
        default: skip.until > now
        }
    }

    /// Which issues are open, with their sentence. `order` is the effective order
    /// (`SummaryProviders.effective`); a skip for a provider not in it says nothing.
    public static func derive(
        order: [SummaryProvider], skips: [Skip], now: Date = Date(),
        timeZone: TimeZone = .current, locale: Locale = Format.fixed
    ) -> [SetupIssue: String] {
        let relevant = order.compactMap { provider in skips.first { $0.provider == provider } }
        let blocked = Set(relevant.filter { blocks($0, now: now) }.map(\.provider))
        let summarizing = order.first { !blocked.contains($0) }
        var issues: [SetupIssue: String] = [:]

        for skip in relevant {
            guard let tool = skip.provider.tool else { continue }
            switch skip.kind {
            case .signedOut, .notSubscription:
                let issue: SetupIssue = tool == .claude ? .claudeSignedOut : .codexSignedOut
                issues[issue] = signedOutMessage(tool, summarizing: summarizing)
            case let .usageLimit(resetsAt):
                guard skip.until > now, issues[.subscriptionLimit] == nil else { continue }
                issues[.subscriptionLimit] = limitMessage(
                    tool, summarizing: summarizing, until: resetsAt == nil ? nil : skip.until,
                    timeZone: timeZone, locale: locale
                )
            default:
                continue
            }
        }
        return issues
    }

    /// `Your Claude sign-in stopped working: run claude auth login in Terminal. ChatGPT is
    /// summarizing for now.`
    public static func signedOutMessage(_ tool: SubscriptionTool, summarizing: SummaryProvider?) -> String {
        let plan = DescribeHealth.planName(tool)
        if let summarizing {
            return L10n.format(
                "Your %@ sign-in stopped working: run %@ in Terminal. %@ is summarizing for now.",
                plan, tool.loginCommand, SummaryConnection.name(summarizing))
        }
        return L10n.format(
            "Your %@ sign-in stopped working: run %@ in Terminal. Nothing is summarized until you do.",
            plan, tool.loginCommand)
    }

    /// `Your Claude plan hit its limit; ChatGPT is summarizing until 15:40.`
    public static func limitMessage(
        _ tool: SubscriptionTool, summarizing: SummaryProvider?, until: Date?,
        timeZone: TimeZone = .current, locale: Locale = Format.fixed
    ) -> String {
        let plan = DescribeHealth.planName(tool)
        guard let until else {
            if let summarizing {
                return L10n.format(
                    "Your %@ plan hit its limit; %@ is summarizing for now.", plan, SummaryConnection.name(summarizing))
            }
            return L10n.format("Your %@ plan hit its limit; nothing is summarized until it resets.", plan)
        }
        let clock = Format.clock(until, timeZone: timeZone, locale: locale)
        if let summarizing {
            return L10n.format(
                "Your %@ plan hit its limit; %@ is summarizing until %@.", plan, SummaryConnection.name(summarizing), clock)
        }
        return L10n.format("Your %@ plan hit its limit; nothing is summarized until %@.", plan, clock)
    }

    /// What went wrong the last time a provider was tried, for its row in Settings →
    /// Connections, and the troubleshooting section that explains it. Nil when the chain is not
    /// skipping it, or when its skip has run out and was only about a slow or failed call.
    public static func rowProblem(
        _ provider: SummaryProvider, order: [SummaryProvider], skips: [Skip], now: Date = Date(),
        timeZone: TimeZone = .current, locale: Locale = Format.fixed
    ) -> (text: String, help: HelpLink?)? {
        guard let skip = skips.first(where: { $0.provider == provider }) else { return nil }
        let others = order.filter { other in
            other != provider && !skips.contains { $0.provider == other && blocks($0, now: now) }
        }
        let summarizing = others.first
        guard let tool = provider.tool else {
            guard skip.until > now else { return nil }
            return (L10n.string("Google did not take the last summary request. Worklens tries again in a few minutes."), nil)
        }
        switch skip.kind {
        case .signedOut, .notSubscription:
            return (signedOutMessage(tool, summarizing: summarizing), .signInStopped)
        case .notInstalled:
            return (L10n.format("%@ is not installed on this Mac.", DescribeHealth.commandName(tool)), nil)
        case let .usageLimit(resetsAt):
            guard skip.until > now else { return nil }
            return (
                limitMessage(
                    tool, summarizing: summarizing, until: resetsAt == nil ? nil : skip.until,
                    timeZone: timeZone, locale: locale),
                .planLimit
            )
        case .timedOut, .general:
            guard skip.until > now else { return nil }
            return (
                L10n.format(
                    "The last summary through %@ did not work. Worklens tries again in a few minutes.",
                    DescribeHealth.commandName(tool)),
                nil
            )
        }
    }

    /// `120 screenshots are waiting to be summarized.`, or nil below the threshold.
    public static func backlogMessage(waiting: Int, locale: Locale = Format.fixed) -> String? {
        guard waiting >= backlogThreshold else { return nil }
        return L10n.format(
            "%@ screenshots are waiting to be summarized: Settings \u{2192} Connections shows what each way of summarizing is doing.",
            Format.count(waiting, locale: locale))
    }
}
