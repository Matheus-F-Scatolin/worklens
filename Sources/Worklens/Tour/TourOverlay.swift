import SwiftUI
import WorklensCore

/// The tour over the reader window (#351): everything dimmed and blurred but one rounded cut-out
/// around the current stop, and the card beside it.
///
/// The cut-out is an even-odd mask, so the stop shows through untouched and stays live under the
/// pointer: on the step that asks you to open Weeks, the click inside it reaches the rail button
/// (#357). Everything else is behind a layer that takes the clicks, so the tour cannot be lost
/// by a stray one. The hole moves between stops with the
/// card, and jumps under Reduce Motion.
struct TourOverlay: View {
    @ObservedObject var tour: TourController
    let anchors: [TourStop: [Anchor<CGRect>]]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 320
    @State private var cardHeight: CGFloat = 180

    var body: some View {
        if let state = tour.state {
            GeometryReader { proxy in
                let container = CGRect(origin: .zero, size: proxy.size)
                let stop = state.stop
                let anchor = stop.hasAnchor ? Self.bounds(anchors[stop], in: proxy) : nil
                let hole = TourLayout.hole(for: anchor, in: container)
                let ring = stop.drawsClickRing ? TourLayout.clickRing(for: anchor, in: container) : nil
                // The ring's own stop is explained in the panel under it; the window only dims.
                let cardHere = stop.isInsideWindow || !tour.menuBarFound
                let card = CGSize(width: cardWidth, height: cardHeight)
                let origin = TourLayout.cardOrigin(
                    card: card, hole: hole, in: container, prefersVertical: stop == .moment
                )
                ZStack(alignment: .topLeading) {
                    TourScrim(hole: hole, container: container)
                    if let ring {
                        // Keyed by the stop, so coming back to the step draws the ring again.
                        TourClickRing(ring: ring)
                            .id(stop)
                            .transition(.opacity)
                    }
                    if cardHere {
                        TourCard(tour: tour, state: state)
                            .frame(width: cardWidth)
                            .background(
                                GeometryReader { measured in
                                    Color.clear.preference(
                                        key: TourCardHeightKey.self, value: measured.size.height)
                                }
                            )
                            .offset(x: origin.x, y: origin.y)
                    }
                }
                .animation(
                    Theme.Motion.animation(reduceMotion: reduceMotion, TourOverlay.move),
                    value: stop
                )
                .animation(
                    Theme.Motion.animation(reduceMotion: reduceMotion, TourOverlay.move),
                    value: hole
                )
                // Keyed by the stop too: two stops in a row that both find their view would
                // otherwise not tell the controller the second one did.
                .onChange(of: "\(stop.rawValue)|\(hole != nil)", initial: true) { _, _ in
                    tour.anchorMeasured(hole != nil)
                }
            }
            .onPreferenceChange(TourCardHeightKey.self) { cardHeight = $0 }
            .transition(.opacity)
            .onDisappear { tour.hostWentAway() }
        }
    }

    /// Every view tagged with the stop, as one rectangle; nil when none is on screen.
    private static func bounds(_ anchors: [Anchor<CGRect>]?, in proxy: GeometryProxy) -> CGRect? {
        guard let anchors, let first = anchors.first else { return nil }
        return anchors.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
    }

    /// The cut-out sliding from one stop to the next.
    static let move: Animation = .easeInOut(duration: 0.32)
}

/// The ring around the control a waiting step asks you to click (#357 second pass): a terracotta
/// rounded square that draws itself round the Weeks button, then pulses gently until the click
/// moves the tour on. Under Reduce Motion it is drawn whole and stays still.
///
/// Placed from the button's own bounds on every layout pass (`TourLayout.clickRing`), so it
/// follows the button when the window is resized. It takes no clicks: they go to the button.
struct TourClickRing: View {
    let ring: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var pulsing = false

    var body: some View {
        TourClickRingShape(drawn: reduceMotion ? 1 : drawn, pulse: reduceMotion ? 0 : (pulsing ? 1 : 0))
            .frame(width: ring.width, height: ring.height)
            .position(x: ring.midX, y: ring.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear(perform: start)
            .onChange(of: reduceMotion) { _, _ in start() }
    }

    private func start() {
        pulsing = false
        guard !reduceMotion else {
            drawn = 1
            return
        }
        drawn = 0
        withAnimation(Self.draw) {
            drawn = 1
        } completion: {
            withAnimation(Self.pulse) { pulsing = true }
        }
    }

    /// The stroke going round once, from nothing to a closed square.
    static let draw: Animation = .easeInOut(duration: 0.9)
    /// A slow breath, out and back, until the click.
    static let pulse: Animation = .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
}

/// The ring itself at one moment: `drawn` of its stroke (0 to 1) and `pulse` of the way out to
/// its widest, faintest point (0 to 1). Split from the animation so a still frame can be drawn.
struct TourClickRingShape: View {
    var drawn: CGFloat
    var pulse: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: ReaderTheme.Radius.card, style: .continuous)
            .trim(from: 0, to: drawn)
            .stroke(ReaderTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .scaleEffect(1 + 0.07 * pulse)
            .opacity(Double(1 - 0.45 * pulse))
    }
}

/// The dim and the blur, with the hole cut out of both.
private struct TourScrim: View {
    let hole: CGRect?
    let container: CGRect

    /// No hole is a hole of no size in the middle, so the cut-out shrinks into the centre and
    /// grows out of it rather than appearing from the corner.
    private var cut: CGRect {
        hole ?? CGRect(x: container.midX, y: container.midY, width: 0, height: 0)
    }

    var body: some View {
        let shape = TourCutout(hole: cut, cornerRadius: ReaderTheme.Radius.panel)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(TourOverlayStyle.dim)
        }
        .mask(shape.fill(style: FillStyle(eoFill: true)))
        // Clicks outside the hole stop here; clicks inside it reach the stop.
        .contentShape(shape, eoFill: true)
        .onTapGesture {}
        .accessibilityHidden(true)
    }
}

/// A rectangle with a rounded hole in it, the hole animatable.
struct TourCutout: Shape {
    var hole: CGRect
    var cornerRadius: CGFloat

    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 0, hole.height > 0 {
            path.addRoundedRect(
                in: hole,
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                style: .continuous
            )
        }
        return path
    }
}

private struct TourCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 180 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum TourOverlayStyle {
    /// Over the blur, so the page reads as set back in both appearances.
    static let dim = Color.black.opacity(0.28)
    static let cardShadow = Color.black.opacity(0.18)
}
