import Foundation

/// Summarizes through the person's own `claude` command (Claude Code), signed in with their
/// Claude plan. No API key: the call uses the plan's allowance, and costs Worklens $0.
///
/// The command shape was verified live on `claude` 2.1.326 on 2026-11-27 and is quoted in
/// `docs/api-shapes.md`. Every flag in `arguments` is there to keep the call isolated, because a
/// screenshot is untrusted input (a page on screen can say "run this command"): no tools, no MCP
/// servers, no user settings, hooks, skills or plugins, no auto-memory, no saved session, an
/// empty working directory. The plugins built into the `claude` install itself still load; only
/// `--bare` drops them, and with no tools they have nothing to act on. `--bare` would be tidier and is deliberately absent: it turns off the subscription
/// login ("Not logged in · Please run /login", checked the same day).
public final class ClaudeDescriber: VisionDescriber {
    public static let provider = "claude"
    /// Low effort: a summary is a short read of one screen.
    public static let effort = "low"
    /// How long a sign-in check is trusted before a call asks again.
    public static let statusTTL: TimeInterval = 6 * 60 * 60

    private let cli: any SubscriptionCLI
    private let model: String
    private let workspace: SubscriptionWorkspace
    private let timeout: TimeInterval
    private let headroomPercent: Int
    private let now: @Sendable () -> Date
    private let state = LockedBox(State())

    struct State {
        var status: SubscriptionStatus?
        var statusAt: Date?
        var rateLimits: ClaudeRateLimits?
        var rateLimitsAt: Date?
    }

    /// - Parameter model: an alias (`sonnet`, `haiku`), never a full id: the CLI resolves it to
    ///   the newest model of that family it knows, so a release needs no change here.
    public init(
        cli: any SubscriptionCLI,
        model: String,
        workspace: SubscriptionWorkspace,
        timeout: TimeInterval = SubscriptionCLIRunner.defaultTimeout,
        headroomPercent: Int = PlanHeadroom.defaultPercent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cli = cli
        self.model = model
        self.workspace = workspace
        self.timeout = timeout
        self.headroomPercent = headroomPercent
        self.now = now
    }

    public var provider: String { ClaudeDescriber.provider }

    /// A plan call is never billed per token, so the daily budget does not hold it.
    public var costsMoney: Bool { false }

    /// Until when the plan is left to the person, from the windows the last call reported.
    public func headroomUntil(now: Date) -> Date? {
        let (limits, at) = state.withLock { ($0.rateLimits, $0.rateLimitsAt) }
        return PlanHeadroom.until(limits, observedAt: at, percent: headroomPercent, now: now)
    }

    /// The plan windows the last call reported, for leaving room in the plan (Part 4).
    public var lastRateLimits: ClaudeRateLimits? { state.withLock { $0.rateLimits } }

    // MARK: - The command

    /// Everything after `claude`. Nothing here is private: the instruction is the fixed describe
    /// instruction, and `argvSafe` takes the person's project names out of the schema. The
    /// screen's text, titles and URLs travel on stdin.
    public static func arguments(model: String, systemInstruction: String, schema: JSONValue) -> [String] {
        [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--effort", effort,
            "--system-prompt", systemInstruction,
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--settings", #"{"autoMemoryEnabled":false}"#,
            "--no-session-persistence",
            "--disable-slash-commands",
            "--json-schema", compactJSON(argvSafe(schema)),
        ]
    }

    /// The schema without the `project_key` enum. Its values are the person's own project
    /// names, and `--json-schema` only takes the schema inline, where `ps` can read it. The
    /// prompt on stdin still lists the keys, and `DescribeWorker.store` drops any key the
    /// catalog does not know, so the answer is held to the same list either way.
    ///
    /// Walks the whole schema, because a batch nests the per-screenshot fields under
    /// `screenshots.items`, and the project list must stay off argv there too.
    public static func argvSafe(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case let .object(object):
            var copy: [String: JSONValue] = [:]
            for (key, value) in object {
                if key == "properties", case var .object(properties) = value {
                    if case var .object(project)? = properties["project_key"] {
                        project["enum"] = nil
                        properties["project_key"] = .object(project)
                    }
                    copy[key] = argvSafe(.object(properties))
                } else {
                    copy[key] = argvSafe(value)
                }
            }
            return .object(copy)
        case let .array(values):
            return .array(values.map(argvSafe))
        default:
            return schema
        }
    }

    /// One stream-json user message: the prompt as a text block, then the screenshot as a
    /// base64 `image` block. A batch puts a text block with each picture's label
    /// ("Screenshot 3 of 7, 14:32:10") before that picture, in the order the prompt lists them.
    public static func stdin(for request: DescribeRequest) -> Data {
        var content: [JSONValue] = [["type": "text", "text": .string(request.userPrompt)]]
        for image in request.images {
            if let label = image.label {
                content.append(["type": "text", "text": .string(label)])
            }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": .string(image.jpeg.base64EncodedString()),
                ],
            ])
        }
        let message: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
        ]
        return Data((compactJSON(message) + "\n").utf8)
    }

    static func compactJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - VisionDescriber

    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        let executable = try await checkedExecutable()
        try workspace.prepare()
        let invocation = CLIInvocation(
            executable: executable,
            arguments: Self.arguments(
                model: model, systemInstruction: request.systemInstruction, schema: request.schema
            ),
            stdin: Self.stdin(for: request),
            workingDirectory: workspace.emptyDirectory,
            timeout: timeout
        )

        var output: CLIOutput?
        for attempt in 1...2 {
            do {
                output = try await cli.run(invocation)
                break
            } catch CLIRunError.timedOut {
                Log.describe.warn("claude did not answer within \(Int(timeout))s (attempt \(attempt))")
            } catch let CLIRunError.launchFailed(reason) {
                Log.describe.warn("claude could not be started: \(reason)")
                throw SubscriptionError.notInstalled(.claude)
            }
        }
        guard let output else { throw SubscriptionError.timedOut(.claude) }

        let parsed = Self.parse(output, requestedModel: model)
        if let limits = parsed.rateLimits {
            let instant = now()
            state.withLock {
                $0.rateLimits = limits
                $0.rateLimitsAt = instant
            }
        }
        switch parsed.outcome {
        case let .answer(json, usage, answeringModel):
            Log.describe.info("claude answered: exit \(output.status), \(output.durationMs) ms")
            return DescribeResponse(
                json: json, usage: usage, costUSD: 0, latencyMs: output.durationMs,
                model: answeringModel, provider: provider
            )
        case let .failure(error):
            Log.describe.info("claude failed: exit \(output.status), \(output.durationMs) ms, \(Self.errorClass(error))")
            Log.describe.debug("claude stderr tail: \(SubscriptionLogTail.scrub(output.stderrText))")
            if case .signedOut = error as? SubscriptionError {
                // Ask again next time rather than trusting a cached "signed in".
                state.withLock { $0.statusAt = nil }
            }
            throw error
        }
    }

    /// The command's path, once its sign-in is known to be a plan. The check is cached for
    /// `statusTTL`, so most calls spawn one process, not two.
    private func checkedExecutable() async throws -> String {
        let instant = now()
        let cached: SubscriptionStatus? = state.withLock { current in
            guard let at = current.statusAt, instant.timeIntervalSince(at) < Self.statusTTL else { return nil }
            return current.status
        }
        let status: SubscriptionStatus
        if let cached {
            status = cached
        } else {
            status = await SubscriptionStatusChecker(cli: cli, workingDirectory: workspace.emptyDirectory)
                .status(.claude)
            state.withLock {
                $0.status = status
                $0.statusAt = instant
            }
        }
        if let error = status.blockingError(now: instant) { throw error }
        guard let executable = status.executable else { throw SubscriptionError.notInstalled(.claude) }
        return executable
    }

    /// The sign-in as last checked, for Settings and the expiry notices.
    public var lastStatus: SubscriptionStatus? { state.withLock { $0.status } }

    // MARK: - Reading the answer

    enum Outcome {
        case answer(json: String, usage: LLMUsage, model: String)
        case failure(Error)
    }

    struct Parsed {
        var outcome: Outcome
        var rateLimits: ClaudeRateLimits?
    }

    /// Reads the stream-json events. The `result` event carries the answer (`structured_output`
    /// when `--json-schema` was honoured, else `result` text), the usage and `modelUsage`, whose
    /// key is the exact model that answered. `rate_limit_event`s carry the plan windows.
    static func parse(_ output: CLIOutput, requestedModel: String) -> Parsed {
        var result: [String: JSONValue]?
        var initModel: String?
        var limits: ClaudeRateLimits?
        for line in output.stdoutText.split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue else {
                continue
            }
            switch event["type"]?.stringValue {
            case "system" where event["subtype"]?.stringValue == "init":
                initModel = event["model"]?.stringValue
            case "rate_limit_event":
                if let info = event["rate_limit_info"], let parsed = ClaudeRateLimits(info) {
                    limits = parsed
                }
            case "result":
                result = event
            default:
                continue
            }
        }

        guard let result else {
            let error = classifyFailure(text: output.stderrText, limits: limits)
                ?? SubscriptionError.failed(.claude, status: output.status)
            return Parsed(outcome: .failure(error), rateLimits: limits)
        }

        let text = result["result"]?.stringValue ?? ""
        if result["is_error"]?.boolValue == true || result["subtype"]?.stringValue != "success" {
            let error = classifyFailure(text: text + "\n" + output.stderrText, limits: limits)
                ?? classifyStatus(result["api_error_status"]?.intValue)
                ?? SubscriptionError.failed(.claude, status: output.status == 0 ? 1 : output.status)
            return Parsed(outcome: .failure(error), rateLimits: limits)
        }

        let json: String
        if let structured = result["structured_output"], !structured.isNull {
            json = compactJSON(structured)
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            json = text
        } else {
            return Parsed(outcome: .failure(LLMError.decode("claude returned no answer")), rateLimits: limits)
        }

        let usage = result["usage"]
        let cacheRead = usage?["cache_read_input_tokens"]?.intValue ?? 0
        let cacheWrite = usage?["cache_creation_input_tokens"]?.intValue ?? 0
        let output = usage?["output_tokens"]?.intValue ?? 0
        let thinking = usage?["output_tokens_details"]?["thinking_tokens"]?.intValue ?? 0
        let llmUsage = LLMUsage(
            promptTokens: (usage?["input_tokens"]?.intValue ?? 0) + cacheRead + cacheWrite,
            outputTokens: max(0, output - thinking),
            thoughtTokens: thinking,
            cachedTokens: cacheRead
        )

        // The model that did the work: the `modelUsage` entry with the most output, which is the
        // only one unless the CLI handed part of the turn to a smaller model.
        let answering = result["modelUsage"]?.objectValue?
            .max { ($0.value["outputTokens"]?.intValue ?? 0) < ($1.value["outputTokens"]?.intValue ?? 0) }?
            .key
        return Parsed(
            outcome: .answer(json: json, usage: llmUsage, model: answering ?? initModel ?? requestedModel),
            rateLimits: limits
        )
    }

    /// Matches the command's words to a class and throws the words away. Nil when nothing fits.
    static func classifyFailure(text: String, limits: ClaudeRateLimits?) -> SubscriptionError? {
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("/login")
            || lowered.contains("oauth token has expired") || lowered.contains("authentication_error")
            || lowered.contains("invalid api key") || lowered.contains("please run claude auth login") {
            return .signedOut(.claude)
        }
        if lowered.contains("usage limit") || lowered.contains("hit your limit")
            || lowered.contains("rate_limit_error") || lowered.contains("out of extra usage")
            || limits?.isRejected == true {
            return .usageLimit(.claude, resetsAt: limits?.rejectedResetsAt ?? resetEpoch(in: text))
        }
        if lowered.contains("connection error") || lowered.contains("enotfound")
            || lowered.contains("fetch failed") || lowered.contains("econnrefused")
            || lowered.contains("network") || lowered.contains("overloaded") {
            return .unreachable(.claude)
        }
        return nil
    }

    static func classifyStatus(_ status: Int?) -> SubscriptionError? {
        switch status {
        case 401, 403: .signedOut(.claude)
        case 429: .usageLimit(.claude, resetsAt: nil)
        case let status? where status >= 500: .unreachable(.claude)
        default: nil
        }
    }

    /// "Claude AI usage limit reached|1795805400": the older wording carried the reset as epoch
    /// seconds after a bar.
    static func resetEpoch(in text: String) -> Date? {
        guard let bar = text.firstIndex(of: "|") else { return nil }
        let digits = text[text.index(after: bar)...].prefix { $0.isNumber }
        guard let seconds = TimeInterval(digits), seconds > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func errorClass(_ error: Error) -> String {
        if let subscription = error as? SubscriptionError { return subscription.description }
        if let llm = error as? LLMError { return llm.description }
        return "error"
    }
}

/// The plan windows a `rate_limit_event` reported, verified 2026-11-27:
/// `{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.14,"resetsAt":1795805400,
/// "status":"allowed"},"seven_day":{…}}}`. `utilization` is a share, 0…1.
public struct ClaudeRateLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var utilization: Double
        public var resetsAt: Date?
        public var status: String?
    }

    public var status: String?
    public var windows: [String: Window]

    public init(status: String?, windows: [String: Window]) {
        self.status = status
        self.windows = windows
    }

    init?(_ info: JSONValue) {
        var windows: [String: Window] = [:]
        for (name, value) in info["unifiedWindows"]?.objectValue ?? [:] {
            guard let utilization = value["utilization"]?.numberValue else { continue }
            windows[name] = Window(
                utilization: utilization,
                resetsAt: value["resetsAt"]?.numberValue.map { Date(timeIntervalSince1970: $0) },
                status: value["status"]?.stringValue
            )
        }
        let status = info["status"]?.stringValue
        guard !windows.isEmpty || status != nil else { return nil }
        self.status = status
        self.windows = windows
    }

    public var isRejected: Bool {
        status == "rejected" || windows.values.contains { $0.status == "rejected" }
    }

    /// When the furthest-out rejected window lifts.
    public var rejectedResetsAt: Date? {
        windows.values.filter { $0.status == "rejected" }.compactMap(\.resetsAt).max()
    }
}

/// What may be kept of a command's stderr at `debug`: the last 200 characters, with anything
/// that looks like a URL or a quoted title taken out.
enum SubscriptionLogTail {
    static func scrub(_ text: String) -> String {
        var tail = String(text.suffix(200))
        for pattern in [#"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#, #""[^"\n]*""#, #"'[^'\n]*'"#] {
            tail = tail.replacingOccurrences(of: pattern, with: "…", options: .regularExpression)
        }
        return tail
    }
}
