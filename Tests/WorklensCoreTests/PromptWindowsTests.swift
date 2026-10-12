import Foundation
import Testing
@testable import WorklensCore

@Suite("PromptWindows")
struct PromptWindowsTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-07 09:00 UTC.
    let nine = Date(timeIntervalSince1970: 1_791_363_600)
    let claude = "com.anthropic.claudefordesktop"

    func front(_ bundle: String, _ start: Date, _ end: Date?) -> ForegroundSession {
        ForegroundSession(startAt: start, endAt: end, appBundleId: bundle)
    }

    func prompt(_ offset: TimeInterval, _ session: String, host: String? = "claude-desktop") -> PromptWindows.Prompt {
        .init(at: nine + offset, sessionId: session, repo: "me/\(session)", host: host)
    }

    @Test("a prompt claims three minutes before and ten after, inside the app and while active")
    func window() {
        let out = PromptWindows.attribute(
            prompts: [prompt(0, "a")],
            foreground: [front(claude, nine - 3_600, nine + 3_600)],
            active: [DateInterval(start: nine - 3_600, end: nine + 3_600)],
            timeZone: utc
        )
        #expect(out == [RepoInterval(day: "2026-10-07", repo: "me/a", sessionId: "a", start: nine - 180, end: nine + 600)])
        #expect(out.first?.seconds == 780)
    }

    @Test("the later prompt takes over at its instant")
    func takeover() {
        let out = PromptWindows.attribute(
            prompts: [prompt(0, "a"), prompt(240, "b")],
            foreground: [front(claude, nine - 3_600, nil)],
            active: [DateInterval(start: nine - 3_600, end: nine + 3_600)],
            timeZone: utc
        )
        #expect(out.map(\.sessionId) == ["a", "b"])
        #expect(out[0].end == nine + 240)
        #expect(out[1].start == nine + 240)
        #expect(out[1].end == nine + 840)
    }

    @Test("a prompt sent from elsewhere adds nothing and cuts nothing")
    func remote() {
        let out = PromptWindows.attribute(
            prompts: [prompt(0, "a"), prompt(60, "remote", host: "sdk-cli")],
            foreground: [front(claude, nine - 3_600, nine + 3_600)],
            active: [DateInterval(start: nine - 3_600, end: nine + 3_600)],
            timeZone: utc
        )
        #expect(out.count == 1)
        #expect(out[0].sessionId == "a")
        #expect(out[0].seconds == 780)
    }

    @Test("time in another app, or idle, is not counted")
    func intersection() {
        let out = PromptWindows.attribute(
            prompts: [prompt(0, "a")],
            foreground: [
                front(claude, nine - 600, nine + 60),
                front("com.apple.Safari", nine + 60, nine + 300),
                front(claude, nine + 300, nine + 3_600),
            ],
            active: [DateInterval(start: nine - 600, end: nine + 420)],
            timeZone: utc
        )
        #expect(out.map(\.seconds) == [240, 120])
    }

    @Test("a terminal prompt counts in a terminal; Codex prompts in the Codex app")
    func hosts() {
        #expect(PromptWindows.bundleIds(forHost: "cli").contains("com.googlecode.iterm2"))
        #expect(PromptWindows.bundleIds(forHost: "codex-desktop") == ["com.openai.codex"])
        #expect(PromptWindows.bundleIds(forHost: "sdk-cli").isEmpty)
        #expect(PromptWindows.bundleIds(forHost: nil).isEmpty)
    }

    @Test("a window across midnight splits into two days")
    func midnight() {
        let late = Date(timeIntervalSince1970: 1_791_417_540) // 2026-10-07 23:59 UTC
        let out = PromptWindows.attribute(
            prompts: [.init(at: late, sessionId: "a", repo: nil, host: "claude-desktop")],
            foreground: [front(claude, late - 3_600, late + 3_600)],
            active: [DateInterval(start: late - 3_600, end: late + 3_600)],
            timeZone: utc
        )
        #expect(out.map(\.day) == ["2026-10-07", "2026-10-08"])
        #expect(out.map(\.seconds) == [240, 540])
    }
}
