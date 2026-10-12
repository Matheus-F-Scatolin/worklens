import Foundation

/// Which language the describe pass writes its summaries in (#157), and the one sentence that
/// tells the model.
///
/// The type keeps the `REPORT_LANGUAGE` key's name so an existing `.env` needs no migration; the
/// reports it was first written for were cut on 2026-10-05.
///
/// The default is `en`, and it is a *constant* rather than the current locale's language: a
/// default read from System Settings would make the describe prompt — and every snapshot test
/// that pins its bytes — depend on the machine that ran them. Until somebody sets
/// `REPORT_LANGUAGE=pt-BR`, the prompt is byte for byte what it has always been, because `rule`
/// returns nil for English.
///
/// Only the *prose* changes: keys, slugs, app names and identifiers stay in English, so the
/// timeline and the stats still line up.
public enum ReportLanguage {
    /// The default, and the one value that adds nothing to a prompt.
    public static let english = "en"

    /// True for the default, for an empty value, and for any other spelling of English.
    public static func isEnglish(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty || trimmed == english || trimmed.hasPrefix("en-")
            || trimmed.hasPrefix("en_")
    }

    /// `Portuguese (Brazil)` for `pt-BR`, and the code itself when Foundation has no name for it.
    public static func name(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "English" }
        let canonical = trimmed.replacingOccurrences(of: "_", with: "-")
        // The name is written in English because the sentence around it is: this is an
        // instruction to a model, not a label in the user's interface.
        return Format.fixed.localizedString(forIdentifier: canonical)
            ?? Format.fixed.localizedString(forLanguageCode: canonical)
            ?? trimmed
    }

    /// The one sentence appended to a system prompt, or nil when there is nothing to say.
    ///
    /// Nil for English is what keeps the acceptance test honest: with `REPORT_LANGUAGE` unset,
    /// `DescribePrompt`'s system instruction is unchanged, to the byte.
    public static func rule(_ code: String) -> String? {
        guard !isEnglish(code) else { return nil }
        return "Write the summary and every other free-text field in \(name(code)), "
            + "addressing the reader as \"you\". "
            + "Keep every key, slug, app name and identifier exactly as given, in English."
    }

    /// The same sentence appended to a system prompt, or the prompt unchanged.
    static func applied(to prompt: String, code: String) -> String {
        guard let rule = rule(code) else { return prompt }
        return prompt + "\n" + rule
    }
}
