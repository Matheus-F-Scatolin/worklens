import Foundation

/// Newline-delimited JSON-RPC 2.0 — the whole wire format MCP's stdio transport asks for (#89).
///
/// Hand-rolled on purpose: the CLT toolchain has already refused one package over macros (#16),
/// and stdio MCP is three real methods. Everything here is a pure function of a string, so
/// `MCPServerTests` drives the protocol without a process.

/// The subset of JSON-RPC error codes this server can produce.
public enum JSONRPCError: Error, Equatable, CustomStringConvertible {
    /// The line was not JSON at all.
    case parse(String)
    /// It was JSON, but not a JSON-RPC request object.
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case server(String)

    public var code: Int {
        switch self {
        case .parse: -32_700
        case .invalidRequest: -32_600
        case .methodNotFound: -32_601
        case .invalidParams: -32_602
        case .server: -32_603
        }
    }

    public var message: String {
        switch self {
        case let .parse(detail): "Parse error: \(detail)"
        case let .invalidRequest(detail): "Invalid Request: \(detail)"
        case let .methodNotFound(method): "Method not found: \(method)"
        case let .invalidParams(detail): "Invalid params: \(detail)"
        case let .server(detail): "Internal error: \(detail)"
        }
    }

    public var description: String { message }
}

/// One decoded request. `id == nil` means a notification, which by the spec gets no response.
public struct JSONRPCRequest: Sendable, Equatable {
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }

    /// A `params` object, or an empty one — a method with no arguments may omit the member.
    public var arguments: JSONValue { params ?? .object([:]) }

    /// A missing *or* null `id` is treated as a notification: MCP clients omit the member for
    /// notifications, and nothing in the protocol ever addresses a null id.
    public static func decode(_ line: String) throws -> JSONRPCRequest {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        } catch {
            throw JSONRPCError.parse("not JSON")
        }
        guard let object = value.objectValue else {
            throw JSONRPCError.invalidRequest("not an object")
        }
        guard let method = object["method"]?.stringValue, !method.isEmpty else {
            throw JSONRPCError.invalidRequest("no method")
        }
        // Spelled out rather than with `flatMap`: `JSONValue` is `ExpressibleByNilLiteral`, so a
        // `nil` in a ternary there becomes `.null` instead of "no id".
        var id: JSONValue?
        if let raw = object["id"], !raw.isNull { id = raw }
        return JSONRPCRequest(id: id, method: method, params: object["params"])
    }
}

/// The two response shapes, and the one-line encoder both go through.
public enum JSONRPCResponse {
    public static func result(id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": value])
    }

    /// `id` is nil only when the request could not be parsed far enough to have one; the spec
    /// asks for an explicit null there.
    public static func failure(id: JSONValue?, _ error: JSONRPCError) -> JSONValue {
        .object([
            "jsonrpc": "2.0",
            "id": id ?? .null,
            "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)]),
        ])
    }

    /// Compact, newline-free JSON. Sorted keys so a transcript test can compare strings.
    public static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            // Unreachable for a JSONValue; a silent drop would look like a hung server.
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: unencodable"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
