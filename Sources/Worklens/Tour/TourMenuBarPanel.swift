import AppKit
import SwiftUI
import WorklensCore

/// The tour's last stop, which is outside the window (#351): a small borderless panel with an
/// arrow, under the menu-bar ring.
///
/// Non-activating, so the reader window stays key and the tour's keys keep working. The ring is
/// a `MenuBarExtra`, so there is no `NSStatusItem` of Worklens's own to ask: its button lives in
/// an `NSStatusBarWindow`, and that window's frame is the item's. When there is no such window,
/// or macOS has stopped drawing it — a full menu bar, the notch — `show` answers false and the
/// card in the reader says how to get back in instead.
@MainActor
final class TourMenuBarPanel {
    private var panel: NSPanel?

    /// Puts the panel up under the ring. False when the ring cannot be found on screen.
    func show(tour: TourController) -> Bool {
        guard let (item, screen) = TourMenuBarPanel.statusItem() else {
            hide()
            return false
        }
        let host = NSHostingView(rootView: TourMenuBarCallout(tour: tour, arrowOffset: nil))
        let size = host.fittingSize
        let frame = TourLayout.panelFrame(item: item, panel: size, screen: screen)
        host.rootView = TourMenuBarCallout(
            tour: tour, arrowOffset: TourLayout.arrowOffset(item: item, panel: frame)
        )

        let panel = self.panel ?? TourMenuBarPanel.makePanel()
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        return true
    }

    /// Whether the ring is on screen right now, asked before `show` so the card the panel
    /// measures is the one it will draw.
    var ringIsOnScreen: Bool { TourMenuBarPanel.statusItem() != nil }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// The ring's frame and its screen's, when it is drawn where someone can see it.
    private static func statusItem() -> (CGRect, CGRect)? {
        guard
            let window = NSApp.windows.first(where: {
                String(describing: type(of: $0)).contains("NSStatusBarWindow")
            }),
            let screen = window.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        else { return nil }
        let found = TourLayout.menuBarItem(
            frame: window.frame,
            isVisible: window.isVisible && window.occlusionState.contains(.visible),
            screen: screen.frame,
            leftOfNotch: screen.auxiliaryTopLeftArea,
            rightOfNotch: screen.auxiliaryTopRightArea
        )
        return found.map { ($0, screen.frame) }
    }
}

/// The arrow and the card, as the panel draws them.
private struct TourMenuBarCallout: View {
    @ObservedObject var tour: TourController
    /// From the leading edge; nil while the panel is being measured.
    let arrowOffset: CGFloat?
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 300

    /// Room for the card's shadow either side, inside a panel that draws none of its own.
    static let margin: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TourArrow()
                .fill(ReaderTheme.surface)
                .frame(width: 18, height: 9)
                .offset(x: (arrowOffset.map { $0 - TourMenuBarCallout.margin } ?? cardWidth / 2) - 9)
            if let state = tour.state {
                TourCard(tour: tour, state: state)
            }
        }
        .frame(width: cardWidth)
        .padding(.horizontal, TourMenuBarCallout.margin)
        .padding(.bottom, 24)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A triangle pointing up at the ring.
private struct TourArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
