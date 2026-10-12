import Foundation

/// The conversation starters `worklens mcp` offers a client's "+" menu (#241).
///
/// A tool list tells a model what it *may* call; it does not tell a person what is worth asking.
/// These four do: each one names the tools to call and the order to call them in, so the answer
/// comes from the timeline and the numbers rather than from a guess, and each one carries the
/// house rules — second person, no scores, no day-against-day comparisons.
///
/// The messages are model-facing prose and stay English, like every other prompt in this package.
/// The `title` and `description` are read by a person in a menu, so they go through `L10n` (#161).
public struct MCPPromptArgument: Sendable, Equatable {
    public let name: String
    public let description: String
    public let required: Bool

    public init(name: String, description: String, required: Bool = false) {
        self.name = name
        self.description = description
        self.required = required
    }

    public var listEntry: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "required": .bool(required),
        ])
    }
}

/// One declared prompt: what `prompts/list` says about it, and the message `prompts/get` builds.
public struct MCPPrompt: Sendable {
    public let name: String
    /// Shown in the client's menu. Localized.
    public let title: String
    /// The line under the title. Localized.
    public let description: String
    public let arguments: [MCPPromptArgument]
    /// The single user message, built from whatever arguments the client filled in.
    public let build: @Sendable (JSONValue) -> String

    public init(
        name: String,
        title: String,
        description: String,
        arguments: [MCPPromptArgument] = [],
        build: @escaping @Sendable (JSONValue) -> String
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.build = build
    }

    public var listEntry: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "arguments": .array(arguments.map(\.listEntry)),
        ])
    }

    public func getJSON(arguments values: JSONValue) -> JSONValue {
        .object([
            "description": .string(description),
            "messages": .array([
                .object([
                    "role": "user",
                    "content": .object(["type": "text", "text": .string(build(values))]),
                ]),
            ]),
        ])
    }
}

/// The five Worklens prompts, built once per registry.
public enum WorklensMCPPrompts {
    /// The rules the answer is written under.
    static let houseRules =
        "Write the answer in the second person, about your own day. Do not score anything, do "
            + "not rank the day against another day, and do not invent anything the tools did not "
            + "return."

    private static func dayLine(_ arguments: JSONValue) -> String {
        if let day = arguments.optionalString("day") {
            return "The day to look at is \(day)."
        }
        return "No day was given: call `days` first and use the most recent day that has data."
    }

    private static func weekLine(_ arguments: JSONValue) -> String {
        if let week = arguments.optionalString("week") {
            return "The week to look at is \(week)."
        }
        return "No week was given: call `days` first and work from the week the most recent day "
            + "with data falls in."
    }

    public static func all() -> [MCPPrompt] {
        [
            howWasToday(),
            whatDidIWorkOn(),
            whenDidILast(),
            whereDidMyWeekGo(),
            whatDidIShip(),
        ]
    }

    // MARK: - The five

    private static func howWasToday() -> MCPPrompt {
        MCPPrompt(
            name: "how_was_today",
            title: L10n.string("How did today go?"),
            description: L10n.string("Walk through one day from what was actually on screen."),
            arguments: [
                MCPPromptArgument(name: "day", description: "A local day, YYYY-MM-DD. Optional."),
            ]
        ) { arguments in
            """
            Tell me how my day went.

            \(dayLine(arguments))

            Call `stats` for that day to get the totals, then `timeline` for the shape of the \
            day, then `context_events` for the meetings in it. The timeline and the numbers are \
            the whole answer.

            \(houseRules)
            """
        }
    }

    private static func whatDidIWorkOn() -> MCPPrompt {
        MCPPrompt(
            name: "what_did_i_work_on",
            title: L10n.string("What did I work on this week?"),
            description: L10n.string("Pull the week together from the days that have data."),
            arguments: [
                MCPPromptArgument(name: "week", description: "An ISO week, e.g. 2026-W37. Optional."),
            ]
        ) { arguments in
            """
            Tell me what I worked on over the week.

            \(weekLine(arguments))

            Call `days` for the days that have data, then `stats` with that week for the \
            totals by project and by app, then `timeline` for the two or three days that carry \
            most of the time. The numbers and the days are the whole answer.

            \(houseRules)
            """
        }
    }

    private static func whenDidILast() -> MCPPrompt {
        MCPPrompt(
            name: "when_did_i_last",
            title: L10n.string("When did I last touch this?"),
            description: L10n.string("Find the last time something was on your screen."),
            arguments: [
                MCPPromptArgument(
                    name: "subject",
                    description: "The thing to look for: a project, a document, a person.",
                    required: true
                ),
            ]
        ) { arguments in
            let subject = arguments.optionalString("subject") ?? "the thing I am asking about"
            return """
                Find when I last touched \(subject).

                Call `vocabulary` first so you use the project and app names Worklens actually \
                knows, then `search` for it over all days, narrowing with the `project` or `app` \
                filter when one of those names fits. Take the most recent hit, then call \
                `timeline` for that day so you can say what I was doing around it.

                \(houseRules)
                """
        }
    }

    private static func whereDidMyWeekGo() -> MCPPrompt {
        MCPPrompt(
            name: "where_did_my_week_go",
            title: L10n.string("Where did my week go, by project?"),
            description: L10n.string("Split the week's tracked time across projects."),
            arguments: [
                MCPPromptArgument(name: "week", description: "An ISO week, e.g. 2026-W37. Optional."),
            ]
        ) { arguments in
            """
            Show me where my week went, by project.

            \(weekLine(arguments))

            Call `vocabulary` for the projects Worklens knows, then `span` over that week's first \
            and last day with `by` set to "project": every project with its screen, meeting and \
            agent minutes per day, the time no project claimed and the time nothing was recorded. \
            Call `timeline` on the day with the most minutes across the rows' perDay if \
            something in the split needs explaining.

            Give me the minutes per project and what each one was. Read the unattributed and \
            not-recorded minutes back as the answer gives them. \(houseRules)
            """
        }
    }

    private static func whatDidIShip() -> MCPPrompt {
        MCPPrompt(
            name: "what_did_i_ship",
            title: L10n.string("What did I ship, and where did my time go?"),
            description: L10n.string("Put what you shipped beside the time each project took."),
            arguments: [
                MCPPromptArgument(name: "from", description: "First local day, YYYY-MM-DD. Optional."),
                MCPPromptArgument(name: "to", description: "Last local day, inclusive, YYYY-MM-DD. Optional."),
            ]
        ) { arguments in
            let from = arguments.optionalString("from")
            let to = arguments.optionalString("to")
            let range: String
            if let from, let to {
                range = "The range to look at is \(from) to \(to)."
            } else if let day = from ?? to {
                range = "The day to look at is \(day)."
            } else {
                range = "No range was given: call `days` first and use the most recent day that has data."
            }
            return """
                Tell me what I shipped and where my time went.

                \(range)

                Call `span` over that range with `by` set to "project" (at most \
                \(WorklensMCPTools.spanProjectMaxDays) days), then `shipped` over the same range, \
                \(WorklensMCPTools.spanMaxDays) days at a time, since `shipped` takes at most that many. Put \
                each thing I shipped under the project it names, and give each project its \
                minutes as `span` returned them. Never say a thing I shipped took a project's \
                minutes: the two sit side by side, not one inside the other. Read the \
                unattributed and not-recorded minutes back as the answer gives them.

                \(houseRules)
                """
        }
    }
}
