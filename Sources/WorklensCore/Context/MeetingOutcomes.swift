import Foundation

/// What came out of a meeting: the next steps and the decisions its Granola summary lists (#316).
///
/// Most summaries end in a "Next steps" or "Próximos passos" section, which `body_md`'s 2,000
/// characters and the MCP body's 400 almost always cut. This reads the *full* summary at sync time,
/// with no model call, and keeps the items in `context_events.outcomes_json`. Only
/// `summary_markdown` is ever parsed here: the transcript and the private notes never are.
public struct MeetingOutcomes: Codable, Sendable, Equatable {
    /// Bump when the parser changes what it finds; `refreshMeetingOutcomes` re-parses every row
    /// stored with an older one.
    public static let parserVersion = 1
    public static let maxItems = 12
    public static let textLimit = 300
    public static let detailLimit = 600

    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        /// Continuation lines and nested bullets, joined.
        public var detail: String?
        /// The item says your name, "you" or "você".
        public var namesYou: Bool

        public init(text: String, detail: String? = nil, namesYou: Bool = false) {
            self.text = text
            self.detail = detail
            self.namesYou = namesYou
        }
    }

    public var v: Int
    public var nextSteps: [Item]
    public var decisions: [Item]

    public init(v: Int = MeetingOutcomes.parserVersion, nextSteps: [Item] = [], decisions: [Item] = []) {
        self.v = v
        self.nextSteps = nextSteps
        self.decisions = decisions
    }

    public var isEmpty: Bool { nextSteps.isEmpty && decisions.isEmpty }

    // MARK: Parsing

    enum Kind { case nextSteps, decisions }

    /// Folded heading prefixes. Folding drops case, diacritics, `*` and `:`.
    static let nextStepLabels = [
        "next step", "action item", "follow-up", "follow up", "proximos passos", "pendencias", "encaminhamentos",
    ]
    /// Whole folded labels, not prefixes: "Decision makers" on a sales call is a list of people.
    static let decisionLabels = [
        "decision", "decisions", "decisions made", "decisao", "decisoes", "decisoes tomadas",
    ]

    /// Every next step and decision in `summaryMarkdown`. A summary with neither heading gives
    /// empty arrays, never nil, so a row is parsed once and not on every sync.
    ///
    /// `youName` is the account's name (`ContextEventStore.granolaYouName`), the same for every
    /// note: not the note's own `owner.name`, which on a note a colleague shared is theirs.
    public static func parse(summaryMarkdown: String?, youName: String?) -> MeetingOutcomes {
        var outcomes = MeetingOutcomes()
        guard let summary = summaryMarkdown, !summary.isEmpty else { return outcomes }
        let names = YouMatcher(youName: youName)

        var section: (kind: Kind, level: Int)?
        var collector = Collector()

        func close() {
            guard let open = section else { return }
            let items = collector.finish().map { item -> Item in
                var copy = item
                copy.namesYou = names.matches(item.text + " " + (item.detail ?? ""))
                return copy
            }
            switch open.kind {
            case .nextSteps: outcomes.nextSteps = Array((outcomes.nextSteps + items).prefix(maxItems))
            case .decisions: outcomes.decisions = Array((outcomes.decisions + items).prefix(maxItems))
            }
            section = nil
            collector = Collector()
        }

        let lines = summary.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            if let heading = heading(line) {
                // A deeper heading stays inside the open section and names what follows it, even
                // one that reads like the same section (`### Follow-up with Ana` under `## Next
                // steps`); only the other kind opens its own. A same-or-higher heading is the
                // next part of the summary.
                let kind = kind(of: heading.label)
                if let open = section, heading.level > open.level, kind == nil || kind == open.kind {
                    collector.headingGroup(clean(heading.label))
                } else if let kind {
                    close()
                    section = (kind, heading.level)
                } else {
                    close()
                }
                continue
            }
            guard section != nil else { continue }
            if !collector.take(line) { close() }
        }
        close()
        return outcomes
    }

    static func kind(of label: String) -> Kind? {
        let folded = fold(label)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        if nextStepLabels.contains(where: folded.hasPrefix) { return .nextSteps }
        if decisionLabels.contains(folded) { return .decisions }
        return nil
    }

    /// An ATX heading: up to three spaces, one to six `#`, then a space or the end of the line.
    static func heading(_ line: String) -> (level: Int, label: String)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let hashes = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var label = after.trimmingCharacters(in: .whitespaces)
        // A closing sequence (`## Next steps ##`) is not part of the label.
        while label.hasSuffix("#") { label.removeLast() }
        return (hashes, label.trimmingCharacters(in: .whitespaces))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// The bullet's text, or nil when the line is not a list item.
    static func bulletText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        if trimmed == "-" || trimmed == "*" || trimmed == "+" { return "" }
        let digits = trimmed.prefix { $0.isNumber }.count
        if digits > 0, digits <= 3 {
            let after = trimmed.dropFirst(digits)
            if after.hasPrefix(". ") || after.hasPrefix(") ") { return String(after.dropFirst(2)) }
        }
        return nil
    }

    /// Markdown emphasis and a task checkbox out, whitespace collapsed.
    static func clean(_ text: String) -> String {
        var out = text
        for checkbox in ["[ ] ", "[x] ", "[X] "] where out.hasPrefix(checkbox) {
            out = String(out.dropFirst(checkbox.count))
        }
        out = out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return out.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    static func capped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A bare `Name:` bullet: a few words ending in a colon, whose children are the real items.
    static func groupName(_ text: String) -> String? {
        guard text.hasSuffix(":") else { return nil }
        let name = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 60, name.split(separator: " ").count <= 4 else { return nil }
        return name
    }

    // MARK: Collecting one section

    /// Turns a section's lines into items: one per top-level bullet, its indented lines as detail.
    struct Collector {
        private struct Draft {
            var text: String
            var detail: [String] = []
        }

        private var items: [Item] = []
        private var current: Draft?
        /// The label of a deeper heading inside the section.
        private var heading: String?
        /// An open `Name:` bullet, and the indent its children use.
        private var group: (name: String, childIndent: Int?)?

        mutating func headingGroup(_ label: String) {
            flush()
            group = nil
            heading = label.isEmpty ? nil : label
        }

        /// False when the line ends the section: a flush line that is not a bullet (the footer).
        mutating func take(_ line: String) -> Bool {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            let indent = expanded.prefix { $0 == " " }.count
            let bullet = MeetingOutcomes.bulletText(trimmed).map(MeetingOutcomes.clean)

            if indent < 2 {
                guard let bullet else { return false }
                flush()
                group = nil
                if let name = MeetingOutcomes.groupName(bullet) {
                    group = (name, nil)
                } else if !bullet.isEmpty {
                    current = Draft(text: prefixed(bullet, heading))
                }
                return true
            }

            let content = bullet ?? MeetingOutcomes.clean(trimmed)
            guard !content.isEmpty else { return true }
            if let open = group {
                // A child of a `Name:` bullet is an item of its own; anything deeper is its detail.
                if bullet != nil, open.childIndent.map({ indent <= $0 }) ?? true {
                    flush()
                    group = (open.name, open.childIndent ?? indent)
                    current = Draft(text: prefixed(content, open.name))
                    return true
                }
                if current == nil {
                    current = Draft(text: prefixed(content, open.name))
                    return true
                }
            }
            if current != nil {
                current?.detail.append(content)
            } else {
                current = Draft(text: prefixed(content, heading))
            }
            return true
        }

        mutating func finish() -> [Item] {
            flush()
            return items
        }

        private mutating func flush() {
            guard let draft = current else { return }
            current = nil
            let detail = draft.detail.joined(separator: "; ")
            items.append(Item(
                text: MeetingOutcomes.capped(draft.text, MeetingOutcomes.textLimit),
                detail: detail.isEmpty ? nil : MeetingOutcomes.capped(detail, MeetingOutcomes.detailLimit)
            ))
        }

        private func prefixed(_ text: String, _ name: String?) -> String {
            guard let name else { return text }
            return "\(name): \(text)"
        }
    }

    /// Whether a line says your first or full name, "you" or "você", as whole words.
    struct YouMatcher {
        private let phrases: [[String]]

        init(youName: String?) {
            var phrases = [["you"], ["voce"]]
            let owner = youName.map(YouMatcher.words) ?? []
            if let first = owner.first { phrases.append([first]) }
            if owner.count > 1 { phrases.append(owner) }
            self.phrases = phrases
        }

        func matches(_ text: String) -> Bool {
            let words = YouMatcher.words(text)
            return phrases.contains { phrase in
                guard words.count >= phrase.count else { return false }
                return (0...(words.count - phrase.count)).contains { start in
                    Array(words[start..<(start + phrase.count)]) == phrase
                }
            }
        }

        static func words(_ text: String) -> [String] {
            MeetingOutcomes.fold(text)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
    }

    // MARK: Storage

    /// The JSON `outcomes_json` holds.
    public var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String?) -> MeetingOutcomes? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingOutcomes.self, from: data)
    }
}
