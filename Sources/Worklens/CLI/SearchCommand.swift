import ArgumentParser
import Foundation
import WorklensCore

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find frames by the text that was on screen: outlines, descriptions, titles, URLs."
    )

    @Argument(help: "What to look for. Double-quote a run of words to search it as a phrase.")
    var query: String

    @Option(help: "How many days back to look, counting today. 0 searches everything.")
    var days: Int = 30

    @Option(help: "How many results to print.")
    var limit: Int = 20

    @Flag(help: "Print JSON instead of the lines.")
    var json: Bool = false

    func run() throws {
        guard days >= 0 else { throw ValidationError("--days cannot be negative") }
        guard limit > 0 else { throw ValidationError("--limit must be at least 1") }

        let config = try CLIConfig.load()
        let db = try Database(dataDir: config.dataDir)
        let hits = try SearchService(db).search(query: query, days: range(), limit: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(hits), as: UTF8.self))
            return
        }

        guard !hits.isEmpty else {
            print("No frames match \"\(query)\"\(days == 0 ? "" : " in the last \(days) day(s)").")
            return
        }
        for hit in hits { print(lines(for: hit, config: config).joined(separator: "\n")) }
    }

    /// `--days 30` counts today plus the 29 before it; `--days 0` means the whole database.
    private func range() -> ClosedRange<String>? {
        guard days > 0 else { return nil }
        let today = Date()
        let first = today.addingTimeInterval(-Double(days - 1) * 86_400)
        return DayBoundaries.dayString(first)...DayBoundaries.dayString(today)
    }

    /// `time · app · title`, the snippet, then the frame itself when retention has not taken it.
    private func lines(for hit: SearchHit, config: Config) -> [String] {
        let where_ = [hit.appName ?? hit.appKey, hit.windowTitle ?? hit.urlHost]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var out = [
            ([Self.clock.string(from: hit.capturedAt)] + where_).joined(separator: " · ")
                + (hit.frames > 1 ? "  (\(hit.frames) frames)" : "")
        ]
        out.append("  \(hit.kind.rawValue): \(Self.oneLine(hit.snippet))")
        if let relative = hit.imagePath {
            let url = config.dataDir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { out.append("  frame: \(url.path)") }
        }
        return out + [""]
    }

    /// A window outline is indented tree text; on one terminal line the indentation is noise.
    private static func oneLine(_ snippet: String) -> String {
        snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
