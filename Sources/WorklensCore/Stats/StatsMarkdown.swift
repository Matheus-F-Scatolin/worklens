import Foundation

/// The two renderings of the stats that something still reads: pretty JSON for the MCP tools'
/// answers, and the `2h 05m` duration Today and Weeks print.
public extension StatsAggregator {
    /// Pretty JSON, for the MCP tools' answers.
    static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// `2h 05m`, `45m`, `0m` for nothing.
    static func duration(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(String(format: "%02d", rest))m" : "\(rest)m"
    }
}
