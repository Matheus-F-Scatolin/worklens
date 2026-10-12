import CoreGraphics
import Foundation

/// The geometry of the spotlight tour (#351), as pure functions so the awkward cases are tested
/// rather than looked at: an anchor that is missing, off screen or a sliver; a card with no room
/// beside its hole; a status item behind the notch.
///
/// In-window rectangles are in the overlay's own coordinate space, origin top left. The panel
/// under the status item is in AppKit screen coordinates, origin bottom left.
public enum TourLayout {
    /// How far the cut-out stands off the view it is around.
    public static let holePadding: CGFloat = 8
    /// The least the card and the cut-out keep from the container's edges.
    public static let edgeMargin: CGFloat = 12
    /// The space between the cut-out and the card beside it.
    public static let gap: CGFloat = 14
    /// A cut-out smaller than this on either side is not worth pointing at, and the stop is
    /// drawn as a centred card instead.
    public static let smallestHole: CGFloat = 16

    /// The cut-out around `anchor`, or nil when there is nothing to cut out — the anchor is
    /// missing, empty, or outside the container — in which case the stop is a centred card.
    ///
    /// Clipped to the container: the week's grid is taller than the window, and a hole that runs
    /// off its edge would leave the card nowhere to sit.
    public static func hole(for anchor: CGRect?, in container: CGRect) -> CGRect? {
        guard let anchor, !anchor.isNull, !anchor.isInfinite,
            anchor.width > 0, anchor.height > 0
        else { return nil }
        let padded = anchor.insetBy(dx: -holePadding, dy: -holePadding)
        let clipped = padded.intersection(container.insetBy(dx: edgeMargin / 2, dy: edgeMargin / 2))
        guard !clipped.isNull, clipped.width >= smallestHole, clipped.height >= smallestHole
        else { return nil }
        return clipped
    }

    /// How far the click ring stands off the control a waiting stop asks you to click: inside
    /// the cut-out, hugging the control, so it reads as "this one" rather than as the hole's edge.
    public static let ringPadding: CGFloat = 3

    /// The terracotta ring the Weeks step draws around the rail button (#357 second pass), from
    /// the button's own bounds, so it sits on the button whatever the window's size. Nil whenever
    /// the step has no cut-out to draw it in.
    public static func clickRing(for anchor: CGRect?, in container: CGRect) -> CGRect? {
        guard let anchor, hole(for: anchor, in: container) != nil else { return nil }
        return anchor.insetBy(dx: -ringPadding, dy: -ringPadding)
    }

    /// Where the card's top-left corner goes.
    ///
    /// Beside the hole when there is room — trailing, then below, above and leading — and kept
    /// inside the container along the other axis. A hole that leaves room on no side (the week
    /// grid fills the page) puts the card wherever, kept on screen, it covers the least of the
    /// hole, the bottom-trailing corner when that is a tie (#357: the card must not sit on the
    /// bar the moment stop opens). No hole at all is the centred card.
    ///
    /// `prefersVertical` tries below and above first: the moment stop's tooltip opens to the
    /// right of its bar, and a card there would cover what the stop asks you to look at.
    public static func cardOrigin(
        card: CGSize, hole: CGRect?, in container: CGRect, prefersVertical: Bool = false
    ) -> CGPoint {
        let inner = container.insetBy(dx: edgeMargin, dy: edgeMargin)
        guard let hole else {
            return CGPoint(x: container.midX - card.width / 2, y: container.midY - card.height / 2)
        }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, inner.minX), inner.maxX - card.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, inner.minY), inner.maxY - card.height) }

        let trailing = CGPoint(x: hole.maxX + gap, y: clampY(hole.midY - card.height / 2))
        let below = CGPoint(x: clampX(hole.midX - card.width / 2), y: hole.maxY + gap)
        let above = CGPoint(x: clampX(hole.midX - card.width / 2), y: hole.minY - gap - card.height)
        let leading = CGPoint(x: hole.minX - gap - card.width, y: clampY(hole.midY - card.height / 2))
        let candidates = prefersVertical
            ? [below, above, trailing, leading]
            : [trailing, below, above, leading]
        for origin in candidates {
            let frame = CGRect(origin: origin, size: card)
            if inner.contains(frame) { return origin }
        }
        // No side has room: of the corner and each side pushed back on screen, the one that
        // covers the least of the hole.
        let corner = CGPoint(x: inner.maxX - card.width, y: inner.maxY - card.height)
        func covered(_ origin: CGPoint) -> CGFloat {
            let overlap = CGRect(origin: origin, size: card).intersection(hole)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let kept = ([corner] + candidates.map { CGPoint(x: clampX($0.x), y: clampY($0.y)) })
        return kept.min { covered($0) < covered($1) } ?? corner
    }

    // MARK: - The menu-bar ring

    /// The status item's frame when it is really on screen, or nil when the tour should say how
    /// to get back in instead.
    ///
    /// - Parameters:
    ///   - frame: the frame of the window the status item's button lives in, or nil when there is
    ///     no such window.
    ///   - isVisible: whether that window is on screen and not occluded. macOS keeps the window
    ///     of an item a full menu bar has pushed out, and stops drawing it.
    ///   - screen: the frame of the screen the item is on.
    ///   - leftOfNotch / rightOfNotch: `NSScreen.auxiliaryTopLeftArea` and
    ///     `auxiliaryTopRightArea`, nil on a screen with no notch. An item between them is behind
    ///     the notch.
    public static func menuBarItem(
        frame: CGRect?,
        isVisible: Bool,
        screen: CGRect?,
        leftOfNotch: CGRect? = nil,
        rightOfNotch: CGRect? = nil
    ) -> CGRect? {
        guard let frame, isVisible, let screen, frame.width > 0, frame.height > 0 else { return nil }
        guard screen.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        if let left = leftOfNotch, let right = rightOfNotch, left.maxX < right.minX {
            if frame.maxX > left.maxX, frame.minX < right.minX { return nil }
        }
        return frame
    }

    /// The panel under the status item: centred on it, kept on the screen, `gap` below it.
    /// AppKit coordinates, so "below" is a smaller y.
    public static func panelFrame(item: CGRect, panel: CGSize, screen: CGRect) -> CGRect {
        let minX = screen.minX + edgeMargin
        let maxX = screen.maxX - edgeMargin - panel.width
        let x = min(max(item.midX - panel.width / 2, minX), max(minX, maxX))
        let y = item.minY - gap / 2 - panel.height
        return CGRect(x: x, y: y, width: panel.width, height: panel.height)
    }

    /// Where the panel's arrow points, measured from the panel's leading edge, kept clear of
    /// its rounded corners.
    public static func arrowOffset(item: CGRect, panel: CGRect, inset: CGFloat = 20) -> CGFloat {
        min(max(item.midX - panel.minX, inset), max(inset, panel.width - inset))
    }
}
