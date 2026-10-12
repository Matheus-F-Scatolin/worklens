import SwiftUI
import WorklensCore

// MARK: - Page 1: light or dark

/// The welcome window's first page (#357 second pass): light, dark or the Mac's own, as three
/// large cards with a small drawing of Worklens on each.
///
/// Light is first and already ringed in terracotta, and a new install is already showing it
/// (`AppearanceChoice.firstRunDefault`), so the obvious answer costs one click or one Return.
/// Clicking a card applies it at once — the same `app_state` row Settings → General writes —
/// and goes on to the next page. The arrow keys move the ring; Return is the footer's Continue,
/// which picks the ringed card.
struct SetupAppearancePage: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AppearanceChoice
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            HStack(spacing: Theme.Space.section) {
                ForEach(AppearanceChoice.cards, id: \.self) { choice in
                    SetupAppearanceCard(choice: choice, isSelected: choice == selection) {
                        selection = choice
                        model.chooseSetupAppearance(choice)
                    }
                }
            }
            Text(SetupAppearanceCopy.keys)
                .font(Theme.Text.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.pane)
        // Centred in the page, so the three cards are the page rather than its top half.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            selection = selection.moved(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selection = selection.moved(by: 1)
            return .handled
        }
        .onAppear {
            selection = model.setupAppearancePreselection
            focused = true
        }
    }
}

/// The page's few words, kept together so the strings catalogue has one place to look.
enum SetupAppearanceCopy {
    static let keys = String(localized: "Click one to go on. The arrow keys move the ring, and Return picks the ringed one.")
    static let lightNote = String(localized: "Bright all day")
    static let darkNote = String(localized: "Dark all day")
    static let systemNote = String(localized: "Follows your Mac")

    static func note(_ choice: AppearanceChoice) -> String {
        switch choice {
        case .light: lightNote
        case .dark: darkNote
        case .system: systemNote
        }
    }
}

/// One card: the drawing, the name and a short note, with the terracotta ring when it is the
/// ringed one and a faint one under the pointer.
struct SetupAppearanceCard: View {
    let choice: AppearanceChoice
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.section) {
                AppearancePreview(choice: choice)
                    .frame(height: 200)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(choice.name)
                        .font(Theme.Text.statusTitle)
                    Text(SetupAppearanceCopy.note(choice))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.section)
            .frame(maxWidth: .infinity)
            .background(.background.secondary, in: Theme.Surface.shape)
            .overlay(ring)
            .contentShape(Theme.Surface.shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: isSelected)
        .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel(choice.name)
        .accessibilityHint(SetupAppearanceCopy.note(choice))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var ring: some View {
        if isSelected {
            Theme.Surface.shape.strokeBorder(ReaderTheme.accent, lineWidth: 2.5)
        } else if hovering {
            Theme.Surface.shape.strokeBorder(ReaderTheme.accent.opacity(0.4), lineWidth: 1.5)
        } else {
            Theme.Surface.shape.strokeBorder(.separator, lineWidth: 1)
        }
    }
}

/// A small Worklens window in one appearance: the rail down the side, a heading and four bars
/// in the Weeks page's app colours. System is the two cut on the diagonal. Drawn in fixed colours
/// — `ReaderTheme`'s two sides — so each card shows its own appearance whatever the window is in.
struct AppearancePreview: View {
    let choice: AppearanceChoice

    var body: some View {
        switch choice {
        case .light: MiniWindow(palette: .light)
        case .dark: MiniWindow(palette: .dark)
        case .system:
            ZStack {
                MiniWindow(palette: .light)
                MiniWindow(palette: .dark).mask(LowerDiagonal())
            }
        }
    }
}

private struct MiniWindow: View {
    let palette: PreviewPalette

    /// Today's bars, longest first, in the colours Claude Desktop, the browser, Codex and Google
    /// Calendar get on your own days and the sample's alike (#357).
    private static let bars: [(fraction: CGFloat, hex: UInt32)] = [
        (0.92, AppPalette.hex(forApp: "Claude Desktop", key: "claude_desktop")),
        (0.66, AppPalette.hex(forApp: "Web browser", key: "browser")),
        (0.44, AppPalette.hex(forApp: "Codex", key: "codex_desktop")),
        (0.26, AppPalette.hex(forApp: "Google Calendar", key: "gcal")),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ReaderTheme.Radius.field, style: .continuous)
        HStack(spacing: 0) {
            VStack(spacing: 7) {
                HStack(spacing: 2.5) {
                    ForEach([0xEE6A5F, 0xF5BF4F, 0x61C454] as [UInt32], id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 4.5, height: 4.5)
                    }
                }
                .padding(.bottom, 3)
                RoundedRectangle(cornerRadius: ReaderTheme.Radius.bar)
                    .fill(ReaderTheme.accent.opacity(0.85))
                    .frame(width: 12, height: 12)
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: ReaderTheme.Radius.bar)
                        .fill(palette.faint)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.top, 6)
            .frame(width: 32)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette.rail)
            GeometryReader { proxy in
                let width = proxy.size.width
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(palette.text).frame(width: width * 0.4, height: 6)
                    Capsule().fill(palette.faint).frame(width: width * 0.25, height: 4)
                        .padding(.bottom, 4)
                    ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                        RoundedRectangle(cornerRadius: ReaderTheme.Radius.bar)
                            .fill(Color(hex: bar.hex))
                            .frame(width: width * bar.fraction, height: 11)
                    }
                }
            }
            .padding(12)
            .background(palette.canvas)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.line, lineWidth: 1))
    }
}

/// The two sides of `ReaderTheme`'s canvas, rail, text, faint and line colours.
private struct PreviewPalette {
    let canvas: Color
    let rail: Color
    let text: Color
    let faint: Color
    let line: Color

    static let light = PreviewPalette(
        canvas: Color(hex: 0xFAF9F5), rail: Color(hex: 0xF0EEE6), text: Color(hex: 0x141413),
        faint: Color(hex: 0xD3CFC3), line: Color(hex: 0xD3CFC3))
    static let dark = PreviewPalette(
        canvas: Color(hex: 0x262624), rail: Color(hex: 0x1F1E1D), text: Color(hex: 0xF5F4EE),
        faint: Color(hex: 0x4A4945), line: Color(hex: 0x3A3936))
}

/// The half of a rectangle below the diagonal from its top-right corner to its bottom-left one.
private struct LowerDiagonal: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
