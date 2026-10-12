import Foundation

/// Worklens shows no em dash and no en dash anywhere, and the models that write its reports and
/// summaries reach for both constantly. Their prompts forbid it; this is what catches the ones that slip through,
/// on the way to disk and again on the way to the screen, so a report written before the rule
/// reads the same as one written after it.
public enum NoEmDash {
    static let dashes: Set<Character> = ["\u{2014}", "\u{2013}"]

    /// `09:00 — 10:00` and `09:00–10:00` become `09:00-10:00`, `coding — then review` becomes
    /// `coding, then review`, and a dash at the edge of a line or alone in a table cell becomes a
    /// hyphen.
    public static func replaced(_ text: String) -> String {
        guard text.contains(where: dashes.contains) else { return text }
        let chars = Array(text)
        var out = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            guard dashes.contains(char) else {
                out.append(char)
                index += 1
                continue
            }
            var after = index + 1
            while after < chars.count, chars[after] == " " || chars[after] == "\u{2009}" { after += 1 }
            while let last = out.last, last == " " || last == "\u{2009}" { out.removeLast() }
            let before = out.last
            let next = after < chars.count ? chars[after] : nil
            if let before, let next, before.isNumber, next.isNumber {
                out.append("-")
            } else if let before, let next, !"\n|".contains(before), !"\n|".contains(next) {
                out.append(", ")
            } else {
                if before != nil, before != "\n" { out.append(" ") }
                out.append("-")
                if next != nil, next != "\n" { out.append(" ") }
            }
            index = after
        }
        return out
    }

    /// A range Foundation formatted (`21–27 September`, `28 September – 4 October`), with its
    /// dash made a hyphen: tight where Foundation set it tight, spaced where it spaced it. Unlike
    /// `replaced`, a dash between words stays a range and never turns into a comma.
    public static func range(_ text: String) -> String {
        var out = ""
        var chars = Array(text)[...]
        while let char = chars.first {
            chars = chars.dropFirst()
            guard dashes.contains(char) else {
                out.append(char)
                continue
            }
            var spaced = false
            while let last = out.last, last == " " || last == "\u{2009}" || last == "\u{202F}" {
                out.removeLast()
                spaced = true
            }
            while let next = chars.first, next == " " || next == "\u{2009}" || next == "\u{202F}" {
                chars = chars.dropFirst()
                spaced = true
            }
            out.append(spaced ? " - " : "-")
        }
        return out
    }
}
