import Foundation

/// The interface's strings, looked up in the app bundle and falling back to the English literal
/// written at the call site (#161).
///
/// **The English sentence is the key.** `swift test` and `swift run` load no `.lproj` at all —
/// SwiftPM resource bundles are not used here — so every lookup outside the built `.app` misses,
/// and a helper that returned the key on a miss has to return correct English. It does: the key
/// *is* the English, and `value:` repeats it so a `.strings` file with the key commented out
/// behaves the same way. The CLI, the test suite and a `swift run` app therefore print exactly
/// what they printed before this type existed, byte for byte, with no bundle anywhere in sight.
///
/// **Only the interface.** Reports, timeline text, model prompts, log lines, CLI output and
/// anything written to the database stay English — they are read by models, by golden fixtures
/// and by a developer, not by a person choosing a language in System Settings. For most of those
/// it is by construction, but the CLI needs care: the installed `worklens` is a symlink into
/// `Worklens.app/Contents/MacOS/Worklens`, so `Bundle.main` there *is* the app bundle and a
/// lookup would find the catalogs. A CLI printer must therefore reach for the stable spelling
/// (a `rawValue`, a slug) and never for a `title` that went through this type.
/// `REPORT_LANGUAGE` (#157) is the separate, complementary half: it tells the report model which
/// language to *write* in. This type decides which language the *menu* is in.
///
/// **Adding a language** is `CONTRIBUTING.md` → "Add a language": copy `Resources/en.lproj` and
/// translate the right-hand sides. `make lint-strings` checks the catalogs.
public enum L10n {
    /// The one table. `Localizable.strings` and `Localizable.stringsdict` are merged into it by
    /// CFBundle, which is why `plural` can look its format up through the same call.
    public static let table = "Localizable"

    /// A user-visible string. `key` is the English sentence; `value` overrides the fallback only
    /// when the key had to be shortened or disambiguated.
    ///
    /// - Parameters:
    ///   - key: the English sentence, which is also the key in `Localizable.strings`.
    ///   - value: the English to fall back to when no bundle answers. Defaults to `key`.
    ///   - comment: what a translator needs to know. Not read at runtime; `strings-extract.sh`
    ///     carries it into the catalog.
    public static func string(_ key: String, value: String? = nil, comment: String = "") -> String {
        Bundle.main.localizedString(forKey: key, value: value ?? key, table: table)
    }

    /// A user-visible string with `%@`/`%lld` holes in it, so a translator can move the pieces.
    public static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    /// A counted noun. `one` and `other` are English format strings holding one `%lld`, and
    /// `other` doubles as the stringsdict key — the same "the English is the key" rule the rest
    /// of this type follows.
    ///
    /// The stringsdict is consulted first and used when a bundle answers; otherwise the English
    /// pair is picked here. Either way the count goes through the plain `String(format:)`, which
    /// groups no digits and so prints `1440` whatever the running Mac's region is set to.
    /// `String.localizedStringWithFormat` would print `1.440` under a Brazilian locale, while the
    /// other half of the same row — `L10n.format("%lld summarized", …)` — never groups, so a
    /// bundled app rendered `Today: 1.440 screenshots · 1400 summarized`, one number grouped and
    /// the next not. The no-bundle branch is the one `swift test` and `swift run` take, and it is
    /// why `Today: 1 screenshot` stays correct under a catalog that only knows `%lld`.
    public static func plural(count: Int, one: String, other: String) -> String {
        let missing = "\u{1}wl-missing\u{1}"
        let found = Bundle.main.localizedString(forKey: other, value: missing, table: table)
        guard found != missing else {
            return String(format: count == 1 ? one : other, count)
        }
        return String(format: found, count)
    }
}
