import Foundation
import Testing
@testable import WorklensCore

/// #89: the protocol, over a scripted transcript rather than by hand.
///
/// The transport is an in-memory pipe — a list of request lines in, the response lines out — so
/// these exercise exactly what `worklens mcp` does with a client's stdin, without a process and
/// without stdout.
private final class PipeTransport: MCPTransport, @unchecked Sendable {
    private var pending: [String]
    private(set) var written: [String] = []

    init(_ lines: [String]) { pending = lines }

    func readLine() throws -> String? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    func write(_ line: String) throws { written.append(line) }

    /// Every response, decoded. A notification produced none, so this is shorter than the input.
    var responses: [JSONValue] {
        written.map { try! JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}

private func request(_ id: Int, _ method: String, _ params: String = "") -> String {
    let tail = params.isEmpty ? "" : ",\"params\":\(params)"
    return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"\#(tail)}"#
}

/// Two tools: one that echoes what it was handed, one that always throws.
private func registry() -> MCPToolRegistry {
    MCPToolRegistry([
        MCPTool(
            name: "echo",
            description: "Echoes its text back.",
            inputSchema: .object(["type": "object", "properties": .object([:])])
        ) { arguments in
            "echoed: \(arguments["text"]?.stringValue ?? "(nothing)")"
        },
        MCPTool(
            name: "boom",
            description: "Always fails.",
            inputSchema: .object(["type": "object", "properties": .object([:])])
        ) { _ in
            throw MCPToolError("no data for 2019-01-01")
        },
    ])
}

private func server() -> MCPServer { MCPServer(registry: registry(), version: "test") }

@Suite("MCP protocol")
struct MCPProtocolTests {
    @Test("initialize → tools/list → tools/call round-trips over a pipe")
    func roundTrip() throws {
        let transport = PipeTransport([
            request(1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}"#),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            request(2, "tools/list"),
            request(3, "tools/call", #"{"name":"echo","arguments":{"text":"hello"}}"#),
        ])
        try server().serve(transport)

        // Three responses for four lines: the notification got none.
        #expect(transport.written.count == 3)
        let responses = transport.responses

        #expect(responses[0]["id"]?.intValue == 1)
        // A supported version the client asks for is echoed, not replaced with the newest.
        #expect(responses[0]["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(responses[0]["result"]?["capabilities"]?["tools"]?.objectValue != nil)
        #expect(responses[0]["result"]?["serverInfo"]?["name"]?.stringValue == "worklens")

        let names = responses[1]["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["echo", "boom"])
        // Every declared tool carries a schema a client can render.
        #expect(responses[1]["result"]?["tools"]?[0]?["inputSchema"]?["type"]?.stringValue == "object")

        #expect(responses[2]["result"]?["isError"]?.boolValue == false)
        let content = responses[2]["result"]?["content"]?[0]
        #expect(content?["type"]?.stringValue == "text")
        #expect(content?["text"]?.stringValue == "echoed: hello")
    }

    @Test("a notification is answered with nothing at all")
    func notificationIsSilent() {
        #expect(server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        // An explicit null id is a notification too — nothing in MCP addresses one.
        #expect(server().handle(line: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == nil)
        #expect(server().handle(line: "   ") == nil)
    }

    @Test("ping answers with an empty result")
    func ping() throws {
        let response = try decode(server().handle(line: request(7, "ping")))
        #expect(response["id"]?.intValue == 7)
        #expect(response["result"]?.objectValue?.isEmpty == true)
    }

    @Test("an unknown method is -32601, keeping the request's id")
    func unknownMethod() throws {
        let response = try decode(server().handle(line: request(4, "tools/subscribe")))
        #expect(response["id"]?.intValue == 4)
        #expect(response["error"]?["code"]?.intValue == -32_601)
        #expect(response["error"]?["message"]?.stringValue?.contains("tools/subscribe") == true)
        #expect(response["result"] == nil)
    }

    @Test("malformed JSON is -32700 with a null id")
    func malformedJSON() throws {
        let response = try decode(server().handle(line: #"{"jsonrpc":"2.0","id":1,"method":"#))
        #expect(response["error"]?["code"]?.intValue == -32_700)
        #expect(response["id"]?.isNull == true)
    }

    @Test("JSON that is not a request object is -32600")
    func notARequest() throws {
        #expect(try decode(server().handle(line: "[1,2,3]"))["error"]?["code"]?.intValue == -32_600)
        #expect(try decode(server().handle(line: #"{"jsonrpc":"2.0","id":1}"#))["error"]?["code"]?.intValue == -32_600)
    }

    @Test("a throwing tool is isError content, not a crash and not a protocol error")
    func throwingTool() throws {
        let response = try decode(server().handle(line: request(5, "tools/call", #"{"name":"boom","arguments":{}}"#)))
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"]?.boolValue == true)
        #expect(response["result"]?["content"]?[0]?["text"]?.stringValue == "no data for 2019-01-01")
    }

    @Test("an unknown tool name is a protocol error, and a missing name too")
    func unknownTool() throws {
        let unknown = try decode(server().handle(line: request(6, "tools/call", #"{"name":"erase","arguments":{}}"#)))
        #expect(unknown["error"]?["code"]?.intValue == -32_602)
        #expect(unknown["error"]?["message"]?.stringValue?.contains("erase") == true)

        let nameless = try decode(server().handle(line: request(6, "tools/call", "{}")))
        #expect(nameless["error"]?["code"]?.intValue == -32_602)
    }

    @Test("tools/call with no arguments member still reaches the handler")
    func missingArguments() throws {
        let response = try decode(server().handle(line: request(8, "tools/call", #"{"name":"echo"}"#)))
        #expect(response["result"]?["content"]?[0]?["text"]?.stringValue == "echoed: (nothing)")
    }

    @Test("a string id is echoed as a string")
    func stringID() throws {
        let response = try decode(server().handle(line: #"{"jsonrpc":"2.0","id":"a-1","method":"ping"}"#))
        #expect(response["id"]?.stringValue == "a-1")
    }

    @Test("every response is exactly one line")
    func oneLinePerResponse() throws {
        // A tool whose text has newlines in it — a timeline is nothing but newlines — must still
        // come back as a single framed line.
        let multiline = MCPToolRegistry([
            MCPTool(name: "md", description: "…", inputSchema: .object(["type": "object"])) { _ in
                "## 09:00\nline two\nline three"
            },
        ])
        let transport = PipeTransport([request(1, "tools/call", #"{"name":"md","arguments":{}}"#)])
        try MCPServer(registry: multiline, version: "test").serve(transport)
        #expect(transport.written.count == 1)
        #expect(!transport.written[0].contains("\n"))
        #expect(transport.responses[0]["result"]?["content"]?[0]?["text"]?.stringValue
            == "## 09:00\nline two\nline three")
    }

    /// The client's own log of the server is the only place a call that "failed" can be traced,
    /// and a search term or a day is window content: the tool's name goes in, its arguments never.
    @Test("the trace names each request and its outcome, never its arguments")
    func traceLines() throws {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let transport = PipeTransport([
            request(1, "tools/list"),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            request(2, "tools/call", #"{"name":"echo","arguments":{"text":"secret window title"}}"#),
            request(3, "tools/call", #"{"name":"boom","arguments":{}}"#),
            request(4, "tools/call", #"{"name":"erase","arguments":{}}"#),
            "not json",
        ])
        try server().serve(transport) { lines.all.append($0) }

        // The notification says nothing; everything else is one line.
        #expect(lines.all.count == 5)
        #expect(lines.all[0].hasPrefix("worklens mcp: tools/list -> ok in "))
        #expect(lines.all[1].hasPrefix("worklens mcp: tools/call echo -> ok in "))
        #expect(lines.all[2].hasPrefix("worklens mcp: tools/call boom -> tool error in "))
        #expect(lines.all[3].hasPrefix("worklens mcp: tools/call erase -> error -32602 in "))
        #expect(lines.all[4].hasPrefix("worklens mcp: unreadable request -> error -32700 in "))
        #expect(!lines.all.joined().contains("secret"))
        #expect(lines.all.allSatisfy { $0.hasSuffix(" ms") })
    }
}

private func decode(_ line: String?) throws -> JSONValue {
    let line = try #require(line)
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

/// #241: what a client shows before anybody calls anything — the prompts in its "+" menu, the
/// read-only badge on every tool, and the sentence that says what to ask about.
@Suite("MCP prompts and annotations")
struct MCPPromptTests {
    private func promptServer() -> MCPServer {
        MCPServer(
            registry: MCPToolRegistry(
                [
                    MCPTool(
                        name: "echo", title: "Echo it back", description: "Echoes its text back.",
                        inputSchema: .object(["type": "object"]), annotations: .read
                    ) { _ in "echoed" },
                ],
                prompts: WorklensMCPPrompts.all(),
                instructions: WorklensMCPTools.instructions
            ),
            version: "test",
            dataDir: URL(fileURLWithPath: "/tmp/worklens-test")
        )
    }

    @Test("initialize declares prompts and says what to ask about")
    func initializeCarriesTheInstall() throws {
        let response = try decode(promptServer().handle(line: request(1, "initialize")))
        #expect(response["result"]?["capabilities"]?["prompts"]?.objectValue != nil)
        let instructions = try #require(response["result"]?["instructions"]?.stringValue)
        #expect(instructions.contains("/tmp/worklens-test"))
        #expect(instructions.contains("Ask about the timeline and the stats."))
        #expect(!instructions.contains("friction"))
        #expect(!instructions.contains("report"))

        // A registry with no prompts still says so honestly.
        #expect(try decode(server().handle(line: request(1, "initialize")))["result"]?["capabilities"]?["prompts"] == nil)
    }

    @Test("prompts/list returns the five, with their arguments")
    func promptsList() throws {
        let response = try decode(promptServer().handle(line: request(2, "prompts/list")))
        let prompts = try #require(response["result"]?["prompts"]?.arrayValue)
        #expect(prompts.compactMap { $0["name"]?.stringValue } == [
            "how_was_today", "what_did_i_work_on", "when_did_i_last", "where_did_my_week_go",
            "what_did_i_ship",
        ])
        for prompt in prompts {
            #expect(prompt["title"]?.stringValue?.isEmpty == false)
            #expect(prompt["description"]?.stringValue?.isEmpty == false)
        }
        #expect(prompts[0]["arguments"]?[0]?["name"]?.stringValue == "day")
        #expect(prompts[2]["arguments"]?[0]?["required"]?.boolValue == true)
    }

    @Test("prompts/get returns a message naming tools that exist")
    func promptsGet() throws {
        let tools = Set(["days", "timeline", "stats", "search", "span",
                         "vocabulary", "context_events", "now", "shipped"])
        // The argument names a message is allowed to quote beside a tool name.
        let arguments = Set(["project", "app", "by"])
        for name in ["how_was_today", "what_did_i_work_on", "when_did_i_last",
                     "where_did_my_week_go", "what_did_i_ship"] {
            let response = try decode(promptServer()
                .handle(line: request(3, "prompts/get", #"{"name":"\#(name)","arguments":{}}"#)))
            let message = try #require(
                response["result"]?["messages"]?[0]?["content"]?["text"]?.stringValue
            )
            #expect(response["result"]?["messages"]?[0]?["role"]?.stringValue == "user")
            // Every backticked name in a message is a tool the registry really declares.
            let named = message.split(separator: "`").enumerated()
                .filter { $0.offset % 2 == 1 }
                .map { String($0.element) }
            #expect(!named.isEmpty)
            #expect(named.contains { tools.contains($0) }, "\(name) names no tool")
            for tool in named {
                #expect(tools.contains(tool) || arguments.contains(tool), "\(name) names \(tool)")
            }
            #expect(message.contains("second person"))
        }

        // A day argument reaches the message.
        let today = try decode(promptServer()
            .handle(line: request(5, "prompts/get", #"{"name":"how_was_today","arguments":{"day":"2026-09-09"}}"#)))
        let todayText = try #require(today["result"]?["messages"]?[0]?["content"]?["text"]?.stringValue)
        #expect(todayText.contains("2026-09-09"))
        #expect(!todayText.contains("`report`"))
    }

    @Test("an unknown prompt, and a nameless one, are protocol errors")
    func unknownPrompt() throws {
        let unknown = try decode(promptServer()
            .handle(line: request(6, "prompts/get", #"{"name":"how_was_1999","arguments":{}}"#)))
        #expect(unknown["error"]?["code"]?.intValue == -32_602)
        #expect(try decode(promptServer().handle(line: request(7, "prompts/get", "{}")))["error"]?["code"]?.intValue
            == -32_602)
    }

    @Test("tools/list carries the title and the three read-only hints")
    func toolAnnotations() throws {
        let response = try decode(promptServer().handle(line: request(8, "tools/list")))
        let tool = try #require(response["result"]?["tools"]?[0])
        #expect(tool["title"]?.stringValue == "Echo it back")
        #expect(tool["annotations"]?["readOnlyHint"]?.boolValue == true)
        #expect(tool["annotations"]?["openWorldHint"]?.boolValue == false)
        #expect(tool["annotations"]?["idempotentHint"]?.boolValue == true)
    }
}

@Suite("MCP server icon")
struct MCPServerIconTests {
    @Test("initialize carries the app icon as a PNG data URI")
    func initializeCarriesIcon() throws {
        let transport = PipeTransport([
            request(1, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}"#)
        ])
        try server().serve(transport)
        let result = transport.responses[0]["result"]
        #expect(result?["protocolVersion"]?.stringValue == "2025-11-25")
        let icon = result?["serverInfo"]?["icons"]?[0]
        #expect(icon?["mimeType"]?.stringValue == "image/png")
        #expect(icon?["sizes"]?[0]?.stringValue == "64x64")
        #expect(icon?["src"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test("an unknown protocol version is answered with the newest one")
    func unknownVersionGetsNewest() {
        #expect(MCPServer.negotiatedVersion(requested: "2024-11-05") == MCPServer.protocolVersion)
        #expect(MCPServer.negotiatedVersion(requested: nil) == MCPServer.protocolVersion)
    }

    /// The inlined bytes are the iconset's 64 px PNG; an icon change without a regenerate fails here.
    @Test("the embedded icon matches the iconset")
    func embeddedIconMatchesIconset() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let png = try Data(contentsOf: repo.appendingPathComponent("Resources/AppIcon.iconset/icon_32x32@2x.png"))
        #expect(Data(base64Encoded: MCPServerIcon.base64) == png)
    }
}

/// An out-of-range number is an argument error, never a trap that ends `worklens mcp`.
@Suite("MCP numeric arguments")
struct MCPNumericArgumentTests {
    private func limitServer() -> MCPServer {
        MCPServer(registry: MCPToolRegistry([
            MCPTool(
                name: "days",
                description: "Reads a bounded limit.",
                inputSchema: .object(["type": "object", "properties": .object([:])])
            ) { arguments in
                "limit \(try arguments.int("limit", default: 7, range: 1...90))"
            },
        ]), version: "test")
    }

    private func call(_ arguments: String) throws -> JSONValue {
        try decode(limitServer().handle(line: request(1, "tools/call", #"{"name":"days","arguments":\#(arguments)}"#)))
    }

    @Test("{\"limit\":1e100} answers with the tool's error and the server keeps going")
    func hugeLimit() throws {
        let response = try call(#"{"limit":1e100}"#)
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"]?.boolValue == true)
        #expect(response["result"]?["content"]?[0]?["text"]?.stringValue == "limit must be a whole number")
        #expect(try call(#"{"limit":-1e300}"#)["result"]?["isError"]?.boolValue == true)
    }

    @Test("negative, fractional and in-range limits")
    func boundedLimits() throws {
        #expect(try call(#"{"limit":-5}"#)["result"]?["content"]?[0]?["text"]?.stringValue == "limit must be between 1 and 90")
        #expect(try call(#"{"limit":2.5}"#)["result"]?["content"]?[0]?["text"]?.stringValue == "limit must be a whole number")
        #expect(try call(#"{"limit":20}"#)["result"]?["content"]?[0]?["text"]?.stringValue == "limit 20")
        #expect(try call(#"{"limit":"20"}"#)["result"]?["content"]?[0]?["text"]?.stringValue == "limit 20")
        #expect(try call(#"{"limit":"1e100"}"#)["result"]?["isError"]?.boolValue == true)
    }

    @Test("NaN, infinity and past-Int.max numbers neither trap nor convert")
    func nonFiniteNumbers() {
        for number in [Double.nan, .infinity, -.infinity, 1e100, Double(Int.max) * 2] {
            let arguments: JSONValue = .object(["limit": .number(number)])
            #expect(throws: MCPToolError.self) { try arguments.optionalInt("limit") }
            #expect(JSONValue.number(number).intValue == nil)
        }
        #expect(JSONValue.number(42.9).intValue == 42)
        #expect(JSONValue.number(-3).intValue == -3)
    }
}
