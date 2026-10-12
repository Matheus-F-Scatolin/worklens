import Foundation
import Testing
@testable import WorklensCore

private let utc = TimeZone(identifier: "UTC")!
/// 2026-09-07 is a Monday; the fixture day starts at 09:00 UTC.
private let dayStart = DayBoundaries.range(day: "2026-09-07", timeZone: utc)!.start
private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

/// Fixtures live next to the tests rather than in an SPM resource bundle (`Bundle.module` is
/// unreliable in a hand-built .app, so the package declares no resources at all).
/// Re-record with `WORKLENS_UPDATE_FIXTURES=1 make test`.
private func goldenFile(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func compareToGolden(_ actual: String, _ name: String) throws {
    let url = goldenFile(name)
    if ProcessInfo.processInfo.environment["WORKLENS_UPDATE_FIXTURES"] == "1" {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(actual.utf8).write(to: url, options: .atomic)
    }
    let expected = try String(contentsOf: url, encoding: .utf8)
    #expect(actual == expected, "\(name) drifted; re-record with WORKLENS_UPDATE_FIXTURES=1")
}

// MARK: - The fixture day

private func fixtureFrames() -> [TimelineFrame] {
    var frames: [TimelineFrame] = []
    func add(
        _ hour: Int, _ minute: Int, app: String?, task: String?, title: String?,
        summary: String?, idle: Bool = false, redacted: Bool = false,
        inherited: Bool = false, meeting: Bool = false, sensitive: Bool = false
    ) {
        frames.append(TimelineFrame(
            captureId: "f\(frames.count)", at: at(hour, minute), appKey: app, taskKey: task,
            title: title, summary: summary, isIdle: idle, isRedacted: redacted,
            isMeeting: meeting, isInherited: inherited, isSensitive: sensitive
        ))
    }

    // 09:00-09:03 triaging email in Gmail, one inherited frame in the middle.
    add(9, 0, app: "gmail", task: "triaging", title: "Inbox (14) - Gmail",
        summary: "Reading a thread about the Series A term sheet.")
    add(9, 1, app: "gmail", task: "triaging", title: "Inbox (14) - Gmail",
        summary: "Reading a thread about the Series A term sheet.", inherited: true)
    add(9, 2, app: "gmail", task: "triaging", title: "Inbox (14) - Gmail",
        summary: "Archiving newsletters and replying to a scheduling request.")

    // 09:04-09:06 Slack.
    add(9, 4, app: "slack", task: "reading_messages", title: "#deal-flow",
        summary: "Catching up on #deal-flow.")
    add(9, 5, app: "slack", task: "reading_messages", title: "#deal-flow",
        summary: "Catching up on #deal-flow.", inherited: true)

    // 09:07 a one-frame detour that gets absorbed back into Slack.
    add(9, 6, app: "finder", task: "browsing_files", title: "Downloads",
        summary: "Looking through Downloads.")
    add(9, 7, app: "slack", task: "reading_messages", title: "#deal-flow",
        summary: "Replying in #deal-flow about the data room.")

    // 09:09-09:10 away from the keyboard.
    add(9, 9, app: nil, task: nil, title: nil, summary: nil, idle: true)
    add(9, 10, app: nil, task: nil, title: nil, summary: nil, idle: true)

    // 09:12 a blocked app: metadata only.
    add(9, 12, app: "onepassword", task: nil, title: "1Password", summary: nil, redacted: true)

    // 09:14-09:16 a meeting, and one frame the describer flagged sensitive.
    add(9, 14, app: "gmeet", task: "video_call", title: "Portfolio review",
        summary: "In a video call with two people.", meeting: true)
    add(9, 15, app: "gmeet", task: "video_call", title: "Portfolio review",
        summary: "In a video call with two people.", inherited: true, meeting: true)
    add(9, 16, app: "gmail", task: "reading_email", title: "Payroll - Gmail",
        summary: "Reading an email about payroll.", sensitive: true)

    return frames
}

@Suite("TimelineRenderer")
struct TimelineRendererTests {
    private func labels() -> TimelineLabels { TimelineLabels.from(Taxonomy.seed) }

    private func render(
        extraBlocks: [ActivityBlock] = [], coverageGaps: [CoverageGap] = []
    ) -> String {
        let frames = fixtureFrames()
        let blocks = BlockBuilder.build(
            frames: frames, gapTolerance: 180, tickInterval: 60, timeZone: utc,
            now: at(9, 20)
        ) + extraBlocks
        return TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, frames: frames,
            labels: labels(), coverageGaps: coverageGaps, timeZone: utc
        )
    }

    /// #146: the fixture day was not watched from end to end — Worklens was started at 09:00 and
    /// paused over lunch — so the golden file carries the coverage sentence too.
    private static let fixtureGaps = [
        CoverageGap(start: dayStart, end: at(9, 0), reason: .notRunning),
        CoverageGap(start: at(11, 45), end: at(13, 30), reason: .paused),
    ]

    @Test("a full day renders exactly like the checked-in fixture")
    func goldenDay() throws {
        let calendarBlock = ActivityBlock(
            id: "meeting-1", day: "2026-09-07",
            startAt: at(10, 30), endAt: at(11, 40),
            appKey: "gcal", taskKey: "video_call",
            title: "Portfolio review", summaryMd: "Quarterly portfolio review.",
            captureCount: 0, source: .calendar
        )
        try compareToGolden(
            render(extraBlocks: [calendarBlock], coverageGaps: TimelineRendererTests.fixtureGaps),
            "timeline-golden.md"
        )
    }

    @Test("the footer says when Worklens was not watching, in the user's words")
    func coverageFooter() {
        let markdown = render(coverageGaps: TimelineRendererTests.fixtureGaps)
        #expect(markdown.contains(
            "Worklens was not running until 09:00, paused 11:45-13:30"
        ))
    }

    @Test("a day with nothing in it still says why there is nothing in it")
    func emptyDayCarriesTheReason() {
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: [], frames: [],
            coverageGaps: [CoverageGap(start: dayStart, end: at(24, 0), reason: .paused)],
            timeZone: utc
        )
        #expect(markdown.contains("Nothing recorded for this day."))
        #expect(markdown.contains("Worklens was paused all day"))
    }

    @Test("a day Worklens watched end to end gains no footnote")
    func watchedDayHasNoCoverageLine() {
        #expect(!render().contains("Worklens was"))
    }

    @Test("the header counts described and inherited frames separately")
    func headerCounts() {
        let markdown = render()
        #expect(markdown.contains("7 frames described, 3 inherited"))
        #expect(markdown.hasPrefix("# Worklens timeline: 2026-09-07 (Monday)"))
    }

    @Test("web apps are named through their browser and tasks are humanized")
    func appAndTaskNames() {
        #expect(render().contains("· Web browser / Gmail · Triaging ("))
    }

    @Test("inherited frames are not quoted twice")
    func inheritedNotQuoted() {
        let markdown = render()
        let repeats = markdown.components(separatedBy: "Catching up on #deal-flow.").count - 1
        #expect(repeats == 1)
    }

    @Test("a blocked app shows as redacted, with no content, and is counted in the footer")
    func redactedBlock() {
        let markdown = render()
        #expect(markdown.contains("Redacted (blocked app)"))
        #expect(markdown.contains("redacted (blocked app or title)"))
        #expect(markdown.contains("1 frame flagged sensitive"))
    }

    @Test("blocks from a context source name their source instead of an app")
    func contextSourceBlock() {
        let markdown = render(extraBlocks: [ActivityBlock(
            day: "2026-09-07", startAt: at(10, 30), endAt: at(11, 40),
            appKey: "gcal", taskKey: "video_call", title: "Portfolio review",
            captureCount: 0, source: .calendar
        )])
        #expect(markdown.contains("· Meeting · \"Portfolio review\" (1h 10m), source: calendar"))
    }

    @Test("an empty day says so instead of rendering nothing")
    func emptyDay() {
        let markdown = TimelineRenderer.render(day: "2026-09-07", blocks: [], timeZone: utc)
        #expect(markdown.contains("Nothing recorded for this day."))
        #expect(markdown.contains("Tracked 0m"))
    }

    @Test("a long block keeps its first summary and its most recent ones")
    func bulletsAreTrimmed() {
        let frames = (0..<12).map { index in
            TimelineFrame(
                captureId: "f\(index)", at: at(9, index), appKey: "vscode", taskKey: "coding",
                title: "Worklens", summary: "Editing file \(index).swift."
            )
        }
        let blocks = BlockBuilder.build(
            frames: frames, gapTolerance: 180, tickInterval: 60, timeZone: utc
        )
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, frames: frames, timeZone: utc
        )
        let bullets = markdown.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(bullets.count == TimelineRenderer.maxBulletsPerBlock)
        #expect(bullets.first?.contains("file 0.swift") == true)
        #expect(bullets.last?.contains("file 11.swift") == true)
    }

    @Test("a stored block with no duration is not rendered")
    func zeroLengthBlockIsSkipped() {
        // Databases written before #63 still hold these; the renderer drops them so an old day
        // reads clean without a rebuild.
        let frames = [
            TimelineFrame(
                captureId: "f0", at: at(9, 0), appKey: "vscode", taskKey: "coding",
                title: "Worklens", summary: "Editing BlockBuilder.swift."
            ),
        ]
        let blocks = [
            ActivityBlock(
                day: "2026-09-07", startAt: at(9, 0), endAt: at(9, 0).addingTimeInterval(0.028),
                appKey: "chrome", taskKey: "video", title: "Youka",
                summaryMd: "Syncing lyrics to a video.", captureCount: 1, source: .screen
            ),
            ActivityBlock(
                day: "2026-09-07", startAt: at(9, 0), endAt: at(9, 3),
                appKey: "vscode", taskKey: "coding", title: "Worklens",
                summaryMd: "Editing BlockBuilder.swift.", captureCount: 1, source: .screen
            ),
        ]
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, frames: frames, timeZone: utc
        )
        #expect(!markdown.contains("(0m)"))
        #expect(!markdown.contains("Youka"))
        #expect(markdown.contains("09:00-09:03"))
    }

    // MARK: - Projects in the heading (#90)

    /// One run of frames in one app, each naming a project.
    private func projectFrames(_ hints: [String?]) -> [TimelineFrame] {
        hints.enumerated().map { index, hint in
            TimelineFrame(
                captureId: "p\(index)", at: at(9, index), appKey: "claude_desktop",
                taskKey: "chatting_with_ai", title: "Claude", summary: "Summary \(index).",
                document: "Migration plan", projectHint: hint, bundleID: nil, appName: "Claude"
            )
        }
    }

    private func renderProjects(
        _ frames: [TimelineFrame], projects: [ProjectEntry] = []
    ) -> String {
        let blocks = BlockBuilder.build(
            frames: frames, gapTolerance: 180, tickInterval: 60, timeZone: utc
        )
        return TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, frames: frames, labels: labels(),
            projects: projects, timeZone: utc
        )
    }

    @Test("a block's heading names the project its frames were about")
    func headingCarriesTheProject() {
        let markdown = renderProjects(projectFrames(["worklens", "worklens", "Worklens"]))
        #expect(markdown.contains("## 09:00-09:03 · Claude Desktop · Chatting with ai · worklens"))
        // The subject line is still the document (#69), untouched.
        #expect(markdown.contains("Topic: Migration plan"))
    }

    @Test("the canonical list decides the spelling in the heading too")
    func headingUsesTheCanonicalSpelling() {
        let markdown = renderProjects(
            projectFrames(["worklens", "worklens", "Worklens"]),
            projects: [ProjectEntry(key: "worklens", name: "Worklens")]
        )
        #expect(markdown.contains("· Chatting with ai · Worklens ("))
    }

    @Test("a day whose frames named nothing renders exactly as it did before #90")
    func noProjectsNoChange() {
        let frames = projectFrames([nil, nil, nil])
        #expect(!renderProjects(frames).contains("Chatting with ai ·"))
    }

    // MARK: - Topic instead of Window (#69)

    /// Frames for one app, all in the same minute-by-minute run, each with a `document`.
    private func documentFrames(
        app: String, task: String, title: String?, appName: String?, documents: [String?]
    ) -> [TimelineFrame] {
        documents.enumerated().map { index, document in
            TimelineFrame(
                captureId: "d\(index)", at: at(9, index), appKey: app, taskKey: task,
                title: title, summary: "Summary \(index).", document: document,
                bundleID: nil, appName: appName
            )
        }
    }

    private func renderOnly(_ frames: [TimelineFrame]) -> String {
        let blocks = BlockBuilder.build(
            frames: frames, gapTolerance: 180, tickInterval: 60, timeZone: utc
        )
        return TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, frames: frames, labels: labels(), timeZone: utc
        )
    }

    @Test("a window title that is only the app's own name gives way to the dominant document")
    func topicFromDominantDocument() {
        let markdown = renderOnly(documentFrames(
            app: "claude_desktop", task: "chatting_with_ai", title: "Claude", appName: "Claude",
            documents: ["Parody lyrics for KPL trivia night", "Issues review", "Parody lyrics for KPL trivia night"]
        ))
        #expect(markdown.contains("Topic: Parody lyrics for KPL trivia night"))
        #expect(!markdown.contains("Window: Claude"))
        #expect(markdown.contains("Topic:") && !markdown.contains("Topic: Issues review"))
    }

    @Test("a title equal to the app's taxonomy label counts as the app's own name")
    func topicWhenTitleMatchesTheAppLabel() {
        let markdown = renderOnly(documentFrames(
            app: "granola", task: "reviewing_meeting_notes", title: "Granola", appName: nil,
            documents: ["DD Solara", "DD Solara"]
        ))
        #expect(markdown.contains("Topic: DD Solara"))
        #expect(!markdown.contains("Window: Granola"))
    }

    @Test("a block with no title at all takes the document too")
    func topicWithoutATitle() {
        let markdown = renderOnly(documentFrames(
            app: "finder", task: "browsing_files", title: nil, appName: "Finder",
            documents: ["Trivia Night", "Trivia Night"]
        ))
        #expect(markdown.contains("Topic: Trivia Night"))
    }

    @Test("a real page title still renders as Window, document or not")
    func windowKeptForARealTitle() {
        let markdown = renderOnly(documentFrames(
            app: "browser", task: "browsing", title: "Deal Radar · Riverbend Capital",
            appName: "Google Chrome", documents: ["Deal Radar"]
        ))
        #expect(markdown.contains("Window: Deal Radar · Riverbend Capital"))
        #expect(!markdown.contains("Topic:"))
    }

    @Test("without documents an app-named block renders exactly as before")
    func windowKeptWithoutDocuments() {
        let markdown = renderOnly(documentFrames(
            app: "claude_desktop", task: "chatting_with_ai", title: "Claude", appName: "Claude",
            documents: [nil, nil]
        ))
        #expect(markdown.contains("Window: Claude"))
        #expect(!markdown.contains("Topic:"))
    }

    @Test("inherited frames only vote when no described frame carries a document")
    func inheritedDocumentsAreTheLastResort() {
        var frames = documentFrames(
            app: "claude_desktop", task: "chatting_with_ai", title: "Claude", appName: "Claude",
            documents: ["Reviewed once", nil, nil]
        )
        // Two inherited echoes of a later document would win a plain count.
        for index in 1...2 {
            frames[index] = TimelineFrame(
                captureId: frames[index].captureId, at: frames[index].at,
                appKey: "claude_desktop", taskKey: "chatting_with_ai", title: "Claude",
                summary: frames[index].summary, document: "Echoed twice",
                appName: "Claude", isInherited: true
            )
        }
        #expect(renderOnly(frames).contains("Topic: Reviewed once"))
    }

    @Test("a screen block nested in a meeting gets the same line, indented")
    func nestedBlocksTakeTheSameLine() {
        let frames = documentFrames(
            app: "granola", task: "reviewing_meeting_notes", title: "Granola", appName: "Granola",
            documents: ["DD Solara", "DD Solara"]
        )
        let meeting = ActivityBlock(
            id: "meeting-1", day: "2026-09-07", startAt: at(8, 55), endAt: at(9, 30),
            appKey: "gcal", taskKey: "video_call", title: "DD Solara",
            summaryMd: "Team backgrounds.", captureCount: 0, source: .granola
        )
        let blocks = BlockBuilder.build(
            frames: frames, gapTolerance: 180, tickInterval: 60, timeZone: utc
        ) + [meeting]
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, frames: frames, labels: labels(), timeZone: utc
        )
        #expect(markdown.contains("- During the call:"))
        #expect(markdown.contains("\n    Topic: DD Solara"))
    }

    @Test("a repeated document title becomes one Topic line")
    func repeatedDocumentIsOneTopicLine() {
        let markdown = renderOnly(documentFrames(
            app: "claude_desktop", task: "chatting_with_ai", title: "Claude", appName: "Claude",
            documents: ["Parody lyrics for KPL trivia night", "Parody lyrics for KPL trivia night"]
        ))
        #expect(markdown.contains("Topic: Parody lyrics for KPL trivia night"))
    }

    // MARK: - Sub-minute runs (#94)

    /// `count` one-frame blocks back to back from `hour:minute`, each 30 s long.
    private func shortBlocks(
        from hour: Int, _ minute: Int, apps: [(app: String, task: String, title: String)]
    ) -> [ActivityBlock] {
        apps.enumerated().map { index, step in
            let start = at(hour, minute).addingTimeInterval(Double(index) * 30)
            return ActivityBlock(
                day: "2026-09-07", startAt: start, endAt: start.addingTimeInterval(30),
                appKey: step.app, taskKey: step.task, title: step.title,
                summaryMd: "A moment in \(step.title).", captureCount: 1, source: .screen
            )
        }
    }

    private func longBlock(
        _ fromHour: Int, _ fromMinute: Int, _ toHour: Int, _ toMinute: Int,
        app: String = "vscode", task: String = "coding", title: String = "Worklens"
    ) -> ActivityBlock {
        ActivityBlock(
            day: "2026-09-07", startAt: at(fromHour, fromMinute), endAt: at(toHour, toMinute),
            appKey: app, taskKey: task, title: title, summaryMd: "Editing \(title).",
            captureCount: 5, source: .screen
        )
    }

    @Test("five consecutive one-frame blocks become one Switching line")
    func shortRunCollapses() {
        let blocks = shortBlocks(from: 8, 50, apps: [
            ("chrome", "browsing", "New Tab"),
            ("chrome", "browsing", "GitHub PR #55"),
            ("claude_desktop", "chatting_with_ai", "Claude"),
            ("slack", "reading_messages", "#deal-flow"),
            ("finder", "browsing_files", "Downloads"),
        ]) + [longBlock(8, 55, 9, 30)]

        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, labels: labels(), timeZone: utc
        )
        #expect(!markdown.contains("(0m)"))
        // One heading — the long block's — and one line for the run under it.
        #expect(markdown.components(separatedBy: "## ").count == 2)
        #expect(markdown.contains(
            "- 08:50-08:52 Switching: Chrome (New Tab) → Chrome (GitHub PR #55)"
                + " → Claude Desktop (Claude) → Slack (#deal-flow) → Finder (Downloads)"
        ))
    }

    @Test("a single short block between two long ones folds the same way")
    func singleShortBlockFolds() {
        let blocks = [longBlock(9, 0, 9, 30)]
            + shortBlocks(from: 9, 30, apps: [("slack", "reading_messages", "#deal-flow")])
            + [longBlock(9, 31, 10, 0, app: "chrome", task: "browsing", title: "GitHub")]

        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, labels: labels(), timeZone: utc
        )
        #expect(markdown.contains("- 09:30-09:30 Switching: Slack (#deal-flow)"))
        // Under the block that follows it, not the one before.
        let underSecond = markdown
            .components(separatedBy: "## 09:31-10:00")[1]
            .contains("Switching: Slack")
        #expect(underSecond)
    }

    @Test("a run at the end of the day sits on its own")
    func shortRunAtDayEnd() {
        let blocks = [longBlock(9, 0, 9, 30)]
            + shortBlocks(from: 9, 30, apps: [
                ("slack", "reading_messages", "#deal-flow"),
                ("finder", "browsing_files", "Downloads"),
            ])

        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, labels: labels(), timeZone: utc
        )
        #expect(markdown.contains("- 09:30-09:31 Switching: Slack (#deal-flow) → Finder (Downloads)"))
        #expect(markdown.components(separatedBy: "## ").count == 2)
    }

    @Test("a day without short blocks renders exactly as it did before")
    func noShortBlocksNoChange() {
        // The whole fixture day is the byte-for-byte guard (`fullDayMatchesFixture`); this is the
        // narrow one: nothing is collapsed, and no run line appears from nowhere.
        let blocks = [
            longBlock(9, 0, 9, 30),
            longBlock(9, 30, 10, 0, app: "slack", task: "reading_messages", title: "#deal-flow"),
        ]
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, labels: labels(), timeZone: utc
        )
        #expect(!markdown.contains("Switching:"))
        #expect(markdown.contains("## 09:00-09:30"))
        #expect(markdown.contains("## 09:30-10:00"))
        #expect(TimelineRenderer.collapsedRun([], frames: [], labels: labels(), timeZone: utc) == nil)
    }

    @Test("consecutive moments in the same app and subject are one step, not three")
    func repeatedStepsCollapse() {
        let blocks = shortBlocks(from: 9, 0, apps: [
            ("chrome", "browsing", "GitHub"),
            ("chrome", "browsing", "GitHub"),
            ("chrome", "browsing", "GitHub"),
        ]) + [longBlock(9, 2, 9, 30)]
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: blocks, labels: labels(), timeZone: utc
        )
        #expect(markdown.contains("- 09:00-09:01 Switching: Chrome (GitHub)\n"))
    }

    // MARK: - Away blocks (#94)

    private func awayBlock() -> ActivityBlock {
        ActivityBlock(
            id: "away-ctx-calendar-e1", day: "2026-09-07", startAt: at(12, 0), endAt: at(13, 0),
            appKey: ContextBlocks.awayAppKey, taskKey: ContextBlocks.awayTaskKey,
            title: "Lunch at bem", captureCount: 0, source: .calendar
        )
    }

    @Test("an away block names the calendar event and is not called a meeting")
    func awayBlockHeading() {
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: [awayBlock()], labels: labels(), timeZone: utc
        )
        #expect(markdown.contains(
            "## 12:00-13:00 · Away · \"Lunch at bem\" (1h), source: calendar"
        ))
        #expect(!markdown.contains("Meeting"))
        // The header's meeting total must not grow by an hour of lunch.
        #expect(!markdown.contains("Meetings 1h"))
    }

    @Test("screen time inside an away window keeps its own place in the day")
    func awayDoesNotNestScreenBlocks() {
        let inside = longBlock(12, 10, 12, 20, app: "slack", task: "reading_messages",
                               title: "#deal-flow")
        let markdown = TimelineRenderer.render(
            day: "2026-09-07", blocks: [awayBlock(), inside], labels: labels(), timeZone: utc
        )
        #expect(!markdown.contains("During the call"))
        #expect(markdown.contains("## 12:10-12:20 · Slack"))
    }

    @Test("durations read the way a person would say them")
    func durationFormatting() {
        #expect(TimelineRenderer.duration(0) == "0m")
        #expect(TimelineRenderer.duration(44 * 60) == "44m")
        #expect(TimelineRenderer.duration(3600) == "1h")
        #expect(TimelineRenderer.duration(7 * 3600 + 42 * 60) == "7h 42m")
    }
}
