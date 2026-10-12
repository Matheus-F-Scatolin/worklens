import CoreGraphics
import Foundation

/// The Worklens mark, drawn in code: one ring — the lens — that the app icon and every
/// menu-bar glyph are cut from.
///
/// Nothing here is an image asset. The package ships no SPM resources (`Bundle.module` is
/// unreliable in a hand-built `.app`), so the menu bar draws its glyphs at runtime and
/// `scripts/render-icon.sh` compiles *this same file* alongside `scripts/render-icon.swift`
/// to render `Resources/AppIcon.icns`. One file, both outputs.
///
/// CoreGraphics only, on purpose: `WorklensCore` stays free of AppKit and SwiftUI, and the
/// renderer stays a two-file `swiftc` invocation that needs no package build.
///
/// This deliberately replaces the `eye` / `eye.slash` symbols #15 chose
/// (`docs/issues/15-menu-bar-ui.md:34`). An eye is the surveillance metaphor this product
/// rejects, and four symbols could not tell eight scheduler states apart.
public enum WorklensMark {
    /// The directions drawn for the owner to judge. Switch the icon by changing `chosen` and
    /// running `make icon` — one line, no pipeline change.
    public enum Concept: String, CaseIterable, Sendable {
        /// The lens as the reader's rail draws it: a terracotta ring and dot on ivory — the
        /// recording mark. The chosen one since the reader redesign moved the app to that palette.
        case recording
        /// A lens ring over the bars of a day. The icon from #238 until the redesign.
        case lensTimeline
        /// A six-bladed aperture.
        case aperturePause
        /// A W drawn as a timeline.
        case wTimeline

        /// The colour the mark is drawn in over its tile.
        var markColor: CGColor {
            self == .recording ? Palette.terracotta : CGColor(gray: 1, alpha: 1)
        }
    }

    public static let chosen: Concept = .recording

    /// What sits inside the ring. One per thing the menu bar has to tell apart at a glance.
    public enum Badge: String, CaseIterable, Sendable {
        /// Capturing: the lens is open.
        case dot
        /// Over budget — capturing, not describing. An open centre, not a dollar badge: the
        /// menu already shows the spend, and this state is about frames, not money. The name is
        /// the contract with `MenuIcon.badge`; the drawing is a lens with the middle taken out.
        case hollow
        /// Paused by the user, with no end — it stays off until they say otherwise.
        case pause
        /// Paused with an end: it comes back by itself (#252). The same two bars, shorter, over
        /// a ring left open at the bottom the way a dial that is running down is.
        case pauseTimed
        /// Stopped: the lens struck through.
        case slash
        /// Idle, locked or asleep — nothing to record.
        case dash
        /// Something needs the user.
        case alert
    }

    // MARK: - The glyph

    /// The menu-bar glyph is designed on an 18 pt square, which is the height AppKit gives a
    /// status item's image.
    public static let glyphDesignSize: CGFloat = 18

    private static let center = CGPoint(x: 9, y: 9)
    /// The ring is padded in from the 18 pt square so the whole mark — the slash included —
    /// stays inside roughly 15 pt and sits *with* the system's own menu-bar items rather than
    /// filling the bar's height. Before #238 the ring alone was 15.2 pt across and `.slash`
    /// reached 18.5 pt, which is wider than the canvas it is drawn on.
    private static let ringRadius: CGFloat = 6.4
    private static let ringWidth: CGFloat = 1.7
    /// The ring's outer edge, and the widest anything but `.slash`'s round cap gets.
    static let ringOuterRadius: CGFloat = ringRadius + ringWidth / 2
    /// The ring's inner edge. Everything a badge draws stays well inside it.
    private static var innerRadius: CGFloat { ringRadius - ringWidth / 2 }

    /// Draws one glyph filled with the current fill/stroke colour, scaled to `size`.
    ///
    /// The caller owns the colour: a menu-bar template image is drawn in opaque black and
    /// tinted by AppKit, so the alpha channel is the shape.
    /// `busy` is a treatment over the badge, not a badge of its own (#252): a sync or a reload
    /// in progress must not replace the answer to "is Worklens watching?" for the minute it takes.
    /// Static, like everything else here — `MenuBarGlyph` draws once per `(badge, busy)` and
    /// keeps it, and nothing in the menu bar animates.
    public static func drawGlyph(
        _ badge: Badge, busy: Bool = false, in ctx: CGContext, size: CGFloat
    ) {
        ctx.saveGState()
        let scale = size / glyphDesignSize
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        strokeRing(in: ctx, gapDegrees: badge == .pauseTimed ? 120 : 0, centeredAt: 270)

        switch badge {
        case .dot:
            ctx.fillEllipse(in: square(around: center, radius: 2.4))
        case .hollow:
            // Not a thinner dot: a second ring, wide enough that the hole is the shape. At
            // 18 pt that is a 6.9 pt lens around a 4.8 pt opening, against `.dot`'s solid
            // 4.8 pt disc — the two cannot be told apart by squinting, which is the point.
            ctx.setLineWidth(1.1)
            ctx.strokeEllipse(in: square(around: center, radius: 2.95))
        case .pause, .pauseTimed:
            // The timed pause draws shorter bars as well as the open ring, so the two are told
            // apart by the shape inside the ring and not only by the gap under it.
            let height: CGFloat = badge == .pauseTimed ? 4.4 : 5.6
            for dx in [CGFloat(-1.5), 1.5] {
                ctx.addPath(bar(x: center.x + dx, y: center.y, width: 1.5, height: height))
            }
            ctx.fillPath()
        case .dash:
            ctx.addPath(bar(x: center.x, y: center.y, width: 5.0, height: 1.6))
            ctx.fillPath()
        case .alert:
            ctx.addPath(bar(x: center.x, y: center.y + 1.3, width: 1.6, height: 4.2))
            ctx.addEllipse(in: square(around: CGPoint(x: center.x, y: center.y - 2.5), radius: 0.9))
            ctx.fillPath()
        case .slash:
            // Cut a clear channel first, so the bar reads as a slash across the lens rather
            // than a chord drawn inside it — the same trick SF Symbols' `.slash` uses. The
            // reach clears the ring by a cap's width and no more, so the strike reads as a
            // strike without pushing the mark past the 18 pt canvas the way 5.9 did.
            let reach: CGFloat = 5.35
            let from = CGPoint(x: center.x - reach, y: center.y - reach)
            let to = CGPoint(x: center.x + reach, y: center.y + reach)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(ringWidth + 1.5)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
        }

        // Last, not before the badge: `.slash` clears a channel along the diagonal, and an arc
        // drawn earlier is cut in half by it.
        if busy { strokeBusyArc(in: ctx) }

        ctx.restoreGState()
    }

    private static func strokeRing(
        in ctx: CGContext, gapDegrees: CGFloat, centeredAt: CGFloat = 90
    ) {
        ctx.setLineWidth(ringWidth)
        let half = gapDegrees / 2
        let start = (centeredAt + half) * .pi / 180
        let end = (centeredAt - half + 360) * .pi / 180
        ctx.addArc(
            center: center, radius: ringRadius,
            startAngle: start, endAngle: end, clockwise: false
        )
        ctx.strokePath()
    }

    /// The busy treatment: one thin arc riding just outside the ring, at the top where no badge
    /// draws. Additive, so it composes with all seven badges without hiding any of them, and it
    /// stops at 8.8 pt — inside the 18 pt square, like everything else. It starts at 7.9, half a
    /// point clear of the ring's 7.25 outer edge: any closer and antialiasing welds the two
    /// together at 18 pt 1×, where busy then reads as nothing but a thicker ring.
    private static func strokeBusyArc(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.butt)
        ctx.addArc(
            center: center, radius: 8.35,
            startAngle: 30 * .pi / 180, endAngle: 150 * .pi / 180, clockwise: false
        )
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func square(around point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    /// A rounded bar centred on (`x`, `y`). Fully rounded ends, like every other stroke here.
    private static func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
        let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
        let radius = min(width, height) / 2
        return CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
    }

    // MARK: - The app icon

    /// A macOS app icon is drawn on a 1024 pt canvas. What sits on it is one container and
    /// nothing else — #238 removed the tile-inside-a-tile the old 100 pt inset and 185.4 pt
    /// corner drew, along with the white hairline that rang every edge of it.
    public static let iconDesignSize: CGFloat = 1024

    /// How much of the canvas the container fills. macOS 26 draws its own icons much closer to
    /// the edge than the 824 pt tile this app used to draw, and a legacy `.icns` is presented
    /// as it is authored — no mask, no rescale — so this is the one thing only a real Dock can
    /// settle. Both are rendered for that judgement (`render-icon.sh --candidates`).
    public enum Container: String, CaseIterable, Sendable {
        /// A: the squircle runs to the edge of the canvas, the way an Icon Composer asset does.
        case fullBleed
        /// B: the squircle keeps a 46 pt margin, so a legacy `.icns` lands at about the size
        /// the Dock gives the icons beside it instead of overhanging them. Shipped.
        case dockSafe

        var inset: CGFloat { self == .fullBleed ? 0 : 46 }
        var side: CGFloat { iconDesignSize - inset * 2 }
        var rect: CGRect { CGRect(x: inset, y: inset, width: side, height: side) }
        /// The mark keeps the proportion of the container it had on the old 824 pt tile.
        var markScale: CGFloat { side / 824 }
    }

    /// The container the committed `AppIcon.icns` is drawn with.
    public static let shippedContainer: Container = .dockSafe

    /// Draws the full app icon — container, gradient and mark — into `ctx` at `pixels` square.
    ///
    /// Below 64 px the lens's timeline bars turn to mud, so its small tiles get the ring and the
    /// dot alone. The recording mark is already just that, and draws the same at every size.
    public static func drawAppIcon(
        _ concept: Concept = chosen, container: Container = shippedContainer,
        in ctx: CGContext, pixels: CGFloat
    ) {
        ctx.saveGState()
        ctx.scaleBy(x: pixels / iconDesignSize, y: pixels / iconDesignSize)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        drawContainer(concept, container, in: ctx)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(concept.markColor)
        ctx.setFillColor(concept.markColor)
        let scale = container.markScale
        ctx.translateBy(x: pixels / 2, y: pixels / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -pixels / 2, y: -pixels / 2)
        drawMark(concept, in: ctx, pixels: pixels)
        ctx.restoreGState()
    }

    /// Draws the mark alone — no tile, and no colour of its own — into `ctx` at `pixels`
    /// square, in whatever fill and stroke colour the caller has already set.
    ///
    /// This is the half of the icon the social banner borrows (`render-icon.sh --banner`), so
    /// the banner cannot drift away from the app icon: there is one `drawRecording` and both
    /// of them call it.
    public static func drawMark(
        _ concept: Concept = chosen, in ctx: CGContext, pixels: CGFloat
    ) {
        ctx.saveGState()
        ctx.scaleBy(x: pixels / iconDesignSize, y: pixels / iconDesignSize)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if concept == .recording {
            drawRecording(in: ctx)
        } else if pixels < 64 {
            drawSimpleMark(in: ctx)
        } else {
            switch concept {
            case .recording: break
            case .lensTimeline: drawLensTimeline(in: ctx)
            case .aperturePause: drawAperture(in: ctx)
            case .wTimeline: drawWTimeline(in: ctx)
            }
        }
        ctx.restoreGState()
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func drawContainer(
        _ concept: Concept, _ container: Container, in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.addPath(squircle(in: container.rect))
        ctx.clip()
        ctx.drawLinearGradient(
            concept == .recording ? tileGradient() : duskGradient(),
            start: CGPoint(x: 0, y: iconDesignSize), end: CGPoint(x: 0, y: 0),
            options: []
        )
        // Light along the *top* edge only, as a short gradient inside the clip rather than a
        // stroke around the path. The stroke this replaces claimed the top edge in its comment
        // and in fact rang all four, which is the second rounded outline the eye was reading.
        let top = container.rect.maxY
        ctx.drawLinearGradient(
            topLight(),
            start: CGPoint(x: 0, y: top),
            end: CGPoint(x: 0, y: top - container.side * 0.16),
            options: []
        )
        ctx.restoreGState()
    }

    /// The container shape: a superellipse, not a rounded rectangle.
    ///
    /// macOS 26's icon shape is a continuous curve — there is no point where a straight edge
    /// hands over to a circular arc, which is exactly the join that makes a `CGPath`
    /// rounded-rect tile look like a sticker. |x|ⁿ + |y|ⁿ = 1 with n = 5 is that curve to
    /// within a pixel at 1024, and it is four lines of CoreGraphics instead of a table of
    /// bezier constants.
    static func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2
        let b = rect.height / 2
        let steps = 512
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let c = cos(t)
            let s = sin(t)
            let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
            let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }

    /// White, fading to nothing: the edge treatment that gives the container a lit top without
    /// drawing a second outline around it.
    private static func topLight() -> CGGradient {
        CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(colorSpace: sRGB, components: [1, 1, 1, 0.20])!,
                CGColor(colorSpace: sRGB, components: [1, 1, 1, 0])!,
            ] as CFArray,
            locations: [0, 1]
        )!
    }

    /// The reader's palette (`Theme` in the app target), as CoreGraphics colours, because
    /// `WorklensCore` cannot see SwiftUI. The icon uses it so the Dock tile and the window it
    /// opens are the same ivory and the same terracotta.
    public enum Palette {
        /// #FAF9F5, the page.
        public static let ivory = rgb(0xFA, 0xF9, 0xF5)
        /// #F0EEE6, the rail.
        public static let stone = rgb(0xF0, 0xEE, 0xE6)
        /// #141413, text.
        public static let ink = rgb(0x14, 0x14, 0x13)
        /// #73726C, secondary text.
        public static let muted = rgb(0x73, 0x72, 0x6C)
        /// #D97757, the accent.
        public static let terracotta = rgb(0xD9, 0x77, 0x57)

        private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
            CGColor(colorSpace: sRGB, components: [
                CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1,
            ])!
        }
    }

    /// Ivory at the top to the rail's stone at the bottom: both are colours the app already
    /// uses, and the step between them is what keeps an ivory tile from dissolving into a light
    /// Dock. Drawn top to bottom.
    ///
    /// Public because the social card draws it too (`scripts/render-icon.sh --banner`) over a
    /// 1280×640 rectangle instead of the tile. Declaring the stops in both places is how a card
    /// ends up a different colour from the icon beside it.
    public static func tileGradient() -> CGGradient {
        CGGradient(
            colorsSpace: sRGB, colors: [Palette.ivory, Palette.stone] as CFArray,
            locations: [0, 1]
        )!
    }

    /// The dusk gradient the lens concepts were drawn on, kept so they still render as judged.
    private static func duskGradient() -> CGGradient {
        CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(colorSpace: sRGB, components: [0.353, 0.408, 0.886, 1])!,
                CGColor(colorSpace: sRGB, components: [0.180, 0.204, 0.545, 1])!,
            ] as CFArray,
            locations: [0, 1]
        )!
    }

    private static let iconCenter = CGPoint(x: 512, y: 512)

    /// Ring and dot in the proportions of the rail's `lensMark` (a 15 pt ring, 2.2 pt stroke,
    /// 5.2 pt dot), sized so the ring's outer edge spans about 60 % of the old 824 pt tile —
    /// the space the concept the owner picked leaves around it. The stroke is 63 pt, which is
    /// still a full pixel on the 16 px tile, so no size needs a simpler version.
    private static func drawRecording(in ctx: CGContext) {
        let unit: CGFloat = 247 / (7.5 + 1.1)
        ctx.setLineWidth(2.2 * unit)
        ctx.addArc(
            center: iconCenter, radius: 7.5 * unit,
            startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        ctx.strokePath()
        ctx.fillEllipse(in: square(around: iconCenter, radius: 2.6 * unit))
    }

    /// Ring and dot — the menu-bar glyph at icon scale.
    private static func drawSimpleMark(in ctx: CGContext) {
        ctx.setLineWidth(76)
        ctx.addArc(
            center: iconCenter, radius: 232, startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        ctx.strokePath()
        ctx.fillEllipse(in: square(around: iconCenter, radius: 74))
    }

    /// The chosen mark: the lens ring holding four bars of a day.
    private static func drawLensTimeline(in ctx: CGContext) {
        ctx.setLineWidth(64)
        ctx.addArc(
            center: iconCenter, radius: 250, startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        ctx.strokePath()

        let heights: [CGFloat] = [104, 196, 148, 248]
        let width: CGFloat = 44
        let gap: CGFloat = 34
        let span = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
        let baseline = iconCenter.y - 125
        var x = iconCenter.x - span / 2
        for height in heights {
            ctx.addPath(bar(x: x + width / 2, y: baseline + height / 2, width: width, height: height))
            x += width + gap
        }
        ctx.fillPath()
    }

    /// A six-bladed iris: a hexagonal opening with a blade swept off each vertex.
    private static func drawAperture(in ctx: CGContext) {
        ctx.setLineWidth(64)
        ctx.addArc(
            center: iconCenter, radius: 250, startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        ctx.strokePath()

        let opening: CGFloat = 86
        let reach: CGFloat = 198
        let sweep: CGFloat = 52 * .pi / 180
        ctx.setLineWidth(40)
        for blade in 0..<6 {
            let a = (CGFloat(blade) * 60 + 30) * .pi / 180
            ctx.move(to: CGPoint(
                x: iconCenter.x + cos(a) * opening, y: iconCenter.y + sin(a) * opening
            ))
            ctx.addLine(to: CGPoint(
                x: iconCenter.x + cos(a + sweep) * reach,
                y: iconCenter.y + sin(a + sweep) * reach
            ))
        }
        ctx.strokePath()
    }

    /// A W whose strokes are the bars of a week.
    private static func drawWTimeline(in ctx: CGContext) {
        ctx.setLineWidth(84)
        let top: CGFloat = 700
        let bottom: CGFloat = 380
        let points = [
            CGPoint(x: 292, y: top),
            CGPoint(x: 402, y: bottom),
            CGPoint(x: 512, y: 618),
            CGPoint(x: 622, y: bottom),
            CGPoint(x: 732, y: top),
        ]
        ctx.move(to: points[0])
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()

        ctx.setLineWidth(36)
        ctx.move(to: CGPoint(x: 292, y: 276))
        ctx.addLine(to: CGPoint(x: 732, y: 276))
        ctx.strokePath()
    }
}
