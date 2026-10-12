import Foundation
import Testing
@testable import WorklensCore

@Suite("DotEnv")
struct DotEnvTests {
    @Test("ignores comments and blank lines")
    func commentsAndBlanks() {
        let env = DotEnv.parse("""
        # a comment
        KEY=value

           # indented comment
        OTHER=2
        """)
        #expect(env == ["KEY": "value", "OTHER": "2"])
    }

    @Test("strips one pair of surrounding quotes")
    func quotes() {
        let env = DotEnv.parse("""
        A="double"
        B='single'
        C="unbalanced
        D=""
        E='"nested"'
        """)
        #expect(env["A"] == "double")
        #expect(env["B"] == "single")
        #expect(env["C"] == "\"unbalanced")
        #expect(env["D"] == "")
        #expect(env["E"] == "\"nested\"")
    }

    @Test("supports export prefix")
    func exportPrefix() {
        let env = DotEnv.parse("export FOO=bar\nexport  BAZ = qux ")
        #expect(env["FOO"] == "bar")
        #expect(env["BAZ"] == "qux")
    }

    @Test("keeps = inside values")
    func equalsInValue() {
        let env = DotEnv.parse("TOKEN=abc=def==\nURL=https://x.test/?a=1&b=2")
        #expect(env["TOKEN"] == "abc=def==")
        #expect(env["URL"] == "https://x.test/?a=1&b=2")
    }

    @Test("handles CRLF line endings")
    func crlf() {
        let env = DotEnv.parse("A=1\r\nB=2\r\n# c\r\nC=3")
        #expect(env == ["A": "1", "B": "2", "C": "3"])
    }

    @Test("skips malformed lines")
    func malformed() {
        let env = DotEnv.parse("no_equals_here\n=novalue\nOK=1")
        #expect(env == ["OK": "1"])
    }

    @Test("does not interpolate variables")
    func noInterpolation() {
        let env = DotEnv.parse("A=1\nB=${A}/x")
        #expect(env["B"] == "${A}/x")
    }

    @Test("later duplicate wins within one file")
    func duplicates() {
        let env = DotEnv.parse("A=1\nA=2")
        #expect(env["A"] == "2")
    }

    @Test("missing file yields an empty dictionary")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/worklens-\(UUID().uuidString)/.env")
        #expect(DotEnv.load(contentsOf: url).isEmpty)
    }

    // MARK: Trailing comments (#126)

    @Test("an unquoted trailing comment is stripped when the # has a space before it")
    func trailingComment() {
        let env = DotEnv.parse("""
        CAPTURE_INTERVAL_SECONDS=60  # seconds
        LOG_LEVEL=debug\t# noisy
        """)
        #expect(env["CAPTURE_INTERVAL_SECONDS"] == "60")
        #expect(env["LOG_LEVEL"] == "debug")
    }

    @Test("a quoted value keeps its # verbatim")
    func quotedHashSurvives() {
        let env = DotEnv.parse("""
        A="secret #1 # still"
        B='hash # here'
        """)
        #expect(env["A"] == "secret #1 # still")
        #expect(env["B"] == "hash # here")
    }

    @Test("a # with nothing in front of it is part of the value — fragments and regexes")
    func attachedHashSurvives() {
        let env = DotEnv.parse("""
        BLOCKED_URL_HOSTS=example.com/page#section
        REDACT_EXTRA_PATTERNS=ticket\\d{2,3}#\\d+
        """)
        #expect(env["BLOCKED_URL_HOSTS"] == "example.com/page#section")
        #expect(env["REDACT_EXTRA_PATTERNS"] == "ticket\\d{2,3}#\\d+")
    }

    @Test("a value that is only a comment reads as not set")
    func commentOnlyValue() {
        #expect(DotEnv.parse("KEY= # nothing here")["KEY"] == "")
    }
}
