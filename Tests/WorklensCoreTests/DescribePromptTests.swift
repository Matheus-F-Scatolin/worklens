import Foundation
import Testing
@testable import WorklensCore

// MARK: - Fixtures

/// A taxonomy over a throwaway data dir, so `promptFragment` is the real seeded one.
private struct PromptHarness {
    let dataDir: URL
    let taxonomy: TaxonomyStore
    let resolved: ResolvedApp?

    init(bundleID: String? = "com.tinyspeck.slackmacgap") throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        taxonomy = try TaxonomyStore(dataDir: dataDir)
        resolved = taxonomy.resolve(bundleID: bundleID, url: nil)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dataDir) }

    func prompt(_ input: DescribePrompt.Input) -> String {
        DescribePrompt.userPrompt(
            resolved: resolved, taxonomy: taxonomy, input: input,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }
}

/// 2026-09-07T09:00:00Z, a Monday.
private let monday = Date(timeIntervalSince1970: 1_788_771_600)
private let outline = "[AXStaticText] #general, Ana: standup at ten."

private func input(
    mode: DescribePrompt.Mode,
    windowText: String? = outline,
    coverage: AXSnapshot.Coverage? = .full
) -> DescribePrompt.Input {
    DescribePrompt.Input(
        at: monday,
        appName: "Slack",
        bundleID: "com.tinyspeck.slackmacgap",
        windowTitle: "#general",
        windowText: windowText,
        coverage: coverage,
        mode: mode
    )
}

// MARK: - The three renderings

@Suite("DescribePrompt d5 renderings")
struct DescribePromptModeTests {
    @Test("the version is d5, the subject is gone, every sensitivity rule kept")
    func systemInstruction() {
        // d4 (#90) added the known-project list and d5 (#315) lists it by key; the system text
        // is still d3's.
        #expect(DescribePrompt.version == "d5")
        let system = DescribePrompt.systemInstruction
        // d3 (#65): no instruction seeds "The person", and the delta ask is spelled out.
        #expect(!system.contains("the person is doing"))
        #expect(system.contains(
            "Start every summary with a verb (\"Reads…\", \"Drafts…\", \"Reviews…\"): no subject, "
                + "never \"the person\", \"the user\" or \"you\"."
        ))
        #expect(system.contains(
            "If this frame continues the activity in the context, say what is new (the document, "
                + "thread, step, person or result) rather than restating it."
        ))
        // The hedge d2 drops: the window's own text is the exact metadata it stood in for.
        #expect(!system.contains("Prefer the metadata"))
        #expect(!system.contains("ambiguous"))
        #expect(system.contains("the text of the focused window as the operating system exposes it"))
        #expect(system.contains("a screenshot only when that text is incomplete"))
        // …and every rule that was there before still is, word for word.
        #expect(system.contains(
            "Never transcribe passwords, card numbers, one-time codes, or the verbatim text of "
                + "personal messages"
        ))
        #expect(system.contains(
            "set is_sensitive=true when such content, banking, medical, HR, dating, or private "
                + "browsing is visible"
        ))
        // #151: the list is a constant now, and Settings → Privacy quotes the same one. This is
        // what stops the pane describing a rule the model is no longer being given.
        #expect(system.contains(DescribePrompt.sensitiveCategories))
        #expect(DescribePrompt.sensitiveCategories
            == "banking, medical, HR, dating, or private browsing")
        #expect(system.contains("Classify the activity using ONLY the provided app and task keys."))
        #expect(system.contains("Respond with JSON only."))
        // One paragraph, as it has always been: the export writes the constant verbatim.
        #expect(!system.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"))
    }

    @Test("a fully covered window: the outline, and nothing about a screenshot")
    func textOnly() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        #expect(harness.prompt(input(mode: .text)) == """
            Time: 2026-09-07 09:00 (Monday)
            App: Slack (com.tinyspeck.slackmacgap)
            Window title: #general
            URL: n/a
            In meeting (per calendar/detector): no
            Known tasks for this app:
            \(harness.taxonomy.promptFragment(for: harness.resolved))
            Focused window text (accessibility outline, full coverage):
            \(outline)
            Describe what is happening, from the window text above. Prefer a universal task key over proposing a new one.
            """)
    }

    @Test("a partly covered window: the outline says so, and the screenshot has the rest")
    func textAndImage() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        #expect(harness.prompt(input(mode: .textAndImage, coverage: .partial)) == """
            Time: 2026-09-07 09:00 (Monday)
            App: Slack (com.tinyspeck.slackmacgap)
            Window title: #general
            URL: n/a
            In meeting (per calendar/detector): no
            Known tasks for this app:
            \(harness.taxonomy.promptFragment(for: harness.resolved))
            Focused window text (accessibility outline, partial coverage):
            \(outline)
            Describe what is happening, from the window text and the screenshot. Prefer a universal task key over proposing a new one.
            """)
    }

    @Test("a window that exposed nothing: d1's prompt, unchanged")
    func imageOnly() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        // No text block at all — not an empty heading — and the closing line is the one d1 sent.
        #expect(harness.prompt(input(mode: .image, windowText: nil, coverage: nil)) == """
            Time: 2026-09-07 09:00 (Monday)
            App: Slack (com.tinyspeck.slackmacgap)
            Window title: #general
            URL: n/a
            In meeting (per calendar/detector): no
            Known tasks for this app:
            \(harness.taxonomy.promptFragment(for: harness.resolved))
            Describe the screenshot. Prefer a universal task key over proposing a new one.
            """)
    }

    @Test("image mode never leaks the outline, even when the frame has one")
    func imageModeWithheldText() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let rendered = harness.prompt(input(mode: .image))
        #expect(!rendered.contains(outline))
        #expect(!rendered.contains("Focused window text"))
        #expect(rendered.hasSuffix("Describe the screenshot. Prefer a universal task key over proposing a new one."))
    }

    @Test("the recent context and the repair note keep their places around the outline")
    func blockOrder() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let withContext = DescribePrompt.Input(
            at: monday,
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#general",
            context: .compressed(before: nil, run: [DescribePrompt.RecentFrame(
                at: monday.addingTimeInterval(-300), appKey: "slack",
                taskKey: "reading_messages", summary: "Reads #general."
            )]),
            repairNote: DescribePrompt.repairNote,
            windowText: outline,
            coverage: .full,
            mode: .text
        )
        let lines = harness.prompt(withContext).split(separator: "\n", omittingEmptySubsequences: false)
        let recent = try #require(lines.firstIndex(where: { $0.hasPrefix("In this app since") }))
        let text = try #require(lines.firstIndex(where: { $0.hasPrefix("Focused window text") }))
        let closing = try #require(lines.firstIndex(where: { $0.hasPrefix("Describe what") }))
        #expect(recent < text)
        #expect(text < closing)
        #expect(lines.last == Substring(DescribePrompt.repairNote))
    }
}

// MARK: - Which mode a frame gets

@Suite("DescribePrompt.Mode")
struct DescribePromptModeChoiceTests {
    @Test("full text goes alone, partial text takes the picture with it, no text is a picture")
    func choice() {
        #expect(DescribePrompt.Mode.forFrame(hasText: true, coverage: .full, hasImage: true) == .text)
        #expect(DescribePrompt.Mode.forFrame(hasText: true, coverage: .partial, hasImage: true) == .textAndImage)
        #expect(DescribePrompt.Mode.forFrame(
            hasText: false, coverage: AXSnapshot.Coverage.none, hasImage: true
        ) == .image)
        #expect(DescribePrompt.Mode.forFrame(hasText: false, coverage: nil, hasImage: true) == .image)
    }

    @Test("a frame with text and no picture is text-only whatever its grade")
    func noPicture() {
        #expect(DescribePrompt.Mode.forFrame(hasText: true, coverage: .full, hasImage: false) == .text)
        #expect(DescribePrompt.Mode.forFrame(hasText: true, coverage: .partial, hasImage: false) == .text)
        #expect(DescribePrompt.Mode.forFrame(hasText: true, coverage: nil, hasImage: false) == .text)
    }

    @Test("the request carries the image only when the mode says it should")
    func requestFollowsTheMode() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

        func request(_ mode: DescribePrompt.Mode) -> DescribeRequest {
            DescribePrompt.request(
                imageJPEG: jpeg, resolved: harness.resolved, taxonomy: harness.taxonomy,
                input: input(mode: mode), timeZone: TimeZone(identifier: "UTC")!
            )
        }
        // Text mode drops a JPEG it was handed rather than sending a prompt that contradicts it.
        #expect(request(.text).imageJPEG == nil)
        #expect(request(.textAndImage).imageJPEG == jpeg)
        #expect(request(.image).imageJPEG == jpeg)
        #expect(DescribePrompt.request(
            imageJPEG: nil, resolved: harness.resolved, taxonomy: harness.taxonomy,
            input: input(mode: .text), timeZone: TimeZone(identifier: "UTC")!
        ).imageJPEG == nil)
    }

    @Test("a repair keeps the mode and the text of the answer it is repairing")
    func repairKeepsTheMode() {
        let repaired = input(mode: .text).withRepairNote(DescribePrompt.repairNote)
        #expect(repaired.mode == .text)
        #expect(repaired.windowText == outline)
        #expect(repaired.coverage == .full)
        #expect(repaired.repairNote == DescribePrompt.repairNote)
    }
}

// MARK: - The run context (#65)

private func frame(_ minutesBefore: Int, _ summary: String, task: String = "prompting")
    -> DescribePrompt.RecentFrame
{
    DescribePrompt.RecentFrame(
        at: monday.addingTimeInterval(TimeInterval(-60 * minutesBefore)),
        appKey: "claude_desktop", taskKey: task, summary: summary
    )
}

@Suite("DescribePrompt run context")
struct DescribePromptRunContextTests {
    /// The whole prompt for a frame carrying `context`, in text mode.
    private func prompt(_ context: DescribePrompt.RunContext, harness: PromptHarness) -> String {
        harness.prompt(DescribePrompt.Input(
            at: monday, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#general", context: context, windowText: outline,
            coverage: .full, mode: .text
        ))
    }

    @Test("no context: the prompt has no context block at all")
    func none() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let rendered = prompt(.empty, harness: harness)
        #expect(!rendered.contains("Before this app:"))
        #expect(!rendered.contains("In this app since"))
        #expect(DescribePrompt.RunContext.empty.isEmpty)
    }

    @Test("a switch only: one line for what came before, and no run block")
    func switchOnly() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let context = DescribePrompt.RunContext.compressed(
            before: DescribePrompt.RecentFrame(
                at: monday.addingTimeInterval(-19 * 60), appKey: "slack",
                taskKey: "reading_messages", summary: "Reads #deal-flow about a term sheet."
            ),
            run: []
        )
        let rendered = prompt(context, harness: harness)
        #expect(rendered.contains(
            "Before this app: 08:41 slack/reading_messages: Reads #deal-flow about a term sheet."
        ))
        #expect(!rendered.contains("In this app since"))
    }

    @Test("a 20-frame run: the first frame, “… 15 more frames”, four tail lines, under 700 chars")
    func longRun() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let run = (1...20).reversed().map { index in
            frame(index, "Step \(21 - index) of the migration plan.")
        }
        let context = DescribePrompt.RunContext.compressed(
            before: DescribePrompt.RecentFrame(
                at: monday.addingTimeInterval(-21 * 60), appKey: "slack",
                taskKey: "reading_messages", summary: "Reads #deal-flow."
            ),
            run: run
        )
        let block = try #require(
            DescribePrompt.contextBlock(context, timeZone: TimeZone(identifier: "UTC")!)
        )
        #expect(block == """
            Before this app: 08:39 slack/reading_messages: Reads #deal-flow.
            In this app since 08:40 (20 frames):
            - 08:40 claude_desktop/prompting: Step 1 of the migration plan.
            … 15 more frames
            - 08:56 claude_desktop/prompting: Step 17 of the migration plan.
            - 08:57 claude_desktop/prompting: Step 18 of the migration plan.
            - 08:58 claude_desktop/prompting: Step 19 of the migration plan.
            - 08:59 claude_desktop/prompting: Step 20 of the migration plan.
            """)
        #expect(block.count <= DescribePrompt.runContextBudget)
        #expect(context.tail.count == DescribePrompt.runContextTail)
        #expect(context.omitted == 15)
        #expect(prompt(context, harness: harness).contains(block))
    }

    @Test("identical summaries collapse onto the first time they were said")
    func deduplicates() {
        let run = [
            frame(8, "Reviews parody lyrics."),
            frame(6, "Reviews parody lyrics."),
            frame(4, "Reviews parody lyrics."),
            frame(2, "Formats the lyrics into verses."),
        ]
        let context = DescribePrompt.RunContext.compressed(before: nil, run: run)
        #expect(context.runFrames == 4)
        #expect(context.tail.map(\.summary) == [
            "Reviews parody lyrics.", "Formats the lyrics into verses.",
        ])
        // The quoted time is when that summary first appeared, not when it was last repeated.
        #expect(context.tail.first?.at == run[0].at)
        #expect(context.first == nil)
        // Two of the four frames said nothing new, and the header still says there were four.
        #expect(context.omitted == 2)
    }

    @Test("the budget drops quoted frames oldest first and keeps the switch line longest")
    func budget() {
        let long = String(repeating: "migration ", count: 60)
        let run = (1...12).reversed().map { frame($0, "\(long)step \(13 - $0).") }
        let context = DescribePrompt.RunContext.compressed(
            before: DescribePrompt.RecentFrame(
                at: monday.addingTimeInterval(-13 * 60), appKey: "slack",
                taskKey: "reading_messages", summary: long
            ),
            run: run
        )
        let block = DescribePrompt.contextBlock(context, timeZone: TimeZone(identifier: "UTC")!)
        #expect((block?.count ?? 0) <= DescribePrompt.runContextBudget)
        // Every quoted summary was cut to the per-line limit, and the newest frame survived.
        #expect(context.tail.allSatisfy { $0.summary.count <= DescribePrompt.runContextSummaryLimit + 1 })
        #expect(context.tail.last?.summary.hasSuffix("…") == true)
        #expect(context.before != nil)
        #expect(context.runFrames == 12)
        // …and what was dropped is counted, not silently lost.
        #expect(context.omitted + context.tail.count + (context.first == nil ? 0 : 1) == 12)
    }

    @Test("the context is rendered in all three modes")
    func everyMode() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let context = DescribePrompt.RunContext.compressed(
            before: nil, run: [frame(5, "Drafts a migration plan.")]
        )
        for mode in DescribePrompt.Mode.allCases {
            let rendered = harness.prompt(DescribePrompt.Input(
                at: monday, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: "#general", context: context, windowText: outline,
                coverage: .full, mode: mode
            ))
            #expect(rendered.contains("In this app since 08:55 (1 frame):"), "\(mode)")
            #expect(rendered.contains("- 08:55 claude_desktop/prompting: Drafts a migration plan."), "\(mode)")
        }
    }

    @Test("the schema asks for a verb-first summary and for the delta")
    func schemaSummary() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }

        let schema = DescribePrompt.schema(
            resolved: harness.resolved, taxonomy: harness.taxonomy.current
        )
        let description = try #require(
            schema["properties"]?["summary"]?["description"]?.stringValue
        )
        #expect(description.contains("Start with a verb and no subject"))
        #expect(description.contains("say what is new"))
        #expect(description.contains("at most 60 words"))
    }
}

// MARK: - Known projects (#90)

@Suite("DescribePrompt known projects")
struct DescribePromptProjectTests {
    @Test("an empty list leaves the prompt exactly as d3 wrote it")
    func silentWhileEmpty() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }
        #expect(harness.taxonomy.projects.isEmpty)
        #expect(!harness.prompt(input(mode: .image)).contains("Known projects"))
    }

    @Test("a 15-entry catalog lists all 15 by key, house first with its rule")
    func listsEveryEntry() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }
        var taxonomy = harness.taxonomy.current
        taxonomy.projects = (0..<15).map {
            ProjectEntry(
                key: "p\($0)", name: "Project \($0)", aliases: ["alias \($0)"],
                kind: $0 == 7 ? .house : ($0 < 5 ? .company : ($0 < 9 ? .side : nil))
            )
        }
        try harness.taxonomy.save(taxonomy)

        let prompt = harness.prompt(input(mode: .image))
        let lines = prompt.split(separator: "\n").map(String.init)
        let header = try #require(lines.firstIndex { $0.hasPrefix("Known projects") })
        #expect(lines[header + 1] == "- house: \"p7\" (Project 7). " + DescribePrompt.houseRule)
        #expect(lines[header + 2].hasPrefix("- companies: \"p0\" (Project 0), "))
        #expect(lines[header + 3].hasPrefix("- side projects: \"p5\""))
        #expect(lines[header + 4].hasPrefix("- other: \"p9\""))
        #expect(lines[header + 5].hasPrefix("Otherwise, use the key of the entry on screen."))
        for index in 0..<15 { #expect(prompt.contains("\"p\(index)\" (Project \(index))")) }
        // Aliases are the resolver's business, never the model's.
        #expect(!prompt.contains("alias 0"))

        let schema = DescribePrompt.schema(resolved: harness.resolved, taxonomy: harness.taxonomy.current)
        let keys = schema["properties"]?["project_key"]?["enum"]
        #expect(keys == .array((0..<15).map { .string("p\($0)") } + [.null]))
    }

    @Test("over the cap, the house entry and the most used entries stay")
    func capKeepsHouseAndMostUsed() {
        let limit = 4
        let projects = (0..<10).map {
            ProjectEntry(key: "p\($0)", name: "Project \($0)", kind: $0 == 9 ? .house : nil)
        }
        let listed = DescribePrompt.promptProjects(
            projects, frameCounts: ["p3": 50, "p6": 20, "p1": 20, "p9": 0], limit: limit
        )
        // House first whatever its count, then by frames, ties in file order.
        #expect(listed.map(\.key) == ["p9", "p3", "p1", "p6"])
        // Under the cap, the list is the catalog as it is.
        #expect(DescribePrompt.promptProjects(Array(projects.prefix(4)), limit: limit) == Array(projects.prefix(4)))
        // The real cap.
        #expect(DescribePrompt.projectKeyLimit == 40)
    }

    @Test("an empty catalog gives no project_key, and a request names the same keys twice")
    func emptyCatalogHasNoKey() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }
        let empty = DescribePrompt.schema(resolved: harness.resolved, taxonomy: harness.taxonomy.current)
        #expect(empty["properties"]?["project_key"] == nil)

        var taxonomy = harness.taxonomy.current
        taxonomy.projects = [ProjectEntry(key: "acme", name: "Acme", kind: .company)]
        try harness.taxonomy.save(taxonomy)
        let request = DescribePrompt.request(
            imageJPEG: nil, resolved: harness.resolved, taxonomy: harness.taxonomy,
            input: input(mode: .text), timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(request.userPrompt.contains("- companies: \"acme\" (Acme)"))
        #expect(request.userPrompt.contains("Use the key of the entry on screen."))
        #expect(request.schema["properties"]?["project_key"]?["enum"] == .array([.string("acme"), .null]))
    }

    @Test("the d5 schema: project_key plus null, no people, no confidence")
    func d5Schema() throws {
        let harness = try PromptHarness()
        defer { harness.cleanUp() }
        var taxonomy = harness.taxonomy.current
        taxonomy.projects = [ProjectEntry(key: "acme", name: "Acme")]
        try harness.taxonomy.save(taxonomy)
        let schema = DescribePrompt.schema(resolved: harness.resolved, taxonomy: harness.taxonomy.current)
        let property = try #require(schema["properties"]?["project_key"])
        #expect(property["type"] == .array([.string("string"), .string("null")]))
        #expect(schema["properties"]?["people"] == nil)
        #expect(schema["properties"]?["confidence"] == nil)
        let required = schema["required"]
        #expect(required == .array(
            ["app_key", "task_key", "summary", "is_meeting", "is_sensitive"].map(JSONValue.string)
        ))
    }
}
