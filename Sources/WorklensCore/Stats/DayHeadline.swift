import Foundation

/// The day's sentence (#249): one line that says what a day held, so the reader's sidebar and
/// the MCP `days` table can name a day and say something about it.
///
/// Two sources, one shape. For a day an older build wrote a daily report for, the sentence is
/// that report's own opening line. The reports were cut on 2026-10-05, so every newer day's
/// sentence is made from the day's own facts instead.
///
/// Facts only: the app names the timeline already shows and a duration. Never a window title,
/// never a URL, never a score and never one day measured against another.
public enum DayHeadline {
    /// About this many characters, cut at a word boundary — `MenuRow.textLimit`'s number, for the
    /// same reason: past it a one-line row stops being one line.
    public static let textLimit = 90

    /// How many app names a stats sentence names before it stops listing.
    static let nameLimit = 2

    // MARK: - From a report

    /// The first sentence of a report's lede, or nil when there is no usable one.
    ///
    /// Skips the front-matter block and any heading, takes the first ordinary paragraph — every
    /// line of it, since a model may hard-wrap its lede — cuts it at the first sentence end and
    /// trims it to one line of about `textLimit` characters.
    public static func fromReport(_ markdown: String) -> String? {
        let body = NoEmDash.replaced(withoutFrontMatter(markdown))
        var paragraph: [String] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || !isProse(line) {
                // A blank line or a heading ends the paragraph being collected; before one has
                // started, it is only more of the preamble to walk over.
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        guard !paragraph.isEmpty,
              let sentence = firstSentence(stripEmphasis(paragraph.joined(separator: " ")))
        else { return nil }
        return truncate(sentence)
    }

    /// `markdown` without the YAML front-matter block — everything up to the second `---` —
    /// when it opens with one. The block is bookkeeping (which model, what it cost), not prose.
    static func withoutFrontMatter(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return markdown }
        return lines[lines.index(after: end)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a non-empty line is ordinary prose rather than markdown scaffolding. A heading
    /// names the section, a fence or a table is not prose, and a bullet is a list item — but a
    /// bolded lede (`**You spent the morning…**`) is prose, so a marker counts as a bullet only
    /// when a space follows it.
    static func isProse(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("|")
            || line.hasPrefix(">") || line.hasPrefix("- ") || line.hasPrefix("* ") {
            return false
        }
        // A rule (`---`, `***`) is not prose either.
        return !line.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }

    /// The line without its markdown emphasis, so a bolded lede reads as a sentence.
    static func stripEmphasis(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        while result.hasPrefix("*") || result.hasPrefix("_") { result.removeFirst() }
        while result.hasSuffix("*") || result.hasSuffix("_") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Up to the first `.`, `!` or `?` that ends a sentence, the mark kept.
    ///
    /// A mark ends a sentence only when the text breaks after it or ends there: the dot in
    /// `2.5 h`, `e.g.` or `Preview.app` is followed by another character, so it ends nothing,
    /// and a mark between two digits therefore never cuts a number in half.
    static func firstSentence(_ line: String) -> String? {
        let characters = Array(line)
        var cut = characters.count
        for index in characters.indices {
            let character = characters[index]
            guard character == "." || character == "!" || character == "?" else { continue }
            if index + 1 < characters.count, !characters[index + 1].isWhitespace { continue }
            cut = index + 1
            break
        }
        let trimmed = String(characters[..<cut]).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One line of at most `textLimit` characters, cut at a word boundary with an ellipsis.
    static func truncate(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > textLimit else { return oneLine }
        let cut = oneLine.prefix(textLimit)
        let words = cut.split(separator: " ").dropLast()
        let head = words.isEmpty ? String(cut) : words.joined(separator: " ")
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - From the day's own facts

    /// What a day with no report says about itself: the apps it mostly went into, and how long it
    /// was. Nil for a day with nothing worth stating.
    ///
    /// `names` are app names as the timeline shows them, longest first.
    public static func fromStats(names: [String], activeMinutes: Int) -> String? {
        guard activeMinutes > 0 else { return nil }
        let onScreen = StatsAggregator.duration(activeMinutes)
        let named = Array(names.prefix(nameLimit))
        guard !named.isEmpty else {
            return truncate(L10n.format("%@ on screen", onScreen))
        }
        return truncate(L10n.format("Mostly %1$@, %2$@ on screen", list(named), onScreen))
    }

    /// `Code editor` or `Code editor and Email` — never more than `nameLimit` of them.
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let first = names.first, let second = names.dropFirst().first else {
            return names.first ?? ""
        }
        return L10n.format("%1$@ and %2$@", first, second)
    }
}
