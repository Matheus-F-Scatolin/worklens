import Foundation

/// The `mcpServers` entry an MCP client holds for Worklens, read back so the app can say why the
/// server never appeared (#118).
///
/// The setup step in docs/user/claude-desktop.md is four lines of JSON with three ways to get it
/// wrong, and every one of them is silent — the client launches the command, it fails, and
/// nothing surfaces. So the
/// checks here are the three: the command has to exist and be executable, the arguments have to
/// be exactly `["mcp"]`, and — because the client launches the binary with a minimal
/// environment, no shell and no working directory — `~/Library/Application Support/Worklens/.env`
/// has to exist, since it is the only configuration layer that process will ever find.
public struct MCPClientConfig: Sendable, Equatable {
    /// An MCP client on this Mac whose configuration Worklens can write (#248).
    ///
    /// There is one writer for all of them, not one each: `install` and `remove` take a URL, the
    /// rules about the backup, the merge and a file that does not parse are the same rules, and
    /// this enum is the only thing that differs — which file, and what the row is called. Codex's
    /// file is TOML, which the URL's extension routes to `MCPTOML`; adding it therefore cannot
    /// change what a Claude Desktop connect writes.
    public enum Client: String, Sendable, Equatable, CaseIterable, Codable, Identifiable {
        /// The desktop app's own file, in App Support.
        case claudeDesktop
        /// Claude Code's user-level file, `~/.claude.json`, whose top-level `mcpServers` is the
        /// same shape Claude Desktop's file uses.
        case claudeCode
        /// Codex's `~/.codex/config.toml`, which its CLI, its IDE extension and the ChatGPT app
        /// all read. Servers there are `[mcp_servers.<name>]` tables (checked 2026-09-24).
        case codex

        public var id: String { rawValue }

        /// The row's heading. A product name, so it is the same in every language.
        public var title: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        public func configURL(
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            switch self {
            case .claudeDesktop:
                return home.appendingPathComponent(
                    "Library/Application Support/Claude/claude_desktop_config.json")
            case .claudeCode:
                return home.appendingPathComponent(".claude.json")
            case .codex:
                return home.appendingPathComponent(".codex/config.toml")
            }
        }

        /// The bundle identifier to look this client up by, or nil for a client that is not an
        /// application — Claude Code is a command, so its presence is a file on disk instead.
        public var bundleID: String? {
            switch self {
            case .claudeDesktop: return MCPClientConfig.claudeDesktopBundleID
            case .claudeCode, .codex: return nil
            }
        }

        /// Paths that say this client is on the Mac when it is not an application. Empty for one
        /// that is.
        public func presencePaths(
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> [URL] {
            switch self {
            case .claudeDesktop:
                return []
            case .claudeCode:
                return [
                    configURL(home: home),
                    home.appendingPathComponent(".claude"),
                    home.appendingPathComponent(".local/bin/claude"),
                    URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                    URL(fileURLWithPath: "/usr/local/bin/claude"),
                ]
            case .codex:
                // The command, the app, or the directory any of them leaves behind.
                return [
                    configURL(home: home),
                    home.appendingPathComponent(".codex"),
                    home.appendingPathComponent(".local/bin/codex"),
                    URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                    URL(fileURLWithPath: "/usr/local/bin/codex"),
                    URL(fileURLWithPath: "/Applications/Codex.app"),
                ]
            }
        }

        /// Where to get it, for a client this Mac does not have. Nil for one with no single page
        /// to send somebody to.
        public var downloadURL: URL? {
            switch self {
            case .claudeDesktop: return URL(string: "https://claude.ai/download")
            case .claudeCode: return nil
            case .codex: return URL(string: "https://openai.com/codex/")
            }
        }
    }

    /// What the file said about Worklens.
    public enum Entry: Sendable, Equatable {
        /// No file at that path. Not an error: most people do not use an MCP client.
        case noFile
        /// There is a file but it could not be read or parsed — which is worth telling apart
        /// from "missing", because editing it by hand is how it got there.
        case unreadable(String)
        /// The file parsed and has no `worklens` server in it.
        case notConfigured
        /// A `worklens` entry, exactly as written. `env` is the launch environment the entry
        /// pins, which is the difference between a server that finds this `DATA_DIR` and one
        /// that reads an empty database (#140).
        case configured(command: String, args: [String], env: [String: String])
    }

    /// Parses the file's bytes. Pure: the caller does the reading, so a test needs no home
    /// directory and the live path needs no special case.
    public static func parse(_ data: Data) -> Entry {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("not valid JSON")
        }
        guard let servers = object["mcpServers"] as? [String: Any] else {
            return .notConfigured
        }
        // docs/user/claude-desktop.md names the server `worklens`; anything else is the user's
        // own name for it, so fall back to whichever entry launches a binary called Worklens.
        let named = servers["worklens"] as? [String: Any]
        let byCommand = servers.values.compactMap { $0 as? [String: Any] }.first {
            ($0["command"] as? String)?.hasSuffix("/Worklens") == true
        }
        guard let entry = named ?? byCommand else { return .notConfigured }
        guard let command = entry["command"] as? String else {
            return .unreadable("the worklens entry has no \"command\"")
        }
        let env = (entry["env"] as? [String: String]) ?? [:]
        return .configured(command: command, args: (entry["args"] as? [String]) ?? [], env: env)
    }

    /// Reads and parses, turning every failure into an `Entry` rather than throwing: "could not
    /// read it" is one of the answers Connections shows.
    public static func read(at url: URL) -> Entry {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable("could not read \(url.path)")
        }
        return isTOML(url) ? MCPTOML.parse(String(decoding: data, as: UTF8.self)) : parse(data)
    }

    /// Codex's file, which is edited as TOML rather than JSON.
    static func isTOML(_ url: URL) -> Bool { url.pathExtension == "toml" }

    /// `/…/Worklens.app/Contents/MacOS/Worklens` → `/…/Worklens.app`, so a configured command
    /// can be compared with the bundle the user actually runs. Nil for a bare binary path.
    public static func bundle(forCommand command: String) -> URL? {
        let url = URL(fileURLWithPath: command)
        let bundle = url.deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()              // Contents
            .deletingLastPathComponent()              // Worklens.app
        return bundle.pathExtension == "app" ? bundle : nil
    }

    // MARK: - The entry the app writes (#140)

    /// Claude Desktop's bundle identifier, so the app can say whether it is installed without
    /// hard-coding a path. Verified against the copy on this machine, 2026-09.
    public static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// The `mcpServers.worklens` entry Worklens would write for itself.
    ///
    /// `env` is the half that is easy to miss. Claude Desktop launches the command with a
    /// minimal environment and no working directory, so `Config.loadWithProvenance` sees only
    /// the App Support layer — while the app itself usually runs with `WORKLENS_ENV_FILE` set by
    /// `scripts/update.sh`. Pinning that path into the entry is what keeps the server reading
    /// the same `DATA_DIR` the menu bar shows.
    public struct Plan: Sendable, Equatable {
        public let command: String
        public let args: [String]
        public let env: [String: String]

        public init(command: String, args: [String] = ["mcp"], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }

        /// The entry alone, as a JSON object.
        var entry: [String: Any] {
            var entry: [String: Any] = ["command": command, "args": args]
            if !env.isEmpty { entry["env"] = env }
            return entry
        }

        /// `{"mcpServers": {"worklens": …}}`, pretty-printed — what Copy JSON puts on the
        /// pasteboard and what `worklens mcp install --print` writes to stdout, for a client
        /// whose file Worklens does not write (Cowork).
        public var json: String {
            let object: [String: Any] = ["mcpServers": [serverName: entry]]
            guard let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        /// The same entry as the `[mcp_servers.worklens]` table Codex's `config.toml` holds.
        public var toml: String {
            MCPTOML.entry(self, key: serverName).joined(separator: "\n")
        }
    }

    /// The key `mcpServers` holds this server under. `parse` already treats any other name as
    /// the user's own, and reading it back is how the health check finds an entry a user renamed.
    public static let serverName = "worklens"

    /// Builds the entry for a binary. `executable` is resolved in the `Worklens` target
    /// (`Bundle.main.executableURL`) and passed in, because `WorklensCore` must stay testable
    /// against a temporary directory with no bundle around it.
    public static func plan(executable: URL, envFile: URL? = nil) -> Plan {
        Plan(
            command: executable.resolvingSymlinksInPath().path,
            args: ["mcp"],
            env: envFile.map { ["WORKLENS_ENV_FILE": $0.path] } ?? [:]
        )
    }

    // MARK: - Health

    /// What the card says about the entry that is there now.
    public enum Health: Sendable, Equatable {
        /// No file, or a file with no Worklens entry.
        case notInstalled
        /// The entry is exactly what this app would write.
        case pointsHere
        /// An entry whose command is a different binary — another checkout, most often.
        case pointsElsewhere(command: String)
        /// The right idea, stale in the details: the same command with different arguments or a
        /// different pinned environment.
        case outOfDate(command: String)
        /// The command is not on disk any more, which is the normal outcome after a checkout
        /// moves or a worktree is deleted.
        case stalePath(command: String)
        /// There is a file and it is not JSON Worklens can merge into. Never overwritten.
        case unparseable(String)
    }

    /// Compares what is written with what this app would write. `isExecutable` is injected so a
    /// test can describe a disk without making one.
    public static func health(
        entry: Entry,
        expecting plan: Plan,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Health {
        switch entry {
        case .noFile, .notConfigured:
            return .notInstalled
        case .unreadable(let why):
            return .unparseable(why)
        case .configured(let command, let args, let env):
            if !isExecutable(command) { return .stalePath(command: command) }
            if command != plan.command { return .pointsElsewhere(command: command) }
            if args != plan.args || env != plan.env { return .outOfDate(command: command) }
            return .pointsHere
        }
    }

    // MARK: - Watching the link (#248)

    /// What a sweep of every client's health means for the user.
    ///
    /// The whole decision, in one pure function, because the thing it protects against is a
    /// notice nobody asked for: an install that never connected must never be told its link
    /// broke, and `outOfDate` must not raise anything either — that server still runs.
    public enum LinkState: Sendable, Equatable {
        /// Nothing to watch: no client points here and none ever did.
        case nothingConnected
        /// At least one client points at this app.
        case connected
        /// A client was connected and is not any more — the binary its entry names is gone.
        case broken(Client)
    }

    /// One client's file, read. A named type rather than a tuple, so a sweep can cross an actor
    /// boundary on its way back to the main one.
    public struct Reading: Sendable, Equatable {
        public let client: Client
        public let health: Health

        public init(client: Client, health: Health) {
            self.client = client
            self.health = health
        }
    }

    /// `everConnected` is the set of clients `app_state` remembers this install having connected.
    /// Without it a first launch on a Mac with somebody else's stale entry in the file would open
    /// with a problem the user never caused.
    ///
    /// It is a set rather than a flag because the two clients break one at a time: with Claude
    /// Desktop still pointing here and the Claude Code entry gone stale, a single flag plus a
    /// "does anything point here" short-circuit would say `connected` and the user would never
    /// be told. So a client that has connected is checked before any client that still points
    /// here is allowed to answer. A client not in the set can still never raise anything.
    public static func linkState(
        _ readings: [Reading],
        everConnected: Set<Client>
    ) -> LinkState {
        // Only a binary that is gone is a broken link. `unparseable` is somebody else's file and
        // is never written; `outOfDate` still launches a server that works, and so does
        // `pointsElsewhere`: the usual "elsewhere" is this checkout's `build/Worklens.app` while
        // the menu bar runs the copy `make install` put in /Applications, and Claude Desktop
        // writes its own file back from memory, so a Reconnect made while it runs is undone
        // within minutes and the notice came straight back (2026-10-09). The Settings card
        // still shows either one.
        for reading in readings where everConnected.contains(reading.client) {
            switch reading.health {
            case .stalePath: return .broken(reading.client)
            case .notInstalled, .pointsHere, .pointsElsewhere, .outOfDate, .unparseable: continue
            }
        }
        if readings.contains(where: { $0.health == .pointsHere }) { return .connected }
        return .nothingConnected
    }

    // MARK: - Installing

    /// What a write did, so the card and the CLI can say where the old file went.
    public struct Installation: Sendable, Equatable {
        public let url: URL
        /// Nil when there was no file to back up.
        public let backup: URL?
        public let createdFile: Bool

        public init(url: URL, backup: URL?, createdFile: Bool) {
            self.url = url
            self.backup = backup
            self.createdFile = createdFile
        }
    }

    public enum InstallError: Error, CustomStringConvertible, Equatable {
        /// The existing file is not something Worklens can merge into. It is left untouched:
        /// overwriting a file somebody hand-edited is the one failure this feature must not have.
        case unmergeable(String)
        case write(String)

        public var description: String {
            switch self {
            case .unmergeable(let why): return why
            case .write(let why): return why
            }
        }
    }

    /// Reads the client's file, copies it aside with a timestamp, merges **only**
    /// `mcpServers.worklens` and writes the result atomically.
    ///
    /// Everything else in the file survives byte-for-byte in meaning: other servers, other
    /// top-level keys, and any entry the user renamed. A file that does not parse is an error
    /// rather than a fresh start.
    @discardableResult
    public static func install(_ plan: Plan, at url: URL, now: Date = Date()) throws -> Installation {
        let manager = FileManager.default
        var object: [String: Any] = [:]
        var backup: URL?
        let existed = manager.fileExists(atPath: url.path)

        if isTOML(url) { return try installTOML(plan, at: url, now: now) }

        if existed {
            guard let data = try? Data(contentsOf: url) else {
                throw InstallError.unmergeable("could not read \(url.path)")
            }
            let text = String(decoding: data, as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.unmergeable("\(url.lastPathComponent) is not valid JSON")
                }
                object = parsed
            }
            backup = try keepBackup(of: data, beside: url, now: now)
        }

        var servers: [String: Any] = [:]
        if let existing = object["mcpServers"] {
            guard let existing = existing as? [String: Any] else {
                throw InstallError.unmergeable("\"mcpServers\" is not an object")
            }
            servers = existing
        }
        // `parse` reads a renamed entry back by its command, so the card can say "points at a
        // build that is gone" about an entry the user called something else. Writing `worklens`
        // regardless would leave that entry behind, still launching the old path, while health
        // — which finds the new one first — reported everything fine. So the entry that is
        // already there is the one that gets repointed, under the name its owner gave it.
        servers[renamedEntryKey(in: servers) ?? serverName] = plan.entry
        object["mcpServers"] = servers

        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        } catch {
            throw InstallError.write("could not write \(url.path)")
        }
        return Installation(url: url, backup: backup, createdFile: !existed)
    }

    /// `install` for Codex: the same backup and the same refusal, with `MCPTOML` doing the edit.
    private static func installTOML(_ plan: Plan, at url: URL, now: Date) throws -> Installation {
        let manager = FileManager.default
        let existed = manager.fileExists(atPath: url.path)
        var text = ""
        var backup: URL?
        if existed {
            guard let data = try? Data(contentsOf: url) else {
                throw InstallError.unmergeable("could not read \(url.path)")
            }
            text = String(decoding: data, as: UTF8.self)
            // Refuse before the backup, as the JSON side does for a file that does not parse.
            let updated = try MCPTOML.installing(plan, into: text)
            backup = try keepBackup(of: data, beside: url, now: now)
            text = updated
        } else {
            text = try MCPTOML.installing(plan, into: "")
        }
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw InstallError.write("could not write \(url.path)")
        }
        return Installation(url: url, backup: backup, createdFile: !existed)
    }

    /// Copies the file aside and returns where. The name is second-granular, so two writes in the
    /// same second want the same path. The copy worth keeping is the first — the user's own file;
    /// the second would only preserve what Worklens itself wrote a moment earlier. So an existing
    /// backup is left exactly as it is rather than replaced.
    private static func keepBackup(of data: Data, beside url: URL, now: Date) throws -> URL {
        let candidate = backupURL(for: url, now: now)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            do {
                try data.write(to: candidate, options: .atomic)
            } catch {
                throw InstallError.write("could not write the backup beside \(url.path)")
            }
        }
        return candidate
    }

    // MARK: - Removing (#155)

    /// What a removal did, so the caller can say which key went and where the old file is.
    public struct Removal: Sendable, Equatable {
        public let url: URL
        public let key: String
        /// Nil only when the file could not be copied aside, which `remove` treats as fatal —
        /// so in practice always set. Kept optional so the shape matches `Installation`.
        public let backup: URL?

        public init(url: URL, key: String, backup: URL?) {
            self.url = url
            self.key = key
            self.backup = backup
        }
    }

    /// The `mcpServers` key that holds Worklens in this file, under whatever name it was given.
    /// Nil when the file is missing, unparseable, or simply has no Worklens entry.
    ///
    /// Connections asks this before it removes anything, so it can name the key it is about to
    /// take out instead of promising to remove something that may not be there.
    public static func installedKey(at url: URL) -> String? {
        if isTOML(url) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return MCPTOML.installedKey(in: String(decoding: data, as: UTF8.self))
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any]
        else { return nil }
        if servers[serverName] != nil { return serverName }
        return renamedEntryKey(in: servers)
    }

    /// Copies the file aside and takes out exactly one `mcpServers` key.
    ///
    /// The mirror of `install`, and it keeps the same promise: every other server, every other
    /// top-level key and the user's own formatting choices in meaning all survive, and a file
    /// that does not parse is an error rather than something to overwrite. `mcpServers` itself
    /// is left in place even when it ends up empty — an empty object is valid, and deleting a
    /// key the user did not ask about is the failure this method must not have.
    ///
    /// Returns nil when there is nothing to do: no file, or no such key.
    @discardableResult
    public static func remove(
        key: String, at url: URL, now: Date = Date()
    ) throws -> Removal? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw InstallError.unmergeable("could not read \(url.path)")
        }
        if isTOML(url) {
            guard let updated = try MCPTOML.removing(
                key: key, from: String(decoding: data, as: UTF8.self)
            ) else { return nil }
            let backup = try keepBackup(of: data, beside: url, now: now)
            do {
                try Data(updated.utf8).write(to: url, options: .atomic)
            } catch {
                throw InstallError.write("could not write \(url.path)")
            }
            return Removal(url: url, key: key, backup: backup)
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unmergeable("\(url.lastPathComponent) is not valid JSON")
        }
        guard var servers = object["mcpServers"] as? [String: Any] else { return nil }
        guard servers.removeValue(forKey: key) != nil else { return nil }

        let backup = try keepBackup(of: data, beside: url, now: now)

        object["mcpServers"] = servers
        do {
            let updated = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try (updated + Data("\n".utf8)).write(to: url, options: .atomic)
        } catch {
            throw InstallError.write("could not write \(url.path)")
        }
        return Removal(url: url, key: key, backup: backup)
    }

    /// The key of an entry the user renamed: no `worklens` key, but one that launches a binary
    /// called `Worklens` — the same entry `parse` falls back to. Nil when `worklens` is there or
    /// nothing matches. Sorted, so a file with two of them resolves the same way every time.
    static func renamedEntryKey(in servers: [String: Any]) -> String? {
        guard servers[serverName] == nil else { return nil }
        return servers.keys.sorted().first {
            ((servers[$0] as? [String: Any])?["command"] as? String)?.hasSuffix("/Worklens") == true
        }
    }

    /// `claude_desktop_config.json` → `claude_desktop_config.json.worklens-20260915-141530.bak`,
    /// beside the original so it is obvious what it is a copy of.
    public static func backupURL(for url: URL, now: Date = Date()) -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone.current
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).worklens-\(stamp.string(from: now)).bak")
    }
}
