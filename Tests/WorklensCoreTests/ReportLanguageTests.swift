import Foundation
import Testing
@testable import WorklensCore

@Suite("REPORT_LANGUAGE (#157)")
struct ReportLanguageTests {
    /// The acceptance criterion for the whole key: with nothing set, the describe prompt is what
    /// it was before the key existed, to the byte.
    @Test("English adds nothing to the describe prompt")
    func englishIsAbsent() {
        #expect(ReportLanguage.rule("en") == nil)
        #expect(ReportLanguage.rule("") == nil)
        #expect(ReportLanguage.rule("EN") == nil)
        #expect(ReportLanguage.rule("en-GB") == nil)

        #expect(DescribePrompt.systemInstruction(language: "en") == DescribePrompt.systemInstruction)
        // And the default of the key itself is the constant, never the machine's own language.
        #expect(Config.defaults().reportLanguage == "en")
    }

    @Test("another language appends one sentence, and only appends")
    func otherLanguageIsOneSentence() throws {
        let rule = try #require(ReportLanguage.rule("pt-BR"))
        #expect(rule.contains("Portuguese (Brazil)"))
        #expect(rule.contains("in English"))

        let describe = DescribePrompt.systemInstruction(language: "de")
        #expect(describe.hasPrefix(DescribePrompt.systemInstruction))
        #expect(describe.contains("German"))
        #expect(describe.hasSuffix(try #require(ReportLanguage.rule("de"))))
    }

    @Test("an unknown code is passed through rather than dropped")
    func unknownCode() {
        #expect(ReportLanguage.name("xx-ZZ") == "xx-ZZ")
        #expect(ReportLanguage.rule("xx-ZZ")?.contains("xx-ZZ") == true)
    }
}
