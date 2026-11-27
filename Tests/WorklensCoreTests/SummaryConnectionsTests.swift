import Foundation
import Testing
@testable import WorklensCore

@Suite("How Worklens summarizes: cards, order and notices")
struct SummaryConnectionsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!

    func status(_ tool: SubscriptionTool, _ login: SubscriptionStatus.Login, plan: String? = nil, expires: Date? = nil) -> SubscriptionStatus {
        SubscriptionStatus(tool: tool, executable: "/usr/local/bin/\(tool.rawValue)", login: login, plan: plan, loginExpiresAt: expires)
    }

    func config(_ providers: [SummaryProvider] = [], key: String? = nil) -> Config {
        var config = Config.defaults()
        config.summaryProviders = providers
        config.geminiAPIKey = key
        return config
    }

    // MARK: Cards

    @Test("a subscription card moves from checking to connected")
    func subscriptionStates() {
        let empty = config()
        #expect(SummaryConnection.make(.claude, config: empty, status: nil, now: now).state == .checking)
        #expect(SummaryConnection.make(.claude, config: empty, status: status(.claude, .notInstalled), now: now).state == .notInstalled)
        let signedOut = SummaryConnection.make(.claude, config: empty, status: status(.claude, .signedOut), now: now)
        #expect(signedOut.state == .signedOut)
        #expect(signedOut.needsSignIn)
        #expect(signedOut.loginCommand == SubscriptionTool.claude.loginCommand)
        #expect(signedOut.level == .attention)
        let apiKey = SummaryConnection.make(.codex, config: empty, status: status(.codex, .notSubscription(method: "api_key")), now: now)
        #expect(apiKey.state == .notSubscription)
        #expect(apiKey.needsSignIn)
        let ready = SummaryConnection.make(.claude, config: empty, status: status(.claude, .subscription, plan: "max"), now: now)
        #expect(ready.state == .ready(plan: "max"))
        #expect(!ready.isConnected)
        #expect(ready.level == .neutral)
        #expect(ready.stateLine == "Signed in with your Claude Max plan.")
        let connected = SummaryConnection.make(.claude, config: config([.claude]), status: status(.claude, .subscription, plan: "max"), now: now)
        #expect(connected.isConnected)
        #expect(connected.level == .ok)
        #expect(connected.stateLine == "Connected. Worklens summarizes with your Claude Max plan.")
        #expect(!connected.needsSignIn)
    }

    @Test("a sign-in that ran out reads as signed out, and a listed one is a problem")
    func expired() {
        let card = SummaryConnection.make(
            .claude, config: config([.claude]),
            status: status(.claude, .subscription, expires: now.addingTimeInterval(-60)), now: now)
        #expect(card.state == .signedOut)
        #expect(card.listed)
        #expect(card.level == .problem)
        #expect(card.expiryLine(timeZone: utc) != nil)
        #expect(SummaryConnection.make(.codex, config: config(), status: status(.codex, .subscription), now: now).expiryLine() == nil)
    }

    @Test("Gemini asks only for a key")
    func gemini() {
        #expect(SummaryConnection.make(.gemini, config: config(), status: nil).state == .needsKey)
        #expect(SummaryConnection.make(.gemini, config: config(key: "k"), status: nil).isConnected, "a key alone is the install from before")
        #expect(SummaryConnection.make(.gemini, config: config([.claude], key: "k"), status: nil).state == .ready(plan: nil))
        #expect(SummaryConnection.make(.gemini, config: config([.claude, .gemini], key: "k"), status: nil).isConnected)
        #expect(!SummaryConnection.make(.gemini, config: config([.gemini]), status: nil).needsSignIn)
    }

    @Test("the three cards come in the welcome window's order")
    func all() {
        let cards = SummaryConnection.all(config: config(), statuses: [:], now: now)
        #expect(cards.map(\.provider) == [.claude, .codex, .gemini])
    }

    // MARK: Order

    @Test("Connect keeps the default order until the person reorders")
    func connecting() {
        #expect(SummaryProviders.connecting(.claude, config: config()) == [.claude])
        #expect(SummaryProviders.connecting(.claude, config: config(key: "k")) == [.claude, .gemini],
                "connecting Claude to a Gemini install tries Claude first")
        #expect(SummaryProviders.connecting(.codex, config: config([.claude, .gemini])) == [.claude, .codex, .gemini])
        #expect(SummaryProviders.connecting(.claude, config: config([.gemini, .codex])) == [.gemini, .codex, .claude])
        #expect(SummaryProviders.connecting(.claude, config: config([.claude])) == [.claude])
    }

    @Test("Disconnect only takes the name out; the arrows swap neighbours")
    func disconnectingAndMoving() {
        let three = config([.claude, .codex, .gemini], key: "k")
        #expect(SummaryProviders.disconnecting(.codex, config: three) == [.claude, .gemini])
        #expect(SummaryProviders.disconnecting(.gemini, config: config(key: "k")).isEmpty)
        #expect(SummaryProviders.moving(.codex, by: -1, config: three) == [.codex, .claude, .gemini])
        #expect(SummaryProviders.moving(.codex, by: 1, config: three) == [.claude, .gemini, .codex])
        #expect(SummaryProviders.moving(.claude, by: -1, config: three) == [.claude, .codex, .gemini])
        #expect(SummaryProviders.moving(.gemini, by: 1, config: config([.claude])) == [.claude])
        #expect(SummaryProviders.value([.codex, .gemini]) == "codex,gemini")
    }

    @Test("the ready page names the order only for two or more")
    func orderSentence() {
        #expect(SummaryProviders.orderSentence([.claude]) == nil)
        #expect(SummaryProviders.orderSentence([]) == nil)
        #expect(SummaryProviders.orderSentence([.claude, .codex])
            == "Worklens tries Claude first, then ChatGPT. Settings \u{2192} Connections changes the order.")
        #expect(SummaryProviders.orderSentence([.codex, .gemini, .claude])
            == "Worklens tries ChatGPT first, then Gemini, then Claude. Settings \u{2192} Connections changes the order.")
    }

    // MARK: Notices

    @Test("a signed-out Claude names the one summarizing instead")
    func signedOut() {
        let skip = SummaryNotices.Skip(provider: .claude, until: now.addingTimeInterval(-1), kind: .signedOut)
        let open = SummaryNotices.derive(order: [.claude, .codex], skips: [skip], now: now)
        #expect(open[.claudeSignedOut]
            == "Your Claude sign-in stopped working: run \(SubscriptionTool.claude.loginCommand) in Terminal. ChatGPT is summarizing for now.",
            "a sign-in that stopped working stays a problem after its quarter hour")
        #expect(open[.codexSignedOut] == nil)
        let alone = SummaryNotices.derive(order: [.claude], skips: [skip], now: now)
        #expect(alone[.claudeSignedOut]?.hasSuffix("Nothing is summarized until you do.") == true)
        #expect(SummaryNotices.derive(order: [.codex], skips: [skip], now: now).isEmpty, "a provider not in the order says nothing")
        #expect(SummaryNotices.derive(order: [.claude, .codex], skips: [], now: now).isEmpty)
    }

    @Test("a plan limit shows only until it resets")
    func limit() {
        let reset = now.addingTimeInterval(3600)
        let skip = SummaryNotices.Skip(provider: .codex, until: reset, kind: .usageLimit(resetsAt: reset))
        let open = SummaryNotices.derive(order: [.codex, .gemini], skips: [skip], now: now, timeZone: utc)
        let clock = Format.clock(reset, timeZone: utc, locale: Format.fixed)
        #expect(open[.subscriptionLimit] == "Your ChatGPT plan hit its limit; Gemini is summarizing until \(clock).")
        #expect(SummaryNotices.derive(order: [.codex, .gemini], skips: [skip], now: reset.addingTimeInterval(1)).isEmpty)
        let unknown = SummaryNotices.Skip(provider: .claude, until: reset, kind: .usageLimit(resetsAt: nil))
        #expect(SummaryNotices.derive(order: [.claude], skips: [unknown], now: now)[.subscriptionLimit]
            == "Your Claude plan hit its limit; nothing is summarized until it resets.")
    }

    @Test("a row says what went wrong and which section explains it")
    func rowProblem() {
        let later = now.addingTimeInterval(600)
        let signedOut = SummaryNotices.Skip(provider: .claude, until: later, kind: .signedOut)
        let problem = SummaryNotices.rowProblem(.claude, order: [.claude, .gemini], skips: [signedOut], now: now)
        #expect(problem?.help == .signInStopped)
        #expect(problem?.text.hasSuffix("Gemini is summarizing for now.") == true)
        #expect(SummaryNotices.rowProblem(.gemini, order: [.claude, .gemini], skips: [signedOut], now: now) == nil)

        let slow = SummaryNotices.Skip(provider: .codex, until: later, kind: .timedOut)
        #expect(SummaryNotices.rowProblem(.codex, order: [.codex], skips: [slow], now: now)?.text
            == "The last summary through Codex did not work. Worklens tries again in a few minutes.")
        #expect(SummaryNotices.rowProblem(.codex, order: [.codex], skips: [slow], now: later.addingTimeInterval(1)) == nil,
                "a slow call is forgotten once its skip runs out")

        let limit = SummaryNotices.Skip(provider: .codex, until: later, kind: .usageLimit(resetsAt: later))
        #expect(SummaryNotices.rowProblem(.codex, order: [.codex], skips: [limit], now: now)?.help == .planLimit)

        let missing = SummaryNotices.Skip(provider: .claude, until: later, kind: .notInstalled)
        #expect(SummaryNotices.rowProblem(.claude, order: [.claude], skips: [missing], now: now)?.text
            == "Claude Code is not installed on this Mac.")

        let google = SummaryNotices.Skip(provider: .gemini, until: later, kind: .general)
        #expect(SummaryNotices.rowProblem(.gemini, order: [.gemini], skips: [google], now: now)?.help == nil)
    }

    @Test("the backlog notice waits for a hundred")
    func backlog() {
        #expect(SummaryNotices.backlogMessage(waiting: 99) == nil)
        #expect(SummaryNotices.backlogMessage(waiting: 120)?.hasPrefix("120 screenshots are waiting to be summarized") == true)
    }

    @Test("every summarizing notice has a Learn more")
    func helpLinks() {
        #expect(SetupIssue.noSummarizer.helpLink == .nothingSummarizes)
        #expect(SetupIssue.claudeSignedOut.helpLink == .signInStopped)
        #expect(SetupIssue.codexSignedOut.helpLink == .signInStopped)
        #expect(SetupIssue.subscriptionLimit.helpLink == .planLimit)
        #expect(SetupIssue.summariesWaiting.helpLink == .screenshotsWaiting)
        #expect(SummaryNotices.derivedIssues.allSatisfy { $0.helpLink != nil })
    }
}
