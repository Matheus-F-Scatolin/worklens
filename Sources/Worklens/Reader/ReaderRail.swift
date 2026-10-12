import SwiftUI
import WorklensCore

/// The icon-only rail down the reader's left edge (reader redesign): Today, Weeks, and the
/// Settings gear at its foot.
struct ReaderRail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            lensMark
                .padding(.bottom, 12)
            ForEach(ReaderPlace.allCases) { place in
                ReaderRailItem(
                    symbolName: place.symbolName,
                    title: place.title,
                    isActive: model.settingsSection == nil && model.readerPlace == place,
                    badge: false,
                    accessibilityLabel: place.title
                ) {
                    // #286: a rail place always leaves Settings, whichever page it lands on.
                    model.closeSettings()
                    if place == .today { model.showToday() } else { model.show(place) }
                }
                // #357: the tour cuts this out and waits for you to click it.
                .tourAnchor(place == .weeks ? .openWeeks : nil)
            }
            Spacer(minLength: 0)
            // #286: Settings, at the rail's foot. Not a `ReaderPlace` — the two above stay the
            // reading places — and lit with only the soft square the places get, never a solid
            // terracotta tile. The dot is the needs-you dot the section list carries too.
            ReaderRailItem(
                symbolName: "gearshape",
                title: String(localized: "Settings", comment: "Rail item"),
                hint: "\u{2318},",
                isActive: model.settingsSection != nil,
                badge: model.settingsNeedsYou != nil,
                accessibilityLabel: model.settingsNeedsYou != nil
                    ? String(localized: "Settings, something needs you", comment: "VoiceOver")
                    : String(localized: "Settings", comment: "Rail item")
            ) {
                if model.settingsSection == nil { model.openSettings() }
            }
            .tourAnchor(.askClaude)
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(width: ReaderTheme.railWidth)
        .frame(maxHeight: .infinity)
        .background(ReaderTheme.rail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Worklens", comment: "VoiceOver"))
    }

    /// A ring and a dot, in the accent: the lens.
    private var lensMark: some View {
        ZStack {
            Circle().stroke(ReaderTheme.accent, lineWidth: 2.2).frame(width: 15, height: 15)
            Circle().fill(ReaderTheme.accent).frame(width: 5.2, height: 5.2)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

private struct ReaderRailItem: View {
    let symbolName: String
    let title: String
    /// The shortcut, beside the name in the hover label: Settings' ⌘,.
    var hint: String?
    let isActive: Bool
    let badge: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(ReaderTheme.Size.railIcon)
                .foregroundStyle(isActive || hovered ? ReaderTheme.text : ReaderTheme.muted)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: ReaderTheme.Radius.railItem)
                        .fill(isActive ? ReaderTheme.active : .clear)
                )
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(ReaderTheme.accent)
                            .frame(width: 6, height: 6)
                            .padding(8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        // The label beside the icon, the moment the pointer is on it: the rail carries no text of
        // its own, so waiting for the system tooltip's delay would leave every icon unnamed.
        .overlay(alignment: .leading) {
            if hovered {
                Text(hint.map { "\(title)  \($0)" } ?? title)
                    .font(ReaderTheme.Size.small)
                    .foregroundStyle(ReaderTheme.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: ReaderTheme.Radius.tooltip).fill(ReaderTheme.surface)
                            .shadow(color: ReaderTheme.tooltipShadow, radius: 8, y: 3)
                    )
                    .fixedSize()
                    .offset(x: 48)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: hovered)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
