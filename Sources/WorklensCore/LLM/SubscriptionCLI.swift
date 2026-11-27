import Foundation

/// The two commands Worklens can summarize through with a person's own plan instead of an API key.
public enum SubscriptionTool: String, Sendable, CaseIterable, Codable {
    /// Claude Code, signed in with a Claude plan.
    case claude
    /// Codex CLI, signed in with a ChatGPT plan.
    case codex

    public var binaryName: String { rawValue }

    /// The command the person runs to sign in. Worklens shows it and never runs it.
    public var loginCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        }
    }
}

/// One run of a subscription command: what to start, what to feed it, where, and for how long.
///
/// The prompt and the images travel in `stdin`, never in `arguments`: any program on the Mac can
/// list another process's arguments, and the prompt carries window titles and URLs.
public struct CLIInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var stdin: Data
    public var workingDirectory: URL
    public var timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String],
        stdin: Data = Data(),
        workingDirectory: URL,
        timeout: TimeInterval = SubscriptionCLIRunner.defaultTimeout
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

/// What one run printed. Neither stream is ever logged at `info` or above: a CLI can echo the
/// prompt back, and the prompt names windows and pages.
public struct CLIOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var durationMs: Int

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data(), durationMs: Int = 0) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Why a run produced no output at all.
public enum CLIRunError: Error, Equatable, Sendable {
    /// The executable could not be started.
    case launchFailed(String)
    /// The run went past its timeout and its process group was killed.
    case timedOut
}

/// Something that finds and runs `claude` or `codex`. The real one is `SubscriptionCLIRunner`;
/// tests hand the summarizers a fake that answers from fixtures.
public protocol SubscriptionCLI: Sendable {
    /// The first executable for `tool`, or nil when it is not on this Mac.
    func locate(_ tool: SubscriptionTool) -> String?
    func run(_ invocation: CLIInvocation) async throws -> CLIOutput
}

/// Runs a subscription command the way `GHRunner` runs `gh`, with three differences that matter:
///
/// - **A small, explicit environment.** Only `HOME`, `USER`, `LOGNAME`, `PATH`, `LANG` and
///   `TMPDIR` are passed (`USER` and `LOGNAME` because `claude` finds its keychain login through
///   them: without them it answers "Not logged in", checked 2026-11-27). `ANTHROPIC_API_KEY`,
///   `OPENAI_API_KEY` and their kind are never copied from the app's environment, so a stray key
///   cannot quietly turn a subscription call into a billed API call.
/// - **Its own process group**, killed whole on timeout or cancellation, so nothing the command
///   started outlives the call.
/// - **Stdin for the prompt.** It is written on its own thread while both output streams drain on
///   theirs, so a megabyte of base64 images never deadlocks against a full stdout pipe.
public struct SubscriptionCLIRunner: SubscriptionCLI {
    public static let defaultTimeout: TimeInterval = 180

    /// Variables that would turn a subscription call into an API-key call or point the CLI at
    /// another account. Named so a test can assert none of them survive `environment(base:home:)`.
    public static let forbiddenEnvironment: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_HOME", "CODEX_API_KEY",
    ]

    private let baseEnvironment: [String: String]
    private let home: String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) {
        self.baseEnvironment = environment
        self.home = home
    }

    // MARK: - Finding the binary

    /// Where the installers put these commands, in the order they are tried: Claude Code's own
    /// installer (`~/.local/bin`), Homebrew, `/usr/local/bin`, then the app's `PATH`, then npm's
    /// global folder and the newest nvm Node. A GUI app's `PATH` is nearly empty, so the fixed
    /// folders come first.
    public static func searchDirectories(
        environment: [String: String],
        home: String,
        listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> [String] {
        var directories = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories.append("\(home)/.npm-global/bin")
        let nvm = "\(home)/.nvm/versions/node"
        if let newest = listDirectory(nvm).filter({ $0.hasPrefix("v") }).max(by: { lhs, rhs in
            NumericVersion(lhs) < NumericVersion(rhs)
        }) {
            directories.append("\(nvm)/\(newest)/bin")
        }
        var seen: Set<String> = []
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func locate(
        _ tool: SubscriptionTool,
        environment: [String: String],
        home: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> String? {
        searchDirectories(environment: environment, home: home, listDirectory: listDirectory)
            .map { "\($0)/\(tool.binaryName)" }
            .first(where: isExecutable)
    }

    public func locate(_ tool: SubscriptionTool) -> String? {
        Self.locate(tool, environment: baseEnvironment, home: home)
    }

    /// The whole environment the child gets. Built from nothing, not filtered from the app's:
    /// a variable this list does not name cannot reach the command.
    public static func environment(base: [String: String], home: String) -> [String: String] {
        let user = base["USER"] ?? base["LOGNAME"] ?? NSUserName()
        var path = searchDirectories(environment: base, home: home)
        for system in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(system) {
            path.append(system)
        }
        return [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": path.joined(separator: ":"),
            "LANG": base["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": base["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
    }

    // MARK: - Running

    public func run(_ invocation: CLIInvocation) async throws -> CLIOutput {
        let environment = Self.environment(base: baseEnvironment, home: home)
        let handle = SpawnedProcess.Handle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try SpawnedProcess.run(invocation, environment: environment, handle: handle)
                    })
                }
            }
        } onCancel: {
            handle.kill()
        }
    }
}

// MARK: - posix_spawn

/// `Process` cannot put the child in a process group of its own, and a summarizer that leaves a
/// half-finished `claude` behind after Quit is worse than one that never ran. So the child is
/// spawned directly: its own group, only the three standard descriptors, the working directory
/// set before `exec`.
enum SpawnedProcess {
    /// The pid, once there is one, and whether it was killed — shared between the run and
    /// whoever cancels or times it out.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var killed = false
        private var finished = false
        private var reason: KillReason?

        enum KillReason { case cancelled, timedOut }

        func started(_ pid: pid_t) -> Bool {
            lock.withLock {
                self.pid = pid
                return !killed
            }
        }

        /// The command exited by itself; a timeout or cancellation arriving now is too late to
        /// be its reason.
        func finish() {
            lock.withLock { finished = true }
        }

        func kill(_ why: KillReason = .cancelled) {
            let target: pid_t = lock.withLock {
                if finished { return 0 }
                if reason == nil { reason = why }
                killed = true
                return pid
            }
            guard target > 0 else { return }
            // The whole group: anything the command started goes with it.
            Darwin.killpg(target, SIGKILL)
        }

        var killReason: KillReason? { lock.withLock { reason } }
    }

    static func run(_ invocation: CLIInvocation, environment: [String: String], handle: Handle) throws -> CLIOutput {
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw CLIRunError.launchFailed("pipe: errno \(errno)")
        }
        // A command that exits before reading its prompt must not take Worklens down with it.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, invocation.workingDirectory.path)

        let argv = [invocation.executable] + invocation.arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let started = Date()
        var pid: pid_t = 0
        let spawned = withCStringArray(argv) { cArgs in
            withCStringArray(envp) { cEnv in
                posix_spawn(&pid, invocation.executable, &actions, &attributes, cArgs, cEnv)
            }
        }
        // The child has its copies; ours of the far ends must close or EOF never comes.
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        guard spawned == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            close(errPipe[0])
            throw CLIRunError.launchFailed("posix_spawn: \(String(cString: strerror(spawned)))")
        }
        if !handle.started(pid) {
            // Cancelled between the request and the spawn.
            Darwin.killpg(pid, SIGKILL)
        }

        let watchdog = DispatchWorkItem { handle.kill(.timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + invocation.timeout, execute: watchdog)

        let group = DispatchGroup()
        let stdout = DataBox()
        let stderr = DataBox()
        group.enter()
        DispatchQueue.global().async {
            writeAll(invocation.stdin, to: inPipe[1])
            close(inPipe[1])
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stdout.set(readAll(outPipe[0]))
            close(outPipe[0])
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderr.set(readAll(errPipe[0]))
            close(errPipe[0])
            group.leave()
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        handle.finish()
        watchdog.cancel()
        // The command is gone; anything it left in the group goes too, so the pipes reach EOF.
        Darwin.killpg(pid, SIGKILL)
        group.wait()

        switch handle.killReason {
        case .timedOut: throw CLIRunError.timedOut
        case .cancelled: throw CancellationError()
        case nil: break
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CLIOutput(
            status: exitCode,
            stdout: stdout.value,
            stderr: stderr.value,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return // EPIPE: the command stopped reading, and its exit status will say why.
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }

    private static func withCStringArray<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.withLock { data = new } }
    var value: Data { lock.withLock { data } }
}

// MARK: - Versions

/// `6.1` > `6` > `5.6`, `v22.10.0` > `v22.9.1`: dotted numbers compared as numbers, a missing part
/// counting as zero. Anything that is not a digit separates parts and is otherwise ignored.
public struct NumericVersion: Comparable, Sendable, Equatable {
    public let parts: [Int]

    public init(_ text: String) {
        parts = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    public static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
