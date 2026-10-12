import SwiftUI
import WorklensCore

/// The card beside the cut-out (#351): where you are, a heading, one or two sentences, the keys
/// as caps where the stop is about keys, and Back / Next / Skip.
///
/// #357: Skip is only on a tour from Settings; the first run has none. On a step that asks you
/// to click a rail button, Next is gone while that button is cut out, and back when it is not.
///
/// The same card sits in the reader window and in the panel under the menu-bar ring. It takes
/// the accessibility focus whenever the stop changes, and `TourController` announces the stop.
struct TourCard: View {
    @ObservedObject var tour: TourController
    let state: TourState
    /// Opens the troubleshooting section about a missing menu-bar icon.
    var openHelp: () -> Void = { AppModel.shared.openTroubleshooting(.menuBarIconMissing) }
    @AccessibilityFocusState private var focused: Bool

    private var stop: TourStop { state.stop }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.counter)
                    .font(ReaderTheme.Size.small)
                    .monospacedDigit()
                    .foregroundStyle(ReaderTheme.muted)
                Spacer(minLength: 8)
                if state.allowsSkip {
                    Button(TourCopy.skip) { tour.skip() }
                        .buttonStyle(.plain)
                        .font(ReaderTheme.Size.small)
                        .foregroundStyle(ReaderTheme.muted)
                }
            }
            Text(stop.title)
                .font(ReaderTheme.serif(20))
                .foregroundStyle(ReaderTheme.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focused)
            Text(stop.body(keys: tour.keys, menuBarFound: tour.menuBarFound))
                .font(ReaderTheme.Size.control)
                .foregroundStyle(ReaderTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            let caps = stop.keyCaps(keys: tour.keys, menuBarFound: tour.menuBarFound)
            if !caps.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                        TourKeyCap(text: cap)
                    }
                }
                // The sentence above already names the shortcut; the caps are for the eye.
                .accessibilityHidden(true)
            }
            if stop.offersMenuBarHelp(menuBarFound: tour.menuBarFound) {
                Button(TourCopy.menuBarHelp, action: openHelp)
                    .buttonStyle(.link)
                    .font(ReaderTheme.Size.small)
            }
            HStack {
                Button(TourCopy.back) { tour.back() }
                    .disabled(state.isFirst)
                Spacer(minLength: 8)
                if state.canGoNext(anchorFound: tour.anchorFound) {
                    Button(state.nextLabel) { tour.next() }
                        .buttonStyle(.borderedProminent)
                        .tint(ReaderTheme.accent)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ReaderTheme.Radius.card, style: .continuous)
                .fill(ReaderTheme.surface)
                .shadow(color: TourOverlayStyle.cardShadow, radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ReaderTheme.Radius.card, style: .continuous)
                .strokeBorder(ReaderTheme.line)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TourCopy.cardLabel)
        .accessibilityAddTraits(.isModal)
        .onAppear { focused = true }
        .onChange(of: stop) { _, _ in focused = true }
    }
}

/// One key, drawn as a cap.
struct TourKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ReaderTheme.Size.control.weight(.medium))
            .foregroundStyle(ReaderTheme.text)
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: ReaderTheme.Radius.chip, style: .continuous)
                    .fill(ReaderTheme.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ReaderTheme.Radius.chip, style: .continuous)
                    .strokeBorder(ReaderTheme.line)
            )
    }
}
