import AppKit
import SwiftUI
import WorklensCore

/// The one place Worklens decides what a status looks like and how wide a column is (#109).
///
/// Rules for anything added here:
/// * A token earns its place by having call sites. This file is a vocabulary, not a wish list —
///   it is meant to stay under a screen, or it becomes the smell it was written to remove.
/// * `Layout` and `Typography` are plain `CGFloat`, so the `NSView`-backed hotkey recorder in
///   `PrivacySettingsView` can use the same numbers as the SwiftUI views.
/// * Colours come from `StatusLevel` (WorklensCore) and from the system's semantic colours — no
///   asset catalogue and no hard-coded hex, so light and dark both follow macOS, and the hotkey
///   recorder keeps using `NSColor.controlAccentColor` so it follows the user's chosen accent.
///
/// Documented in `docs/architecture.md`; new UI pulls from here rather than inventing a literal.
enum Theme {
    enum Colors {
        /// The colour of a status, everywhere. See `StatusLevel` for what each case means.
        static func status(_ level: StatusLevel) -> Color {
            switch level {
            case .ok: return .green
            case .attention: return .orange
            case .problem: return .red
            case .neutral: return .primary
            case .muted: return .secondary
            }
        }
    }

    enum Symbols {
        /// The SF Symbol for a status, everywhere. Colour alone is not a status (#133): the
        /// meaning lives on `StatusLevel` in WorklensCore, where it is tested, and this is the
        /// one place the UI asks for it.
        static func status(_ level: StatusLevel) -> String { level.symbolName }
    }

    /// What a piece of text *is*, not what size it is (#237). Every role is a system text style
    /// plus a weight and never a point size, so all of it follows the user's text size for free —
    /// which a hand-set 11-point font never does. `scripts/design-lint.sh` counts the ones left.
    ///
    /// Colour is not part of a `Font`: `sectionHeader` and `metadata` are drawn
    /// `.foregroundStyle(.secondary)` at their call sites, the way they already were.
    enum Text {
        /// The one sentence a window or a banner opens with.
        static let statusTitle: Font = .callout.weight(.semibold)
        /// The text of a row.
        static let rowBody: Font = .callout
        /// The label above a group. Drawn secondary.
        static let sectionHeader: Font = .caption.weight(.semibold)
        /// A time, a count, a filename under a row. Drawn secondary.
        static let metadata: Font = .caption
    }

    /// The two containers, so the material and the corner stop being copy-pasted (#237). Both
    /// take their radius from `Layout.cornerRadius` and their stroke from a system semantic
    /// colour, so light and dark follow macOS with no asset catalogue.
    enum Surface {
        /// The raised block a tile or an empty state sits on.
        struct Card: ViewModifier {
            var padding: CGFloat = Space.section

            func body(content: Content) -> some View {
                content
                    .padding(padding)
                    .background(.background.secondary, in: shape)
                    .overlay(shape.strokeBorder(.separator, lineWidth: 1))
            }
        }

        /// The recessed container a list sits in.
        struct Panel: ViewModifier {
            var padding: CGFloat = Space.row

            func body(content: Content) -> some View {
                content
                    .padding(padding)
                    .background(.quaternary.opacity(0.4), in: shape)
            }
        }

        /// A card or a panel.
        static var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
        }
    }

    /// Two durations and one curve, so a hover and a disclosure do not each invent their own
    /// timing (#237). Nothing here is decorative: `quick` is a state settling, `reveal` is
    /// something appearing.
    enum Motion {
        /// A hover or a press settling.
        static let quick: Animation = .easeOut(duration: 0.12)
        /// A disclosure, a row appearing.
        static let reveal: Animation = .easeOut(duration: 0.22)

        /// `nil` under Reduce Motion, which is how SwiftUI is told to change the value with no
        /// animation at all.
        static func animation(reduceMotion: Bool, _ animation: Animation = quick) -> Animation? {
            reduceMotion ? nil : animation
        }
    }

    /// Gaps. `row` inside a row, `section` between the blocks of a tab, `pane` around a tab.
    enum Space {
        static let row: CGFloat = 6
        static let section: CGFloat = 14
        static let pane: CGFloat = 20
    }

    enum Layout {
        /// A text field or control sitting in a row. A base size: a view that keeps a width
        /// wraps it in `@ScaledMetric` so it grows with the user's text size (#133).
        static let field: CGFloat = 240
        /// The narrow gutter left where a column of timestamps or layer names still has to line
        /// up — Activity's clock, the provenance file list. Also `@ScaledMetric`'s base.
        static let labelColumnNarrow: CGFloat = 130
        /// A panel or a grouped list.
        static let cornerRadius: CGFloat = 8
    }

    /// The Settings window itself (#133). It is resizable now — `.windowResizability(
    /// .contentMinSize)` on the `Settings` scene — so these are a floor and a first guess, not
    /// a pin. The minimum is wider than the 580 pt the old fixed window used because the
    /// sidebar takes its share before the content sees any of it.
    enum SettingsWindow {
        /// Fixed, not a min/ideal/max: the sidebar is a plain `List` in an `HStack` now, with no
        /// split view to drag its divider. See `SettingsView.sidebar`.
        static let sidebarWidth: CGFloat = 190
        static let minWidth: CGFloat = 720
        static let idealWidth: CGFloat = 780
        static let minHeight: CGFloat = 560
        static let idealHeight: CGFloat = 640
    }

    /// The reader window (#134). Wider than Settings because the Weeks grid is seven columns wide.
    enum ReaderWindow {
        static let minWidth: CGFloat = 760
        static let idealWidth: CGFloat = 900
        static let minHeight: CGFloat = 520
        static let idealHeight: CGFloat = 700
        /// How wide a centred sentence on a status card is allowed to get before it stops being
        /// readable.
        static let cardWidth: CGFloat = 380
    }

    /// The welcome window (#131). Narrower than the reader — it is one column of prose and a
    /// handful of controls — and tall enough that page 1's four lists do not need scrolling on
    /// a laptop screen.
    enum SetupWindow {
        static let minWidth: CGFloat = 620
        static let idealWidth: CGFloat = 660
        static let minHeight: CGFloat = 520
        static let idealHeight: CGFloat = 640
    }

    enum Typography {
        /// Point size for AppKit text drawn inside a control. SwiftUI uses `.caption` and friends;
        /// only the hand-drawn recorder needs a number, and since #154 it takes
        /// `NSFont.systemFontSize` so it tracks the system text size rather than a hard 12.
        /// Named `Typography` rather than `Type` because `Theme.Type` already means Theme's own
        /// metatype.
        static var controlPointSize: CGFloat { NSFont.systemFontSize }
    }
}

/// `Theme.Surface` as the two modifiers everything actually calls.
extension View {
    /// The raised block a tile or an empty state sits on.
    func card(padding: CGFloat = Theme.Space.section) -> some View {
        modifier(Theme.Surface.Card(padding: padding))
    }

    /// The recessed container a list sits in.
    func panel(padding: CGFloat = Theme.Space.row) -> some View {
        modifier(Theme.Surface.Panel(padding: padding))
    }
}
