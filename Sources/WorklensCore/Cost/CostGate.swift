import Foundation

/// Asked before every LLM call: may this one go out, given what today has already cost?
///
/// `CostTracker` is the real implementation over `llm_calls`. Callers depend on this protocol,
/// never on the concrete type, which is what lets the tests run with `AlwaysAllowCostGate`.
public protocol CostGate: Sendable {
    /// True once today's spend has reached `DAILY_BUDGET_USD`. What the menu colours itself with.
    var isOverBudget: Bool { get async }

    /// Whether one call may go out. `userInitiated` marks a call a person just clicked for, as
    /// opposed to the work Worklens does on its own.
    func allows(_ purpose: LLMPurpose, userInitiated: Bool) async -> Bool

    /// Tells the gate that a row was just written to `llm_calls`, so a cached total cannot lag
    /// the ledger it is guarding. The stages record their own calls (each has the tokens and the
    /// latency to hand); this is how the gate hears about it.
    func ledgerChanged() async
}

public extension CostGate {
    /// The automatic case: what the capture scheduler and the describe worker ask.
    func allows(_ purpose: LLMPurpose) async -> Bool {
        await allows(purpose, userInitiated: false)
    }

    /// `CostPolicy` applied to `isOverBudget`. A gate only has to answer whether the budget is
    /// spent; what that means for each purpose is a policy decision, and it lives in one place.
    /// `CostTracker` overrides this to answer from its cached total rather than re-reading.
    func allows(_ purpose: LLMPurpose, userInitiated: Bool) async -> Bool {
        guard await isOverBudget else { return true }
        return CostPolicy.allowsOverdraft(purpose, userInitiated: userInitiated)
    }

    /// A gate that keeps no state needs no telling.
    func ledgerChanged() async {}
}

/// What the daily budget actually stops, in one place.
///
/// The budget is a **hard** stop on the work Worklens does by itself: describing frames and the
/// scheduled taxonomy review keep spending forever if nothing stops them, and a runaway there is
/// exactly the failure the budget exists to prevent.
///
/// It is an **advisory** stop on everything else. A report you clicked costs about five cents
/// and you are standing right there; refusing it would make the tool feel broken, so the menu
/// tells you the price and lets you decide. The rule in one line: **nothing spends without
/// either a budget under it or a person behind it.**
public enum CostPolicy {
    /// Whether `purpose` may still go out once the budget is spent.
    public static func allowsOverdraft(_ purpose: LLMPurpose, userInitiated: Bool) -> Bool {
        switch purpose {
        case .describe:
            // The only absolute stop, and the only path whose volume is unbounded: one frame a
            // minute, for as long as the Mac is on. Frames keep being captured — they queue up
            // as `skipped/budget` — and the way to resume is to raise DAILY_BUDGET_USD, which
            // is a deliberate act rather than a click-through.
            return false
        case .verify:
            // #124: free, and always a button somebody just pressed. A budget that stopped you
            // checking why nothing is being described would be the budget causing the outage.
            return true
        case .reportDaily, .reportWeekly, .chat, .rangeResolve, .taxonomy:
            // None of these has a caller left: `chat`, `rangeResolve` and `taxonomy` went with
            // #95 and #86, the two report purposes with the reports (2026-10-05). The cases stay
            // because old `llm_calls` rows still decode to them.
            return userInitiated
        }
    }
}

/// The no-op gate: never over budget. The test default, and nothing else — every place the app
/// wires a gate now wires a `CostTracker`.
public struct AlwaysAllowCostGate: CostGate {
    public init() {}
    public var isOverBudget: Bool { get async { false } }
    public func allows(_ purpose: LLMPurpose, userInitiated: Bool) async -> Bool { true }
}
