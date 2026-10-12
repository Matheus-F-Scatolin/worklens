import Foundation

/// What one `gh` run printed.
public struct GHOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Why a `gh` run gave no answer. Each reads as the sentence the status line shows; none names
/// a repo, a title or an account.
public enum GHError: Error, Equatable, CustomStringConvertible {
    case missing
    case loggedOut
    case rateLimited
    case timedOut
    case failed(status: Int32)
    case unreadable

    public var description: String {
        switch self {
        case .missing: "gh is not installed. Install the GitHub CLI and run `gh auth login` in Terminal."
        case .loggedOut: "gh is not logged in. Run `gh auth login` in Terminal."
        case .rateLimited: "GitHub's rate limit was reached. Worklens tries again later."
        case .timedOut: "gh did not answer within 30 seconds."
        case let .failed(status): "gh stopped with exit status \(status)."
        case .unreadable: "gh answered with something Worklens could not read."
        }
    }

    /// The error a finished run stands for, or nil when it succeeded. Exit status 4 is `gh`'s own
    /// "authentication required".
    public static func classify(_ output: GHOutput) -> GHError? {
        guard output.status != 0 else { return nil }
        let text = output.stderr.lowercased()
        if text.contains("rate limit") { return .rateLimited }
        if output.status == 4 || text.contains("gh auth login") || text.contains("not logged in") {
            return .loggedOut
        }
        return .failed(status: output.status)
    }
}

/// Something that runs `gh`. The real one is `GHRunner`; tests hand `OutputSync` a fake.
public protocol GHRunning: Sendable {
    func run(_ arguments: [String]) async throws -> GHOutput
}

/// Runs the GitHub CLI the way `AutoUpdater` runs `git`: a found binary, no prompt, a watchdog.
///
/// `gh` keeps its own login; Worklens never reads the token, never passes one, and never sees
/// more than the JSON a command prints.
public struct GHRunner: GHRunning {
    public static let timeout: TimeInterval = 30
    /// Where Homebrew puts it, before anything on `PATH`: a GUI app's `PATH` is minimal.
    static let knownPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    public init() {}

    /// The first executable `gh`, or nil.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return (knownPaths + onPath).first(where: isExecutable)
    }

    public func run(_ arguments: [String]) async throws -> GHOutput {
        guard let executable = Self.locate() else { throw GHError.missing }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try Self.runBlocking(executable, arguments) })
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String]) throws -> GHOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { "\($0):" } ?? "")
            + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // No prompt can be answered from here, and no pager or colour belongs in a pipe.
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GHError.missing
        }

        let timedOut = TimedOutFlag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // A search can print far more than a pipe buffer, so stderr drains on its own queue
        // while stdout is read here; reading one to EOF first could deadlock on the other.
        let errData = ErrBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut.value { throw GHError.timedOut }
        return GHOutput(
            status: process.terminationStatus,
            stdout: data,
            stderr: String(decoding: errData.value, as: UTF8.self)
        )
    }
}

private final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

private final class ErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.withLock { data = new } }
    var value: Data { lock.withLock { data } }
}
