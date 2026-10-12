import Foundation

/// The sample week (#349): invented days covering all of last calendar week and this week up to
/// today (#357), for a first run to look at before its own day exists.
///
/// Nothing here came off anybody's screen. The project ("Harbor"), the teammates and the
/// documents are invented, and every sentence is written to you in the second person with no
/// score, ranking or comparison in it (`docs/copy.md`). `SampleWeekTests` reads every one.
///
/// **It never reaches Claude.** The sample lives in its own SQLite file in its own folder
/// (`<DATA_DIR>/sample-week/worklens.sqlite`). The MCP server, every CLI command, search, cost,
/// retention and deletes all open `<DATA_DIR>/worklens.sqlite` and nothing else, so the sample is
/// out of their reach by construction; `SampleWeekTests` calls every MCP tool to prove it.
///
/// Deterministic: each weekday always has the same shape, so the same weekday always builds the
/// same days and only the dates move. Built in-process from these constants (no SPM
/// resources), so it costs $0 and needs no Gemini key.
public enum SampleWeek {
    /// The folder under `DATA_DIR` the sample's database lives in.
    public static let folderName = "sample-week"

    /// Every id the sample writes starts with this, so a stray row is recognisable anywhere.
    public static let idPrefix = "sample-"

    /// The `app_state` key the sample database carries and the real ledger never does.
    public static let markerKey = "sample_week"

    /// The invented project every sample day is about. Distinctive on purpose: the exclusion
    /// test looks for it in every MCP answer.
    public static let projectName = "Harbor"

    /// The interval the invented screenshots are spaced at.
    public static let intervalSeconds = 300

    /// `<dataDir>/sample-week`.
    public static func directory(dataDir: URL) -> URL {
        dataDir.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: The shape

    /// An app as the screenshots name it, and the key the timeline files it under.
    ///
    /// The keys a real week is made of (#357): Claude Desktop and the browser carry most of it,
    /// Codex, VS Code, Slack and Claude on the web come and go, and Terminal, email, the calendar
    /// and Docs are short stretches between them. Every key is the taxonomy's own, so each block
    /// takes the name and the colour it would on one of your days.
    struct App: Sendable, Equatable {
        let key: String
        let bundleID: String
        let name: String
        let host: String?

        static let claude = App(
            key: "claude_desktop", bundleID: "com.anthropic.claudefordesktop", name: "Claude", host: nil
        )
        static let codex = App(key: "codex_desktop", bundleID: "com.openai.codex", name: "Codex", host: nil)
        static let editor = App(key: "vscode", bundleID: "com.microsoft.VSCode", name: "Code", host: nil)
        static let terminal = App(key: "terminal", bundleID: "com.apple.Terminal", name: "Terminal", host: nil)
        static let slack = App(key: "slack", bundleID: "com.tinyspeck.slackmacgap", name: "Slack", host: nil)
        /// An app the taxonomy has no key for, filed as other like any such app on a real day.
        static let tickets = App(key: "other", bundleID: "com.linear", name: "Linear", host: nil)
        static let claudeWeb = chrome("claude", "claude.ai")
        static let mail = chrome("gmail", "mail.google.com")
        static let calendar = chrome("gcal", "calendar.google.com")
        static let docs = chrome("gdocs", "docs.google.com")
        static let meet = chrome("gmeet", "meet.google.com")

        static func chrome(_ key: String, _ host: String) -> App {
            App(key: key, bundleID: "com.google.Chrome", name: "Google Chrome", host: host)
        }

        /// Chrome on a site the taxonomy has no app for, filed as the browser.
        static func browser(_ host: String) -> App { chrome("browser", host) }

        static let appleDocs = browser("developer.apple.com")
        static let sqlite = browser("sqlite.org")
        static let forums = browser("forums.swift.org")
        static let essays = browser("www.inkandswitch.com")
    }

    /// A stretch of one day in one window. A call carries the calendar meeting it was for.
    struct Run: Sendable, Equatable {
        let clock: String
        let minutes: Int
        let app: App
        let task: String
        let title: String
        let summary: String
        var meeting: Meeting? = nil
    }

    /// A calendar meeting. The call itself is the `Run` in Meet that carries it.
    struct Meeting: Sendable, Equatable {
        let title: String
        let summary: String
    }

    struct DayShape: Sendable, Equatable {
        let runs: [Run]
        var meetings: [Run] { runs.filter { $0.meeting != nil } }
    }

    /// A meeting and the Google Meet call it was taken on, at the same clock.
    private static func call(_ clock: String, _ minutes: Int, _ title: String, _ summary: String) -> Run {
        Run(
            clock: clock, minutes: minutes, app: .meet, task: "video_call", title: "Meet: \(title)",
            summary: "You joined \(title) on Google Meet.",
            meeting: Meeting(title: title, summary: summary)
        )
    }

    private static func day(_ runs: [Run]) -> DayShape {
        DayShape(runs: runs.sorted { $0.clock < $1.clock })
    }

    /// The shape of a weekday, `Calendar`'s numbering: 1 is Sunday, 7 is Saturday.
    static func shape(weekday: Int) -> DayShape {
        switch weekday {
        case 2: return monday
        case 3: return tuesday
        case 4: return wednesday
        case 5: return thursday
        case 6: return friday
        case 7: return saturday
        default: return sunday
        }
    }

    static let allShapes: [DayShape] = (1...7).map(shape(weekday:))

    private static func claude(_ clock: String, _ minutes: Int, _ task: String, _ summary: String) -> Run {
        Run(clock: clock, minutes: minutes, app: .claude, task: task, title: "Claude", summary: summary)
    }

    private static func slack(_ clock: String, _ summary: String) -> Run {
        Run(clock: clock, minutes: 10, app: .slack, task: "messaging", title: "#harbor-team", summary: summary)
    }

    private static let agent = "coding_with_agent"
    private static let chat = "chatting_with_ai"

    // #357: each half hour on the Weeks page goes to the app with the most minutes in it, and an
    // app outside the week's three draws as Others, as on a real week. Claude Desktop and the
    // browser hold the long stretches, Codex a few shorter ones; Slack, Terminal, email and the
    // rest are ten minutes here and there.
    static let monday = day([
        claude("09:00", 20, chat, "You talked through the week's Harbor work with Claude and picked the retry queue."),
        call("09:20", 15, "Team standup", "You went round the team: what each person is on this week."),
        claude(
            "09:35", 75, agent, "You had Claude draft the retry logic for the Harbor sync queue in an agent session."
        ),
        Run(
            clock: "10:50", minutes: 10, app: .mail, task: "triaging", title: "Inbox",
            summary: "You cleared the weekend's email and flagged two notes about Harbor."
        ),
        slack("11:00", "You caught up on the Harbor channel and the weekend's questions about the sync screen."),
        Run(
            clock: "11:10", minutes: 40, app: .appleDocs,
            task: "researching", title: "Background Tasks: Apple Developer",
            summary: "You read Apple's notes on background tasks to see how long a sync may run."
        ),
        Run(
            clock: "11:50", minutes: 10, app: .claudeWeb, task: chat, title: "Claude: backoff",
            summary: "You asked Claude a quick question about exponential backoff."
        ),
        Run(
            clock: "13:00", minutes: 40, app: .codex, task: agent, title: "Codex: harbor-app",
            summary: "You had Codex write tests for the retry queue and read through each one."
        ),
        Run(
            clock: "13:40", minutes: 10, app: .terminal, task: "running_commands", title: "harbor-app: zsh",
            summary: "You ran the new tests and watched them pass."
        ),
        slack("13:50", "You posted the retry plan to the Harbor channel."),
        call("14:00", 45, "Harbor planning", "You agreed on the scope of the sync work for the next two weeks."),
        Run(
            clock: "14:45", minutes: 60, app: .sqlite, task: "reading", title: "Write-Ahead Logging: SQLite",
            summary: "You read how the SQLite write-ahead log behaves when two writers meet."
        ),
        claude(
            "15:45", 75, agent, "You worked through the Harbor conflict resolver with Claude, one edge case at a time."
        ),
        slack("17:00", "You wrapped up the day with a note on where the retry work stands."),
    ])

    static let tuesday = day([
        Run(
            clock: "09:00", minutes: 10, app: .calendar,
            task: "reviewing_schedule", title: "Google Calendar: This week",
            summary: "You looked over the week's meetings and moved a review to the afternoon."
        ),
        claude(
            "09:10", 80, agent, "You started an agent session in Claude to split the sync screen into smaller views."
        ),
        Run(
            clock: "10:30", minutes: 55, app: .sqlite, task: "researching", title: "UPSERT: SQLite",
            summary: "You read up on UPSERT for the Harbor sync table."
        ),
        Run(
            clock: "11:25", minutes: 25, app: .editor, task: "coding", title: "SyncTable.swift: harbor-app",
            summary: "You tidied the sync table code by hand after the agent session."
        ),
        slack("11:50", "You answered a question from the team about the sync table."),
        claude(
            "13:00", 60, agent,
            "You reviewed the agent's changes to the sync screen with Claude and asked for two fixes."
        ),
        call(
            "14:00", 30, "Design review", "You walked through the new sync screen with design and noted three changes."
        ),
        Run(
            clock: "14:30", minutes: 50, app: .forums, task: "reading", title: "Structured concurrency: Swift Forums",
            summary: "You read a thread on cancelling tasks cleanly in structured concurrency."
        ),
        Run(
            clock: "15:20", minutes: 15, app: .docs, task: "writing", title: "Harbor sync design: Google Docs",
            summary: "You wrote up the sync design notes for the team."
        ),
        claude("15:35", 55, agent, "You had Claude apply the design review's three changes to the sync screen."),
        Run(
            clock: "16:30", minutes: 10, app: .tickets, task: "other", title: "Harbor board",
            summary: "You moved the finished Harbor tickets to done."
        ),
    ])

    static let wednesday = day([
        claude("09:00", 25, chat, "You asked Claude to explain an overnight crash log from the Harbor beta."),
        call("09:25", 15, "Team standup", "You went round the team and took the beta crash yourself."),
        Run(
            clock: "09:40", minutes: 40, app: .appleDocs,
            task: "researching", title: "Diagnosing crashes: Apple Developer",
            summary: "You read about symbolicating crash logs to trace the beta crash."
        ),
        slack("10:20", "You read the team's messages about the beta crash and said you had it."),
        call(
            "10:30", 45, "Pilot customer call",
            "You heard how the pilot customer uses Harbor offline and wrote down two requests."
        ),
        claude("11:15", 45, agent, "You had Claude trace the beta crash to a race in the sync queue."),
        call("13:00", 30, "One-on-one with Avery", "You talked with Avery about the next month of Harbor work."),
        claude("13:30", 70, agent, "You fixed the race in the sync queue with Claude and had it add a test for it."),
        Run(
            clock: "14:40", minutes: 10, app: .terminal, task: "running_commands", title: "harbor-app: zsh",
            summary: "You ran the test suite and pushed the fix."
        ),
        Run(
            clock: "14:50", minutes: 10, app: .mail, task: "writing_email", title: "Re: Harbor pilot",
            summary: "You replied to the pilot customer with the two requests written down."
        ),
        Run(
            clock: "15:00", minutes: 10, app: .tickets, task: "other", title: "Harbor board",
            summary: "You filed the pilot customer's requests as Harbor tickets."
        ),
        call("15:10", 45, "Sprint retro", "You went over what went well in the sprint and what to try next."),
        Run(
            clock: "15:55", minutes: 30, app: .codex, task: agent, title: "Codex: harbor-app",
            summary: "You had Codex review the crash fix and read its notes."
        ),
        Run(
            clock: "16:25", minutes: 40, app: .appleDocs, task: "reading", title: "SwiftData: Apple Developer",
            summary: "You read about SwiftData migrations for the next Harbor release."
        ),
    ])

    static let thursday = day([
        Run(
            clock: "09:00", minutes: 10, app: .calendar, task: "reviewing_schedule", title: "Google Calendar: Today",
            summary: "You checked the day's meetings and kept the morning clear."
        ),
        claude("09:10", 80, agent, "You started the offline mode for Harbor in an agent session with Claude."),
        Run(
            clock: "10:30", minutes: 30, app: .editor, task: "reading_code", title: "OfflineCache.swift: harbor-app",
            summary: "You read the offline mode's first draft in VS Code and left notes."
        ),
        Run(
            clock: "11:00", minutes: 40, app: .codex, task: agent, title: "Codex: harbor-app",
            summary: "You had Codex write the offline cache's tests."
        ),
        slack("11:40", "You shared the offline mode's first draft with the team."),
        Run(
            clock: "11:50", minutes: 10, app: .tickets, task: "other", title: "Harbor board",
            summary: "You split the offline mode into three tickets."
        ),
        Run(
            clock: "13:00", minutes: 60, app: .essays, task: "reading", title: "Local-first software",
            summary: "You read a long essay about local-first software."
        ),
        Run(
            clock: "14:00", minutes: 10, app: .claudeWeb, task: chat, title: "Claude: local-first",
            summary: "You asked Claude to sum up the essay's ideas for Harbor."
        ),
        claude("14:10", 40, agent, "You had Claude apply the essay's ideas to the offline cache."),
        Run(
            clock: "14:50", minutes: 10, app: .terminal, task: "running_commands", title: "harbor-app: zsh",
            summary: "You ran the offline tests with the network switched off."
        ),
        call("15:00", 30, "Harbor demo prep", "You planned Friday's demo and who shows which part."),
        Run(
            clock: "15:30", minutes: 50, app: .appleDocs, task: "researching", title: "URLSession: Apple Developer",
            summary: "You read how URLSession resumes downloads after the network drops."
        ),
        slack("16:20", "You posted the demo plan to the Harbor channel."),
    ])

    /// Nothing at or after 15:00: Friday winds down early.
    static let friday = day([
        Run(
            clock: "09:00", minutes: 10, app: .mail, task: "triaging", title: "Inbox",
            summary: "You skimmed your inbox before the demo."
        ),
        claude("09:10", 70, agent, "You polished the offline mode with Claude ahead of the demo."),
        Run(
            clock: "10:20", minutes: 40, app: .appleDocs, task: "reading", title: "Release notes: Apple Developer",
            summary: "You read the latest release notes for anything that touches Harbor."
        ),
        Run(
            clock: "11:00", minutes: 10, app: .terminal, task: "running_commands", title: "harbor-app: zsh",
            summary: "You built the demo copy of Harbor."
        ),
        call("11:10", 30, "Weekly sync", "You showed the offline mode to the team."),
        claude("11:40", 20, chat, "You asked Claude for a checklist before the Harbor release."),
        Run(
            clock: "13:00", minutes: 30, app: .codex, task: agent, title: "Codex: harbor-app",
            summary: "You had Codex go through the checklist against the code."
        ),
        Run(
            clock: "13:30", minutes: 60, app: .sqlite, task: "reading", title: "Query planning: SQLite",
            summary: "You read how SQLite plans a query to speed up the Harbor history screen."
        ),
        claude("14:30", 20, chat, "You talked through next week's plan with Claude."),
        slack("14:50", "You read the last messages of the week and signed off."),
    ])

    static let saturday = day([
        Run(
            clock: "10:30", minutes: 25, app: .essays, task: "reading", title: "A field guide to sync engines",
            summary: "You read a few chapters about how sync engines work."
        ),
        claude("11:00", 20, chat, "You talked through ideas for the conflict resolver with Claude."),
    ])

    /// Mid-morning, not evening: today is cut at the later of now and noon, so a Sunday with
    /// nothing before noon would open the sample on an empty Today for most of the day.
    static let sunday = day([
        Run(
            clock: "10:00", minutes: 10, app: .mail, task: "triaging", title: "Inbox",
            summary: "You skimmed your inbox for anything urgent before Monday."
        ),
        claude("10:10", 20, chat, "You planned the week ahead with Claude."),
    ])

    /// Every sentence and title the sample can put in front of you, for the voice tests.
    static var everyLine: [String] {
        allShapes.flatMap { shape in
            shape.runs.flatMap { run in
                [run.title, run.summary] + (run.meeting.map { [$0.title, $0.summary] } ?? [])
            }
        }
    }
}
