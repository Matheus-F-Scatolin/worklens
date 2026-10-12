import Foundation

/// What every model call cost, what today has cost so far, and whether the next one may go out.
///
/// The cache is the only interesting part. `spendToday()` is asked on every menu open, before
/// every describe call and once per capture tick, so it cannot be a query each time; it is also
/// the number a budget is enforced on, so it cannot be allowed to drift. Both are satisfied by
/// re-reading `llm_calls` when the local day has rolled over or when the cached value is older
/// than `refreshInterval`, and by adding each recorded call to the total as it happens.
public actor CostTracker: CostGate {
    /// How stale the cached total may get before it is re-read. Calls this process makes are
    /// added immediately; this covers the ones another process (the CLI) made.
    public static let refreshInterval: TimeInterval = 60
    /// The window `estimate(purpose:)` averages over.
    public static let estimateDays = 30
    /// A pending frame older than this at the day rollover is never described: it would spend
    /// today's budget on yesterday's screen.
    public static let stalePendingAge: TimeInterval = 24 * 3600
    /// `app_state` key holding the last local day the rollover ran for.
    public static let lastRolloverKey = "cost_last_rollover_day"
    /// #137: `app_state` keys holding a one-day budget raise, one per local day.
    public static let overrideKeyPrefix = "budget_override_"
    /// The key today's raise is stored under. Local days, the same ones the spend is bucketed by.
    public static func overrideKey(day: String) -> String { "\(overrideKeyPrefix)\(day)" }

    private let db: Database
    private let ledger: LLMCallStore
    private let captures: CaptureStore
    private let appState: AppStateStore
    private let configuredBudget: Double
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    /// The local day `cachedSpend` is for, and when it was last read from the database.
    private var cachedDay: String?
    private var cachedSpend: Double = 0
    private var refreshedAt: Date = .distantPast
    /// #137: today's one-day raise, or 0. Read from `app_state` on the same cadence as the
    /// spend, so a raise made by the CLI or by another window is picked up within a refresh.
    private var overrideBudget: Double = 0
    /// Per-purpose rolling averages, computed at most once per `refreshInterval`.
    private var estimates: [LLMPurpose: Double] = [:]
    private var estimatesAt: Date = .distantPast

    public init(
        db: Database,
        config: Config,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.ledger = LLMCallStore(db)
        self.captures = CaptureStore(db)
        self.appState = AppStateStore(db)
        self.configuredBudget = config.dailyBudgetUSD
        self.timeZone = timeZone
        self.now = now
    }

    /// `DAILY_BUDGET_USD`, as the tracker was built with it. A changed budget arrives through
    /// `AppModel.reloadConfig()`, which builds a new tracker.
    public var configuredBudgetUSD: Double { configuredBudget }

    /// #137: the budget actually in force today — the configured one, or today's one-day raise
    /// when it is higher. This is the one place the number is resolved: `allows`,
    /// `isOverBudget`, `level()`, the menu, Settings and the pre-report confirmation
    /// all read it from here, so they cannot quote different budgets.
    public var budgetUSD: Double { effectiveBudgetCached() }

    /// Today's one-day raise, or nil when there is none. What Settings shows.
    public func overrideToday() -> Double? {
        _ = spendTodayCached()
        return overrideBudget > 0 ? overrideBudget : nil
    }

    /// Raises today's budget to `amount` and puts today's budget-skipped frames back in the
    /// queue, returning how many were requeued.
    ///
    /// Additive only: it never lowers the configured budget or an earlier raise. The requeue is
    /// the half that makes the button mean anything — `CaptureScheduler` marks a frame
    /// `skipped`/`budget` at capture time while over budget, so without it "resume" would
    /// resume nothing for the frames already taken today. Only today's rows: yesterday's belong
    /// to the 24-hour retirement above.
    @discardableResult
    public func raiseBudgetToday(to amount: Double) throws -> Int {
        let day = today()
        let target = max(amount, effectiveBudgetCached())
        try appState.set(CostTracker.overrideKey(day: day), String(target))
        overrideBudget = target
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return 0 }
        return try captures.requeueBudgetSkipped(from: range.start, to: range.end)
    }

    /// `day`'s one-day raise, or nil.
    public static func override(on day: String, appState: AppStateStore) -> Double? {
        let raw = (try? appState.get(overrideKey(day: day))) ?? nil
        return raw.flatMap(Double.init)
    }

    /// What one click should raise the budget to: the spend so far, rounded up to the dollar,
    /// plus fifty cents. Enough to describe the backlog and a while longer, small enough that
    /// clicking it is not a decision to think about.
    public static func suggestedRaise(spend: Double) -> Double {
        (spend.rounded(.up)) + 0.50
    }

    // MARK: Recording

    /// Inserts a call and re-reads today's total, so the very next `isOverBudget` already knows
    /// about it. Re-read rather than added: the row is in the table by then, and adding to a
    /// cached value that may itself have just been re-read would count the call twice.
    public func record(_ call: LLMCall) throws {
        try ledger.insert(call)
        refreshedAt = .distantPast
        _ = spendTodayCached()
    }

    /// Invalidates the cached total. Called by the stages after they write their own ledger row,
    /// which is what keeps the budget from overshooting by a whole refresh interval.
    /// Declared `async` to match the protocol requirement exactly. A sync actor method is an
    /// *overload* of an `async` requirement rather than its witness, and in an async context
    /// Swift then picks the protocol extension's no-op default — so the invalidation silently
    /// never happened. Found by a test that asserted the total moved.
    public func ledgerChanged() async {
        refreshedAt = .distantPast
    }

    // MARK: Reading

    /// Today's spend in USD. Cached; re-read on a day rollover and every `refreshInterval`.
    public func spendToday() -> Double { spendTodayCached() }

    public var isOverBudget: Bool {
        get async {
            let budget = effectiveBudgetCached()
            return budget > 0 && spendTodayCached() >= budget - CostTracker.epsilon
        }
    }

    /// The same tolerance `SpendLevel` uses: a spend of exactly the budget must read as over,
    /// and floating-point sums of cents do not land on round numbers.
    static let epsilon = 1e-9

    public func allows(_ purpose: LLMPurpose, userInitiated: Bool) async -> Bool {
        let budget = effectiveBudgetCached()
        guard budget > 0 else { return true }
        guard spendTodayCached() >= budget - CostTracker.epsilon else { return true }
        return CostPolicy.allowsOverdraft(purpose, userInitiated: userInitiated)
    }

    public func level() -> SpendLevel {
        SpendLevel.of(spend: spendTodayCached(), budget: effectiveBudgetCached())
    }

    public func summary(days: Int) throws -> [DailySpend] {
        try ledger.summary(days: days, timeZone: timeZone, now: now())
    }

    /// What one more call of this kind is likely to cost: the mean of the successful ones over
    /// the last 30 days, or a conservative built-in guess when there is no history yet.
    ///
    /// This is what the menu's confirmation quotes, so a wrong-but-plausible number beats none:
    /// asking "generate anyway?" without saying roughly what for is not a real question.
    public func estimate(purpose: LLMPurpose) -> Double {
        if now().timeIntervalSince(estimatesAt) >= CostTracker.refreshInterval {
            estimates = [:]
            estimatesAt = now()
        }
        if let cached = estimates[purpose] { return cached }
        let measured = (try? ledger.averageCost(
            purpose: purpose, days: CostTracker.estimateDays, timeZone: timeZone, now: now()
        )) ?? nil
        let value = measured ?? CostTracker.firstGuess(purpose)
        estimates[purpose] = value
        return value
    }

    /// Before any call of a kind has been made. Rounded up from the prices in `docs/decisions.md` (cost model)
    /// rather than computed: it exists only so the first confirmation has a number in it.
    static func firstGuess(_ purpose: LLMPurpose) -> Double {
        switch purpose {
        case .describe: return 0.0004
        case .reportDaily: return 0.06
        case .reportWeekly: return 0.10
        case .chat: return 0.05
        case .rangeResolve: return 0.005
        case .taxonomy: return 0.04
        // A models-list GET bills nothing, so this is not a guess (#124).
        case .verify: return 0
        }
    }

    // MARK: The rollover

    /// Called on the app's 30-second timer. Refreshes the cached total and, the first time it
    /// runs on a new local day, retires yesterday's leftovers.
    ///
    /// Returns the number of stale pending frames it marked, so the caller can log it once.
    @discardableResult
    public func tick() -> Int {
        let day = today()
        refresh(day: day)

        // Once per local day, and persisted: a Mac that was asleep at midnight still retires
        // yesterday's leftovers the first time the tracker runs after it wakes. On a brand-new
        // database the stored day is nil, so the first tick also clears any backlog a previous
        // install left behind — which is the same decision for the same reason.
        let stored = (try? appState.get(CostTracker.lastRolloverKey)) ?? nil
        guard stored != day else { return 0 }
        try? appState.set(CostTracker.lastRolloverKey, day)
        // #137: a raise is good for one day. Dropping the older rows here is what keeps
        // `app_state` from growing one row per day the budget was ever raised.
        clearStaleOverrides(keeping: day)
        let marked = (try? markStalePending()) ?? 0
        if marked > 0 {
            Log.describe.info("\(marked) frames from before yesterday retired as skipped/budget")
        }
        return marked
    }

    /// Marks every still-pending frame older than 24 hours `skipped` / `budget`.
    ///
    /// Not a cost calculation but a cost decision: a backlog that survived a day did so because
    /// the budget stopped it, and describing it now would spend today's money on a screen nobody
    /// remembers. The rows stay, so the timeline still shows the time.
    @discardableResult
    public func markStalePending() throws -> Int {
        try captures.markStalePendingOverBudget(
            before: now().addingTimeInterval(-CostTracker.stalePendingAge)
        )
    }

    // MARK: Cache

    private func today() -> String { DayBoundaries.dayString(now(), timeZone: timeZone) }

    /// Today's raise, dropped to 0 when it is for another day. Cheap: the cached value is only
    /// re-read when the spend is.
    private func effectiveBudgetCached() -> Double {
        _ = spendTodayCached()
        return max(configuredBudget, overrideBudget)
    }

    private func clearStaleOverrides(keeping day: String) {
        let keys = (try? appState.keys(withPrefix: CostTracker.overrideKeyPrefix)) ?? []
        for key in keys where key != CostTracker.overrideKey(day: day) {
            try? appState.delete(key)
        }
    }

    private func spendTodayCached() -> Double {
        let day = today()
        if cachedDay == day, now().timeIntervalSince(refreshedAt) < CostTracker.refreshInterval {
            return cachedSpend
        }
        return refresh(day: day)
    }

    @discardableResult
    private func refresh(day: String) -> Double {
        guard let range = DayBoundaries.range(day: day, timeZone: timeZone) else { return cachedSpend }
        cachedSpend = (try? ledger.spend(from: range.start, to: range.end)) ?? cachedSpend
        overrideBudget = CostTracker.override(on: day, appState: appState) ?? 0
        cachedDay = day
        refreshedAt = now()
        return cachedSpend
    }
}
