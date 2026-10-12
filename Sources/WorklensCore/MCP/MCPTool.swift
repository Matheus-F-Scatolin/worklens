import Foundation

/// Anything a tool can fail with that the client should read as prose rather than as a protocol
/// error: a day that is not `YYYY-MM-DD`, a limit out of range, a week with nothing recorded.
public struct MCPToolError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One `tools/call` answer. Every Worklens tool returns text — a timeline, a JSON blob, a table —
/// so the content array is always one `text` block.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var json: JSONValue {
        .object([
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }
}

/// The three hints `tools/list` carries beside a tool, so a client can show what it is allowed to
/// do before anybody runs it (#241).
///
/// Every Worklens tool is the same: it reads the local database, it reaches no network, and
/// calling it twice changes nothing — there is not a write tool in this process. So the values are
/// set once, in `MCPToolAnnotations.read`, rather than per tool.
public struct MCPToolAnnotations: Sendable, Equatable {
    public var readOnlyHint: Bool
    public var openWorldHint: Bool
    public var idempotentHint: Bool

    public init(readOnlyHint: Bool, openWorldHint: Bool, idempotentHint: Bool) {
        self.readOnlyHint = readOnlyHint
        self.openWorldHint = openWorldHint
        self.idempotentHint = idempotentHint
    }

    /// What every tool in this server is.
    public static let read = MCPToolAnnotations(
        readOnlyHint: true, openWorldHint: false, idempotentHint: true
    )

    public var json: JSONValue {
        .object([
            "readOnlyHint": .bool(readOnlyHint),
            "openWorldHint": .bool(openWorldHint),
            "idempotentHint": .bool(idempotentHint),
        ])
    }
}

/// A declared tool: what `tools/list` says about it, and the closure `tools/call` runs.
///
/// The handler is synchronous and throwing. Every Worklens tool is a database read, and a thrown
/// error becomes `isError: true` content rather than a JSON-RPC failure — the client is supposed
/// to show the model what went wrong, not fail the turn.
public struct MCPTool: Sendable {
    public let name: String
    /// What a client shows a person, where `name` is what it shows a model. Nil leaves the entry
    /// exactly as it was before #241.
    public let title: String?
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: MCPToolAnnotations?
    public let handler: @Sendable (JSONValue) throws -> String

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: JSONValue,
        annotations: MCPToolAnnotations? = nil,
        handler: @escaping @Sendable (JSONValue) throws -> String
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.handler = handler
    }

    public var listEntry: JSONValue {
        var entry: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "inputSchema": inputSchema,
        ]
        if let title { entry["title"] = .string(title) }
        if let annotations { entry["annotations"] = annotations.json }
        return .object(entry)
    }
}

/// The set of tools one server exposes. Pure over its tools, so a test can register a throwing
/// one and see what the protocol does with it.
public struct MCPToolRegistry: Sendable {
    public let tools: [MCPTool]
    /// The curated conversation starters `prompts/list` offers (#241). Empty for a registry that
    /// declares none, which is what keeps `prompts` out of the server's capabilities there.
    public let prompts: [MCPPrompt]
    /// One sentence for `initialize`'s instructions — what to ask about. It travels
    /// on the registry because that is the only value the server is handed that was built for
    /// the connection (#241).
    public let instructions: String?

    public init(_ tools: [MCPTool], prompts: [MCPPrompt] = [], instructions: String? = nil) {
        self.tools = tools
        self.prompts = prompts
        self.instructions = instructions
    }

    public var listJSON: JSONValue { .object(["tools": .array(tools.map(\.listEntry))]) }

    public var promptsListJSON: JSONValue { .object(["prompts": .array(prompts.map(\.listEntry))]) }

    public func tool(named name: String) -> MCPTool? { tools.first { $0.name == name } }

    public func prompt(named name: String) -> MCPPrompt? { prompts.first { $0.name == name } }

    /// `prompts/get`. An unknown prompt is a protocol error for the same reason an unknown tool
    /// is: the client asked for something `prompts/list` never offered.
    public func promptJSON(name: String, arguments: JSONValue) throws -> JSONValue {
        guard let prompt = prompt(named: name) else {
            throw JSONRPCError.invalidParams("unknown prompt \"\(name)\"")
        }
        return prompt.getJSON(arguments: arguments)
    }

    /// An unknown tool is a *protocol* error (`-32602`) rather than tool output: the client asked
    /// for something that was never in `tools/list`, which is a bug on its side, not a bad day.
    public func call(name: String, arguments: JSONValue) throws -> MCPToolResult {
        guard let tool = tool(named: name) else {
            throw JSONRPCError.invalidParams("unknown tool \"\(name)\"")
        }
        do {
            return MCPToolResult(text: try tool.handler(arguments))
        } catch let error as MCPToolError {
            return MCPToolResult(text: error.description, isError: true)
        } catch {
            // A storage or filesystem error. The message is the model's only clue, and it never
            // carries screen text.
            return MCPToolResult(text: "\(name) failed: \(error)", isError: true)
        }
    }
}

// MARK: - Argument reading

/// The small amount of coercion a tool needs from `params.arguments`.
///
/// Claude Desktop sends numbers as numbers, but other clients send `"limit": "20"`, so an integer
/// is read from either. Nothing here logs a value: an argument is a search term, and a search term
/// is window content (#89).
public extension JSONValue {
    func requiredString(_ key: String, _ hint: String) throws -> String {
        guard let text = self[key]?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPToolError("\(key) is required: \(hint)")
        }
        return text
    }

    func optionalString(_ key: String) -> String? {
        guard let text = self[key]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = self[key], !value.isNull else { return nil }
        if let number = value.numberValue {
            // `Int(exactly:)` is nil for 2.5, NaN, infinity and 1e100: each is an argument error,
            // never a trap that takes the server down.
            guard number.isFinite, let whole = Int(exactly: number) else {
                throw MCPToolError("\(key) must be a whole number")
            }
            return whole
        }
        if let text = value.stringValue, let number = Int(text) { return number }
        throw MCPToolError("\(key) must be a whole number")
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let value = try optionalInt(key) ?? fallback
        guard range.contains(value) else {
            throw MCPToolError("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return value
    }

    func optionalStrings(_ key: String) -> [String]? {
        guard let value = self[key], !value.isNull else { return nil }
        if let array = value.arrayValue { return array.compactMap(\.stringValue) }
        if let text = value.stringValue {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// A `YYYY-MM-DD` local day, checked against `DayBoundaries` so a tool never asks the database
    /// about a day that cannot exist.
    func day(_ key: String, timeZone: TimeZone = .current) throws -> String {
        let text = try requiredString(key, "a local day like 2026-09-07")
        guard DayBoundaries.range(day: text, timeZone: timeZone) != nil else {
            throw MCPToolError("\(key) must look like 2026-09-07 (got \"\(text)\")")
        }
        return text
    }
}
