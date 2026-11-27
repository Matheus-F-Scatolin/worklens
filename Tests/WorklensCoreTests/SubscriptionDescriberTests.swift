import Foundation
import Testing
@testable import WorklensCore

// MARK: - Doubles

/// A `claude`/`codex` that answers from a handler and remembers every invocation.
final class FakeSubscriptionCLI: SubscriptionCLI, @unchecked Sendable {
    typealias Handler = @Sendable (CLIInvocation) throws -> CLIOutput
    private let lock = NSLock()
    private var seen: [CLIInvocation] = []
    private let handler: Handler
    let installed: Bool

    init(installed: Bool = true, handler: @escaping Handler) {
        self.installed = installed
        self.handler = handler
    }

    var invocations: [CLIInvocation] { lock.withLock { seen } }

    func locate(_ tool: SubscriptionTool) -> String? {
        installed ? "/fake/bin/\(tool.binaryName)" : nil
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIOutput {
        lock.withLock { seen.append(invocation) }
        return try handler(invocation)
    }
}

private let claudeSignedIn = #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","loginExpiresAt":"2026-12-17T03:54:44.907Z","email":"someone@example.com"}"#

/// The events a successful `claude -p` printed on 2026-11-27, trimmed to the fields read.
private let claudeSuccess = """
{"type":"system","subtype":"init","tools":["StructuredOutput"],"mcp_servers":[],"model":"claude-haiku-5-5","apiKeySource":"none"}
{"type":"assistant","message":{"content":[]}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795805400,"unifiedWindows":{"five_hour":{"utilization":0.14,"resetsAt":1795805400,"status":"allowed"},"seven_day":{"utilization":0.24,"resetsAt":1796158800,"status":"allowed"}}}}
{"type":"result","subtype":"success","is_error":false,"result":"ignored","structured_output":{"app_key":"terminal","task_key":"other","summary":"s","is_meeting":false,"is_sensitive":false},"usage":{"input_tokens":2,"cache_creation_input_tokens":1434,"cache_read_input_tokens":10,"output_tokens":480,"output_tokens_details":{"thinking_tokens":216}},"modelUsage":{"claude-haiku-5-5":{"outputTokens":480}},"total_cost_usd":0.000527}
"""

private func output(_ stdout: String, stderr: String = "", status: Int32 = 0) -> CLIOutput {
    CLIOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), durationMs: 1200)
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-subscription-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func request(image: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0]), imageFile: URL? = nil) -> DescribeRequest {
    DescribeRequest(
        imageJPEG: image,
        imageFile: imageFile,
        systemInstruction: "You summarize one screenshot.",
        userPrompt: "Window title: SECRET-TITLE\nURL: https://secret.example/path",
        schema: [
            "type": "object",
            "properties": [
                "app_key": ["type": "string", "enum": ["terminal", "other"]],
                "summary": ["type": "string"],
                "project_key": ["type": "string", "enum": ["acme-private", "house"]],
            ],
            "required": ["app_key", "summary"],
        ]
    )
}

// MARK: - Claude

@Suite("ClaudeDescriber command")
struct ClaudeCommandTests {
    @Test("every call carries the isolation flags, and never --bare")
    func isolationFlags() {
        let r = request()
        let arguments = ClaudeDescriber.arguments(
            model: "sonnet", systemInstruction: r.systemInstruction, schema: r.schema
        )
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        #expect(arguments.first == "-p")
        #expect(value(after: "--tools") == "")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(value(after: "--setting-sources") == "")
        #expect(value(after: "--settings") == #"{"autoMemoryEnabled":false}"#)
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(value(after: "--input-format") == "stream-json")
        #expect(value(after: "--model") == "sonnet")
        #expect(value(after: "--effort") == "low")
        #expect(!arguments.contains("--bare"), "--bare turns the plan's sign-in off")
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("nothing about the screen, nor the project names, ever reaches the arguments")
    func nothingPrivateInArguments() {
        let r = request()
        let joined = ClaudeDescriber.arguments(
            model: "sonnet", systemInstruction: r.systemInstruction, schema: r.schema
        ).joined(separator: " ")
        #expect(!joined.contains("SECRET-TITLE"))
        #expect(!joined.contains("secret.example"))
        #expect(!joined.contains("acme-private"))
        #expect(joined.contains("project_key"))
    }

    @Test("stdin is one stream-json user message: the prompt, then the screenshot")
    func stdinShape() throws {
        let data = ClaudeDescriber.stdin(for: request())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text.filter { $0 == "\n" }.count == 1)
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(message["type"]?.stringValue == "user")
        let content = message["message"]?["content"]?.arrayValue ?? []
        #expect(content.count == 2)
        #expect(content[0]["type"]?.stringValue == "text")
        #expect(content[0]["text"]?.stringValue?.contains("SECRET-TITLE") == true)
        #expect(content[1]["type"]?.stringValue == "image")
        #expect(content[1]["source"]?["media_type"]?.stringValue == "image/jpeg")
        #expect(content[1]["source"]?["data"]?.stringValue == Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString())
    }

    @Test("a text-only frame sends no image block")
    func textOnly() throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: ClaudeDescriber.stdin(for: request(image: nil)))
        #expect(message["message"]?["content"]?.arrayValue?.count == 1)
    }
}

@Suite("ClaudeDescriber answers")
struct ClaudeParseTests {
    @Test("structured_output, usage and the answering model are read off the result event")
    func success() throws {
        let parsed = ClaudeDescriber.parse(output(claudeSuccess), requestedModel: "haiku")
        guard case let .answer(json, usage, model) = parsed.outcome else {
            Issue.record("expected an answer")
            return
        }
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(answer["app_key"]?.stringValue == "terminal")
        #expect(model == "claude-haiku-5-5")
        #expect(usage.promptTokens == 2 + 1434 + 10)
        #expect(usage.cachedTokens == 10)
        #expect(usage.thoughtTokens == 216)
        #expect(usage.outputTokens == 480 - 216)
        #expect(parsed.rateLimits?.windows["five_hour"]?.utilization == 0.14)
        #expect(parsed.rateLimits?.isRejected == false)
    }

    @Test("a signed-out command is signedOut, not a failure about the frame")
    func signedOut() {
        let events = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        let parsed = ClaudeDescriber.parse(output(events, status: 1), requestedModel: "sonnet")
        guard case let .failure(error) = parsed.outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? SubscriptionError == .signedOut(.claude))
    }

    @Test("a rejected plan window is the usage limit, with its reset time")
    func usageLimit() {
        let events = """
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1795805400,"status":"rejected"}}}}
        {"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit"}
        """
        let parsed = ClaudeDescriber.parse(output(events, status: 1), requestedModel: "sonnet")
        guard case let .failure(error) = parsed.outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? SubscriptionError == .usageLimit(.claude, resetsAt: Date(timeIntervalSince1970: 1_795_805_400)))
    }

    @Test("no result event at all is a plain failure with the exit status")
    func noResult() {
        let parsed = ClaudeDescriber.parse(output("", stderr: "something odd", status: 3), requestedModel: "sonnet")
        guard case let .failure(error) = parsed.outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? SubscriptionError == .failed(.claude, status: 3))
    }
}

@Suite("ClaudeDescriber calls")
struct ClaudeCallTests {
    @Test("checks the sign-in once, runs in the empty folder, and costs $0")
    func happyPath() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = FakeSubscriptionCLI { invocation in
            invocation.arguments.first == "auth" ? output(claudeSignedIn) : output(claudeSuccess)
        }
        let workspace = SubscriptionWorkspace(dataDir: dir)
        let describer = ClaudeDescriber(
            cli: cli, model: "sonnet", workspace: workspace,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
        let first = try await describer.describe(request())
        _ = try await describer.describe(request())
        #expect(first.costUSD == 0)
        #expect(first.provider == "claude")
        #expect(first.model == "claude-haiku-5-5")
        let calls = cli.invocations
        #expect(calls.filter { $0.arguments.first == "auth" }.count == 1, "the sign-in check is cached")
        #expect(calls.count == 3)
        let call = calls[1]
        #expect(call.workingDirectory == workspace.emptyDirectory)
        #expect(call.executable == "/fake/bin/claude")
        #expect(String(decoding: call.stdin, as: UTF8.self).contains("SECRET-TITLE"))
        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.emptyDirectory.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test("signed out: no summary call is made at all")
    func signedOutSkipsTheCall() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = FakeSubscriptionCLI { _ in output(#"{"loggedIn":false}"#, status: 1) }
        let describer = ClaudeDescriber(cli: cli, model: "sonnet", workspace: SubscriptionWorkspace(dataDir: dir))
        await #expect(throws: SubscriptionError.signedOut(.claude)) {
            try await describer.describe(request())
        }
        #expect(cli.invocations.count == 1)
    }

    @Test("an API-key sign-in is never used: it would bill someone per token")
    func apiKeyRefused() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = FakeSubscriptionCLI { _ in output(#"{"loggedIn":true,"authMethod":"api_key"}"#) }
        let describer = ClaudeDescriber(cli: cli, model: "sonnet", workspace: SubscriptionWorkspace(dataDir: dir))
        await #expect(throws: SubscriptionError.notSubscription(.claude)) {
            try await describer.describe(request())
        }
    }

    @Test("two timeouts in a row are timedOut")
    func timeouts() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = FakeSubscriptionCLI { invocation in
            if invocation.arguments.first == "auth" { return output(claudeSignedIn) }
            throw CLIRunError.timedOut
        }
        let describer = ClaudeDescriber(
            cli: cli, model: "sonnet", workspace: SubscriptionWorkspace(dataDir: dir),
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
        await #expect(throws: SubscriptionError.timedOut(.claude)) {
            try await describer.describe(request())
        }
        #expect(cli.invocations.count == 3)
    }

    @Test("not installed: nothing runs")
    func notInstalled() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = FakeSubscriptionCLI(installed: false) { _ in output("") }
        let describer = ClaudeDescriber(cli: cli, model: "sonnet", workspace: SubscriptionWorkspace(dataDir: dir))
        await #expect(throws: SubscriptionError.notInstalled(.claude)) {
            try await describer.describe(request())
        }
        #expect(cli.invocations.isEmpty)
    }
}

// MARK: - Codex

private let codexListing = """
{"models":[
 {"slug":"gpt-6-astra","visibility":"list","input_modalities":["text","image"]},
 {"slug":"gpt-6.1-sol","visibility":"list","input_modalities":["text","image"]},
 {"slug":"gpt-6-sol","visibility":"list","input_modalities":["text","image"]},
 {"slug":"gpt-6-luna","visibility":"list","input_modalities":["text","image"]},
 {"slug":"gpt-5.6-sol","visibility":"list","input_modalities":["text","image"]},
 {"slug":"gpt-5.6-terra","visibility":"list","input_modalities":["text","image"]},
 {"slug":"gpt-7-sol","visibility":"hide","input_modalities":["text","image"]},
 {"slug":"gpt-8-luna","visibility":"list","input_modalities":["text"]},
 {"slug":"gpt-5.5","visibility":"list","input_modalities":["text","image"]}
]}
"""

private let codexSuccess = """
{"type":"thread.started","thread_id":"x"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"thinking"}}
{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\\"app_key\\":\\"terminal\\",\\"summary\\":\\"s\\"}"}}
{"type":"turn.completed","usage":{"input_tokens":1500,"cached_input_tokens":300,"output_tokens":90}}
"""

@Suite("CodexDescriber command")
struct CodexCommandTests {
    @Test("every call is isolated, takes the prompt on stdin and the schema from a file")
    func isolationFlags() {
        let r = request()
        let empty = URL(fileURLWithPath: "/data/run/cli-empty")
        let arguments = CodexDescriber.arguments(
            model: "gpt-6.1-sol", systemInstruction: r.systemInstruction,
            imageFile: URL(fileURLWithPath: "/data/screenshots/a.jpg"),
            schemaFile: URL(fileURLWithPath: "/data/run/cli-tmp/s.json"),
            workingDirectory: empty
        )
        #expect(arguments.first == "exec")
        #expect(arguments.last == "-")
        for flag in ["--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] {
            #expect(arguments.contains(flag), "\(flag)")
        }
        #expect(arguments.contains("--image=/data/screenshots/a.jpg"))
        #expect(arguments.joined(separator: " ").contains("-s read-only"))
        #expect(arguments.joined(separator: " ").contains("-C /data/run/cli-empty"))
        #expect(arguments.joined(separator: " ").contains("-m gpt-6.1-sol"))
        #expect(arguments.contains(#"web_search="disabled""#))
        #expect(arguments.contains("project_doc_max_bytes=0"))
        #expect(arguments.contains("--output-schema"))
        for feature in ["shell_tool", "unified_exec", "view_image", "browser_use", "computer_use", "memories", "hooks", "plugins"] {
            let pairs = zip(arguments, arguments.dropFirst()).filter { $0.0 == "--disable" }.map(\.1)
            #expect(pairs.contains(feature), "\(feature)")
        }
        #expect(!arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        let joined = arguments.joined(separator: " ")
        #expect(!joined.contains("SECRET-TITLE"))
        #expect(!joined.contains("acme-private"))
    }

    @Test("no model resolved: no -m, the command picks")
    func noModel() {
        let arguments = CodexDescriber.arguments(
            model: nil, systemInstruction: "x", imageFile: URL(fileURLWithPath: "/a.jpg"),
            schemaFile: URL(fileURLWithPath: "/s.json"), workingDirectory: URL(fileURLWithPath: "/e")
        )
        #expect(!arguments.contains("-m"))
    }

    @Test("the schema is made strict: every property required, optional ones nullable")
    func strictSchema() {
        let strict = CodexDescriber.strictSchema(request().schema)
        let required = Set(strict["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required == ["app_key", "summary", "project_key"])
        #expect(strict["additionalProperties"] == .bool(false))
        #expect(strict["properties"]?["summary"]?["type"] == .string("string"))
        #expect(strict["properties"]?["project_key"]?["type"] == .array([.string("string"), .string("null")]))
        #expect(strict["properties"]?["project_key"]?["enum"]?.arrayValue?.contains(.null) == true)
    }
}

@Suite("CodexDescriber answers")
struct CodexParseTests {
    @Test("the agent message is the answer, turn.completed the usage")
    func success() throws {
        guard case let .answer(json, usage) = CodexDescriber.parse(output(codexSuccess)) else {
            Issue.record("expected an answer")
            return
        }
        #expect(json.contains("terminal"))
        #expect(usage.promptTokens == 1500)
        #expect(usage.cachedTokens == 300)
        #expect(usage.outputTokens == 90)
    }

    @Test("a 401 on the call is signed out, whatever `codex login status` said")
    func unauthorized() {
        let events = """
        {"type":"error","message":"Reconnecting... 1/5 (workspace routing discovery unauthorized (401))"}
        {"type":"turn.failed","error":{"message":"workspace routing discovery unauthorized (401)"}}
        """
        guard case let .failure(error) = CodexDescriber.parse(output(events, status: 1)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? SubscriptionError == .signedOut(.codex))
    }

    @Test("a revoked refresh token on stderr is signed out")
    func revokedToken() {
        let stderr = "ERROR codex_login::auth::manager: Failed to refresh token: your refresh token was revoked. Please log out and sign in again."
        guard case let .failure(error) = CodexDescriber.parse(output("", stderr: stderr, status: 1)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? SubscriptionError == .signedOut(.codex))
    }

    @Test("a usage limit is usageLimit")
    func usageLimit() {
        let events = #"{"type":"turn.failed","error":{"message":"You've hit your usage limit. Try again later."}}"#
        guard case let .failure(error) = CodexDescriber.parse(output(events, status: 1)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? SubscriptionError == .usageLimit(.codex, resetsAt: nil))
    }
}

@Suite("CodexDescriber calls")
struct CodexCallTests {
    @Test("points at the screenshot in place, writes the schema 0600, and deletes it afterwards")
    func happyPath() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screenshot = dir.appendingPathComponent("shot.jpg")
        try Data([0xFF, 0xD8]).write(to: screenshot)
        let schemaSeen = LockedBox<(path: String, mode: Int?, body: String)?>(nil)
        let cli = FakeSubscriptionCLI { invocation in
            switch invocation.arguments.first {
            case "login": return output("", stderr: "Logged in using ChatGPT")
            case "--version": return output("codex-cli 0.159.3\n")
            case "debug": return output(codexListing)
            default:
                if let index = invocation.arguments.firstIndex(of: "--output-schema") {
                    let path = invocation.arguments[index + 1]
                    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
                    let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                    schemaSeen.withLock { $0 = (path, mode, body) }
                }
                return output(codexSuccess)
            }
        }
        let describer = CodexDescriber(cli: cli, family: "sol", workspace: SubscriptionWorkspace(dataDir: dir))
        let response = try await describer.describe(request(imageFile: screenshot))
        #expect(response.model == "gpt-6.1-sol")
        #expect(response.provider == "codex")
        #expect(response.costUSD == 0)
        let call = try #require(cli.invocations.last)
        #expect(call.arguments.contains("--image=\(screenshot.path)"))
        #expect(String(decoding: call.stdin, as: UTF8.self).contains("SECRET-TITLE"))
        let seen = try #require(schemaSeen.withLock { $0 })
        #expect(seen.mode == 0o600)
        #expect(seen.body.contains("additionalProperties"))
        #expect(!FileManager.default.fileExists(atPath: seen.path), "the schema file is removed after the call")
    }

    @Test("a screenshot that is not on disk is written to cli-tmp for the call and removed")
    func temporaryImage() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = FakeSubscriptionCLI { invocation in
            switch invocation.arguments.first {
            case "login": return output("", stderr: "Logged in using ChatGPT")
            case "--version", "debug": return output("", status: 1)
            default: return output(codexSuccess)
            }
        }
        let workspace = SubscriptionWorkspace(dataDir: dir)
        let describer = CodexDescriber(cli: cli, family: "sol", workspace: workspace)
        _ = try await describer.describe(request())
        let call = try #require(cli.invocations.last)
        let image = try #require(call.arguments.first { $0.hasPrefix("--image=") })
        #expect(image.hasPrefix("--image=\(workspace.temporaryDirectory.path)"))
        #expect(!call.arguments.contains("-m"), "nothing resolved and nothing worked before: no -m")
        let left = try FileManager.default.contentsOfDirectory(atPath: workspace.temporaryDirectory.path)
        #expect(left.isEmpty)
    }
}

@Suite("CodexModelResolver")
struct CodexModelResolverTests {
    @Test("picks the newest listed, image-capable gpt-<version>-<family>")
    func resolve() {
        let listing = Data(codexListing.utf8)
        #expect(CodexModelResolver.resolve(family: "sol", listing: listing) == "gpt-6.1-sol")
        #expect(CodexModelResolver.resolve(family: "luna", listing: listing) == "gpt-6-luna")
        #expect(CodexModelResolver.resolve(family: "nova", listing: listing) == nil)
        #expect(CodexModelResolver.resolve(family: "sol", listing: Data("not json".utf8)) == nil)
    }

    @Test("versions compare as numbers, not as text")
    func numericVersions() {
        let listing = Data("""
        {"models":[
         {"slug":"gpt-9.9-sol","visibility":"list","input_modalities":["image"]},
         {"slug":"gpt-10-sol","visibility":"list","input_modalities":["image"]},
         {"slug":"gpt-10.0.1-sol","visibility":"list","input_modalities":["image"]}
        ]}
        """.utf8)
        #expect(CodexModelResolver.resolve(family: "sol", listing: listing) == "gpt-10.0.1-sol")
    }

    @Test("cached a day, re-resolved when the command's version changes, last working slug as fallback")
    func caching() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let version = LockedBox("codex-cli 0.159.3")
        let listingWorks = LockedBox(true)
        let cli = FakeSubscriptionCLI { invocation in
            switch invocation.arguments.first {
            case "--version": return output(version.withLock { $0 })
            case "debug": return listingWorks.withLock { $0 } ? output(codexListing) : output("", status: 1)
            default: return output("")
            }
        }
        let clock = LockedBox(Date(timeIntervalSince1970: 1_790_000_000))
        let cache = dir.appendingPathComponent("run/codex-models.json")
        let resolver = CodexModelResolver(
            cli: cli, cacheFile: cache, workingDirectory: dir, now: { clock.withLock { $0 } }
        )
        func listings() -> Int { cli.invocations.filter { $0.arguments.first == "debug" }.count }

        #expect(await resolver.model(family: "sol", executable: "/x") == "gpt-6.1-sol")
        #expect(await resolver.model(family: "sol", executable: "/x") == "gpt-6.1-sol")
        #expect(listings() == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        version.withLock { $0 = "codex-cli 0.160.0" }
        _ = await resolver.model(family: "sol", executable: "/x")
        #expect(listings() == 2)

        clock.withLock { $0 = $0.addingTimeInterval(CodexModelResolver.ttl + 1) }
        listingWorks.withLock { $0 = false }
        #expect(await resolver.model(family: "sol", executable: "/x") == nil, "nothing has answered yet")
        await resolver.recordWorking("gpt-6-sol", family: "sol")
        #expect(await resolver.model(family: "sol", executable: "/x") == "gpt-6-sol")
    }
}

// MARK: - Sign-in status

@Suite("Subscription sign-in status")
struct SubscriptionStatusTests {
    @Test("claude: only a claude.ai sign-in is a plan, and the e-mail is never kept")
    func claude() {
        let plan = SubscriptionStatus.parseClaude(output(claudeSignedIn), executable: "/c")
        #expect(plan.login == .subscription)
        #expect(plan.plan == "team")
        #expect(plan.loginExpiresAt == SubscriptionStatus.parseInstant("2026-12-17T03:54:44.907Z"))
        #expect(!"\(plan)".contains("example.com"))

        let key = SubscriptionStatus.parseClaude(output(#"{"loggedIn":true,"authMethod":"api_key"}"#), executable: "/c")
        #expect(key.login == .notSubscription(method: "api_key"))
        #expect(SubscriptionStatus.parseClaude(output(#"{"loggedIn":false}"#), executable: "/c").login == .signedOut)
        #expect(SubscriptionStatus.parseClaude(output("garbage"), executable: "/c").login == .signedOut)
    }

    @Test("claude: a sign-in past its expiry blocks calls")
    func expired() {
        let status = SubscriptionStatus.parseClaude(output(claudeSignedIn), executable: "/c")
        let after = status.loginExpiresAt!.addingTimeInterval(1)
        #expect(status.isUsable(now: after) == false)
        #expect(status.blockingError(now: after) == .signedOut(.claude))
        #expect(status.blockingError(now: after.addingTimeInterval(-86400)) == nil)
    }

    @Test("codex: only a ChatGPT sign-in is a plan")
    func codex() {
        #expect(SubscriptionStatus.parseCodex(output("", stderr: "Logged in using ChatGPT\n"), executable: "/x").login == .subscription)
        #expect(SubscriptionStatus.parseCodex(output("Logged in using an API key - sk-***"), executable: "/x").login == .notSubscription(method: "api_key"))
        #expect(SubscriptionStatus.parseCodex(output("", stderr: "Not logged in", status: 1), executable: "/x").login == .signedOut)
    }
}

// MARK: - Runner

@Suite("SubscriptionCLIRunner")
struct SubscriptionCLIRunnerTests {
    @Test("the child gets a short, fixed environment: no API keys, no base URLs, no config dirs")
    func environment() {
        let base = [
            "HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
            "ANTHROPIC_API_KEY": "sk-ant", "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "https://evil",
            "CLAUDE_CONFIG_DIR": "/elsewhere", "OPENAI_API_KEY": "sk-oa", "CODEX_HOME": "/c",
            "GEMINI_API_KEY": "g", "GITHUB_TOKEN": "gh",
        ]
        let environment = SubscriptionCLIRunner.environment(base: base, home: "/Users/x")
        for forbidden in SubscriptionCLIRunner.forbiddenEnvironment {
            #expect(environment[forbidden] == nil, "\(forbidden)")
        }
        #expect(environment["GEMINI_API_KEY"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
        #expect(Set(environment.keys).isSubset(of: ["HOME", "USER", "LOGNAME", "PATH", "LANG", "TMPDIR"]))
        #expect(environment["HOME"] == "/Users/x")
        #expect(environment["USER"] == "x", "claude reads its sign-in as USER; without it, Not logged in")
        #expect(environment["PATH"]?.hasPrefix("/Users/x/.local/bin") == true)
    }

    @Test("finds the command in the installers' folders before PATH")
    func locate() {
        let found = SubscriptionCLIRunner.locate(
            .claude, environment: ["PATH": "/usr/bin"], home: "/Users/x",
            isExecutable: { $0 == "/opt/homebrew/bin/claude" || $0 == "/usr/bin/claude" },
            listDirectory: { _ in [] }
        )
        #expect(found == "/opt/homebrew/bin/claude")
        let none = SubscriptionCLIRunner.locate(
            .codex, environment: [:], home: "/Users/x", isExecutable: { _ in false }, listDirectory: { _ in [] }
        )
        #expect(none == nil)
    }

    @Test("stdin reaches the process, the working directory is the one asked for")
    func realProcess() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SubscriptionCLIRunner(environment: ["HOME": dir.path, "PATH": "/usr/bin:/bin"], home: dir.path)
        let echoed = try await runner.run(CLIInvocation(
            executable: "/bin/cat", arguments: [], stdin: Data("hello\n".utf8), workingDirectory: dir, timeout: 10
        ))
        #expect(echoed.status == 0)
        #expect(echoed.stdoutText == "hello\n")
        let pwd = try await runner.run(CLIInvocation(executable: "/bin/pwd", arguments: ["-P"], workingDirectory: dir, timeout: 10))
        // `pwd -P` prints /private/var/…, Foundation's own spelling drops /private.
        #expect(pwd.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(dir.lastPathComponent))
        let env = try await runner.run(CLIInvocation(executable: "/usr/bin/env", arguments: [], workingDirectory: dir, timeout: 10))
        #expect(!env.stdoutText.contains("API_KEY"))
    }

    @Test("a command that outlives its timeout is killed")
    func timeout() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SubscriptionCLIRunner(environment: ["PATH": "/usr/bin:/bin"], home: dir.path)
        let started = Date()
        await #expect(throws: CLIRunError.timedOut) {
            _ = try await runner.run(CLIInvocation(
                executable: "/bin/sleep", arguments: ["30"], workingDirectory: dir, timeout: 0.5
            ))
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a missing executable is launchFailed")
    func missing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SubscriptionCLIRunner(environment: [:], home: dir.path)
        await #expect(throws: CLIRunError.self) {
            _ = try await runner.run(CLIInvocation(
                executable: dir.appendingPathComponent("nope").path, arguments: [], workingDirectory: dir
            ))
        }
    }
}

// MARK: - Chain

private func answer(_ model: String) -> DescribeResponse {
    DescribeResponse(json: "{}", usage: LLMUsage(), costUSD: 0, latencyMs: 1, model: model)
}

/// A link with a fixed provider name, answering from a list.
final class NamedStub: VisionDescriber, @unchecked Sendable {
    let provider: String
    private let lock = NSLock()
    private var replies: [Result<DescribeResponse, Error>]
    private(set) var calls = 0

    init(_ provider: String, _ replies: [Result<DescribeResponse, Error>]) {
        self.provider = provider
        self.replies = replies
    }

    var callCount: Int { lock.withLock { calls } }

    func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        let reply: Result<DescribeResponse, Error> = lock.withLock {
            calls += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        return try reply.get()
    }
}

@Suite("DescriberChain")
struct DescriberChainTests {
    @Test("falls through a signed-out Claude to Codex, and labels the answer with Codex")
    func fallsThrough() async throws {
        let claude = NamedStub("claude", [.failure(SubscriptionError.signedOut(.claude))])
        let codex = NamedStub("codex", [.success(answer("gpt-6.1-sol"))])
        let chain = DescriberChain([.init(claude, model: "sonnet"), .init(codex, model: "sol")])
        let response = try await chain.describe(request())
        #expect(response.provider == "codex")
        #expect(chain.provider == "claude")
    }

    @Test("a signed-out link is skipped for a quarter hour, then tried again")
    func skipMemory() async throws {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_790_000_000))
        let claude = NamedStub("claude", [.failure(SubscriptionError.signedOut(.claude))])
        let gemini = NamedStub("gemini", [.success(answer("gemini-3.5-flash-lite"))])
        let chain = DescriberChain(
            [.init(claude, model: "sonnet"), .init(gemini, model: "gemini-3.5-flash-lite")],
            now: { clock.withLock { $0 } }
        )
        _ = try await chain.describe(request())
        _ = try await chain.describe(request())
        #expect(claude.callCount == 1)
        clock.withLock { $0 = $0.addingTimeInterval(DescriberChain.skipFor + 1) }
        _ = try await chain.describe(request())
        #expect(claude.callCount == 2)
        #expect(gemini.callCount == 3)
    }

    @Test("a usage limit is skipped until the plan's reset time")
    func usageLimitReset() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = LockedBox(start)
        let reset = start.addingTimeInterval(3 * 3600)
        let claude = NamedStub("claude", [.failure(SubscriptionError.usageLimit(.claude, resetsAt: reset))])
        let codex = NamedStub("codex", [.success(answer("gpt-6.1-sol"))])
        let chain = DescriberChain(
            [.init(claude, model: "sonnet"), .init(codex, model: "sol")], now: { clock.withLock { $0 } }
        )
        _ = try await chain.describe(request())
        clock.withLock { $0 = start.addingTimeInterval(2 * 3600) }
        _ = try await chain.describe(request())
        #expect(claude.callCount == 1)
        clock.withLock { $0 = reset.addingTimeInterval(1) }
        _ = try await chain.describe(request())
        #expect(claude.callCount == 2)
    }

    @Test("everything fails: the first link's error, wrapped with its provider and model")
    func allFail() async throws {
        let claude = NamedStub("claude", [.failure(SubscriptionError.signedOut(.claude))])
        let codex = NamedStub("codex", [.failure(SubscriptionError.notInstalled(.codex))])
        let chain = DescriberChain([.init(claude, model: "sonnet"), .init(codex, model: "sol")])
        do {
            _ = try await chain.describe(request())
            Issue.record("expected a failure")
        } catch let failed as DescriberChain.Failed {
            #expect(failed.provider == "claude")
            #expect(failed.model == "sonnet")
            #expect(failed.underlying as? SubscriptionError == .signedOut(.claude))
            #expect(DescribeHealth.classify(failed, provider: "x").kind == .signedOut)
        }
    }

    @Test("a failure about the screenshot wins over an account failure, so the frame's attempts count")
    func frameFailureWins() async throws {
        let claude = NamedStub("claude", [.failure(SubscriptionError.signedOut(.claude))])
        let gemini = NamedStub("gemini", [.failure(LLMError.badRequest(400, "image too large"))])
        let chain = DescriberChain([.init(claude, model: "sonnet"), .init(gemini, model: "g")])
        do {
            _ = try await chain.describe(request())
            Issue.record("expected a failure")
        } catch let failed as DescriberChain.Failed {
            #expect(failed.provider == "gemini")
        }
    }
}

// MARK: - Configuration

@Suite("SUMMARY_PROVIDERS")
struct SummaryProvidersTests {
    let cwd = URL(fileURLWithPath: "/tmp")

    @Test("defaults: empty list, sonnet, sol")
    func defaults() throws {
        let config = try Config.load(layers: [[:]], cwd: cwd)
        #expect(config.summaryProviders.isEmpty)
        #expect(config.claudeSummaryModel == "sonnet")
        #expect(config.codexSummaryModel == "sol")
    }

    @Test("parses in order, drops repeats, refuses names it does not know")
    func parse() throws {
        let config = try Config.load(layers: [["SUMMARY_PROVIDERS": "Codex, claude,codex;gemini"]], cwd: cwd)
        #expect(config.summaryProviders == [.codex, .claude, .gemini])
        #expect(throws: ConfigError.self) {
            _ = try Config.load(layers: [["SUMMARY_PROVIDERS": "claude,openai"]], cwd: cwd)
        }
        #expect(throws: ConfigError.self) {
            _ = try Config.load(layers: [["CODEX_SUMMARY_MODEL": "astra"]], cwd: cwd)
        }
        #expect(throws: ConfigError.self) {
            _ = try Config.load(layers: [["CLAUDE_SUMMARY_MODEL": "opus"]], cwd: cwd)
        }
    }

    @Test("empty means Gemini alone when its key is set, and nothing otherwise")
    func effective() throws {
        var config = Config.defaults()
        #expect(SummaryProviders.effective(config).isEmpty)
        #expect(SummaryProviders.describer(config: config) == nil)
        config.geminiAPIKey = "k"
        #expect(SummaryProviders.effective(config) == [.gemini])
        #expect(SummaryProviders.describer(config: config) is GeminiClient, "a Gemini-only install is unchanged")
        config.summaryProviders = [.claude, .gemini]
        #expect(SummaryProviders.effective(config) == [.claude, .gemini])
        #expect(SummaryProviders.describer(config: config) is DescriberChain)
        config.geminiAPIKey = nil
        #expect(SummaryProviders.effective(config) == [.claude])
        #expect(SummaryProviders.describer(config: config) is DescriberChain, "a subscription alone still gets skip memory")
        #expect(SummaryProviders.describer(config: config, only: .gemini) == nil)
    }
}

@Suite("DescribeHealth for subscriptions")
struct SubscriptionHealthTests {
    @Test("account failures hold the queue without spending a frame's attempts")
    func classes() {
        let signedOut = DescribeHealth.classify(SubscriptionError.signedOut(.claude), provider: "claude")
        #expect(signedOut.isRefusal)
        #expect(signedOut.kind == .signedOut)
        #expect(signedOut.reason == "Claude Code is not signed in")
        let limit = DescribeHealth.classify(SubscriptionError.usageLimit(.codex, resetsAt: nil), provider: "codex")
        #expect(limit.isRefusal)
        #expect(limit.reason.contains("ChatGPT"))
        #expect(DescribeHealth.classify(SubscriptionError.notInstalled(.codex), provider: "codex").kind == .notInstalled)
        let timedOut = DescribeHealth.classify(SubscriptionError.timedOut(.claude), provider: "claude")
        #expect(timedOut.isUnreachable)
        #expect(timedOut.kind == .timedOut)
        let failed = DescribeHealth.classify(SubscriptionError.failed(.claude, status: 2), provider: "claude")
        #expect(!failed.isRefusal && !failed.isUnreachable)
    }
}
