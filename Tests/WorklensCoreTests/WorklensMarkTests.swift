import CoreGraphics
import Foundation
import Testing

@testable import WorklensCore

/// The goldens behind the drawing, which until #238 had none.
///
/// `AppIconTests` asks whether the `.iconset` is complete; this asks whether the shapes inside
/// it are still shapes. Every number here was recorded from this file's own output on the
/// commit that introduced it: a deliberate redraw is expected to move them, and the diff is
/// then the record of what changed. What they are guarding against is the three ways drawing
/// code fails quietly — a badge that renders blank (which `MenuBarGlyph.swift:40` catches at
/// runtime and nothing catches before that), a badge that drifts into the shape of its
/// neighbour, and a badge that grows past the ring it is supposed to sit inside.
///
/// Rendered into an alpha-only context on purpose: a menu-bar template image *is* its alpha
/// channel — AppKit picks the colour — so alpha is exactly what the menu bar will light up.
@Suite("Worklens mark")
struct WorklensMarkTests {
    // MARK: - Measuring a drawing

    /// One rendered glyph or icon, as coverage numbers.
    struct Bitmap {
        let side: Int
        let alpha: [Double]

        /// Mean alpha over the whole canvas: how much ink the badge puts down.
        var coverage: Double { alpha.reduce(0, +) / Double(alpha.count) }

        /// The box the ink actually occupies, in points on the 18 pt design square.
        var boundsInPoints: CGRect? {
            var minX = side, minY = side, maxX = -1, maxY = -1
            for y in 0..<side {
                for x in 0..<side where alpha[y * side + x] > 0.02 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            let scale = WorklensMark.glyphDesignSize / CGFloat(side)
            return CGRect(
                x: CGFloat(minX) * scale, y: CGFloat(minY) * scale,
                width: CGFloat(maxX + 1 - minX) * scale, height: CGFloat(maxY + 1 - minY) * scale
            )
        }

        /// Mean alpha inside a disc of `radius` points around the centre. This is what tells a
        /// filled lens from an open one; total coverage cannot, because a ring and a disc of
        /// the right sizes put down the same amount of ink.
        func centreCoverage(radius: CGFloat) -> Double {
            let mid = Double(side) / 2
            let r = Double(radius) * Double(side) / Double(WorklensMark.glyphDesignSize)
            var sum = 0.0
            var count = 0
            for y in 0..<side {
                for x in 0..<side {
                    let dx = Double(x) + 0.5 - mid
                    let dy = Double(y) + 0.5 - mid
                    guard dx * dx + dy * dy <= r * r else { continue }
                    sum += alpha[y * side + x]
                    count += 1
                }
            }
            return count == 0 ? 0 : sum / Double(count)
        }

        /// The fraction of pixels where two drawings disagree — the cheapest "these are not the
        /// same silhouette" there is.
        func fractionDiffering(from other: Bitmap) -> Double {
            precondition(side == other.side)
            var differing = 0
            for index in 0..<alpha.count where abs(alpha[index] - other.alpha[index]) > 0.25 {
                differing += 1
            }
            return Double(differing) / Double(alpha.count)
        }
    }

    static func render(_ badge: WorklensMark.Badge, busy: Bool = false, side: Int) -> Bitmap {
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { Issue.record("no \(side)×\(side) bitmap"); return Bitmap(side: 0, alpha: []) }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        WorklensMark.drawGlyph(badge, busy: busy, in: ctx, size: CGFloat(side))
        return Bitmap(side: side, alpha: read(ctx, side: side, stride: 1, offset: 0))
    }

    static func renderIcon(_ container: WorklensMark.Container, pixels: Int) -> Bitmap {
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { Issue.record("no \(pixels)² bitmap"); return Bitmap(side: 0, alpha: []) }
        WorklensMark.drawAppIcon(
            WorklensMark.chosen, container: container, in: ctx, pixels: CGFloat(pixels)
        )
        return Bitmap(side: pixels, alpha: read(ctx, side: pixels, stride: 4, offset: 3))
    }

    private static func read(_ ctx: CGContext, side: Int, stride: Int, offset: Int) -> [Double] {
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var out = [Double]()
        out.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                out.append(Double(base[y * ctx.bytesPerRow + x * stride + offset]) / 255)
            }
        }
        return out
    }

    // MARK: - The recorded bands

    /// Mean alpha over the 18 pt square, recorded at 1× and 2× — they agree to three decimals,
    /// which is itself the check that the glyph is resolution-independent.
    static let recorded: [WorklensMark.Badge: Double] = [
        .dot: 0.265, .hollow: 0.273, .pause: 0.259, .slash: 0.263,
        .dash: 0.233, .alert: 0.237, .pauseTimed: 0.185,
    ]
    /// How far a redraw may move a badge's coverage before this test wants to hear about it.
    static let band = 0.015

    // MARK: - The badges

    @Test("every badge draws, at menu-bar size and at 2×", arguments: WorklensMark.Badge.allCases)
    func badgeDraws(_ badge: WorklensMark.Badge) throws {
        for side in [18, 36] {
            let bitmap = Self.render(badge, side: side)
            let recorded = try #require(Self.recorded[badge])
            // Never blank: the failure `MenuBarGlyph`'s guard exists for.
            #expect(bitmap.coverage > 0.05, "\(badge) at \(side) drew almost nothing")
            #expect(
                abs(bitmap.coverage - recorded) < Self.band,
                "\(badge) at \(side) covers \(bitmap.coverage), recorded \(recorded)"
            )

            // Inside the ring: the whole point of #238's padding is that nothing reaches the
            // edge of the 18 pt square any more. `.slash`'s round cap is the one thing allowed
            // past the ring's outer edge, and half a cap is all it gets.
            let bounds = try #require(bitmap.boundsInPoints)
            let reach = WorklensMark.ringOuterRadius + 0.9
            let allowed = CGRect(
                x: 9 - reach, y: 9 - reach, width: reach * 2, height: reach * 2
            )
            #expect(allowed.contains(bounds), "\(badge) at \(side) drew \(bounds)")
        }
    }

    /// The bug #238 was filed over: at 18 pt `.hollow` was a 3.9 pt ring at 1.25 pt of stroke
    /// and `.dot` a 5 pt disc, so "over budget — capturing, not describing" read as healthy
    /// capture. Total coverage cannot tell them apart (0.265 against 0.273 today, which is why
    /// this is not that assertion); the hole can, and the hole is the meaning.
    @Test("the open lens and the filled one cannot converge")
    func hollowIsNotDot() {
        let radius: CGFloat = 1.2
        let dot = Self.render(.dot, side: 36).centreCoverage(radius: radius)
        let hollow = Self.render(.hollow, side: 36).centreCoverage(radius: radius)
        #expect(dot > 0.95, "`.dot` is meant to be solid at the centre, measured \(dot)")
        #expect(hollow < 0.05, "`.hollow` is meant to be empty at the centre, measured \(hollow)")
        #expect(dot - hollow > 0.75, "margin \(dot - hollow) is too small to see at 18 pt")
    }

    @Test("no two badges draw the same silhouette")
    func badgesDiffer() {
        let rendered = WorklensMark.Badge.allCases.map { ($0, Self.render($0, side: 36)) }
        for (index, left) in rendered.enumerated() {
            for right in rendered.dropFirst(index + 1) {
                let difference = left.1.fractionDiffering(from: right.1)
                #expect(
                    difference > 0.025,
                    "\(left.0) and \(right.0) differ on only \(difference) of their pixels"
                )
            }
        }
    }

    /// #252: the two pauses are the same two bars, and the menu bar has to tell "off until I
    /// say so" from "back in twelve minutes" at 18 pt without a menu open.
    @Test("a timed pause does not draw the indefinite one")
    func timedPauseIsItsOwnShape() {
        let plain = Self.render(.pause, side: 36)
        let timed = Self.render(.pauseTimed, side: 36)
        let difference = plain.fractionDiffering(from: timed)
        #expect(difference > 0.025, "the two pauses differ on only \(difference) of their pixels")
    }

    /// #252: busy is a treatment over whatever the state drew, so a paused app writing a report
    /// still reads as paused. It has to show on every badge, and it has to stay in the square.
    @Test(
        "the busy treatment shows over every badge and stays inside the square",
        arguments: WorklensMark.Badge.allCases
    )
    func busyTreatment(_ badge: WorklensMark.Badge) throws {
        for side in [18, 36] {
            let plain = Self.render(badge, side: side)
            let busy = Self.render(badge, busy: true, side: side)
            let difference = plain.fractionDiffering(from: busy)
            #expect(
                difference > 0.02,
                "busy over \(badge) at \(side) moved only \(difference) of the pixels"
            )
            let bounds = try #require(busy.boundsInPoints)
            // The arc rides outside the ring, so it gets more room than a badge does — and
            // still stops 0.2 pt short of the 18 pt edge. One pixel of slack at each side,
            // because the bounds are measured in whole pixels.
            let slack = WorklensMark.glyphDesignSize / CGFloat(side)
            let allowed = CGRect(
                x: 0.2 - slack, y: 0.2 - slack,
                width: 17.6 + slack * 2, height: 17.6 + slack * 2
            )
            #expect(allowed.contains(bounds), "busy over \(badge) at \(side) drew \(bounds)")
        }
    }

    // MARK: - The icon

    /// One container, drawn by us, filling the canvas the way a macOS 26 icon does — and
    /// nothing outside it, which is what says the tile-inside-a-tile is gone.
    @Test("the icon fills one container and stops there", arguments: WorklensMark.Container.allCases)
    func iconContainer(_ container: WorklensMark.Container) {
        let bitmap = Self.renderIcon(container, pixels: 1024)
        let recorded = container == .fullBleed ? 0.950 : 0.787
        #expect(
            abs(bitmap.coverage - recorded) < 0.02,
            "\(container) covers \(bitmap.coverage), recorded \(recorded)"
        )
        // A superellipse leaves its corners clear, so full bleed still stops short of 1.0.
        #expect(bitmap.coverage < 0.97)
    }

    /// The share of an icon's pixels within a few steps of `color`, read as sRGB.
    static func share(of color: CGColor, inIconAt pixels: Int) -> Double {
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let target = color.components, let base = ctx.data?.assumingMemoryBound(to: UInt8.self)
        else { Issue.record("no \(pixels)² bitmap"); return 0 }
        WorklensMark.drawAppIcon(in: ctx, pixels: CGFloat(pixels))
        var hits = 0
        for y in 0..<pixels {
            for x in 0..<pixels {
                let offset = y * ctx.bytesPerRow + x * 4
                let close = (0..<3).allSatisfy {
                    abs(Double(base[offset + $0]) / 255 - Double(target[$0])) < 0.04
                }
                if close { hits += 1 }
            }
        }
        return Double(hits) / Double(pixels * pixels)
    }

    /// The recording mark is terracotta on ivory at every size the iconset carries, 16 px
    /// included: a tile that drew nothing, or drew in the old white, would still pass the
    /// container test above, and this one would not.
    @Test("the icon draws the terracotta lens at every size", arguments: [16, 32, 128, 1024])
    func recordingColour(_ pixels: Int) {
        let accent = Self.share(of: WorklensMark.Palette.terracotta, inIconAt: pixels)
        // At 16 px most of a 1 px stroke is an antialiased edge rather than the colour itself.
        let floor = pixels < 32 ? 0.03 : 0.08
        #expect(accent > floor && accent < 0.25, "terracotta covers \(accent) at \(pixels) px")
    }
}
