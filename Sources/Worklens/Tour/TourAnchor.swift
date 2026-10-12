import SwiftUI
import WorklensCore

/// The bounds of every view that is a tour stop, keyed by the stop (#351). A stop can be more
/// than one view: the moment stop is its bar and, while you point at it, the tooltip beside it,
/// and the cut-out goes around all of them.
///
/// Each stop is found through the real view it is about, never through coordinates, so a layout
/// change takes the cut-out with it. A stop whose view is not on screen is simply absent here,
/// and the overlay draws it as a centred card.
struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourStop: [Anchor<CGRect>]] { [:] }

    static func reduce(
        value: inout [TourStop: [Anchor<CGRect>]],
        nextValue: () -> [TourStop: [Anchor<CGRect>]]
    ) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

extension View {
    /// Marks this view as the place `stop` points at. Nil marks nothing, which is how a view
    /// drawn in a loop tags only one of its copies.
    ///
    /// Stops nest: `.timeline` sits on the waterfall chart and `.moment` on the bar
    /// `Waterfall.momentIndex` names. So this
    /// adds to what the views inside published rather than replacing it. `anchorPreference` would
    /// replace it: a standalone probe against MacOSX26.sdk (an outer and an inner tagged view under
    /// one `overlayPreferenceValue`) saw only `["timeline"]` with it, and `["moment", "timeline"]`
    /// with `transformAnchorPreference`, nil-tagged siblings included.
    func tourAnchor(_ stop: TourStop?) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { value, anchor in
            if let stop { value[stop, default: []].append(anchor) }
        }
    }

    /// Hangs the tour over this view: the dim, the cut-out and the card, reading the anchors
    /// every `tourAnchor` below it publishes. The reader window's root carries it.
    func tourOverlay(_ tour: TourController) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourOverlay(tour: tour, anchors: anchors)
        }
    }
}
