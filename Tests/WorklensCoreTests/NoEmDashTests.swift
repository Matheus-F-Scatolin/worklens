import Foundation
import Testing
@testable import WorklensCore

struct NoEmDashTests {
    @Test func aDashBetweenWordsBecomesAComma() {
        #expect(NoEmDash.replaced("A long day — mostly coding.") == "A long day, mostly coding.")
        #expect(NoEmDash.replaced("the vendor call—then review") == "the vendor call, then review")
    }

    @Test func aDashBetweenNumbersBecomesARange() {
        #expect(NoEmDash.replaced("09:00 — 10:30") == "09:00-10:30")
    }

    @Test func anEnDashGoesTheSameWay() {
        #expect(NoEmDash.replaced("09:00–10:30") == "09:00-10:30")
        #expect(NoEmDash.replaced("coding – then review") == "coding, then review")
    }

    @Test func aFormattedRangeKeepsItsSpacing() {
        #expect(NoEmDash.range("21–27 September") == "21-27 September")
        #expect(NoEmDash.range("28 September\u{2009}–\u{2009}4 October") == "28 September - 4 October")
    }

    @Test func aDashAloneBecomesAHyphen() {
        #expect(NoEmDash.replaced("| focus | — |") == "| focus | - |")
        #expect(NoEmDash.replaced("— first\nsecond —") == "- first\nsecond -")
    }

    @Test func textWithoutOneIsUntouched() {
        #expect(NoEmDash.replaced("09:18-09:36 · Slack · Reading") == "09:18-09:36 · Slack · Reading")
    }

    /// Every sentence a translator is handed, in every language.
    @Test func noCatalogValueHasOne() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for language in ["en", "pt-BR"] {
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let rows = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").filter { $0.hasPrefix("\"") }
            #expect(!rows.isEmpty)
            for row in rows {
                #expect(!row.contains("\u{2014}"), "\(language): \(row)")
            }
        }
    }
}
