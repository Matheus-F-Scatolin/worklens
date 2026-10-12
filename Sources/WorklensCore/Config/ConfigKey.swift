import Foundation

/// One section of `.env.example`, in file order. The raw value is the header text, so the
/// generated file and the registry cannot disagree about either the name or the order.
public enum ConfigSection: String, Sendable, CaseIterable {
    case credentials = "Credentials"
    case describe = "Describe (vision pass)"
    case capture = "Capture"
    case privacy = "Privacy"
    case budgets = "Budgets and storage"
    case context = "Context sources"
    case updates = "Staying current"
}

/// One configuration key, described once.
///
/// Everything that used to be a hand-maintained list — the parse dispatch in `Config.load`,
/// the `config-dump` order, the retired-key warning, `.env.example` itself — reads this
/// registry instead, so adding a key is one entry rather than four edits that drift (the empty
/// "Accessibility" section #87 left behind in `.env.example` is what drift looks like).
public struct ConfigKey: Sendable {
    /// What a value may say. Drives validation, and is what a settings control is chosen from.
    public enum Kind: Sendable, Equatable {
        /// An API key or token. Never printed unmasked, by anything.
        case secret
        case string
        case int
        case double
        /// A double the loader also range-checks to `0...1`.
        case unitDouble
        case bool
        /// One of a fixed set of spellings.
        case choice([String])
        /// A separated list; the separator is what `.env` uses for this key, and `,` and `;`
        /// are both accepted on the way in (#126).
        case list(Character)
        /// A list of regexes. Single-separator on purpose: a comma is legal inside a quantifier
        /// such as `{2,3}`, so accepting one as a separator would corrupt the pattern (#126).
        case regexList(Character)
        /// A model id. Validated against `ModelPricing.default` as a **warning** only: the price
        /// table is pinned and date-verified, so a new id is a missing row rather than a reason
        /// to refuse a launch — it just means those calls are costed at $0 until someone
        /// adds it (#126).
        case model
        /// A filesystem path, `~` and relative forms allowed.
        case path
    }

    /// The `.env` name. The same spelling is used in `settings.json`.
    public let name: String
    /// Where the key belongs in `.env.example`. Nil for a retired key, which appears nowhere.
    public let section: ConfigSection?
    public let kind: Kind
    /// The default exactly as `.env.example` writes it — `./data`, not the resolved path.
    public let defaultLiteral: String
    /// One sentence, second person, for the UI and the CLI.
    public let help: String
    /// The `.env.example` comment block, without its `# ` prefixes. Defaults to `help`.
    public let docs: String
    /// Whether Worklens may write this key to its own settings file. `DATA_DIR` is false on
    /// purpose: `WORKLENS_ENV_FILE` is how worktrees, tests and scripts pin the data directory,
    /// and a file the GUI writes must never be able to take that away (#34).
    public let editableInApp: Bool
    /// A key that was a setting once and is a constant in the source now (#87). It parses
    /// nothing and prints nowhere; it exists so a stale `.env` gets one warning naming it.
    public let retired: Bool
    /// The smallest value the code can actually honour, for an `int` or `double` key (#126).
    /// Below it is a `ConfigError`, not a silent clamp: `AUTO_UPDATE_POLL_MINUTES=1` used to be
    /// corrected to 5 by `AutoUpdater` without anyone being told, and `.env.example` said
    /// "Minimum 5" as if it were enforced.
    public let minimum: Double?
    /// The largest value, same contract as `minimum` (#242). A pane's stepper reads its own
    /// bounds from here, so the window and `worklens config set` refuse the same number with
    /// the same sentence instead of each carrying its own idea of "too much".
    public let maximum: Double?
    /// Writes a non-empty raw value into `config`, throwing `ConfigError` if it does not parse.
    /// `cwd` is what a relative path resolves against. Nil for a retired key.
    public let apply: (@Sendable (inout Config, String, URL) throws -> Void)?
    /// The value `config-dump` prints, secrets already masked. Nil for a retired key.
    public let read: (@Sendable (Config) -> String)?

    public init(
        name: String,
        section: ConfigSection,
        kind: Kind,
        default defaultLiteral: String,
        help: String,
        docs: String? = nil,
        editableInApp: Bool = true,
        minimum: Double? = nil,
        maximum: Double? = nil,
        apply: @escaping @Sendable (inout Config, String, URL) throws -> Void,
        read: @escaping @Sendable (Config) -> String
    ) {
        self.name = name
        self.section = section
        self.kind = kind
        self.defaultLiteral = defaultLiteral
        self.help = help
        self.docs = docs ?? help
        self.editableInApp = editableInApp
        self.minimum = minimum
        self.maximum = maximum
        self.retired = false
        self.apply = apply
        self.read = read
    }

    /// A key Worklens no longer reads (#87).
    private init(retired name: String) {
        self.name = name
        self.section = nil
        self.kind = .string
        self.defaultLiteral = ""
        self.help = "No longer read: the value moved next to its use (#87)."
        self.docs = "No longer read: the value moved next to its use (#87)."
        self.editableInApp = false
        self.minimum = nil
        self.maximum = nil
        self.retired = true
        self.apply = nil
        self.read = nil
    }

    static func retired(_ name: String) -> ConfigKey { ConfigKey(retired: name) }

    /// The bounds as a closed range, when the key has both. What a stepper is built from.
    public var range: ClosedRange<Double>? {
        guard let minimum, let maximum, minimum <= maximum else { return nil }
        return minimum...maximum
    }

    /// How a bound reads in an error and in `.env.example`: `5 or more`, `600 or less`,
    /// `5 to 600`. One sentence, wherever the value was refused.
    public static func rangeText(minimum: Double?, maximum: Double?) -> String {
        switch (minimum, maximum) {
        case let (low?, high?): return "\(number(low)) to \(number(high))"
        case let (low?, nil): return "\(number(low)) or more"
        case let (nil, high?): return "\(number(high)) or less"
        case (nil, nil): return ""
        }
    }

    /// How a minimum reads on its own: `5 or more`, `0 or more`.
    public static func minimumText(_ minimum: Double) -> String {
        rangeText(minimum: minimum, maximum: nil)
    }

    private static func number(_ value: Double) -> String {
        let whole = value.rounded()
        return whole == value ? String(Int(whole)) : String(value)
    }
}
