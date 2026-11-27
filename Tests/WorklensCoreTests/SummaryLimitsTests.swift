import Foundation
import Testing
@testable import WorklensCore

// Part 4 of summarizing through a plan: the headroom left in a Claude plan, the budget gating
// only what costs money, screenshots set aside while nothing could summarize, and the
// notifications about a sign-in and a backlog.

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

private func window(_ utilization: Double, resetsIn: TimeInterval?) -> ClaudeRateLimits.Window {
    ClaudeRateLimits.Window(
        utilization: utilization, resetsAt: resetsIn.map { t0.addingTimeInterval($0) }, status: "allowed")
}

private func limits(_ windows: [String: ClaudeRateLimits.Window]) -> ClaudeRateLimits {
    ClaudeRateLimits(status: "allowed", windows: windows)
}

private func describeRequest() -> DescribeRequest {
    DescribeRequest(
        imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xE0]), systemInstruction: "s", userPrompt: "u",
        schema: ["type": "object"])
}

private func reply(_ model: String) -> DescribeResponse {
    DescribeResponse(json: "{}", usage: LLMUsage(), costUSD: 0, latencyMs: 1, model: model)
}

/// A link that says whether it costs money and how long it wants to be left alone.
final class LimitStub: VisionDescriber, @unchecked Sendable {
    let provider: String
    let costsMoney: Bool
    private let lock = NSLock()
    private var calls = 0
    private var holdUntil: Date?
    private let result: Result<DescribeResponse, Error>

    init(_ provider: String, costsMoney: Bool, result: Result<DescribeResponse, Error>? = nil) {
        self.provider = provider
        self.costsMoney = costsMoney
        self.result = result ?? .success(reply(provider))
    }

    var callCount: Int { lock.withLock { calls } }
    func hold(until date: Date?) { lock.withLock { holdUntil = date } }
    func headroomUntil(now: Date) -> Date? { lock.withLock { holdUntil.flatMap { $0 > now ? $0 : nil } } }

    func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

private struct BrokeGate: CostGate {
    var isOverBudget: Bool { get async { true } }
}

@Suite("Plan headroom")
struct PlanHeadroomTests {
    @Test("below the threshold the plan is used; at it, left alone until that window resets")
    func threshold() {
        let under = limits(["five_hour": window(0.79, resetsIn: 3600)])
        #expect(PlanHeadroom.until(under, observedAt: t0, percent: 80, now: t0) == nil)
        let at = limits(["five_hour": window(0.80, resetsIn: 3600)])
        #expect(PlanHeadroom.until(at, observedAt: t0, percent: 80, now: t0) == t0.addingTimeInterval(3600))
    }

    @Test("two full windows: the later reset wins; a reading past its reset says nothing")
    func latestWindow() {
        let both = limits(["five_hour": window(0.9, resetsIn: 3600), "seven_day": window(0.85, resetsIn: 86_400)])
        #expect(PlanHeadroom.until(both, observedAt: t0, percent: 80, now: t0) == t0.addingTimeInterval(86_400))
        let stale = limits(["five_hour": window(0.95, resetsIn: -60)])
        #expect(PlanHeadroom.until(stale, observedAt: t0, percent: 80, now: t0) == nil)
    }

    @Test("100 never holds back, no reading never holds back, and no reset time holds a quarter hour")
    func edges() {
        let full = limits(["five_hour": window(0.99, resetsIn: 3600)])
        #expect(PlanHeadroom.until(full, observedAt: t0, percent: 100, now: t0) == nil)
        #expect(PlanHeadroom.until(nil, observedAt: nil, percent: 80, now: t0) == nil)
        let unknown = limits(["five_hour": window(0.9, resetsIn: nil)])
        #expect(PlanHeadroom.until(unknown, observedAt: t0, percent: 80, now: t0)
            == t0.addingTimeInterval(PlanHeadroom.unknownResetHold))
        #expect(PlanHeadroom.until(
            unknown, observedAt: t0, percent: 80, now: t0.addingTimeInterval(PlanHeadroom.unknownResetHold + 1)) == nil)
    }

    @Test("a far-off reset is capped at the chain's longest skip")
    func capped() {
        let far = limits(["seven_day": window(0.9, resetsIn: 30 * 86_400)])
        #expect(PlanHeadroom.until(far, observedAt: t0, percent: 80, now: t0)
            == t0.addingTimeInterval(DescriberChain.longestSkip))
    }

    @Test("Settings offers the usual shares, plus one the file set")
    func choices() {
        #expect(PlanHeadroom.choices(current: 80) == [50, 60, 70, 80, 90, 100])
        #expect(PlanHeadroom.choices(current: 75) == [50, 60, 70, 75, 80, 90, 100])
    }
}

@Suite("DescriberChain limits")
struct DescriberChainLimitTests {
    @Test("a plan past its headroom is skipped, not called, and tried again once it lifts")
    func headroomSkip() async throws {
        let clock = LockedBox(t0)
        let claude = LimitStub("claude", costsMoney: false)
        let gemini = LimitStub("gemini", costsMoney: true)
        claude.hold(until: t0.addingTimeInterval(3600))
        let chain = DescriberChain(
            [.init(claude, model: "sonnet"), .init(gemini, model: "flash-lite")], now: { clock.withLock { $0 } })

        let first = try await chain.describe(describeRequest())
        #expect(first.provider == "gemini")
        #expect(claude.callCount == 0)
        #expect(chain.skipped().contains { $0.provider == .claude && $0.kind == .headroom(resetsAt: t0.addingTimeInterval(3600)) })

        // A status check that finds Claude signed in does not undo the headroom.
        chain.forgetSkip(.claude)
        clock.withLock { $0 = t0.addingTimeInterval(3601) }
        claude.hold(until: nil)
        let second = try await chain.describe(describeRequest())
        #expect(second.provider == "claude")
    }

    @Test("over budget, a paid link is passed over without a call and a plan still answers")
    func budgetSkipsPaidOnly() async throws {
        let gemini = LimitStub("gemini", costsMoney: true)
        let claude = LimitStub("claude", costsMoney: false)
        let chain = DescriberChain(
            [.init(gemini, model: "flash-lite"), .init(claude, model: "sonnet")], budget: BrokeGate())
        let response = try await chain.describe(describeRequest())
        #expect(response.provider == "claude")
        #expect(gemini.callCount == 0)
    }

    @Test("when only a budget-stopped link could answer, the chain says so and calls nothing")
    func budgetSpent() async throws {
        let claude = LimitStub("claude", costsMoney: false, result: .failure(SubscriptionError.signedOut(.claude)))
        let gemini = LimitStub("gemini", costsMoney: true)
        let chain = DescriberChain(
            [.init(claude, model: "sonnet"), .init(gemini, model: "flash-lite")], budget: BrokeGate())
        await #expect(throws: (any Error).self) { try await chain.describe(describeRequest()) }
        do {
            _ = try await chain.describe(describeRequest())
        } catch {
            #expect(DescriberChain.isBudgetSpent(error))
        }
        #expect(gemini.callCount == 0)
    }

    @Test("a chain with a plan in it is free; one of paid links only is not")
    func costsMoney() {
        let plan = DescriberChain([
            .init(LimitStub("claude", costsMoney: false), model: "sonnet"),
            .init(LimitStub("gemini", costsMoney: true), model: "flash-lite"),
        ])
        #expect(!plan.costsMoney)
        let paid = DescriberChain([.init(LimitStub("gemini", costsMoney: true), model: "flash-lite")])
        #expect(paid.costsMoney)
    }

    @Test("the scheduler's gate lets describing through when a plan can summarize")
    func summaryBudgetGate() async {
        let plan = LimitStub("claude", costsMoney: false)
        #expect(await SummaryBudgetGate(BrokeGate(), describer: plan).allows(.describe))
        #expect(!(await SummaryBudgetGate(BrokeGate(), describer: nil).allows(.describe)))
        #expect(!(await SummaryBudgetGate(BrokeGate(), describer: LimitStub("gemini", costsMoney: true)).allows(.describe)))
        #expect(await SummaryBudgetGate(BrokeGate(), describer: plan).isOverBudget)
    }
}

@Suite("Plan usage in the ledger")
struct PlanUsageLedgerTests {
    private func call(_ provider: String, cost: Double, frames: Int = 1, error: String? = nil) -> LLMCall {
        LLMCall(provider: provider, model: "m", purpose: .describe, costUsd: cost, error: error, frames: frames, createdAt: t0)
    }

    @Test("a plan's $0 rows never drag the estimate of a paid call down")
    func averageExcludesPlans() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(call("gemini", cost: 0.20))
        try store.insert(call(ClaudeDescriber.provider, cost: 0))
        try store.insert(call(CodexDescriber.provider, cost: 0))
        let average = try store.averageCost(purpose: .describe, days: 1, timeZone: utc, now: t0)
        #expect(abs((average ?? 0) - 0.20) < 1e-9)
    }

    @Test("calls and screenshots per provider, successful calls only")
    func summaryUsage() throws {
        let db = try Database.inMemory()
        let store = LLMCallStore(db)
        try store.insert(call("claude", cost: 0, frames: 5))
        try store.insert(call("claude", cost: 0, frames: 3))
        try store.insert(call("claude", cost: 0, frames: 4, error: "signed out"))
        try store.insert(call("gemini", cost: 0.01))
        let usage = try store.summaryUsage(from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        #expect(usage["claude"] == ProviderUsage(calls: 2, screenshots: 8, costUSD: 0))
        #expect(usage["gemini"]?.calls == 1)
    }

    @Test("Usage shows dollars for Gemini only, and every way in the order")
    func providerRows() {
        let rows = UsageSummary.providerRows(
            order: [.claude, .codex, .gemini],
            usage: [
                "claude": ProviderUsage(calls: 2, screenshots: 8, costUSD: 0),
                "gemini": ProviderUsage(calls: 1, screenshots: 1, costUSD: 0.01),
            ],
            locale: Format.fixed)
        #expect(rows.map(\.provider) == ["claude", "codex", "gemini"])
        #expect(rows[0].detail == "2 calls · 8 screenshots")
        #expect(rows[1].detail == "Nothing summarized today")
        #expect(rows[2].detail.hasPrefix("1 call · 1 screenshot · $"))
    }
}

@Suite("Screenshots set aside while nothing could summarize")
struct UnavailableScreenshotTests {
    @Test("with no way available they wait 72 hours, not 24, and are set aside as unavailable")
    func seventyTwoHours() async throws {
        let db = try Database.inMemory()
        let cost = CostTracker(db: db, config: Config.defaults(), timeZone: utc, now: { t0 })
        let captures = CaptureStore(db)
        let twoDays = Capture(capturedAt: t0.addingTimeInterval(-2 * 86_400), imagePath: "a.jpg", describeStatus: .pending)
        let fourDays = Capture(capturedAt: t0.addingTimeInterval(-4 * 86_400), imagePath: "b.jpg", describeStatus: .pending)
        for capture in [twoDays, fourDays] { try captures.insert(capture) }

        await cost.setStaleReason(.unavailable)
        #expect(try await cost.markStalePending() == 1)
        #expect(try captures.fetch(id: twoDays.id)?.describeStatus == .pending)
        let aside = try captures.fetch(id: fourDays.id)
        #expect(aside?.describeStatus == .skipped)
        #expect(aside?.skipReason == .unavailable)
    }

    @Test("they go back in the queue while the screenshot is on disk; a budget skip stays")
    func requeue() throws {
        let db = try Database.inMemory()
        let captures = CaptureStore(db)
        let kept = Capture(capturedAt: t0, imagePath: "a.jpg", skipReason: .unavailable, describeStatus: .skipped)
        let gone = Capture(capturedAt: t0, imagePath: nil, skipReason: .unavailable, describeStatus: .skipped)
        let budget = Capture(capturedAt: t0, imagePath: "c.jpg", skipReason: .budget, describeStatus: .skipped)
        for capture in [kept, gone, budget] { try captures.insert(capture) }

        #expect(try captures.requeueUnavailableSkipped() == 1)
        #expect(try captures.fetch(id: kept.id)?.describeStatus == .pending)
        #expect(try captures.fetch(id: gone.id)?.describeStatus == .skipped)
        #expect(try captures.fetch(id: budget.id)?.skipReason == .budget)
    }

    @Test("the reason is budget unless every way in an order with a plan is out of reach")
    func staleReason() {
        let claudeOut = SummaryNotices.Skip(provider: .claude, until: t0.addingTimeInterval(900), kind: .signedOut)
        #expect(SummaryAlerts.staleReason(order: [.claude], skips: [claudeOut], signedOut: [], now: t0) == .unavailable)
        #expect(SummaryAlerts.staleReason(order: [.claude, .gemini], skips: [claudeOut], signedOut: [], now: t0) == .budget)
        #expect(SummaryAlerts.staleReason(order: [.gemini], skips: [], signedOut: [], now: t0) == .budget)
        #expect(SummaryAlerts.staleReason(order: [.claude], skips: [], signedOut: [.claude], now: t0) == .unavailable)
        #expect(SummaryAlerts.staleReason(order: [.claude], skips: [], signedOut: [], now: t0) == .budget)
    }
}

@Suite("Summary alerts")
struct SummaryAlertsTests {
    private func claude(expiresIn: TimeInterval?, login: SubscriptionStatus.Login = .subscription) -> [SubscriptionTool: SubscriptionStatus] {
        [.claude: SubscriptionStatus(
            tool: .claude, executable: "/c", login: login, loginExpiresAt: expiresIn.map { t0.addingTimeInterval($0) })]
    }

    @Test("three days and one day before a sign-in ends, once each; a new sign-in starts over")
    func expiryStages() {
        var memory = SummaryAlerts.Memory()
        let expires = t0.addingTimeInterval(5 * 86_400)
        func run(at now: Date, statuses: [SubscriptionTool: SubscriptionStatus]) -> [SummaryAlerts.Alert] {
            let (alerts, next) = SummaryAlerts.due(
                memory: memory, order: [.claude], statuses: statuses, signedOut: [], waiting: nil, now: now)
            memory = next
            return alerts
        }
        let statuses = [SubscriptionTool.claude: SubscriptionStatus(
            tool: .claude, executable: "/c", login: .subscription, loginExpiresAt: expires)]
        #expect(run(at: t0, statuses: statuses).isEmpty)
        let threeDays = t0.addingTimeInterval(2 * 86_400 + 60)
        #expect(run(at: threeDays, statuses: statuses) == [.signInEnding(.claude, expiresAt: expires)])
        #expect(run(at: threeDays.addingTimeInterval(3600), statuses: statuses).isEmpty)
        let oneDay = t0.addingTimeInterval(4 * 86_400 + 60)
        #expect(run(at: oneDay, statuses: statuses) == [.signInEnding(.claude, expiresAt: expires)])
        #expect(run(at: oneDay.addingTimeInterval(60), statuses: statuses).isEmpty)

        // Signed in again: a new end date, and both warnings are owed again.
        let renewed = expires.addingTimeInterval(2 * 86_400)
        let fresh = [SubscriptionTool.claude: SubscriptionStatus(
            tool: .claude, executable: "/c", login: .subscription, loginExpiresAt: renewed)]
        #expect(run(at: renewed.addingTimeInterval(-2 * 86_400), statuses: fresh)
            == [.signInEnding(.claude, expiresAt: renewed)])
    }

    @Test("a first look inside the last day sends only the one warning")
    func lateFirstLook() {
        let (alerts, memory) = SummaryAlerts.due(
            memory: .init(), order: [.claude], statuses: claude(expiresIn: 3600), signedOut: [], waiting: nil, now: t0)
        #expect(alerts.count == 1)
        let (again, _) = SummaryAlerts.due(
            memory: memory, order: [.claude], statuses: claude(expiresIn: 3600), signedOut: [], waiting: nil,
            now: t0.addingTimeInterval(600))
        #expect(again.isEmpty)
    }

    @Test("signed out once per occurrence, re-armed only by a status check that finds it working")
    func signedOutOnce() {
        var memory = SummaryAlerts.Memory()
        func run(_ signedOut: Set<SubscriptionTool>, _ statuses: [SubscriptionTool: SubscriptionStatus]) -> Int {
            let (alerts, next) = SummaryAlerts.due(
                memory: memory, order: [.claude, .codex], statuses: statuses, signedOut: signedOut, waiting: nil, now: t0)
            memory = next
            return alerts.count
        }
        #expect(run([.codex], [:]) == 1)
        #expect(run([.codex], [:]) == 0)
        // The skip ran out but nothing said it works: still the same occurrence.
        #expect(run([], [:]) == 0)
        #expect(run([.codex], [:]) == 0)
        let working = [SubscriptionTool.codex: SubscriptionStatus(tool: .codex, executable: "/x", login: .subscription)]
        #expect(run([], working) == 0)
        #expect(run([.codex], [:]) == 1)
    }

    @Test("the backlog notifies when it reaches the threshold, and again only after it dropped")
    func backlogLatch() {
        var memory = SummaryAlerts.Memory()
        func run(_ waiting: Int?) -> [SummaryAlerts.Alert] {
            let (alerts, next) = SummaryAlerts.due(
                memory: memory, order: [.claude], statuses: [:], signedOut: [], waiting: waiting, now: t0)
            memory = next
            return alerts
        }
        #expect(run(99).isEmpty)
        #expect(run(100) == [.screenshotsWaiting(100)])
        #expect(run(150).isEmpty)
        #expect(run(nil).isEmpty)
        #expect(run(20).isEmpty)
        #expect(run(120) == [.screenshotsWaiting(120)])
    }

    @Test("a plan not in the order says nothing, and its memory is dropped")
    func notInOrder() {
        var memory = SummaryAlerts.Memory()
        memory.signedOut = ["claude"]
        let (alerts, next) = SummaryAlerts.due(
            memory: memory, order: [.gemini], statuses: claude(expiresIn: 3600), signedOut: [.claude], waiting: nil, now: t0)
        #expect(alerts.isEmpty)
        #expect(next.signedOut.isEmpty)
    }

    @Test("the memory survives app_state as JSON, and a garbled value starts clean")
    func memoryRoundTrip() {
        var memory = SummaryAlerts.Memory()
        memory.backlog = true
        memory.signedOut = ["codex"]
        memory.expiry["claude"] = .init(expiresAt: t0, warned: 86_400)
        #expect(SummaryAlerts.Memory.decode(memory.encoded) == memory)
        #expect(SummaryAlerts.Memory.decode("not json") == SummaryAlerts.Memory())
        #expect(SummaryAlerts.Memory.decode(nil) == SummaryAlerts.Memory())
    }

    @Test("an end date that passed is signed out, as is a failed call")
    func signedOutTools() {
        let expired = claude(expiresIn: -60)
        #expect(SummaryAlerts.signedOutTools(order: [.claude], skips: [], statuses: expired, now: t0) == [.claude])
        let skip = SummaryNotices.Skip(provider: .codex, until: t0.addingTimeInterval(900), kind: .signedOut)
        #expect(SummaryAlerts.signedOutTools(order: [.claude, .codex], skips: [skip], statuses: claude(expiresIn: 3600), now: t0)
            == [.codex])
        #expect(SummaryAlerts.summarizing(order: [.claude, .codex], skips: [skip], signedOut: [.codex], now: t0) == .claude)
        #expect(SummaryAlerts.summarizing(order: [.codex], skips: [skip], signedOut: [.codex], now: t0) == nil)
    }

    @Test("ending soon means a plan sign-in inside three days, still ahead")
    func endingSoon() {
        #expect(SummaryAlerts.endingSoon(.claude, statuses: claude(expiresIn: 2 * 86_400), now: t0) != nil)
        #expect(SummaryAlerts.endingSoon(.claude, statuses: claude(expiresIn: 4 * 86_400), now: t0) == nil)
        #expect(SummaryAlerts.endingSoon(.claude, statuses: claude(expiresIn: -1), now: t0) == nil)
        #expect(SummaryAlerts.endingSoon(
            .claude, statuses: claude(expiresIn: 3600, login: .notSubscription(method: "api_key")), now: t0) == nil)
    }

    @Test("a batch still inside its window is never counted as past due")
    func pastDueOutlastsBatches() {
        #expect(SummaryNotices.pastDueAfter > TimeInterval((SummaryBatching.minuteChoices.max() ?? 0) * 60))
    }
}

@Suite("Plan limit copy")
struct PlanLimitCopyTests {
    @Test("the sign-in warning names a weekday, tomorrow or today, never a date")
    func endingBody() {
        let threeDays = NotificationCopy.signInEndingBody(
            .claude, expiresAt: t0.addingTimeInterval(3 * 86_400), now: t0, timeZone: utc)
        #expect(threeDays.contains(Format.weekday(t0.addingTimeInterval(3 * 86_400), timeZone: utc, locale: Format.fixed)))
        #expect(threeDays.contains("claude auth login"))
        #expect(NotificationCopy.signInEndingBody(
            .claude, expiresAt: t0.addingTimeInterval(86_400), now: t0, timeZone: utc).contains("tomorrow"))
    }

    @Test("ran out: names what took over, or says nothing is summarized")
    func endedBody() {
        #expect(NotificationCopy.signInEndedBody(.claude, summarizing: .codex).contains("ChatGPT is summarizing"))
        #expect(NotificationCopy.signInEndedBody(.claude, summarizing: nil).contains("nothing is summarized"))
    }

    @Test("headroom raises the plan notice only when nothing else summarizes")
    func headroomNotice() {
        let skip = SummaryNotices.Skip(
            provider: .claude, until: t0.addingTimeInterval(3600), kind: .headroom(resetsAt: t0.addingTimeInterval(3600)))
        let alone = SummaryNotices.derive(order: [.claude], skips: [skip], now: t0, timeZone: utc)
        #expect(alone[.subscriptionLimit]?.contains("nothing is summarized") == true)
        let covered = SummaryNotices.derive(order: [.claude, .gemini], skips: [skip], now: t0, timeZone: utc)
        #expect(covered[.subscriptionLimit] == nil)
        let row = SummaryNotices.rowProblem(.claude, order: [.claude, .gemini], skips: [skip], now: t0, timeZone: utc)
        #expect(row?.help == .planHeadroom)
        #expect(SummaryNotices.rowProblem(
            .claude, order: [.claude], skips: [skip], now: t0.addingTimeInterval(3601), timeZone: utc) == nil)
    }

    @Test("a clock on the same day, a weekday and a clock on another")
    func clockOrDay() {
        let same = Format.clockOrDay(t0.addingTimeInterval(60), now: t0, timeZone: utc, locale: Format.fixed)
        let later = Format.clockOrDay(t0.addingTimeInterval(2 * 86_400), now: t0, timeZone: utc, locale: Format.fixed)
        #expect(!same.contains(" "))
        #expect(later.hasPrefix(Format.weekday(t0.addingTimeInterval(2 * 86_400), timeZone: utc, locale: Format.fixed)))
        #expect(Format.percent(80) == "80%")
    }

    @Test("the new notice leads to Connections and its own troubleshooting paragraph")
    func endingIssue() {
        #expect(SetupIssue.claudeSignInEnding.action == .openAccountSettings)
        #expect(!SetupIssue.claudeSignInEnding.blocksWork)
        #expect(SetupIssue.claudeSignInEnding.helpLink == .signInEnding)
    }
}
