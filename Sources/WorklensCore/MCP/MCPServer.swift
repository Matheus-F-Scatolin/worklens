import Foundation

/// The MCP methods `worklens mcp` answers, over newline-delimited JSON-RPC (#89).
///
/// `handle(line:)` is the whole protocol and it is pure: one line in, zero or one line out. The
/// read loop in `serve(transport:)` adds nothing but I/O, which is what lets `MCPServerTests`
/// drive a full `initialize` → `tools/list` → `tools/call` round trip in memory.
///
/// Read-only by construction: the registry holds only reading closures, so this command never
/// writes to `DATA_DIR` and deliberately takes no instance lock — it runs *while* the menu-bar
/// app runs, which is the entire point.
public struct MCPServer: Sendable {
    /// The newest revision this server speaks. 2025-11-25 is the one that added `serverInfo.icons`;
    /// nothing else in it changes what a tools-and-prompts server must do.
    public static let protocolVersion = "2025-11-25"
    /// Every revision this server answers in. A client asking for one of these gets it echoed back
    /// (Claude Desktop asked for 2025-06-18 as of 2026-09); any other gets `protocolVersion`, per
    /// the spec's "server responds with the latest version it supports".
    public static let supportedProtocolVersions: Set<String> = ["2025-11-25", "2025-06-18"]

    /// The version `initialize` answers with, given the one the client asked for.
    static func negotiatedVersion(requested: String?) -> String {
        guard let requested, supportedProtocolVersions.contains(requested) else { return protocolVersion }
        return requested
    }
    public static let serverName = "worklens"

    private let registry: MCPToolRegistry
    private let version: String
    /// The directory this server is answering from, surfaced to the client in `initialize` so a
    /// `DATA_DIR` mismatch is visible inside Claude Desktop without opening the log file (#140).
    private let dataDir: URL?

    public init(
        registry: MCPToolRegistry,
        version: String = WorklensVersion.short,
        dataDir: URL? = nil
    ) {
        self.registry = registry
        self.version = version
        self.dataDir = dataDir
    }

    // MARK: - Dispatch

    /// Nil when the line was a notification: the spec forbids a response to one.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let request: JSONRPCRequest
        do {
            request = try JSONRPCRequest.decode(trimmed)
        } catch let error as JSONRPCError {
            return JSONRPCResponse.encode(JSONRPCResponse.failure(id: nil, error))
        } catch {
            return JSONRPCResponse.encode(JSONRPCResponse.failure(id: nil, .parse("\(error)")))
        }

        do {
            guard let value = try result(for: request) else { return nil }
            guard let id = request.id else { return nil }
            return JSONRPCResponse.encode(JSONRPCResponse.result(id: id, value))
        } catch let error as JSONRPCError {
            // A notification that fails still gets no response — there is nobody to answer.
            guard let id = request.id else { return nil }
            return JSONRPCResponse.encode(JSONRPCResponse.failure(id: id, error))
        } catch {
            guard let id = request.id else { return nil }
            return JSONRPCResponse.encode(JSONRPCResponse.failure(id: id, .server("\(error)")))
        }
    }

    /// Nil for a method that answers with nothing (the `notifications/*` family).
    private func result(for request: JSONRPCRequest) throws -> JSONValue? {
        switch request.method {
        case "initialize":
            var capabilities: [String: JSONValue] = ["tools": .object([:])]
            // Declared only where there are prompts to list, so a registry without them (a test's
            // two tools, say) still describes itself honestly.
            if !registry.prompts.isEmpty { capabilities["prompts"] = .object([:]) }
            var result: [String: JSONValue] = [
                "protocolVersion": .string(
                    Self.negotiatedVersion(requested: request.arguments["protocolVersion"]?.stringValue)
                ),
                "capabilities": .object(capabilities),
                // `icons` is sent whatever the version: an older client ignores a member it does
                // not know, and a newer one draws the app icon instead of a letter badge.
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string(version),
                    "icons": MCPServerIcon.iconsJSON,
                ]),
            ]
            // A wrong path and a wrong DATA_DIR fail the same way from the client's side —
            // silently. This is the one sentence that makes the second one answerable: ask the
            // assistant what Worklens says it is reading and compare it with Settings (#140).
            //
            // The second sentence points a model at the timeline and the stats once, at connect
            // time (#241). It rides on the registry.
            var sentences: [String] = []
            if let dataDir {
                sentences.append(
                    "Worklens is answering from \(dataDir.path). Every tool here reads that "
                        + "directory and nothing else; there are no write tools."
                )
            }
            if let instructions = registry.instructions { sentences.append(instructions) }
            if !sentences.isEmpty { result["instructions"] = .string(sentences.joined(separator: " ")) }
            return .object(result)
        case "ping":
            return .object([:])
        case "tools/list":
            return registry.listJSON
        case "prompts/list":
            return registry.promptsListJSON
        case "prompts/get":
            let arguments = request.arguments
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw JSONRPCError.invalidParams("prompts/get needs a prompt name")
            }
            return try registry.promptJSON(name: name, arguments: arguments["arguments"] ?? .object([:]))
        case "tools/call":
            let arguments = request.arguments
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw JSONRPCError.invalidParams("tools/call needs a tool name")
            }
            return try registry.call(name: name, arguments: arguments["arguments"] ?? .object([:])).json
        case let method where method.hasPrefix("notifications/"):
            return nil
        default:
            throw JSONRPCError.methodNotFound(request.method)
        }
    }

    // MARK: - The loop

    /// Reads lines until the client closes stdin, answering each one.
    ///
    /// Nothing but a response is ever written: `Log` goes to os_log and `FileLog`, and the CLI
    /// command points fd 1 at stderr before this runs, so a stray `print` cannot corrupt the
    /// stream. `trace` gets one `traceLine` per request; the CLI hands it stderr, which is the
    /// file a client keeps about the server (Claude Desktop's `mcp-server-worklens.log`).
    public func serve(_ transport: some MCPTransport, trace: ((String) -> Void)? = nil) throws {
        while let line = try transport.readLine() {
            let started = Date()
            let response = handle(line: line)
            if let trace,
                let entry = MCPServer.traceLine(
                    request: line, response: response, elapsed: Date().timeIntervalSince(started))
            {
                trace(entry)
            }
            guard let response else { continue }
            try transport.write(response)
        }
    }

    /// One line about one request: the method, the tool's name on a `tools/call`, how it ended
    /// and how long it took. Never the arguments, which hold search terms and days, and never the
    /// result, which is window content. Nil for a notification, which has nothing to report.
    ///
    /// Before this the server said nothing between "came up" and "exiting", so a client reporting
    /// a bare "Tool execution failed" on every call (2026-10-09) left no way to tell whether a
    /// call had reached the server at all.
    static func traceLine(request line: String, response: String?, elapsed: TimeInterval) -> String? {
        let milliseconds = Int((elapsed * 1000).rounded())
        guard let request = try? JSONRPCRequest.decode(line.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return "worklens mcp: unreadable request -> \(outcome(of: response)) in \(milliseconds) ms"
        }
        guard request.id != nil else { return nil }
        var what = request.method
        if request.method == "tools/call", let name = request.arguments["name"]?.stringValue {
            what += " " + name.prefix(64)
        }
        return "worklens mcp: \(what) -> \(outcome(of: response)) in \(milliseconds) ms"
    }

    /// `ok`, `tool error` (a result with `isError`), `error <code>`, or `no response`.
    static func outcome(of response: String?) -> String {
        guard let response,
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        else { return "no response" }
        if let code = value["error"]?["code"]?.intValue { return "error \(code)" }
        if value["result"]?["isError"]?.boolValue == true { return "tool error" }
        return "ok"
    }
}

/// The seam under the read loop: a line source and a line sink. `MCPStdioTransport` is the real
/// one; the tests use an in-memory pipe.
public protocol MCPTransport: Sendable {
    /// Nil at end of input.
    func readLine() throws -> String?
    /// Writes one response; the transport appends the newline the framing needs.
    func write(_ line: String) throws
}
