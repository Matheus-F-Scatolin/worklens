import CryptoKit
import Foundation

/// Where the long half of a context event lives.
///
/// `context_events.body_md` is meant to be quotable inside a prompt, so it is capped; anything
/// longer (a Granola transcript runs to tens of thousands of characters) goes to a file under
/// `DATA_DIR/context/<source>/<external-id>.md` and the row keeps only the path. Transcripts
/// therefore never reach a report prompt by accident — only what a source deliberately put in
/// `body_md` does.
public enum ContextBody {
    /// Longest `body_md` any source may store. Issue #19's "≤ 2k-char summary".
    public static let inlineLimit = 2000

    /// Trims to `limit` characters on a word boundary, appending an ellipsis when it cut.
    public static func inline(_ text: String?, limit: Int = inlineLimit) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }

        let head = trimmed.prefix(limit - 1)
        // Cut at the last space in the final 20 % rather than mid-word, unless there is none.
        let floor = head.index(head.startIndex, offsetBy: (limit - 1) * 4 / 5)
        let cut = head[floor...].lastIndex(of: " ").map { head[..<$0] } ?? head
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The same trim, flattened to one line.
    ///
    /// Summaries arrive as markdown — Granola's start with an H1 and continue as a bullet list —
    /// and a multi-line string dropped into a `- ` bullet breaks the document around it: only the
    /// first line stays a bullet, and a stray `#` becomes a heading in the middle of a timeline.
    /// The stored `body_md` keeps the real markdown; this is for anywhere it is quoted inline.
    public static func oneLine(_ text: String?, limit: Int = inlineLimit) -> String? {
        guard let text else { return nil }
        let flattened = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                // Leading markdown furniture: headings, bullets, quotes.
                while let first = trimmed.first, "#>-*".contains(first) {
                    trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return inline(flattened, limit: limit)
    }

    /// The path a body file takes, relative to `DATA_DIR`.
    public static func relativePath(source: ContextSource, externalId: String) -> String {
        "context/\(source.rawValue)/\(fileName(externalId)).md"
    }

    /// Writes `markdown` and returns the path to store in `body_path`. Existing files are
    /// replaced: a re-sync of a changed note should not leave the old transcript behind.
    @discardableResult
    public static func write(
        _ markdown: String, source: ContextSource, externalId: String, config: Config
    ) throws -> String {
        let relative = relativePath(source: source, externalId: externalId)
        let url = config.dataDir.appendingPathComponent(relative)
        try FilePermissions.createPrivateDirectory(at: url.deletingLastPathComponent())
        try FilePermissions.writePrivate(Data(markdown.utf8), to: url)
        return relative
    }

    public static func read(_ relativePath: String, config: Config) throws -> String {
        try String(contentsOf: config.dataDir.appendingPathComponent(relativePath), encoding: .utf8)
    }

    public static func delete(_ relativePath: String, config: Config) {
        try? FileManager.default.removeItem(at: config.dataDir.appendingPathComponent(relativePath))
    }

    /// External ids are opaque strings from someone else's system; Google's carry a plus.
    /// Keep them recognizable but make them safe as a file name.
    static func fileName(_ externalId: String) -> String {
        let safe = externalId.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let name = String(safe)
        // A very long id would blow past the 255-byte limit; keep the head and a short digest so
        // two ids that share a prefix cannot collide. SHA-256 rather than `hashValue`: Swift seeds
        // that per process, so the same id would land in a different file on every launch —
        // orphaning the old body and reporting the row as "updated" on every sync.
        guard name.count > 120 else { return name }
        let digest = SHA256.hash(data: Data(externalId.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(name.prefix(110))-\(digest)"
    }

    /// The front matter every body file starts with, so the file makes sense on its own.
    public static func frontMatter(
        source: ContextSource,
        externalId: String,
        title: String?,
        startAt: Date,
        endAt: Date?,
        participants: [String]
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [
            "---",
            "source: \(source.rawValue)",
            "external_id: \(externalId)",
            "title: \(quote(title ?? "untitled"))",
            "start_at: \(iso.string(from: startAt))",
        ]
        if let endAt { lines.append("end_at: \(iso.string(from: endAt))") }
        if !participants.isEmpty {
            lines.append("participants: [\(participants.map(quote).joined(separator: ", "))]")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
