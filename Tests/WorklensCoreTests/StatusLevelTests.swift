import Foundation
import Testing
@testable import WorklensCore

/// The mapping half of #109's design-token layer. Only the meaning is testable here: the colours
/// live in `Theme` in the `Worklens` executable target, which has no test target, and that switch
/// is exhaustive by compiler check anyway.
@Suite("Status level")
struct StatusLevelTests {
    /// `nominal` must stay `neutral`, not `muted`: `muted` is grey, and greying today's spend
    /// would hide the figure the Cost tab exists to show.
    @Test("spend levels map onto status levels without losing the full-strength one")
    func spendLevels() {
        #expect(SpendLevel.nominal.level == .neutral)
        #expect(SpendLevel.warning.level == .attention)
        #expect(SpendLevel.over.level == .problem)
        #expect(SpendLevel.nominal.level != .muted)
    }

    @Test("a level round-trips through its raw value")
    func rawValues() {
        for level in StatusLevel.allCases {
            #expect(StatusLevel(rawValue: level.rawValue) == level)
        }
        #expect(StatusLevel.allCases.count == 5)
    }

    /// #133: colour alone is not a status. A greyscale screenshot, a colour-blind reader and
    /// VoiceOver all see the symbol and nothing else, so two levels sharing one would make two
    /// statuses indistinguishable.
    @Test("every status level has its own symbol")
    func symbols() {
        let symbols = StatusLevel.allCases.map(\.symbolName)
        #expect(Set(symbols).count == StatusLevel.allCases.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(StatusLevel.ok.symbolName != StatusLevel.problem.symbolName)
    }
}
