import Foundation

/// Takes credentials and payment instruments out of a string before it is stored or sent (#49).
///
/// **What is replaced** is what someone else could *use*: card numbers, IBANs, one-time codes,
/// API keys and passwords. **What is kept** is the user's own working context — personal names,
/// phone numbers, emails, CPFs, CNPJs, IP addresses, postal addresses, dates, prices, version
/// numbers and URL hosts. None of those is a credential, and they are what makes a report
/// readable; a `PrivacyPolicy` blocklist is the tool for a window that should not exist at all.
///
/// Pure, stateless and `Sendable`: #53 calls this on every capture tick, off the main actor, so
/// the built-in regexes are compiled once into `builtInRules` and shared by every instance. Only
/// `REDACT_EXTRA_PATTERNS` is compiled per instance.
///
/// Placeholders are numbered per call, so a model can still tell two cards apart, and the same
/// value twice yields the same number: `[CARD_1]`, `[IBAN_1]`, `[OTP]`, `[SECRET_1]`,
/// `[PASSWORD]`, `[CUSTOM_1]`.
public struct TextRedactor: Sendable {
    /// The six things that get replaced. Adding one is a `Kind` case and a `Rule` row.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Comparable {
        case card = "CARD"
        case iban = "IBAN"
        case otp = "OTP"
        case secret = "SECRET"
        case password = "PASSWORD"
        case custom = "CUSTOM"

        /// `[OTP]` and `[PASSWORD]` carry no number: there is nothing useful to tell apart, and a
        /// numbered password would leak how many distinct ones were on screen.
        public var isNumbered: Bool {
            switch self {
            case .otp, .password: return false
            case .card, .iban, .secret, .custom: return true
            }
        }

        /// The key this kind takes in `descriptions.details_json` → `redactions`.
        public var jsonKey: String { rawValue.lowercased() }

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The result of one `redact` call: the text with placeholders in, and how many of each kind
    /// were replaced (occurrences, not distinct values — "N items redacted today" counts events).
    public struct Redacted: Sendable, Equatable {
        public let text: String
        public let counts: [Kind: Int]

        public init(text: String, counts: [Kind: Int]) {
            self.text = text
            self.counts = counts
        }

        public var total: Int { counts.values.reduce(0, +) }
        public var isClean: Bool { counts.isEmpty }

        /// `["card": 1, "secret": 2]` — what goes into `details_json` and `redactions_json`.
        public var countsJSON: [String: Int] { TextRedactor.countsJSON(counts) }
    }

    /// Patterns from `REDACT_EXTRA_PATTERNS` that failed to compile. Dropped, with the source kept
    /// for the log — a typo in one pattern must not silently disable the rest, exactly as in
    /// `PrivacyPolicy.invalidPatterns`.
    public let invalidPatterns: [String]
    private let rules: [Rule]

    public init(extraPatterns: [String] = []) {
        var custom: [Rule] = []
        var invalid: [String] = []
        for source in extraPatterns {
            if let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) {
                custom.append(Rule(kind: .custom, regex: regex))
            } else {
                invalid.append(source)
            }
        }
        self.invalidPatterns = invalid
        // Custom rules come last so a built-in kind wins an overlap: a user pattern that happens
        // to cover a card number should still read `[CARD_1]`.
        self.rules = TextRedactor.builtInRules + custom
    }

    public init(config: Config) {
        self.init(extraPatterns: config.redactExtraPatterns)
    }

    // MARK: - Redacting

    public func redact(_ text: String) -> Redacted {
        guard !text.isEmpty else { return Redacted(text: text, counts: [:]) }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        var candidates: [Candidate] = []
        for (order, rule) in rules.enumerated() {
            rule.regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let match else { return }
                let group = rule.group < match.numberOfRanges ? rule.group : 0
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { return }
                let value = ns.substring(with: range)
                if let validate = rule.validate, !validate(value) { return }
                candidates.append(
                    Candidate(range: range, kind: rule.kind, order: order, value: value)
                )
            }
        }
        // The URL span (`urlQueryRanges`) wins every overlap: it is deleted whole, so no part of
        // a query survives beside a `[SECRET_n]`. A secret found inside it is still counted, so
        // "N items redacted" does not shrink; it just has nothing left to replace.
        let drops = TextRedactor.urlQueryRanges(in: text)
        guard !candidates.isEmpty || !drops.isEmpty else { return Redacted(text: text, counts: [:]) }

        // Overlaps between the other rules: the earliest match wins, then the longest, then the
        // earlier rule in the table.
        candidates.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return a.order < b.order
        }
        var accepted: [Candidate] = []
        for candidate in candidates
        where !accepted.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
            accepted.append(candidate)
        }
        accepted.sort { $0.range.location < $1.range.location }

        // The text in `range`, minus every dropped URL span.
        func kept(_ range: NSRange) -> String {
            var piece = ""
            var cursor = range.location
            let end = range.location + range.length
            for drop in drops where drop.location < end && drop.location + drop.length > cursor {
                if drop.location > cursor {
                    piece += ns.substring(with: NSRange(location: cursor, length: drop.location - cursor))
                }
                cursor = max(cursor, drop.location + drop.length)
            }
            if cursor < end { piece += ns.substring(with: NSRange(location: cursor, length: end - cursor)) }
            return piece
        }

        var counts: [Kind: Int] = [:]
        var numbers: [Kind: [String: Int]] = [:]
        var out = ""
        var cursor = 0
        for candidate in accepted {
            out += kept(NSRange(location: cursor, length: candidate.range.location - cursor))
            let kind = candidate.kind
            counts[kind, default: 0] += 1
            // Wholly inside a dropped span: counted, and nothing to write in its place. A match
            // that only reaches into one still writes its placeholder, so none of it survives.
            let swallowed = drops.contains { NSUnionRange($0, candidate.range) == $0 }
            if !swallowed {
                if kind.isNumbered {
                    let key = TextRedactor.identity(of: candidate.value, kind: kind)
                    var table = numbers[kind] ?? [:]
                    let number = table[key] ?? (table.count + 1)
                    table[key] = number
                    numbers[kind] = table
                    out += "[\(kind.rawValue)_\(number)]"
                } else {
                    out += "[\(kind.rawValue)]"
                }
            }
            cursor = candidate.range.location + candidate.range.length
        }
        out += kept(NSRange(location: cursor, length: ns.length - cursor))
        return Redacted(text: out, counts: counts)
    }

    // MARK: - URL queries

    /// Drops the query string and fragment from every URL-shaped run in `text` and leaves
    /// everything else byte for byte (#87, #332). The rule `redact` applies, exposed on its own so
    /// the migration that repairs stored outlines (`AXOutlineRepair`) applies the same one.
    ///
    /// - With `http://` or `https://` (any case): everything from the first `?` or `#` to the
    ///   next whitespace goes.
    /// - Without a scheme, as a Chromium omnibox shows an address: a host of two or more labels
    ///   whose last is 2–24 letters, not preceded by a letter, digit, `@`, `.`, `/`, `:` or `-`,
    ///   then an optional port and path. A `?` run that holds an `=` goes, with any fragment
    ///   after it; after a path, a `#fragment` goes. `Is it example.com?`, `node.js?`,
    ///   `v1.2.3?x=1` and an email address stay as they are.
    public static func stripURLQueries(_ text: String) -> String {
        let drops = urlQueryRanges(in: text)
        guard !drops.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for drop in drops {
            out += ns.substring(with: NSRange(location: cursor, length: drop.location - cursor))
            cursor = drop.location + drop.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// The spans `stripURLQueries` deletes: sorted, merged, never empty.
    static func urlQueryRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [NSRange] = []
        for regex in urlQueryRules {
            regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let range = match?.range(at: 1), range.location != NSNotFound, range.length > 0
                else { return }
                spans.append(range)
            }
        }
        spans.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for span in spans {
            if let last = merged.last, span.location <= last.location + last.length {
                merged[merged.count - 1] = NSUnionRange(last, span)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Group 1 of each is the span to drop.
    private static let urlQueryRules: [NSRegularExpression] = {
        let host = #"(?<![\p{L}\p{N}@./:\-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,24}(?![A-Za-z0-9-])(?::[0-9]{1,5})?"#
        return [
            // With a scheme: from the first `?` or `#` to whitespace.
            rx(#"\bhttps?://[^\s?#]*([?#]\S*)"#, [.caseInsensitive]),
            // Without one: a query that holds an `=`, and whatever follows it.
            rx(host + #"(?:/[^\s?#]*+)?(\?(?=[^\s#]*=)\S*)"#),
            // Without one: a fragment after a path.
            rx(host + #"/[^\s?#]*+(#\S+)"#),
        ]
    }()

    /// `nil` in, `nil` out — the window title and the URL are both optional on a capture.
    public func redactIfPresent(_ text: String?) -> (text: String?, counts: [Kind: Int]) {
        guard let text else { return (nil, [:]) }
        let result = redact(text)
        return (result.text, result.counts)
    }

    /// Sum two count tables, so one frame's title and URL report as one set of numbers.
    public static func merge(_ lhs: [Kind: Int], _ rhs: [Kind: Int]) -> [Kind: Int] {
        lhs.merging(rhs, uniquingKeysWith: +)
    }

    /// `["card": 1]` — the shape `descriptions.details_json` and `ax_snapshots.redactions_json`
    /// both store.
    public static func countsJSON(_ counts: [Kind: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.key.jsonKey, $0.value) })
    }

    /// Two spellings of one card (`4111 1111 1111 1111` and `4111111111111111`) are one value and
    /// get one number. Everything else is compared verbatim.
    private static func identity(of value: String, kind: Kind) -> String {
        switch kind {
        case .card, .iban:
            return value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        case .otp, .password, .secret, .custom:
            return value
        }
    }

    // MARK: - The rule table

    private struct Candidate {
        let range: NSRange
        let kind: Kind
        let order: Int
        let value: String
    }

    private struct Rule: Sendable {
        let kind: Kind
        let regex: NSRegularExpression
        /// Which capture group holds the secret; `0` is the whole match. `password=hunter2` keeps
        /// its key and replaces only the value.
        let group: Int
        let validate: (@Sendable (String) -> Bool)?

        init(
            kind: Kind,
            regex: NSRegularExpression,
            group: Int = 0,
            validate: (@Sendable (String) -> Bool)? = nil
        ) {
            self.kind = kind
            self.regex = regex
            self.group = group
            self.validate = validate
        }
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Every pattern here is a literal in this file; one that does not compile is a bug to fix,
        // not a runtime condition to carry.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// One row per shape. Order matters only for a tie between two matches (see `redact`).
    private static let builtInRules: [Rule] = [
        // --- Passwords: the key stays, the value goes. Before the card rule, so
        // `senha=4111111111111111` reads `[PASSWORD]` rather than `[CARD_1]`.
        Rule(
            kind: .password,
            regex: rx(#"(?<![A-Za-z0-9_])(?:password|senha|pwd|passwd)\s*=\s*("[^"\n]{1,200}"|'[^'\n]{1,200}'|[^\s&;"'\n]{1,200})"#, [.caseInsensitive]),
            group: 1
        ),

        // --- Secret shapes.
        Rule(kind: .secret, regex: rx(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#)),
        Rule(kind: .secret, regex: rx(#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#)),
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{12,}"#)),
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9])AIza[A-Za-z0-9_-]{16,}"#)),
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9])xox[abpsre]-[A-Za-z0-9-]{10,}"#)),
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}"#)),
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}"#)),
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9])A(?:KIA|SIA)[0-9A-Z]{12,}"#)),
        Rule(kind: .secret, regex: rx(#"\bBearer\s+([A-Za-z0-9._~+/=-]{12,})"#, [.caseInsensitive]), group: 1),

        // --- IBAN: two letters, two check digits, 11–30 alphanumerics, mod-97. Written either
        // compact or in groups of four — spelling out both is what stops a greedy `(?: ?[A-Z0-9])`
        // from swallowing the next word and failing the checksum on an IBAN that is really there.
        Rule(
            kind: .iban,
            regex: rx(#"(?<![A-Za-z0-9])[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)(?![A-Za-z0-9])"#),
            validate: { passesIBAN($0) }
        ),

        // --- Card numbers. Non-digit boundaries on both sides *and* Luhn: the boundary is what
        // keeps a 44-digit NF-e access key or a 47-digit boleto line from donating a 16-digit
        // window, roughly one in ten of which passes Luhn on its own.
        Rule(kind: .card, regex: rx(#"(?<![0-9])[0-9]{13,19}(?![0-9])"#), validate: { passesLuhn($0) }),
        // Grouped spellings: the separator must be the same throughout, so `9 89110000012345`
        // (one stray space in a boleto line) is not a card.
        Rule(
            kind: .card,
            regex: rx(#"(?<![0-9])(?<![0-9][ -])[0-9]{4}([ -])[0-9]{4}\1[0-9]{4}\1[0-9]{1,7}(?![0-9])(?![ -][0-9])"#),
            validate: { passesLuhn($0) }
        ),
        Rule(
            kind: .card,
            regex: rx(#"(?<![0-9])(?<![0-9][ -])[0-9]{4}([ -])[0-9]{6}\1[0-9]{5}(?![0-9])(?![ -][0-9])"#),
            validate: { passesLuhn($0) }
        ),

        // --- One-time codes: 6–8 digits within 30 characters of a word that says "code".
        Rule(
            kind: .otp,
            regex: rx(#"(?:c[oó]digo|code|verification|OTP|2FA|token)[^\n]{0,30}?(?<![0-9])([0-9]{6,8})(?![0-9])"#, [.caseInsensitive]),
            group: 1
        ),
        Rule(
            kind: .otp,
            regex: rx(#"(?<![0-9])([0-9]{6,8})(?![0-9])[^\n]{0,30}?(?:c[oó]digo|code|verification|OTP|2FA|token)"#, [.caseInsensitive]),
            group: 1
        ),
    ]

    // MARK: - Checksums

    /// The Luhn check every card number passes and most other digit runs do not.
    static func passesLuhn(_ raw: String) -> Bool {
        let digits = raw.compactMap { $0.isNumber ? $0.wholeNumberValue : nil }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            var value = digit
            if offset.isMultiple(of: 2) == false {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum.isMultiple(of: 10)
    }

    /// ISO 13616 mod-97: move the first four characters to the end, letters become 10–35, the
    /// whole thing read as one number must leave remainder 1.
    static func passesIBAN(_ raw: String) -> Bool {
        let compact = raw.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let ascii = character.asciiValue else { return false }
            switch ascii {
            case 48...57:  // 0-9
                remainder = (remainder * 10 + Int(ascii - 48)) % 97
            case 65...90:  // A-Z
                remainder = (remainder * 100 + Int(ascii - 65) + 10) % 97
            default:
                return false
            }
        }
        return remainder == 1
    }
}
