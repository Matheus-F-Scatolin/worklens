import Foundation

/// Every word Worklens sends to the vision model, and the schema its answer must fit.
///
/// This is the only place the describe prompt exists. `describe-pending --dry-run` prints
/// exactly what this builds, so tuning the prompt never means reading two files.
/// `version` is stored in `descriptions.raw_json`, so a day's rows can always
/// be traced back to the wording that produced them.
public enum DescribePrompt {
    public static let version = "d5"
    public static let maxOutputTokens = 400
    /// How far back the run — and the one line before it — may reach (#65).
    public static let runContextWindow: TimeInterval = 90 * 60
    /// How many of the run's most recent distinct summaries are quoted.
    public static let runContextTail = 4
    /// Roughly how many characters the whole context block may take. Enforced by dropping
    /// quoted frames, oldest first; the "before this app" line is the last thing to go.
    public static let runContextBudget = 700
    /// The longest one quoted summary may be. A 60-word answer is ~350 characters, and four of
    /// those would be the whole budget.
    public static let runContextSummaryLimit = 180

    /// The kinds of content the model is told to set `is_sensitive` on (#151).
    ///
    /// It is a constant, and `systemInstruction` interpolates it, because Settings → Privacy
    /// quotes the same words. Until now the list existed only inside the prompt literal, so the
    /// pane that explains the rule could describe one the model was no longer being given.
    /// `DescribePromptTests` asserts the built prompt still contains it.
    public static let sensitiveCategories = "banking, medical, HR, dating, or private browsing"

    /// d3 (#65): the model is shown the app it came from and the run it is in, and asked for the
    /// delta rather than a restatement. "The person" is gone from every instruction — 176 of 176
    /// summaries on 2026-09-08 began with it, three words on every line of the day's timeline.
    /// Every sensitivity rule is unchanged.
    public static let systemInstruction = """
        You are Worklens, a private assistant that helps one person understand how they spend \
        their own working time. You receive the text of the focused window as the operating \
        system exposes it, plus a screenshot only when that text is incomplete, plus metadata. \
        Describe what is happening in one or two factual sentences, present tense, no judgment, \
        no advice. Start every summary with a verb ("Reads…", "Drafts…", "Reviews…"): no \
        subject, never "the person", "the user" or "you". If this frame continues the activity \
        in the context, say what is new (the document, thread, step, person or result) rather \
        than restating it. Never use an em dash. Classify the activity using ONLY the provided app and task keys. \
        If no task fits, use "other". Never transcribe passwords, card numbers, one-time codes, or the verbatim text of \
        personal messages; summarize instead and set is_sensitive=true when such content, \
        \(DescribePrompt.sensitiveCategories) is visible. Respond with JSON only.
        """

    // MARK: - Mode

    /// Which of the three d2 renderings a frame gets. Stored on `Input` rather than derived at
    /// the last moment, because the prompt's wording and the request's parts have to agree: one
    /// value decides both.
    public enum Mode: String, Sendable, Equatable, CaseIterable, Codable {
        /// A fully covered window: the outline and no picture at all.
        case text
        /// A partly covered one: the outline plus the screenshot that has the rest.
        case textAndImage = "text+image"
        /// No usable text — a game, a VM, a canvas, or a frame whose outline was dropped.
        case image

        public var sendsImage: Bool { self != .text }
        public var sendsText: Bool { self != .image }

        /// The one place the three renderings are chosen (#50: text-only for `.full`, text plus
        /// image for `.partial`, image-only otherwise). A frame with text but no picture is
        /// text-only whatever its grade — there is nothing else to send.
        public static func forFrame(
            hasText: Bool, coverage: AXSnapshot.Coverage?, hasImage: Bool
        ) -> Mode {
            guard hasText else { return .image }
            switch coverage {
            case .some(.full): return .text
            case .some(.partial): return hasImage ? .textAndImage : .text
            default: return hasImage ? .image : .text
            }
        }
    }

    // MARK: - Input

    /// One earlier frame, quoted so the model can tell "still writing that memo" from
    /// "started a new one".
    public struct RecentFrame: Sendable, Equatable {
        public let at: Date
        public let appKey: String
        public let taskKey: String
        public let summary: String

        public init(at: Date, appKey: String, taskKey: String, summary: String) {
            self.at = at
            self.appKey = appKey
            self.taskKey = taskKey
            self.summary = summary
        }

        /// The same frame with a summary of at most `limit` characters, cut at a word boundary.
        /// One 60-word answer is ~350 characters, so an untrimmed quote can be half the budget.
        func truncated(to limit: Int) -> RecentFrame {
            let summary = self.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard summary.count > limit else {
                return RecentFrame(at: at, appKey: appKey, taskKey: taskKey, summary: summary)
            }
            let head = summary.prefix(limit)
            let cut = head.lastIndex(of: " ").map { head[head.startIndex..<$0] } ?? head
            return RecentFrame(
                at: at, appKey: appKey, taskKey: taskKey,
                summary: cut.trimmingCharacters(in: .whitespaces) + "…"
            )
        }
    }

    /// What the model is told about where this frame sits (#65): the app the user came from, and
    /// the stretch it has spent in this one — compressed, because a 90-minute run is 90 frames
    /// and the whole point is to spend a few hundred tokens, not a few thousand.
    ///
    /// `compressed` is the only way to build a non-empty one, so the character budget cannot be
    /// bypassed by a caller that assembles the fields itself.
    public struct RunContext: Sendable, Equatable {
        /// The most recent quotable description from a *different* app.
        public let before: RecentFrame?
        /// When the current run started, i.e. the first frame of this stretch in this app.
        public let runStart: Date?
        /// How many quotable frames the run has, including the ones no line quotes.
        public let runFrames: Int
        /// The run's first frame, quoted when the tail alone would hide where the run began.
        public let first: RecentFrame?
        /// Frames between `first` and `tail` that no line quotes — "… N more frames".
        public let omitted: Int
        /// The run's last distinct summaries, oldest first.
        public let tail: [RecentFrame]

        public static let empty = RunContext(
            before: nil, runStart: nil, runFrames: 0, first: nil, omitted: 0, tail: []
        )

        public var isEmpty: Bool { before == nil && first == nil && tail.isEmpty }

        init(
            before: RecentFrame?, runStart: Date?, runFrames: Int, first: RecentFrame?,
            omitted: Int, tail: [RecentFrame]
        ) {
            self.before = before
            self.runStart = runStart
            self.runFrames = runFrames
            self.first = first
            self.omitted = omitted
            self.tail = tail
        }

        /// Deduplicates `run` (identical summaries collapse onto the first time they were said),
        /// keeps its first frame and its last `runContextTail` distinct ones, and then drops
        /// quoted frames — oldest first, `first` next, `before` last — until the rendered block
        /// fits `runContextBudget`.
        ///
        /// - Parameters:
        ///   - before: the last quotable frame from another app, already inside the window.
        ///   - run: every quotable frame of the current run, oldest first.
        public static func compressed(before: RecentFrame?, run: [RecentFrame]) -> RunContext {
            let run = run.map { $0.truncated(to: runContextSummaryLimit) }
            let before = before?.truncated(to: runContextSummaryLimit)
            var distinct: [RecentFrame] = []
            var seen: Set<String> = []
            for frame in run where seen.insert(frame.summary.lowercased()).inserted {
                distinct.append(frame)
            }

            var context: RunContext
            if distinct.count > runContextTail {
                let tail = Array(distinct.suffix(runContextTail))
                context = RunContext(
                    before: before, runStart: run.first?.at, runFrames: run.count,
                    first: distinct.first, omitted: max(0, run.count - 1 - tail.count), tail: tail
                )
            } else {
                context = RunContext(
                    before: before, runStart: run.first?.at, runFrames: run.count,
                    first: nil, omitted: max(0, run.count - distinct.count), tail: distinct
                )
            }

            // Measured in UTC, which costs nothing: `HH:MM` is five characters everywhere.
            let utc = TimeZone(secondsFromGMT: 0)!
            while (contextBlock(context, timeZone: utc)?.count ?? 0) > runContextBudget {
                if context.tail.count > 1 {
                    context = context.dropping(oldestTail: 1)
                } else if context.first != nil {
                    context = context.droppingFirst()
                } else if context.before != nil {
                    context = context.droppingBefore()
                } else {
                    break
                }
            }
            return context
        }

        private func dropping(oldestTail count: Int) -> RunContext {
            RunContext(
                before: before, runStart: runStart, runFrames: runFrames, first: first,
                omitted: omitted + count, tail: Array(tail.dropFirst(count))
            )
        }

        private func droppingFirst() -> RunContext {
            RunContext(
                before: before, runStart: runStart, runFrames: runFrames, first: nil,
                omitted: omitted + (first == nil ? 0 : 1), tail: tail
            )
        }

        private func droppingBefore() -> RunContext {
            RunContext(
                before: nil, runStart: runStart, runFrames: runFrames, first: first,
                omitted: omitted, tail: tail
            )
        }
    }

    /// Everything about a frame except its pixels.
    public struct Input: Sendable, Equatable {
        public let at: Date
        public let appName: String?
        public let bundleID: String?
        public let windowTitle: String?
        public let url: String?
        public let isMeeting: Bool
        /// The meeting's name, when a synced calendar or Granola event covers this frame (#19).
        public let meetingTitle: String?
        /// Where this frame sits: the app before it, and the run it belongs to (#65).
        public let context: RunContext
        /// Appended after a first answer failed to parse.
        public let repairNote: String?
        /// The stored, already-redacted accessibility outline of the focused window (#53). Nil
        /// for a frame that has none, or whose text retention has since dropped.
        public let windowText: String?
        /// How much of the window that outline covered — printed with it, so the model knows
        /// whether it is looking at the whole window or at a fragment.
        public let coverage: AXSnapshot.Coverage?
        /// Which rendering this frame gets. `.image` by default, which is d1's behaviour and
        /// what a caller with a picture and nothing else wants.
        public let mode: Mode

        public init(
            at: Date,
            appName: String? = nil,
            bundleID: String? = nil,
            windowTitle: String? = nil,
            url: String? = nil,
            isMeeting: Bool = false,
            meetingTitle: String? = nil,
            context: RunContext = .empty,
            repairNote: String? = nil,
            windowText: String? = nil,
            coverage: AXSnapshot.Coverage? = nil,
            mode: Mode = .image
        ) {
            self.at = at
            self.appName = appName
            self.bundleID = bundleID
            self.windowTitle = windowTitle
            self.url = url
            self.isMeeting = isMeeting
            self.meetingTitle = meetingTitle
            self.context = context
            self.repairNote = repairNote
            self.windowText = windowText
            self.coverage = coverage
            self.mode = mode
        }

        /// The same frame, told that its last answer did not parse. Used by the one repair
        /// attempt, which must keep the mode and the text it already sent.
        public func withRepairNote(_ note: String) -> Input {
            Input(
                at: at, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url,
                isMeeting: isMeeting, meetingTitle: meetingTitle, context: context, repairNote: note,
                windowText: windowText, coverage: coverage, mode: mode
            )
        }
    }

    /// `no`, `yes`, or `yes — "Portfolio review"` once #19 knows which meeting it is.
    static func meetingLine(_ input: Input) -> String {
        guard input.isMeeting else { return "no" }
        guard let title = input.meetingTitle?.nonEmpty else { return "yes" }
        return "yes: \"\(title)\""
    }

    /// What a rejected answer is told, so the retry has a chance of being different.
    public static let repairNote = "Your previous output was not valid JSON for the schema."

    // MARK: - User prompt

    /// `projects` is the catalog as the prompt lists it, `promptProjects(_:frameCounts:)` of the
    /// whole list; nil lists every entry up to the cap with no frame counts to rank by.
    public static func userPrompt(
        resolved: ResolvedApp?,
        taxonomy: TaxonomyStore,
        input: Input,
        timeZone: TimeZone = .current,
        projects: [ProjectEntry]? = nil
    ) -> String {
        var lines = [
            "Time: \(timestamp(input.at, timeZone: timeZone))",
            "App: \(appLine(resolved: resolved, input: input))",
            "Window title: \(input.windowTitle?.nonEmpty ?? "unknown")",
            "URL: \(input.url?.nonEmpty ?? "n/a")",
            "In meeting (per calendar/detector): \(meetingLine(input))",
            "Known tasks for this app:",
            taxonomy.promptFragment(for: resolved),
        ]

        // #90: the canonical project list, so `project_hint` comes back spelled the way
        // yesterday spelled it instead of the way this screen happens to. #315: by key, so the
        // answer can name the entry itself in `project_key`.
        let listed = projects ?? promptProjects(taxonomy.projects)
        if let block = knownProjects(listed) { lines.append(block) }

        if let context = contextBlock(input.context, timeZone: timeZone) { lines.append(context) }

        if let text = windowTextBlock(input) { lines.append(text) }
        lines.append(closing(input.mode))
        if let repairNote = input.repairNote { lines.append(repairNote) }
        return lines.joined(separator: "\n")
    }

    /// How many catalog entries the prompt lists and `project_key` may name (#315). Up to it,
    /// every entry; past it, `promptProjects` keeps the house entry and the most used.
    public static let projectKeyLimit = 40
    /// How far back `promptProjects` counts frames when the catalog is over the cap.
    public static let projectCountDays = 14

    /// The entries the prompt lists and the schema enumerates (#315). The whole catalog while it
    /// fits under `limit`; past it, the house entry and then the entries with the most frames in
    /// `frameCounts` (key → frames over `projectCountDays`), ties in file order. Pure, so the
    /// worker's hourly count cache is the only state.
    public static func promptProjects(
        _ projects: [ProjectEntry], frameCounts: [String: Int] = [:], limit: Int = projectKeyLimit
    ) -> [ProjectEntry] {
        guard projects.count > limit else { return projects }
        let house = projects.first { $0.kind == .house }
        let ranked = projects.enumerated()
            .filter { $0.element.key != house?.key }
            .sorted { lhs, rhs in
                let left = frameCounts[lhs.element.key] ?? 0
                let right = frameCounts[rhs.element.key] ?? 0
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        let kept = (house.map { [$0] } ?? []) + ranked
        return Array(kept.prefix(limit))
    }

    /// The rule the house entry is listed with: the firm's key is for the firm's own work, not
    /// for every frame that happens to be on a work machine.
    static let houseRule = "Use the house key only for firm-wide inbox, calendar or admin work "
        + "with no company, deal or repo on screen."

    /// The catalog by key, house first with its rule, then the rest grouped by kind, or nil
    /// while the list is empty — a fresh install's prompt has no project block at all.
    ///
    ///     Known projects, by key (project_key is one of these keys or null; reuse the name in project_hint):
    ///     - house: "halyard" (Halyard). Use the house key only for firm-wide inbox, … on screen.
    ///     - companies: "riverbend capital group" (Riverbend Capital Group), "acme" (Acme)
    ///     - side projects: "worklens" (Worklens)
    ///     Otherwise, use the key of the entry on screen. When no listed entry fits, set
    ///     project_key to null and name the project in project_hint.
    static func knownProjects(_ projects: [ProjectEntry]) -> String? {
        guard !projects.isEmpty else { return nil }
        func entry(_ project: ProjectEntry) -> String {
            "\"\(project.key)\" (\(project.name))"
        }
        var lines = [
            "Known projects, by key (project_key is one of these keys or null; reuse the name "
                + "in project_hint):"
        ]
        let house = projects.first { $0.kind == .house }
        if let house { lines.append("- house: \(entry(house)). \(houseRule)") }
        let groups: [(label: String, kind: ProjectKind?)] = [
            ("companies", .company), ("side projects", .side), ("other", nil),
        ]
        for group in groups {
            let members = projects.filter { $0.kind == group.kind }
            guard !members.isEmpty else { continue }
            lines.append("- \(group.label): " + members.map(entry).joined(separator: ", "))
        }
        lines.append(
            (house == nil ? "Use" : "Otherwise, use") + " the key of the entry on screen. When no "
                + "listed entry fits, set project_key to null and name the project in project_hint."
        )
        return lines.joined(separator: "\n")
    }

    /// Where this frame sits, or nil when nothing earlier is known (#65). Rendered in every mode:
    /// the run is a fact about the frame, not about which artifacts were sent.
    ///
    ///     Before this app: 09:41 slack/reading_messages — Reads #deal-flow.
    ///     In this app since 09:45 (20 frames):
    ///     - 09:45 chat_llm/prompting: Drafts a migration plan.
    ///     … 15 more frames
    ///     - 10:31 chat_llm/prompting: Reviews the generated SQL.
    static func contextBlock(_ context: RunContext, timeZone: TimeZone) -> String? {
        var lines: [String] = []
        if let before = context.before {
            lines.append("Before this app: \(quote(before, timeZone: timeZone))")
        }
        if let start = context.runStart, context.first != nil || !context.tail.isEmpty {
            let frames = context.runFrames == 1 ? "1 frame" : "\(context.runFrames) frames"
            lines.append("In this app since \(clock(start, timeZone: timeZone)) (\(frames)):")
            if let first = context.first { lines.append("- " + quote(first, timeZone: timeZone)) }
            if context.omitted > 0 {
                lines.append("… \(context.omitted) more frame\(context.omitted == 1 ? "" : "s")")
            }
            lines += context.tail.map { "- " + quote($0, timeZone: timeZone) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func quote(
        _ frame: RecentFrame, timeZone: TimeZone, separator: String = ": "
    ) -> String {
        "\(clock(frame.at, timeZone: timeZone)) \(frame.appKey)/\(frame.taskKey)\(separator)\(frame.summary)"
    }

    /// The outline, headed by the grade it earned, or nil for a mode that sends no text. The
    /// heading is what tells the model whether a missing detail means "not on screen" or only
    /// "the walk did not reach it".
    static func windowTextBlock(_ input: Input) -> String? {
        guard input.mode.sendsText, let text = input.windowText?.nonEmpty else { return nil }
        let grade = (input.coverage ?? .partial).rawValue
        return "Focused window text (accessibility outline, \(grade) coverage):\n\(text)"
    }

    /// The last line of the prompt, which has to name what the model was actually given.
    static func closing(_ mode: Mode) -> String {
        let tail = "Prefer a universal task key over proposing a new one."
        switch mode {
        case .text:
            return "Describe what is happening, from the window text above. \(tail)"
        case .textAndImage:
            return "Describe what is happening, from the window text and the screenshot. \(tail)"
        case .image:
            return "Describe the screenshot. \(tail)"
        }
    }

    private static func appLine(resolved: ResolvedApp?, input: Input) -> String {
        let name = input.appName?.nonEmpty ?? resolved?.name ?? "unknown"
        guard let bundleID = input.bundleID?.nonEmpty else { return name }
        return "\(name) (\(bundleID))"
    }

    /// `2026-09-07 14:32 (Sunday)`.
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        return formatter.string(from: date)
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Schema

    /// Built per request so `app_key` and `task_key` are enums of exactly the keys this frame may
    /// use — the model cannot invent a label, it can only fall back to `other`.
    ///
    /// `projects` is what the prompt listed (#315): `project_key` is an enum of exactly those keys
    /// plus null, and absent while the list is empty. Nil means every entry up to the cap.
    public static func schema(
        resolved: ResolvedApp?, taxonomy: Taxonomy, projects: [ProjectEntry]? = nil
    ) -> JSONValue {
        let appKeys: [String]
        let taskKeys: [String]
        if let resolved {
            appKeys = [resolved.appKey, "other"]
            taskKeys = resolved.tasks.map(\.key) + taxonomy.universalTaskKeys
        } else {
            appKeys = taxonomy.allAppKeys + ["other"]
            taskKeys = taxonomy.universalTaskKeys
        }

        func enumString(_ values: [String], _ description: String) -> JSONValue {
            .object([
                "type": .string("string"),
                "enum": .array(uniqued(values).map(JSONValue.string)),
                "description": .string(description),
            ])
        }
        func nullableString(_ description: String) -> JSONValue {
            .object([
                "type": .array([.string("string"), .string("null")]),
                "description": .string(description),
            ])
        }

        var properties: [String: JSONValue] = [
            "app_key": enumString(appKeys, "Which app or web app is in the foreground."),
            "task_key": enumString(taskKeys, "What the person is doing in it."),
            "summary": .object([
                "type": .string("string"),
                "description": .string(
                    "One or two factual sentences, present tense, at most 60 words. Start with "
                        + "a verb and no subject (\"Reads…\", \"Drafts…\"); no second person. When the "
                        + "context shows this activity continuing, say what is new."
                ),
            ]),
            "document": nullableString("Name of the document, page, file or thread on screen."),
            "project_hint": nullableString("Company, deal or project the content is about."),
            "is_meeting": .object(["type": .string("boolean")]),
            "is_sensitive": .object([
                "type": .string("boolean"),
                "description": .string(
                    "True for passwords, banking, medical, HR, dating, personal chats or private browsing."
                ),
            ]),
        ]
        // #315: null inside the enum is how "none of these" is said; confirmed with a live call
        // on 2026-10-07 (docs/api-shapes.md).
        let keys = uniqued((projects ?? promptProjects(taxonomy.projectList)).map(\.key))
        if !keys.isEmpty {
            properties["project_key"] = .object([
                "type": .array([.string("string"), .string("null")]),
                "enum": .array(keys.map(JSONValue.string) + [.null]),
                "description": .string("Key of the known project this frame is about, or null."),
            ])
        }

        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array([
                "app_key", "task_key", "summary", "is_meeting", "is_sensitive",
            ].map(JSONValue.string)),
        ])
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Assembly

    /// The image is attached only when `input.mode` says so, so the picture and the wording can
    /// never disagree: a text-only prompt is never sent with a JPEG bolted on beside it.
    /// `language` is `REPORT_LANGUAGE` (#157). At its default the instruction is the constant
    /// above, to the byte; anything else appends one sentence naming the language.
    public static func systemInstruction(language: String) -> String {
        ReportLanguage.applied(to: systemInstruction, code: language)
    }

    public static func request(
        imageJPEG: Data?,
        resolved: ResolvedApp?,
        taxonomy: TaxonomyStore,
        input: Input,
        timeZone: TimeZone = .current,
        language: String = ReportLanguage.english,
        projects: [ProjectEntry]? = nil
    ) -> DescribeRequest {
        // One list for both halves, so the prompt never names a key the schema refuses.
        let listed = projects ?? promptProjects(taxonomy.projects)
        return DescribeRequest(
            imageJPEG: input.mode.sendsImage ? imageJPEG : nil,
            systemInstruction: systemInstruction(language: language),
            userPrompt: userPrompt(
                resolved: resolved, taxonomy: taxonomy, input: input, timeZone: timeZone, projects: listed
            ),
            schema: schema(resolved: resolved, taxonomy: taxonomy.current, projects: listed),
            maxOutputTokens: maxOutputTokens
        )
    }

    /// `raw_json` = what the model said, plus which prompt said it.
    public static func rawJSON(modelOutput: String) -> String {
        #"{"prompt_version":"\#(version)","output":\#(modelOutput)}"#
    }

    public static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "<unencodable schema>"
        }
        return text
    }
}

extension String {
    /// Nil for a string that is empty or only whitespace, so `??` chains read naturally.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
