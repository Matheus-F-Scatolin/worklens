import AppKit
import Foundation
import Testing
@testable import WorklensCore

/// #137: what the menu says and offers while today is over budget.
@Suite("Menu, over budget")
struct BudgetMenuTests {
    private func model(spend: Double, budget: Double, scheduler: SchedulerState = .budgetExceeded) -> MenuModel {
        var counts = MenuCounts.zero
        counts.spendUSD = spend
        return MenuModel(
            state: MenuState(scheduler: scheduler, counts: counts, budgetUSD: budget),
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test("over budget shows its own icon, not the healthy capturing one")
    func icon() {
        #expect(MenuModel.icon(for: .budgetExceeded) == .overBudget)
        #expect(MenuModel.icon(for: .budgetExceeded) != MenuModel.icon(for: .running))
        #expect(model(spend: 2.00, budget: 1.50).icon == .overBudget)
    }

    /// One clause, in the same words the counts row uses (#157): the remedy is its own row, so
    /// the status row only has to name the state.
    @Test("the status row names the state in the swept vocabulary")
    func statusSentence() {
        let over = model(spend: 2.00, budget: 1.50)
        #expect(over.statusLine == "Budget reached: screenshots on hold")
        #expect(!over.statusLine.contains("describing"))
        #expect(!over.statusLine.contains("midnight"))
    }

    /// `WorklensApp` renders `Image(systemName:)` with no fallback, so a name macOS does not know
    /// is a blank menu bar rather than a wrong glyph.
    @Test("every menu icon names a symbol this Mac actually has")
    func symbolsResolve() {
        for icon in MenuIcon.allCases {
            #expect(
                NSImage(systemSymbolName: icon.rawValue, accessibilityDescription: nil) != nil,
                "\(icon.rawValue) is not an SF Symbol on this macOS"
            )
        }
    }

    @Test("the raise target exists only while over budget")
    func raiseOffer() {
        let over = model(spend: 1.52, budget: 1.50)
        #expect(over.budgetRaiseTarget == 2.50)

        // Under budget, and with no budget at all, there is nothing to offer.
        #expect(model(spend: 0.10, budget: 1.50, scheduler: .running).budgetRaiseTarget == nil)
        #expect(model(spend: 5.00, budget: 0, scheduler: .running).budgetRaiseTarget == nil)
    }
}
