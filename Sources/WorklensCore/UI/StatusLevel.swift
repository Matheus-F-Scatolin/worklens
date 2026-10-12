import Foundation

/// What a status *means*, independent of how it is drawn. Every badge, dot and coloured number in
/// the app maps its own state onto one of these, and `Theme.Colors.status(_:)` in the `Worklens`
/// target is the single place that turns one into a colour — before #109 the same idea was mapped
/// privately in three views and inline in four more, so "not granted" was amber in one row and red
/// in the next.
///
/// `neutral` and `muted` are both non-status, and deliberately distinct: `neutral` is a
/// full-strength label (today's spend when it is nowhere near the budget) and `muted` is a greyed
/// one (an integration that is simply not configured). Collapsing them would grey out the numbers
/// on the Cost tab.
public enum StatusLevel: String, Sendable, Equatable, CaseIterable {
    /// Working, granted, connected.
    case ok
    /// Not wrong yet, but worth a look: near the budget, a permission that has not been asked for.
    case attention
    /// Broken: an error, a denied permission, spend over the budget.
    case problem
    /// No status to report; drawn at full strength.
    case neutral
    /// No status to report; drawn greyed, because the row is inactive.
    case muted
}

extension SpendLevel {
    /// How today's spend reads as a status. `nominal` is `neutral`, not `muted`: the figure is
    /// live, it just has nothing to warn about.
    public var level: StatusLevel {
        switch self {
        case .nominal: return .neutral
        case .warning: return .attention
        case .over: return .problem
        }
    }
}

public extension StatusLevel {
    /// The SF Symbol that carries this status when colour cannot (#133).
    ///
    /// Accessibility, not decoration: a green dot and a red dot are the same dot in greyscale,
    /// to a colour-blind reader, and to VoiceOver. Every symbol here has a distinct silhouette,
    /// so a status survives a screenshot with the colour taken out of it.
    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .neutral: return "circle.fill"
        case .muted: return "circle.dashed"
        }
    }
}
