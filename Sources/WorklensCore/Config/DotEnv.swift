import Foundation

/// Minimal `.env` parser: one `KEY=VALUE` per line, no variable interpolation.
///
/// Rules:
/// - blank lines and lines whose first non-space character is `#` are ignored
/// - an optional leading `export ` is stripped
/// - the key is everything before the *first* `=`; `=` inside the value is kept
/// - keys and values are trimmed of surrounding whitespace
/// - one pair of matching surrounding single or double quotes is stripped from the value
/// - a trailing `#` comment is stripped from an **unquoted** value when the `#` has whitespace
///   in front of it (#126); everything else is kept verbatim, so `https://x#frag` and a regex
///   like `\d{3}#` survive, and quoting protects a `#` anywhere
/// - CRLF line endings are handled
public enum DotEnv {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            // Untrimmed on purpose: whether a `#` starts a comment depends on the whitespace in
            // front of it, and `KEY= # note` loses that space if the value is trimmed first.
            result[key] = clean(String(line[line.index(after: eq)...]))
        }
        return result
    }

    /// Reads and parses a file; returns `[:]` when it does not exist or cannot be read.
    public static func load(contentsOf url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// A quoted value verbatim; an unquoted one with any trailing comment removed.
    ///
    /// #126: before this, `CAPTURE_INTERVAL_SECONDS=60  # seconds` parsed as the string
    /// `60  # seconds` and failed with "expected an integer", which is a confusing thing to be
    /// told about a line that looks exactly like every documented example.
    private static func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if isQuoted(trimmed) { return String(trimmed.dropFirst().dropLast()) }
        guard let cut = trailingCommentStart(raw) else { return unquote(trimmed) }
        return unquote(String(raw[raw.startIndex..<cut]).trimmingCharacters(in: .whitespaces))
    }

    /// The index of a `#` that starts a comment: one with whitespace in front of it. A `#` that
    /// is part of the value — a URL fragment, a regex — has no space before it and is kept.
    private static func trailingCommentStart(_ value: String) -> String.Index? {
        var previous: Character?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "#", let previous, previous.isWhitespace { return index }
            previous = character
            index = value.index(after: index)
        }
        return nil
    }

    private static func isQuoted(_ value: String) -> Bool {
        guard value.count >= 2, let first = value.first, let last = value.last else { return false }
        return (first == "\"" && last == "\"") || (first == "'" && last == "'")
    }

    private static func unquote(_ value: String) -> String {
        isQuoted(value) ? String(value.dropFirst().dropLast()) : value
    }
}
