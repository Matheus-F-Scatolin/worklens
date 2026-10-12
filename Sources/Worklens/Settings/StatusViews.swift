import SwiftUI
import WorklensCore

// #286: what is left of the old Settings window's shared views — the two the welcome window and
// the Connections setup sheet still draw. The window itself, its `SettingsForm` and its panes are
// gone; Settings is `SettingsPage` in the reader now.

/// A message the reader is expected to act on.
///
/// `.callout` and a full-strength colour, with a symbol in front: an instruction set in
/// `.caption2` and `.tertiary` reads as a disclaimer, which is how several of them went unread.
/// Prose that is merely context belongs in a `Section` footer instead, where the grouped form
/// already sets it small and secondary.
struct SettingsNote: View {
    let text: String
    var level: StatusLevel = .neutral

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: Theme.Symbols.status(level))
                .foregroundStyle(Theme.Colors.status(level))
        }
        .font(.callout)
        .foregroundStyle(level == .neutral ? .primary : Theme.Colors.status(level))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A status: a symbol, a colour and a word.
///
/// The symbol is the accessible half. A green dot and a red dot are the same dot in greyscale
/// and to VoiceOver, so every level now carries a distinct SF Symbol (`StatusLevel.symbolName`,
/// tested in WorklensCore) and the badge reads as a single element. `subject` is whatever has to
/// be spoken *before* the text: usually the thing the status is about — "Screen Recording:
/// Granted" rather than a bare "Granted" — and, where the visible text is already the subject
/// (a diagnostics row names its own check), the status word instead, so the symbol's meaning
/// survives into speech. Leave it off when the text alone reads correctly.
///
/// Whatever it is, it belongs here rather than in an `.accessibilityLabel` around the badge: this
/// label sits closer to the view, so an outer one would never be read.
struct StatusBadge: View {
    /// The three answers a yes/no check has, for a row that has to decide the level here. A view
    /// whose state already carries a `StatusLevel` that WorklensCore decided and tested passes
    /// that one instead (#135): re-deriving it in the view is how a row came to draw a grey icon
    /// and an orange badge for the same fact.
    enum Level {
        case good, bad, unknown

        var level: StatusLevel {
            switch self {
            case .good: return .ok
            case .bad: return .problem
            case .unknown: return .attention
            }
        }
    }

    let level: StatusLevel
    let text: String
    var subject: String?

    init(level: Level, text: String, subject: String? = nil) {
        self.init(level: level.level, text: text, subject: subject)
    }

    init(level: StatusLevel, text: String, subject: String? = nil) {
        self.level = level
        self.text = text
        self.subject = subject
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: Theme.Symbols.status(level))
                .foregroundStyle(Theme.Colors.status(level))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subject.map { "\($0): \(text)" } ?? text)
    }
}
