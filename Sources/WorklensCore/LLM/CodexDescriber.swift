import Foundation

/// Summarizes through the person's own `codex` command (Codex CLI), signed in with their
/// ChatGPT plan. No API key: the call uses the plan's allowance, and costs Worklens $0.
///
/// The command shape was checked on `codex-cli` 0.159.3 on 2026-11-27 and is quoted in
/// `docs/api-shapes.md`. Every flag in `arguments` keeps the call isolated, because a screenshot
/// is untrusted input: the person's config, rules, project docs, skills and plugins are ignored,
/// the built-in tools (shell, browser, image viewer, sub-agents, memories) are off, the sandbox is
/// read-only in an empty directory, nothing is saved, and the prompt arrives on stdin (`-`).
public final class CodexDescriber: VisionDescriber {
    public static let provider = "codex"
    public static let effort = "low"

    /// Built-in capabilities a summary call never needs. Not `code_mode_host`: Codex routes
    /// every tool call through it and it gives no shell or files of its own.
    public static let disabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "browser_use", "computer_use",
        "in_app_browser", "image_generation", "multi_agent", "goals", "view_image",
        "tool_suggest", "skill_search", "hooks", "memories",
    ]

    private let cli: any SubscriptionCLI
    private let family: String
    private let resolver: CodexModelResolver
    private let workspace: SubscriptionWorkspace
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let state = LockedBox(State())

    struct State {
        var status: SubscriptionStatus?
        var statusAt: Date?
    }

    /// - Parameter family: `sol` or `luna`, resolved to the newest `gpt-<version>-<family>` the
    ///   command lists (see `CodexModelResolver`).
    public init(
        cli: any SubscriptionCLI,
        family: String,
        workspace: SubscriptionWorkspace,
        resolver: CodexModelResolver? = nil,
        timeout: TimeInterval = SubscriptionCLIRunner.defaultTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cli = cli
        self.family = family
        self.workspace = workspace
        self.resolver = resolver ?? CodexModelResolver(
            cli: cli,
            cacheFile: workspace.emptyDirectory.deletingLastPathComponent()
                .appendingPathComponent("codex-models.json"),
            workingDirectory: workspace.emptyDirectory,
            now: now
        )
        self.timeout = timeout
        self.now = now
    }

    public var provider: String { CodexDescriber.provider }

    // MARK: - The command

    /// Everything after `codex`. `model` nil leaves the choice to the command. The instruction
    /// is the fixed describe instruction; the screen's words travel on stdin, the image and the
    /// schema as 0600 files in `cli-tmp`.
    public static func arguments(
        model: String?, systemInstruction: String, imageFile: URL, schemaFile: URL, workingDirectory: URL
    ) -> [String] {
        arguments(
            model: model, systemInstruction: systemInstruction, imageFiles: [imageFile],
            schemaFile: schemaFile, workingDirectory: workingDirectory
        )
    }

    /// A batch attaches every picture with its own `--image`, in the order the prompt numbers
    /// them ("image 2 of 5"); a path names a screenshot file, never what is on it.
    public static func arguments(
        model: String?, systemInstruction: String, imageFiles: [URL], schemaFile: URL, workingDirectory: URL
    ) -> [String] {
        var arguments = ["exec"]
        arguments += imageFiles.map { "--image=\($0.path)" }
        arguments += [
            "--json",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "-s", "read-only",
            "-C", workingDirectory.path,
        ]
        if let model { arguments += ["-m", model] }
        arguments += [
            "-c", "model_reasoning_effort=\"\(effort)\"",
            "-c", "developer_instructions=\(tomlString(systemInstruction))",
            "-c", "web_search=\"disabled\"",
            "-c", "approval_policy=\"never\"",
            "-c", "project_doc_max_bytes=0",
            "-c", "history.persistence=\"none\"",
            "-c", "include_permissions_instructions=false",
            "-c", "skills.include_instructions=false",
            "-c", "skills.bundled.enabled=false",
        ]
        for feature in disabledFeatures { arguments += ["--disable", feature] }
        arguments += ["--output-schema", schemaFile.path, "-"]
        return arguments
    }

    /// A string as the inline TOML a `-c` value takes. JSON string escaping is valid TOML.
    static func tomlString(_ text: String) -> String {
        ClaudeDescriber.compactJSON(.string(text))
    }

    /// OpenAI's structured outputs want a strict schema: every property listed in `required`
    /// and no extra properties. The optional fields become nullable instead, which the parser
    /// already treats as absent.
    public static func strictSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case var .object(object):
            if case let .object(properties)? = object["properties"] {
                let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                var strict: [String: JSONValue] = [:]
                for (name, property) in properties {
                    let inner = strictSchema(property)
                    strict[name] = required.contains(name) ? inner : nullable(inner)
                }
                object["properties"] = .object(strict)
                object["required"] = .array(properties.keys.sorted().map { .string($0) })
                object["additionalProperties"] = .bool(false)
            }
            if let items = object["items"] { object["items"] = strictSchema(items) }
            return .object(object)
        case let .array(values):
            return .array(values.map(strictSchema))
        default:
            return schema
        }
    }

    static func nullable(_ property: JSONValue) -> JSONValue {
        guard case var .object(object) = property else { return property }
        switch object["type"] {
        case let .string(type)?:
            object["type"] = .array([.string(type), .string("null")])
        case let .array(types)? where !types.contains(.string("null")):
            object["type"] = .array(types + [.string("null")])
        default:
            break
        }
        if case let .array(values)? = object["enum"], !values.contains(.null) {
            object["enum"] = .array(values + [.null])
        }
        return .object(object)
    }

    // MARK: - VisionDescriber

    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        let executable = try await checkedExecutable()
        try workspace.prepare()
        var cleanup: [URL] = []
        defer { for url in cleanup { try? FileManager.default.removeItem(at: url) } }

        guard !request.images.isEmpty else {
            throw LLMError.badRequest(400, "codex needs a screenshot")
        }
        var imageFiles: [URL] = []
        for image in request.images {
            if let existing = image.file, FileManager.default.isReadableFile(atPath: existing.path) {
                imageFiles.append(existing)
            } else {
                let written = try workspace.writeTemporary(image.jpeg, suffix: "jpg")
                cleanup.append(written)
                imageFiles.append(written)
            }
        }
        let schemaData = Data(ClaudeDescriber.compactJSON(Self.strictSchema(request.schema)).utf8)
        let schemaFile = try workspace.writeTemporary(schemaData, suffix: "json")
        cleanup.append(schemaFile)

        let model = await resolver.model(family: family, executable: executable)
        let invocation = CLIInvocation(
            executable: executable,
            arguments: Self.arguments(
                model: model, systemInstruction: request.systemInstruction,
                imageFiles: imageFiles, schemaFile: schemaFile, workingDirectory: workspace.emptyDirectory
            ),
            stdin: Data(request.userPrompt.utf8),
            workingDirectory: workspace.emptyDirectory,
            timeout: timeout
        )

        var output: CLIOutput?
        for attempt in 1...2 {
            do {
                output = try await cli.run(invocation)
                break
            } catch CLIRunError.timedOut {
                Log.describe.warn("codex did not answer within \(Int(timeout))s (attempt \(attempt))")
            } catch let CLIRunError.launchFailed(reason) {
                Log.describe.warn("codex could not be started: \(reason)")
                throw SubscriptionError.notInstalled(.codex)
            }
        }
        guard let output else { throw SubscriptionError.timedOut(.codex) }

        switch Self.parse(output) {
        case let .answer(json, usage):
            Log.describe.info("codex answered: exit \(output.status), \(output.durationMs) ms")
            if let model { await resolver.recordWorking(model, family: family) }
            return DescribeResponse(
                json: json, usage: usage, costUSD: 0, latencyMs: output.durationMs,
                model: model ?? "codex-default", provider: provider
            )
        case let .failure(error):
            Log.describe.info("codex failed: exit \(output.status), \(output.durationMs) ms, \(ClaudeDescriber.errorClass(error))")
            Log.describe.debug("codex stderr tail: \(SubscriptionLogTail.scrub(output.stderrText))")
            if case .signedOut = error as? SubscriptionError {
                state.withLock { $0.statusAt = nil }
            }
            throw error
        }
    }

    private func checkedExecutable() async throws -> String {
        let instant = now()
        let cached: SubscriptionStatus? = state.withLock { current in
            guard let at = current.statusAt, instant.timeIntervalSince(at) < ClaudeDescriber.statusTTL else {
                return nil
            }
            return current.status
        }
        let status: SubscriptionStatus
        if let cached {
            status = cached
        } else {
            status = await SubscriptionStatusChecker(cli: cli, workingDirectory: workspace.emptyDirectory)
                .status(.codex)
            state.withLock {
                $0.status = status
                $0.statusAt = instant
            }
        }
        if let error = status.blockingError(now: instant) { throw error }
        guard let executable = status.executable else { throw SubscriptionError.notInstalled(.codex) }
        return executable
    }

    public var lastStatus: SubscriptionStatus? { state.withLock { $0.status } }

    // MARK: - Reading the answer

    enum Outcome {
        case answer(json: String, usage: LLMUsage)
        case failure(Error)
    }

    /// Reads the `--json` events: the last `item.completed` whose item is an `agent_message`
    /// carries the answer text; `turn.completed` carries the usage; `turn.failed` and `error`
    /// carry the reason a turn stopped.
    static func parse(_ output: CLIOutput) -> Outcome {
        var answer: String?
        var usage: JSONValue?
        var failure: String?
        var errors: [String] = []
        for line in output.stdoutText.split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue else {
                continue
            }
            switch event["type"]?.stringValue {
            case "item.completed":
                if event["item"]?["type"]?.stringValue == "agent_message" {
                    answer = event["item"]?["text"]?.stringValue
                }
            case "turn.completed":
                usage = event["usage"]
            case "turn.failed":
                failure = event["error"]?["message"]?.stringValue ?? "turn failed"
            case "error":
                if let message = event["message"]?.stringValue { errors.append(message) }
            default:
                continue
            }
        }

        if let answer, failure == nil, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cached = usage?["cached_input_tokens"]?.intValue ?? 0
            return .answer(json: answer, usage: LLMUsage(
                promptTokens: usage?["input_tokens"]?.intValue ?? 0,
                outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                thoughtTokens: usage?["reasoning_output_tokens"]?.intValue ?? 0,
                cachedTokens: cached
            ))
        }
        let text = ([failure].compactMap { $0 } + errors + [output.stderrText]).joined(separator: "\n")
        if let error = classifyFailure(text) { return .failure(error) }
        if answer != nil, failure == nil {
            return .failure(LLMError.decode("codex returned no answer"))
        }
        return .failure(SubscriptionError.failed(.codex, status: output.status == 0 ? 1 : output.status))
    }

    /// Matches the command's words to a class and throws the words away. `codex login status`
    /// can still say "Logged in using ChatGPT" while every call fails with a revoked refresh
    /// token (seen 2026-11-27), so the call's own 401 counts as signed out.
    static func classifyFailure(_ text: String) -> SubscriptionError? {
        let lowered = text.lowercased()
        if lowered.contains("unauthorized (401)") || lowered.contains("401 unauthorized")
            || lowered.contains("refresh token") || lowered.contains("sign in again")
            || lowered.contains("not logged in") || lowered.contains("codex login") {
            return .signedOut(.codex)
        }
        if lowered.contains("usage limit") || lowered.contains("rate limit")
            || lowered.contains("429") || lowered.contains("quota") {
            return .usageLimit(.codex, resetsAt: nil)
        }
        if lowered.contains("stream disconnected") || lowered.contains("error sending request")
            || lowered.contains("connection") || lowered.contains("timed out")
            || lowered.contains("dns") || lowered.contains(" 50") {
            return .unreachable(.codex)
        }
        return nil
    }
}

/// Turns a family name (`sol`, `luna`) into the newest model of that family the person's
/// `codex` lists, so a new release needs no change in Worklens.
///
/// From `codex debug models` it keeps the entries with `visibility == "list"` and image input,
/// takes the slugs shaped `gpt-<version>-<family>`, and picks the highest version numerically
/// (`gpt-6.1-sol` over `gpt-6-sol` over `gpt-5.6-sol`). The answer is cached for 24 hours in
/// `DATA_DIR/run/codex-models.json` and resolved again when the command's version changes. When
/// resolving fails it falls back to the last slug that answered, and with none, to no `-m` at
/// all, which leaves the choice to the command.
public actor CodexModelResolver {
    public static let ttl: TimeInterval = 24 * 60 * 60

    struct Cache: Codable, Equatable {
        var cliVersion: String?
        var resolvedAt: Date?
        var slugs: [String: String] = [:]
        var lastWorking: [String: String] = [:]
    }

    private let cli: any SubscriptionCLI
    private let cacheFile: URL
    private let workingDirectory: URL
    private let now: @Sendable () -> Date
    private var cache: Cache?

    public init(
        cli: any SubscriptionCLI, cacheFile: URL, workingDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cli = cli
        self.cacheFile = cacheFile
        self.workingDirectory = workingDirectory
        self.now = now
    }

    /// The slug to pass as `-m`, or nil to let the command choose.
    public func model(family: String, executable: String) async -> String? {
        var cache = loaded()
        let version = await run(executable, ["--version"]).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fresh = cache.resolvedAt.map { now().timeIntervalSince($0) < Self.ttl } ?? false
        if fresh, version == cache.cliVersion, let slug = cache.slugs[family] {
            return slug
        }
        if let listing = await run(executable, ["debug", "models"]),
           let slug = Self.resolve(family: family, listing: Data(listing.utf8)) {
            cache.cliVersion = version
            cache.resolvedAt = now()
            cache.slugs[family] = slug
            save(cache)
            return slug
        }
        Log.describe.info("codex model family \(family) did not resolve; using the last one that answered")
        return cache.lastWorking[family]
    }

    /// Remembers a slug that answered, for when resolving fails later.
    public func recordWorking(_ slug: String, family: String) {
        var cache = loaded()
        guard cache.lastWorking[family] != slug else { return }
        cache.lastWorking[family] = slug
        save(cache)
    }

    /// The newest listed, image-capable `gpt-<version>-<family>` in a `codex debug models`
    /// listing. Nil when the listing does not parse or has none.
    public static func resolve(family: String, listing: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: listing) else { return nil }
        let models = root["models"]?.arrayValue ?? root.arrayValue ?? []
        let suffix = "-\(family.lowercased())"
        var best: (version: NumericVersion, slug: String)?
        for model in models {
            guard let slug = model["slug"]?.stringValue?.lowercased(),
                  model["visibility"]?.stringValue == "list",
                  model["input_modalities"]?.arrayValue?.contains(.string("image")) == true,
                  slug.hasPrefix("gpt-"), slug.hasSuffix(suffix) else { continue }
            let versionText = String(slug.dropFirst(4).dropLast(suffix.count))
            guard !versionText.isEmpty,
                  versionText.allSatisfy({ $0.isNumber || $0 == "." }),
                  versionText.first?.isNumber == true else { continue }
            let version = NumericVersion(versionText)
            if best == nil || version > best!.version { best = (version, slug) }
        }
        return best?.slug
    }

    private func run(_ executable: String, _ arguments: [String]) async -> String? {
        guard let output = try? await cli.run(CLIInvocation(
            executable: executable, arguments: arguments,
            workingDirectory: workingDirectory, timeout: SubscriptionStatusChecker.timeout
        )), output.status == 0 else { return nil }
        return output.stdoutText
    }

    private func loaded() -> Cache {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = (try? Data(contentsOf: cacheFile)).flatMap { try? decoder.decode(Cache.self, from: $0) }
        cache = read ?? Cache()
        return cache!
    }

    private func save(_ new: Cache) {
        cache = new
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(new) else { return }
        try? FilePermissions.createPrivateDirectory(at: cacheFile.deletingLastPathComponent())
        try? FilePermissions.writePrivate(data, to: cacheFile)
    }
}
