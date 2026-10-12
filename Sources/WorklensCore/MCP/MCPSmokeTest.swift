import Foundation

/// The `initialize` → `tools/list` round trip Worklens runs against itself after writing a
/// client's configuration (#140).
///
/// The point is not that the protocol works — `MCPServerTests` already says so — but *which
/// directory the launched server will read*. Claude Desktop starts the binary with a minimal
/// environment and no working directory, so `Config` sees only the App Support layers, while the
/// app itself usually runs with `WORKLENS_ENV_FILE` set by `scripts/update.sh`. Resolving
/// configuration the client's way and reporting that `DATA_DIR` is the difference between "8
/// tools ready" and a server that cheerfully answers from an empty database.
public enum MCPSmokeTest {
    /// What the card and the CLI print.
    public struct Result: Sendable, Equatable {
        public let toolCount: Int
        /// How many conversation starters the client's "+" menu will show (#241).
        public let promptCount: Int
        /// The directory the *client's* process will read.
        public let dataDir: URL
        /// The directory this app reads, when the caller knows it. Nil from a context that has
        /// no app configuration of its own.
        public let appDataDir: URL?

        public init(toolCount: Int, promptCount: Int = 0, dataDir: URL, appDataDir: URL?) {
            self.toolCount = toolCount
            self.promptCount = promptCount
            self.dataDir = dataDir
            self.appDataDir = appDataDir
        }

        /// False when the client would read somewhere else — the loudest silent failure this
        /// whole feature exists to prevent.
        public var matchesApp: Bool {
            guard let appDataDir else { return true }
            return appDataDir.standardizedFileURL.resolvingSymlinksInPath()
                == dataDir.standardizedFileURL.resolvingSymlinksInPath()
        }

        /// `9 tools and 4 prompts ready, reading /Users/…/data`.
        public var summary: String {
            let tools = "\(toolCount) tool\(toolCount == 1 ? "" : "s")"
            let prompts = promptCount > 0
                ? " and \(promptCount) prompt\(promptCount == 1 ? "" : "s")" : ""
            return "\(tools)\(prompts) ready, reading \(dataDir.path)"
        }

        /// The sentence to show when the two directories disagree.
        public var mismatchNote: String? {
            guard let appDataDir, !matchesApp else { return nil }
            return "Claude Desktop would read \(dataDir.path), but this app is using "
                + "\(appDataDir.path). Install it again from here so the entry pins the same "
                + "configuration, or run `make install-env` once from your checkout."
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The directory the client would read is not there. Reported rather than created: a
        /// smoke test that makes an empty data tree answers its own question wrongly.
        case noDataDir(URL)
        case protocolFailure(String)

        public var description: String {
            switch self {
            case .noDataDir(let url):
                return "the launched server would read \(url.path), which does not exist"
            case .protocolFailure(let why):
                return why
            }
        }
    }

    /// Configuration resolved the way the client will resolve it: no inherited process
    /// environment and a working directory of `/`, so `<cwd>/.env` cannot contribute.
    public static func clientConfig(
        envFile: URL?,
        appSupportEnv: URL = Config.appSupportEnvURL(),
        settingsFile: URL = SettingsStore.defaultURL
    ) throws -> Config {
        var environment: [String: String] = [:]
        if let envFile { environment["WORKLENS_ENV_FILE"] = envFile.path }
        return try Config.load(
            environment: environment,
            cwd: URL(fileURLWithPath: "/", isDirectory: true),
            appSupportEnv: appSupportEnv,
            settingsFile: settingsFile
        )
    }

    /// Builds the registry that configuration implies and drives a real `initialize` +
    /// `tools/list` through `MCPServer`, in process. The tool count comes from the response, not
    /// from the registry, so this fails the way the client would.
    public static func run(config: Config, appDataDir: URL? = nil) throws -> Result {
        guard FileManager.default.fileExists(atPath: config.dataDir.path) else {
            throw Failure.noDataDir(config.dataDir)
        }
        // Read-only on purpose. This runs inside the app, against the directory the app itself
        // has open, and `Database(dataDir:)` reads a busy file as a corrupt one: a smoke test
        // that lands during the weekly VACUUM would move somebody's history aside and start an
        // empty database. Listing tools needs no writer (#140).
        let db = try Database.readOnly(dataDir: config.dataDir)
        let taxonomy = try TaxonomyStore(dataDir: config.dataDir)
        let registry = WorklensMCPTools.registry(config: config, db: db, taxonomy: taxonomy)
        let server = MCPServer(registry: registry, dataDir: config.dataDir)

        let initialize = try result(
            of: server,
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        )
        guard (initialize["protocolVersion"] as? String) != nil else {
            throw Failure.protocolFailure("the server answered initialize without a protocol version")
        }
        let list = try result(of: server, line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard let tools = list["tools"] as? [Any], !tools.isEmpty else {
            throw Failure.protocolFailure("the server listed no tools")
        }
        // The same round trip for the "+" menu's side of it (#241): a client that sees no prompts
        // shows the user nothing to click, which is the failure this line makes visible.
        let prompts = try result(of: server, line: #"{"jsonrpc":"2.0","id":3,"method":"prompts/list"}"#)
        let promptCount = (prompts["prompts"] as? [Any])?.count ?? 0
        return Result(
            toolCount: tools.count, promptCount: promptCount, dataDir: config.dataDir,
            appDataDir: appDataDir
        )
    }

    private static func result(of server: MCPServer, line: String) throws -> [String: Any] {
        guard let response = server.handle(line: line) else {
            throw Failure.protocolFailure("the server answered nothing")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        else {
            throw Failure.protocolFailure("the server answered something that is not JSON")
        }
        if let error = object["error"] as? [String: Any] {
            throw Failure.protocolFailure("\(error["message"] as? String ?? "the server returned an error")")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw Failure.protocolFailure("the server answered without a result")
        }
        return result
    }
}
