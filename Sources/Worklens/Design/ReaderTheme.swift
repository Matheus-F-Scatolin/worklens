import AppKit
import SwiftUI
import WorklensCore

/// The reader's tokens (reader redesign, 2026-09). The style copies the Claude desktop app: an
/// ivory canvas, a slightly darker rail, one terracotta accent, and colour used only as a label.
///
/// Every token is a dynamic `NSColor`, so light and dark follow the window's appearance with no
/// asset catalogue — the app has no SPM resources.
enum ReaderTheme {
    static let canvas = dynamic(light: 0xFAF9F5, dark: 0x262624)
    static let rail = dynamic(light: 0xF0EEE6, dark: 0x1F1E1D)
    /// Tooltips and meeting chips.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x30302E)
    static let text = dynamic(light: 0x141413, dark: 0xF5F4EE)
    static let muted = dynamic(light: 0x73726C, dark: 0xA6A39A)
    static let faint = dynamic(light: 0xA8A69E, dark: 0x75736C)
    static let line = dynamic(light: 0xE6E3DA, dark: 0x3A3936)
    static let active = dynamic(light: 0xE6E1D3, dark: 0x3A3935)
    static let accent = Color(hex: 0xD97757)
    static let totalBar = dynamic(light: 0x3D3D3A, dark: 0xE8E6DC)
    /// The page being left, while the next one is built.
    static let turningOpacity = 0.45
    /// Text on an app-coloured block, in both appearances.
    static let ink = Color(hex: AppPalette.ink)
    static let others = Color(hex: AppPalette.others)

    /// The date and week titles. New York, the system serif, is the bundled stand-in for the
    /// mock's Source Serif 4.
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }

    // #286: the rest of the settings prototype's `:root` block, light and dark.
    /// The Settings section list: a tone between the rail and the canvas. Also the Access card,
    /// the status line and the disclosures — the few things on those pages that are boxed.
    static let list = dynamic(light: 0xF5F4EE, dark: 0x222220)
    /// The accent as text: text buttons, the "needs a yes" pill.
    static let accentInk = dynamic(light: 0xB85C3E, dark: 0xE58F72)
    /// The accent as a wash: an inline confirm, a "needs a yes" pill, a lit row.
    static let accentSoft = dynamic(light: 0xF6E3DA, dark: 0x4A3129)
    static let ok = dynamic(light: 0x4E8A5A, dark: 0x86B88F)
    static let okSoft = dynamic(light: 0xE3EEDF, dark: 0x2C3A2D)
    /// A destructive button's text.
    static let warn = dynamic(light: 0xC0553A, dark: 0xE58F72)
    /// A switch that is off, a meter's track, a chart's bars.
    static let bar = dynamic(light: 0xD3CFC3, dark: 0x4A4945)
    /// Text fields and pickers.
    static let field = dynamic(light: 0xFFFFFF, dark: 0x1F1E1D)

    static let railWidth: CGFloat = 60
    /// The Today column.
    static let columnWidth: CGFloat = 760
    /// #286: the Settings section list, and the column a Settings page is set in.
    static let listWidth: CGFloat = 208
    static let settingsColumnWidth: CGFloat = 640
    static let tooltipShadow = Color.black.opacity(0.12)

    /// The corners the reader and Settings draw, by what they round.
    enum Radius {
        /// A bar in the Usage chart.
        static let bar: CGFloat = 2
        /// A legend swatch on the Weeks page.
        static let swatch: CGFloat = 3
        static let chip: CGFloat = 5
        static let tooltip: CGFloat = 6
        /// A block on the Weeks grid, and the focus ring around a Today bar.
        static let block: CGFloat = 6
        /// A block in the welcome tour page's drawing of the sample week.
        static let miniatureBlock: CGFloat = 3
        static let segment: CGFloat = 7
        static let field: CGFloat = 8
        static let railItem: CGFloat = 9
        static let panel: CGFloat = 10
        static let card: CGFloat = 12
    }

    /// The type sizes of the settings prototype, as roles (#286). Fixed points, like the rest of
    /// the reader: the window is drawn to the mock's measure.
    enum Size {
        static let pageTitle: Font = serif(32)
        static let listTitle: Font = serif(24)
        static let hero: Font = serif(44)
        static let rowTitle: Font = .system(size: 14)
        static let rowDetail: Font = .system(size: 12.5)
        static let groupLabel: Font = .system(size: 12.5, weight: .medium)
        static let control: Font = .system(size: 13)
        static let small: Font = .system(size: 12)
        static let chip: Font = .system(size: 11.5)
        /// The hour labels down the side of the Weeks grid.
        static let axis: Font = .system(size: 11)
        /// The symbol over an empty page.
        static let emptyGlyph: Font = .system(size: 28, weight: .light)
        static let railIcon: Font = .system(size: 16, weight: .light)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A tooltip card: a heading with its value on the right, then rows or a sentence. The waterfall
/// and the Weeks grid share it, so the two pages' hovers look the same.
struct ReaderTooltip: View {
    let title: String
    let value: String
    /// What you were doing, in a line or two under the heading (#357). Wrapped at a fixed
    /// width, so a long summary grows the tooltip downwards rather than across the page.
    var detail: String? = nil
    var rows: [(label: String, value: String)] = []
    var sentences: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(value).foregroundStyle(ReaderTheme.muted).monospacedDigit()
            }
            .font(ReaderTheme.Size.control)
            if let detail {
                Text(detail)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 230, alignment: .leading)
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 18) {
                            Text(row.label)
                            Spacer(minLength: 0)
                            Text(row.value).foregroundStyle(ReaderTheme.muted).monospacedDigit()
                        }
                    }
                }
            }
            ForEach(sentences, id: \.self) { Text($0).foregroundStyle(ReaderTheme.muted) }
        }
        .font(ReaderTheme.Size.rowDetail)
        .foregroundStyle(ReaderTheme.text)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(minWidth: 176, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: ReaderTheme.Radius.panel).fill(ReaderTheme.surface)
                .shadow(color: ReaderTheme.tooltipShadow, radius: 12, y: 6)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// The ‹ › pair around a serif title.
struct ReaderChevron: View {
    let systemName: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(ReaderTheme.Size.rowTitle.weight(.medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovered && enabled ? ReaderTheme.text : ReaderTheme.muted)
                .background(
                    RoundedRectangle(cornerRadius: ReaderTheme.Radius.segment)
                        .fill(hovered && enabled ? ReaderTheme.rail : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
