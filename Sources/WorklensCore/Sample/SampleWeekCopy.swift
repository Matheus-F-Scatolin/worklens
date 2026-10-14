import Foundation

/// The words around the sample week (#349, #350). Second person, no dashes (`docs/copy.md`).
public enum SampleWeekCopy {
    /// The ribbon on the Today and Weeks pages while the sample is shown.
    public static var ribbon: String { L10n.string("Sample week: invented, not yours.") }

    /// The ribbon's button, and the VoiceOver name it is read by.
    public static var leave: String { L10n.string("Leave sample week") }

    /// The ribbon's status line once the welcome is finished and nothing is in the way.
    public static var firstMoments: String { L10n.string("Your first moments show up in about a minute.") }

    /// Settings → Advanced.
    public static var settingTitle: String { L10n.string("Sample week") }
    public static var settingDetail: String {
        L10n.string("An invented week to look around in. It is never sent to Claude.")
    }
    public static var show: String { L10n.string("Show sample week") }

    /// The one notification, on your first real summary.
    public static var startedTitle: String { L10n.string("Your day has started.") }
    public static var startedBody: String {
        L10n.string("The sample week is gone. Your own day is on the Today page: choose Open Worklens in the menu bar.")
    }

    /// The same notification's body when there is a summary to quote: the proof that capture,
    /// Screen Recording and the Gemini key all work, in the words the timeline will use. A click
    /// opens the Today page. Without a quotable summary (none, or marked sensitive), the plain
    /// body above.
    public static func startedBody(quoting summary: String?) -> String {
        guard let quote = quotable(summary) else { return startedBody }
        return L10n.format("Worklens summarized your first screenshot: “%@” Click to open the Today page.", quote)
    }

    /// The longest summary a banner quotes. macOS cuts a banner at a few lines anyway; this keeps
    /// the click hint from being the part that is cut.
    static let quoteLimit = 160

    /// A stored summary as a banner can show it: one line, no Markdown marks, no dashes, and at
    /// most `quoteLimit` characters, cut at a word. Nil when nothing is left, and nil when the
    /// model quoted a web address: a banner sits on screen and in Notification Center for anyone
    /// to read, so a summary that names one is not quoted at all.
    static func quotable(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let lowered = summary.lowercased()
        guard !lowered.contains("://"), !lowered.contains("www.") else { return nil }
        let plain = NoEmDash.replaced(summary)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        guard plain.count > quoteLimit else { return plain }
        let head = plain.prefix(quoteLimit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}
