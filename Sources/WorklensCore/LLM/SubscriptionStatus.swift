import Foundation

/// Why a subscription command could not summarize. Each case names a class of failure, never
/// the command's own words, which can quote the prompt back.
public enum SubscriptionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The command is not on this Mac.
    case notInstalled(SubscriptionTool)
    /// The command runs but is not signed in, or its sign-in ran out.
    case signedOut(SubscriptionTool)
    /// Signed in, but with an API key rather than a plan. Worklens does not use that sign-in: a
    /// call through it would be billed per token to whoever owns the key.
    case notSubscription(SubscriptionTool)
    /// The plan's usage limit is reached. `resetsAt` when the command said when it lifts.
    case usageLimit(SubscriptionTool, resetsAt: Date?)
    /// No answer twice in a row within the timeout.
    case timedOut(SubscriptionTool)
    /// The command could not reach its service.
    case unreachable(SubscriptionTool)
    /// Anything else: the command stopped with this exit status.
    case failed(SubscriptionTool, status: Int32)

    public var tool: SubscriptionTool {
        switch self {
        case let .notInstalled(tool), let .signedOut(tool), let .notSubscription(tool),
             let .usageLimit(tool, _), let .timedOut(tool), let .unreachable(tool),
             let .failed(tool, _):
            return tool
        }
    }

    public var description: String {
        let name = tool.rawValue
        switch self {
        case .notInstalled: return "\(name) is not installed"
        case .signedOut: return "\(name) is not signed in"
        case .notSubscription: return "\(name) is signed in with an API key, not a plan"
        case let .usageLimit(_, resetsAt):
            guard let resetsAt else { return "\(name) reached its plan's usage limit" }
            return "\(name) reached its plan's usage limit until \(ISO8601DateFormatter().string(from: resetsAt))"
        case .timedOut: return "\(name) did not answer in time, twice"
        case .unreachable: return "\(name) could not reach its service"
        case let .failed(_, status): return "\(name) stopped with exit status \(status)"
        }
    }
}

/// What `claude auth status` or `codex login status` said, plus whether the command is there.
///
/// Worklens never reads either command's credentials, keychain item or config file: it asks the
/// command, the same way the person would in Terminal.
public struct SubscriptionStatus: Sendable, Equatable {
    public enum Login: Sendable, Equatable {
        case notInstalled
        case signedOut
        /// Signed in some other way than a plan (an API key, a cloud console). Named by the
        /// method the command reported, which is a fixed word like `api_key`, never the key.
        case notSubscription(method: String)
        case subscription
    }

    public var tool: SubscriptionTool
    public var executable: String?
    public var login: Login
    /// The plan's name as the command spells it (`pro`, `max`, `team`), when it says.
    public var plan: String?
    /// When the sign-in runs out. Only `claude` reports one.
    public var loginExpiresAt: Date?

    public init(
        tool: SubscriptionTool, executable: String?, login: Login,
        plan: String? = nil, loginExpiresAt: Date? = nil
    ) {
        self.tool = tool
        self.executable = executable
        self.login = login
        self.plan = plan
        self.loginExpiresAt = loginExpiresAt
    }

    /// Whether a summary call may go through this command now.
    public func isUsable(now: Date = Date()) -> Bool {
        guard login == .subscription else { return false }
        if let loginExpiresAt, loginExpiresAt <= now { return false }
        return true
    }

    /// The error a call would get, or nil when it may go ahead.
    public func blockingError(now: Date = Date()) -> SubscriptionError? {
        switch login {
        case .notInstalled: return .notInstalled(tool)
        case .signedOut: return .signedOut(tool)
        case .notSubscription: return .notSubscription(tool)
        case .subscription:
            if let loginExpiresAt, loginExpiresAt <= now { return .signedOut(tool) }
            return nil
        }
    }

    // MARK: - Parsing

    /// `claude auth status --json`, verified on `claude` 2.1.326 (2026-11-27):
    /// `{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team",
    ///   "loginExpiresAt":"2026-12-17T03:54:44.907Z", …}`. Only `authMethod == "claude.ai"` is a
    /// plan; the e-mail, org and directories it also prints are never read.
    public static func parseClaude(_ output: CLIOutput, executable: String) -> SubscriptionStatus {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: output.stdout).objectValue else {
            return SubscriptionStatus(tool: .claude, executable: executable, login: .signedOut)
        }
        guard object["loggedIn"]?.boolValue == true else {
            return SubscriptionStatus(tool: .claude, executable: executable, login: .signedOut)
        }
        let method = object["authMethod"]?.stringValue ?? "unknown"
        guard method == "claude.ai" else {
            return SubscriptionStatus(
                tool: .claude, executable: executable, login: .notSubscription(method: method)
            )
        }
        return SubscriptionStatus(
            tool: .claude,
            executable: executable,
            login: .subscription,
            plan: object["subscriptionType"]?.stringValue?.nonEmpty,
            loginExpiresAt: object["loginExpiresAt"]?.stringValue.flatMap(parseInstant)
        )
    }

    /// `codex login status`, verified on `codex-cli` 0.159.3 (2026-11-27): one line on stderr,
    /// `Logged in using ChatGPT`. Only that wording is a plan; `Logged in using an API key` is
    /// not. It reports no plan name and no expiry.
    public static func parseCodex(_ output: CLIOutput, executable: String) -> SubscriptionStatus {
        let text = (output.stdoutText + "\n" + output.stderrText).lowercased()
        if text.contains("logged in using chatgpt") {
            return SubscriptionStatus(tool: .codex, executable: executable, login: .subscription)
        }
        if text.contains("logged in using") {
            let method = text.contains("api key") ? "api_key" : "other"
            return SubscriptionStatus(
                tool: .codex, executable: executable, login: .notSubscription(method: method)
            )
        }
        return SubscriptionStatus(tool: .codex, executable: executable, login: .signedOut)
    }

    static func parseInstant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Asks a command whether it is signed in. Used before summary calls (cached), by Settings and
/// by `worklens summaries check`.
public struct SubscriptionStatusChecker: Sendable {
    public static let timeout: TimeInterval = 20

    private let cli: any SubscriptionCLI
    private let workingDirectory: URL

    public init(cli: any SubscriptionCLI, workingDirectory: URL) {
        self.cli = cli
        self.workingDirectory = workingDirectory
    }

    public func status(_ tool: SubscriptionTool) async -> SubscriptionStatus {
        guard let executable = cli.locate(tool) else {
            return SubscriptionStatus(tool: tool, executable: nil, login: .notInstalled)
        }
        let arguments: [String] = switch tool {
        case .claude: ["auth", "status", "--json"]
        case .codex: ["login", "status"]
        }
        let output: CLIOutput
        do {
            output = try await cli.run(CLIInvocation(
                executable: executable, arguments: arguments,
                workingDirectory: workingDirectory, timeout: Self.timeout
            ))
        } catch {
            return SubscriptionStatus(tool: tool, executable: executable, login: .signedOut)
        }
        switch tool {
        case .claude: return SubscriptionStatus.parseClaude(output, executable: executable)
        case .codex: return SubscriptionStatus.parseCodex(output, executable: executable)
        }
    }
}

/// The folders a subscription call runs in, under `DATA_DIR/run`.
///
/// `cli-empty` is the working directory, mode 0700 and kept empty, so no project `CLAUDE.md` or
/// `AGENTS.md` is ever loaded. `cli-tmp` holds the short-lived 0600 files `codex exec` needs as
/// paths (the schema, an image that was not already on disk), and is never the working directory.
public struct SubscriptionWorkspace: Sendable {
    public let emptyDirectory: URL
    public let temporaryDirectory: URL

    public init(dataDir: URL) {
        let run = dataDir.appendingPathComponent("run")
        emptyDirectory = run.appendingPathComponent("cli-empty")
        temporaryDirectory = run.appendingPathComponent("cli-tmp")
    }

    /// Creates both folders 0700 and clears anything that found its way into the empty one.
    public func prepare() throws {
        let manager = FileManager.default
        try FilePermissions.createPrivateDirectory(at: emptyDirectory.deletingLastPathComponent())
        try FilePermissions.createPrivateDirectory(at: emptyDirectory)
        try FilePermissions.createPrivateDirectory(at: temporaryDirectory)
        for leftover in (try? manager.contentsOfDirectory(atPath: emptyDirectory.path)) ?? [] {
            try? manager.removeItem(at: emptyDirectory.appendingPathComponent(leftover))
        }
    }

    /// A new 0600 file holding `data`, for the caller to delete when the call is over.
    public func writeTemporary(_ data: Data, suffix: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(suffix)")
        try FilePermissions.writePrivate(data, to: url)
        return url
    }
}
